import Foundation
import Combine
import CoreAudio
import AppKit

/// Coalesces device and default-route changes, plus sleep/wake, without polling capture.
@MainActor
final class AudioDeviceWatcher: ObservableObject {
    private var properties: [AudioObjectPropertyAddress] = []
    private var observers: [NSObjectProtocol] = []
    private var refreshTask: Task<Void, Never>?
    private var callback: AudioObjectPropertyListenerBlock?
    var changed: (() -> Void)?
    var sleeping: (() -> Void)?
    var waking: (() -> Void)?

    func start() {
        guard callback == nil else { return }
        let callback: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.schedule() }
        }
        self.callback = callback
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice,
                         kAudioHardwarePropertyDefaultOutputDevice] {
            var property = AudioObjectPropertyAddress(mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                   &property, .main, callback) == noErr {
                properties.append(property)
            }
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.waking?()
                self?.schedule()
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleeping?() }
        })
    }

    private func schedule() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
            self?.changed?()
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        if let callback {
            for var property in properties {
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                        &property, .main, callback)
            }
        }
        properties.removeAll()
        callback = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
    }
}
