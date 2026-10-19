"""Conservative audio conditioning applied to each utterance before ASR.

Deliberately NOT noise suppression. Neural denoisers measurably lower transcription
accuracy and disproportionately clip accented speakers and the first words of short
utterances, which is precisely the workload here. These two steps are safe:

  * a high-pass filter, which removes HVAC rumble, footfall and handling noise that sit
    below the speech band and otherwise eat headroom;
  * gentle level normalisation, which helps quiet far-field audio without touching the
    spectral content the model relies on.

The high-pass is a hand-rolled biquad rather than scipy's ``butter``/``sosfilt``. scipy is
128 MB of the install payload and this was its only use in the whole backend.
"""

from __future__ import annotations

import math

import numpy as np

from .config import SAMPLE_RATE, Settings


def butterworth_highpass_biquad(cutoff_hz: float, sample_rate: int) -> tuple[float, ...]:
    """Second-order Butterworth high-pass, as normalised biquad coefficients.

    Equivalent to ``scipy.signal.butter(2, cutoff/(fs/2), btype="highpass")``. Butterworth
    is the maximally-flat case of the standard bilinear-transform biquad, which is Q=1/sqrt(2).
    Returns ``(b0, b1, b2, a1, a2)`` already divided through by a0.
    """
    w0 = 2.0 * math.pi * cutoff_hz / sample_rate
    cos_w0 = math.cos(w0)
    alpha = math.sin(w0) / (2.0 * (math.sqrt(2.0) / 2.0))

    b0 = (1.0 + cos_w0) / 2.0
    b1 = -(1.0 + cos_w0)
    b2 = (1.0 + cos_w0) / 2.0
    a0 = 1.0 + alpha
    a1 = -2.0 * cos_w0
    a2 = 1.0 - alpha

    return (b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0)


def apply_biquad(audio: np.ndarray, coeffs: tuple[float, ...]) -> np.ndarray:
    """Direct Form II transposed, matching scipy's ``sosfilt`` structure.

    State starts at zero on every call and is not retained between calls. That is
    deliberate: the previous implementation called ``sosfilt`` without ``zi``, so each
    utterance was filtered independently. Carrying state across utterances would change
    behaviour, and utterances are separated by silence anyway.

    An IIR recursion cannot be vectorised, so this is a Python loop — but it runs over
    ``tolist()`` rather than indexing the array, which avoids constructing a NumPy scalar
    per sample and is several times faster for the same arithmetic.
    """
    b0, b1, b2, a1, a2 = coeffs
    samples = audio.tolist()
    out = [0.0] * len(samples)
    s1 = 0.0
    s2 = 0.0
    for i, x in enumerate(samples):
        y = b0 * x + s1
        s1 = b1 * x - a1 * y + s2
        s2 = b2 * x - a2 * y
        out[i] = y
    return np.asarray(out, dtype=np.float32)


class AudioConditioner:
    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        self._coeffs: tuple[float, ...] | None = None
        if settings.highpass_hz > 0:
            self._coeffs = butterworth_highpass_biquad(settings.highpass_hz, SAMPLE_RATE)

    def __call__(self, audio: np.ndarray) -> np.ndarray:
        if audio.size == 0:
            return audio

        out = audio.astype(np.float32, copy=True)
        out -= float(out.mean())  # remove DC offset

        if self._coeffs is not None:
            out = apply_biquad(out, self._coeffs).astype(np.float32)

        target = self.settings.target_rms
        if target > 0:
            rms = float(np.sqrt(np.mean(np.square(out))))
            # Skip near-silence: amplifying it just raises the noise floor.
            if rms > 1e-4:
                gain = min(target / rms, self.settings.max_gain)
                if gain > 1.0:
                    out *= gain

        np.clip(out, -1.0, 1.0, out=out)
        return out


class StreamingAudioConditioner:
    """Causal filtering and smoothed gain. Published samples never change later.

    State is reset between capture sessions, not between partial decodes. Gain follows
    a 200 ms energy envelope, with a 50 ms attack and 500 ms release. The sample-wise
    state makes the result independent of the caller's chunk boundaries.
    """

    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        self._coeffs = (butterworth_highpass_biquad(settings.highpass_hz, SAMPLE_RATE)
                        if settings.highpass_hz > 0 else (1, 0, 0, 0, 0))
        self.reset()

    def reset(self) -> None:
        self._s1 = self._s2 = self._energy = 0.0
        self._gain = 1.0

    def __call__(self, audio: np.ndarray) -> np.ndarray:
        b0, b1, b2, a1, a2 = self._coeffs
        s1, s2, energy, gain = self._s1, self._s2, self._energy, self._gain
        envelope = 1 - math.exp(-1 / (SAMPLE_RATE * .2))
        attack = 1 - math.exp(-1 / (SAMPLE_RATE * .05))
        release = 1 - math.exp(-1 / (SAMPLE_RATE * .5))
        target, ceiling = self.settings.target_rms, self.settings.max_gain
        result = []
        for x in audio.tolist():
            y = b0 * x + s1
            s1 = b1 * x - a1 * y + s2
            s2 = b2 * x - a2 * y
            energy += envelope * (y * y - energy)
            rms = math.sqrt(max(0.0, energy))
            wanted = max(1.0, min(ceiling, target / rms)) if target > 0 and rms > 1e-4 else 1.0
            gain += (attack if wanted < gain else release) * (wanted - gain)
            result.append(max(-1.0, min(1.0, y * gain)))
        self._s1, self._s2, self._energy, self._gain = s1, s2, energy, gain
        return np.asarray(result, dtype=np.float32)
