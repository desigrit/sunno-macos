import Foundation
import SwiftUI

/// Switching the speech model, and surviving one that will not load.
///
/// Two problems live here, and they are the same problem seen from either end.
///
/// **A switch used to do nothing.** The engine reads its model once, at startup, and holds it
/// for the life of the process. Choosing a different one downloaded the weights and stopped
/// there: the radio moved, the download bar ran, and the engine carried on decoding with the
/// model it already had until the app was next launched. So a switch has to restart the
/// engine, exactly as a change of microphone does.
///
/// **A bad choice used to be permanent.** The preference was written the instant a row was
/// clicked, before anything had proved the model could load. A model that downloads and then
/// fails to load — out of memory on a large one, a half-written cache — became the model
/// launched on every subsequent start, and there was no way back from inside the app. So the
/// preference is committed only once the engine reports it running, and a failure falls back
/// to the last model that did work.
///
/// The Windows build states the rule in a comment worth repeating: a model that downloads but
/// fails to load "would otherwise become the choice reloaded on every future launch, turning
/// one bad switch into a crash loop with no way out from inside the app."
@MainActor
final class ModelSwitch: ObservableObject {

    /// The model being switched to, from the click until the engine confirms it. Drives the
    /// picker's busy state.
    @Published private(set) var pending: String?

    /// The last model the engine actually ran. The place to fall back to.
    private(set) var lastGood: String?

    /// True while recovering from a failed switch, so a fallback that also fails cannot
    /// bounce the app between two broken models forever.
    private var recovering = false

    /// Restart the engine on this model. Supplied by the app, which owns the engine.
    var restart: ((String) -> Void)?
    /// Say something in the banner.
    var notify: ((String, TranscriptStore.Problem.Severity) -> Void)?
    /// Write the preference. Called only when a model is confirmed running.
    var commit: ((String) -> Void)?

    /// The user picked a model. Nothing is persisted yet.
    ///
    /// Refused while another switch is in flight, and that refusal is load-bearing rather
    /// than tidiness. The engine's `ensure_model` early-returns when a download is already
    /// running and emits nothing at all, so a second pick produced no event of its own *and*
    /// caused the first pick's `download_complete` to be rejected here as stale. The result
    /// was a switch that never happened, a spinner that never stopped, and no way back
    /// without relaunching. The picker disables its rows to match, so this is a backstop
    /// rather than the only guard.
    @discardableResult
    func request(_ model: String, currentlyRunning: String?) -> Bool {
        guard pending == nil else { return false }
        if lastGood == nil { lastGood = currentlyRunning }
        pending = model
        return true
    }

    /// The weights are on disk. Now the engine has to be restarted onto them, because it
    /// only reads its model at startup.
    func downloadFinished(_ model: String) {
        guard pending == model else { return }
        restart?(model)
    }

    func downloadFailed(_ model: String) {
        guard pending == model else { return }
        pending = nil
        // The picker snaps back on its own, because it renders from the running model.
    }

    /// A status frame naming the model the engine is running.
    func engineReady(model: String) {
        lastGood = model
        recovering = false
        if pending == model {
            pending = nil
            commit?(model)
        }
    }

    /// The engine died. If it died on the way to a new model, that model is the suspect.
    ///
    /// Returns true when a fallback was started, so the caller knows the failure has been
    /// handled and should not also be reported as fatal.
    @discardableResult
    func engineFailed() -> Bool {
        guard let attempted = pending else { return false }
        pending = nil

        guard !recovering, let fallback = lastGood, fallback != attempted else {
            // Either the fallback itself just failed, or there is nothing to fall back to.
            // Say so plainly and stop, rather than restarting into the same wall.
            //
            // Cleared on the way out: leaving it set means a later switch, after the engine
            // has been brought back some other way, would take this branch while a perfectly
            // good `lastGood` was sitting there unused.
            recovering = false
            notify?("\(attempted) could not be loaded, and there is no other model to fall "
                    + "back to. Choose a different one.", .error)
            return false
        }

        recovering = true
        notify?("\(attempted) could not be loaded. Using \(fallback) instead.", .warning)
        restart?(fallback)
        return true
    }
}
