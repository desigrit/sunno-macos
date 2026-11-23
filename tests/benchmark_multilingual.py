"""Real reference speech, saved UTF-8 transcripts and wall-clock live caption timings."""
import argparse
from difflib import SequenceMatcher
import json
import os
from pathlib import Path
import platform
import sys
import tempfile
import time
import unicodedata

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from fleurs_samples import CONFIGS, accented_english, fetch
from server.config import FRAME_SAMPLES, SAMPLE_RATE, Settings
from server.pipeline import CaptionPipeline
from server.recorder import Recorder
from server.spoken_language import SpokenLanguage


def load_audio(path):
    import av
    with av.open(str(path)) as media:
        converter = av.AudioResampler(format="fltp", layout="mono", rate=SAMPLE_RATE)
        frames = [out.to_ndarray().ravel() for frame in media.decode(audio=0) for out in converter.resample(frame)]
        frames.extend(out.to_ndarray().ravel() for out in converter.resample(None))
    return np.concatenate(frames)


def download_whisperkit_fixture(model):
    from server.asr_whisperkit import WhisperKitServiceError, download_model, weights_root

    try:
        download_model(model)
    except WhisperKitServiceError as error:
        if "NSURLErrorDomain Code=-1001" not in str(error):
            raise
        # A slow CDN response can exceed the native client's timeout on a hosted Mac.
        # Fetch the same Core ML fixture before starting the timed native load.
        from huggingface_hub import snapshot_download

        repo = "argmaxinc/whisperkit-coreml"
        print(f"Native download timed out. Retrying the {model} fixture from the model repository.", flush=True)
        snapshot_download(repo, revision="0f63a7800b00dd0226abd051b906c246e1907482",
                          allow_patterns=f"openai_whisper-{model}/*",
                          local_dir=weights_root() / "models" / repo, max_workers=4)


def start_model(engine, cfg, download):
    if engine == "whisperkit":
        from server.asr_whisperkit import WhisperKitEngine
        factory = WhisperKitEngine
        download_model = download_whisperkit_fixture
    elif engine == "onnx":
        from server.asr_onnx import OnnxEngine
        from server.arm_whisper import download as download_model
        factory = OnnxEngine
    else:
        from server.asr import CTranslate2Engine
        from server.models import download as download_model
        factory = CTranslate2Engine
    if download:
        download_model(cfg.model_size)
    start = time.monotonic()
    model = factory(cfg)
    model.warmup()
    return model, round(time.monotonic() - start, 3)


def normalize(text):
    return "".join(c for c in unicodedata.normalize("NFKC", text).casefold()
                   if unicodedata.category(c)[0] in "LMN")


def trimmed(audio):
    loud = np.flatnonzero(abs(audio) > .015)
    return audio[loud[0]:loud[-1]+1] if len(loud) else audio


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--engine", choices=["ct2", "onnx", "whisperkit"], required=True)
    parser.add_argument("--fixtures", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--download", action="store_true")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory() as tmp:
        os.environ.setdefault("Sunno_DATA_DIR", tmp)
        cfg = Settings(model_size="base", language="en", device="cpu", compute_type="int8", enable_speakers=False)
        model, startup = start_model(args.engine, cfg, args.download)
        report = {"engine": args.engine, "machine": platform.machine(), "startup_s": startup, "captions": []}
        # Playback uses two English and Spanish clips. Hindi also checks two corrections.
        clips = {code: fetch(args.fixtures, code, count=2 if code in ("en", "es", "hi") else 1)
                 for code in CONFIGS}
        recorder = Recorder(Path(tmp) / "recordings")
        for index, (code, entries) in enumerate(clips.items()):
            wav, reference = entries[0]
            audio = load_audio(wav)
            model.set_language(code)
            result = model.final(audio)
            record = {"id": index, "started_at": recorder.started_at + index, "text": result.text, "language": code}
            recorder.add_line(record)
            guessed, confidence = model.detect_language(trimmed(audio)[:SAMPLE_RATE*5])
            score = SequenceMatcher(None, normalize(reference), normalize(result.text), autojunk=False).ratio()
            report["captions"].append(dict(language=code, reference=reference, caption=result.text,
                similarity=round(score, 3), detected=guessed, confidence=round(float(confidence), 3)))
            print(code, round(score, 2), guessed, flush=True)
            if code == "hi" and args.engine == "whisperkit":
                repeat = model.final(audio).text
                report["hindi_repeat_matches"] = normalize(repeat) == normalize(result.text)
                report["hindi_uses_devanagari"] = any("\u0900" <= letter <= "\u097f" for letter in result.text)
        path, reference, accent = accented_english()
        model.set_language("en")
        caption = model.final(load_audio(path)).text
        report["accented_english"] = dict(accent=accent, reference=reference, caption=caption,
            similarity=round(SequenceMatcher(None, normalize(reference), normalize(caption), autojunk=False).ratio(), 3))
        recorder.stop()
        stored = json.loads((recorder.folder / "transcript.json").read_text(encoding="utf-8"))["lines"]
        plain = (recorder.folder / "transcript.txt").read_text(encoding="utf-8")
        for ref, saved in zip(report["captions"], stored, strict=True):
            assert ref["caption"] and saved["text"] == ref["caption"] and saved["language"] == ref["language"]
            assert saved["text"] in plain

        events = []
        def emit(event):
            events.append((time.monotonic(), event))
        session = SpokenLanguage("base", "auto", emit)
        pipe = CaptionPipeline(cfg, model, emit, languages=session)
        # A continuous playback clock, with the fixture's leading silence trimmed. The
        # second English interval restores the baseline after a short Spanish insertion.
        spans = [("en", 0, 11), ("es", 0, 1.2), ("en", 1, 11), ("es", 0, 16), ("es", 1, 16)]
        timeline = []
        positions = []
        cursor = 0
        for code, index, seconds in spans:
            sample = trimmed(load_audio(clips[code][index][0]))[:int(seconds*SAMPLE_RATE)]
            positions.append(cursor / SAMPLE_RATE)
            timeline.extend((sample, np.zeros(SAMPLE_RATE, np.float32)))
            cursor += len(sample) + SAMPLE_RATE
        audio = np.concatenate(timeline)
        began = time.monotonic()
        def playback():
            for i in range(0, len(audio) - FRAME_SAMPLES + 1, FRAME_SAMPLES):
                time.sleep(max(0, began + (i + FRAME_SAMPLES) / SAMPLE_RATE - time.monotonic()))
                yield audio[i:i + FRAME_SAMPLES]
        try:
            pipe.run(playback())
            assert pipe.drain(timeout=90)
        finally:
            pipe.close()
        first = next((t-began for t,e in events if e["type"] in ("partial","final") and e.get("text")), None)
        detected = [(round(t-began,3),e["detected"]) for t,e in events if e["type"]=="spoken_language" and e.get("detected")]
        switch = next((t - positions[3] for t,code in detected if code=="es" and t >= positions[3]), None)
        premature = any(code=="es" and t<positions[3] for t,code in detected)
        report.update(first_caption_s=round(first,3) if first is not None else None,
                      language_changes=detected, brief_phrase_changed_language=premature,
                      sustained_switch_s=round(switch,3) if switch is not None else None)
        if args.engine == "whisperkit":
            from dataclasses import replace
            model.close()
            small, _ = start_model(args.engine, replace(cfg, model_size="small", language="hi"), args.download)
            try:
                report["hindi_small"] = []
                for wav, reference in clips["hi"]:
                    caption = small.final(load_audio(wav)).text
                    score = SequenceMatcher(None, normalize(reference), normalize(caption), autojunk=False).ratio()
                    report["hindi_small"].append(dict(reference=reference, caption=caption, similarity=round(score, 3)))
            finally:
                small.close()
        args.report.write_text(json.dumps(report, indent=2, ensure_ascii=False),encoding="utf-8")
        print(json.dumps({k:v for k,v in report.items() if k!="captions"}), flush=True)
        if args.engine == "whisperkit":
            assert all(item["similarity"] > .35 for item in report["hindi_small"]), "Small Hindi model lost the reference"
            assert report["hindi_repeat_matches"] and report["hindi_uses_devanagari"], "Hindi transcription changed across replays"
        assert report["accented_english"]["similarity"] > .35
        assert first is not None and switch is not None and not premature, "Live language switch check failed"
        assert all(row["similarity"] > .12 for row in report["captions"]), "Reference and caption disagree"


if __name__ == "__main__":
    main()

