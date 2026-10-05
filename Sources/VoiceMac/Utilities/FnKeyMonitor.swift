import AppKit
import Carbon.HIToolbox

/// Watches the Fn (Globe) key.
///
/// Fn cannot go through `RegisterEventHotKey` like the other shortcuts: it is
/// a modifier flag rather than a key with a registrable code, so it never
/// produces a key-down event. Instead it shows up as a `flagsChanged` event
/// carrying key code 63 (`kVK_Function`), with press and release distinguished
/// by whether the `.function` flag is still set.
///
/// Both press and release are reported so the caller can support tap-to-toggle
/// and hold-to-talk from the same key.
///
/// Requires Accessibility permission — without it the global monitor is
/// installed successfully but never fires, which is why `isOperational` is
/// checked and surfaced in Settings rather than failing silently.
@MainActor
final class FnKeyMonitor {
    /// `kVK_Function`. A `flagsChanged` event with this code is the Fn key
    /// itself, as opposed to the `.function` flag that arrow and F-keys also
    /// set on their own key events.
    private static let fnKeyCode: UInt16 = 63

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var pressedAt: ContinuousClock.Instant?

    private(set) var isDown = false

    var onPress: (() -> Void)?
    /// Called on release with how long the key was held.
    var onRelease: ((Duration) -> Void)?

    var isRunning: Bool { globalMonitor != nil }

    /// Fn detection needs Accessibility; report it so the UI can explain.
    var isOperational: Bool { AccessibilityManager.isTrusted }

    func start() {
        guard globalMonitor == nil else { return }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handle(event)
        }

        // A global monitor does not see events delivered to our own windows,
        // so Fn would stop working whenever Settings had focus.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handle(event)
            return event
        }

        if isOperational {
            log(.hotkey, "Fn (Globe) key monitor active")
        } else {
            log(.hotkey, "Fn monitor installed but inert — Accessibility permission not granted")
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        isDown = false
        pressedAt = nil
    }

    private func handle(_ event: NSEvent) {
        guard event.keyCode == Self.fnKeyCode else { return }

        let down = event.modifierFlags.contains(.function)
        guard down != isDown else { return }   // ignore repeats
        isDown = down

        if down {
            pressedAt = ContinuousClock.now
            onPress?()
        } else {
            let held = pressedAt.map { ContinuousClock.now - $0 } ?? .zero
            pressedAt = nil
            onRelease?(held)
        }
    }
}
