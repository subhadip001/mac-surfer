import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Apple Events and synthetic input — the lower two tiers of the automation
/// priority ladder (native API > Accessibility > Apple Events > key/mouse).
enum MouseClickKind: Sendable {
    case single, double, right
}

enum AppleEvents {

    // MARK: System volume (StandardAdditions, no automation permission needed)

    static func setOutputVolume(_ level: Int) throws {
        let clamped = max(0, min(100, level))
        // The script text is assembled from a validated integer only. No
        // caller-supplied or model-supplied string ever reaches here.
        try run("set volume output volume \(clamped)")
    }

    static func currentOutputVolume() -> Int? {
        guard let result = try? run("output volume of (get volume settings)") else { return nil }
        return result.int32Value == 0 ? Int(result.stringValue ?? "") : Int(result.int32Value)
    }

    static func setMuted(_ muted: Bool) throws {
        try run("set volume \(muted ? "with" : "without") output muted")
    }

    static func adjustVolume(by delta: Int) throws {
        let current = currentOutputVolume() ?? 50
        try setOutputVolume(current + delta)
    }

    @discardableResult
    private static func run(_ source: String) throws -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: source) else {
            throw ActionError.executionFailed("could not compile Apple Event")
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "unknown"
            throw ActionError.executionFailed("Apple Event failed: \(message)")
        }
        return result
    }

    // MARK: Synthetic keyboard input (last resort)

    /// Key codes for keys a user can name out loud.
    private static let namedKeys: [String: CGKeyCode] = [
        "return": CGKeyCode(kVK_Return), "enter": CGKeyCode(kVK_Return),
        "tab": CGKeyCode(kVK_Tab), "space": CGKeyCode(kVK_Space),
        "delete": CGKeyCode(kVK_Delete), "backspace": CGKeyCode(kVK_Delete),
        "escape": CGKeyCode(kVK_Escape), "esc": CGKeyCode(kVK_Escape),
        "up": CGKeyCode(kVK_UpArrow), "down": CGKeyCode(kVK_DownArrow),
        "left": CGKeyCode(kVK_LeftArrow), "right": CGKeyCode(kVK_RightArrow),
        "home": CGKeyCode(kVK_Home), "end": CGKeyCode(kVK_End),
        "pageup": CGKeyCode(kVK_PageUp), "pagedown": CGKeyCode(kVK_PageDown),
        "a": CGKeyCode(kVK_ANSI_A), "c": CGKeyCode(kVK_ANSI_C),
        "f": CGKeyCode(kVK_ANSI_F), "k": CGKeyCode(kVK_ANSI_K),
        "l": CGKeyCode(kVK_ANSI_L), "n": CGKeyCode(kVK_ANSI_N),
        "s": CGKeyCode(kVK_ANSI_S), "t": CGKeyCode(kVK_ANSI_T),
        "v": CGKeyCode(kVK_ANSI_V), "w": CGKeyCode(kVK_ANSI_W),
        "x": CGKeyCode(kVK_ANSI_X), "z": CGKeyCode(kVK_ANSI_Z),
    ]

    /// Parses a spoken shortcut like "command s" or "control option f".
    static func parseShortcut(_ spoken: String) -> (key: CGKeyCode, flags: CGEventFlags)? {
        let words = Fuzzy.normalize(spoken).split(separator: " ").map(String.init)
        var flags: CGEventFlags = []
        var key: CGKeyCode?

        for word in words {
            switch word {
            case "command", "cmd", "apple": flags.insert(.maskCommand)
            case "control", "ctrl": flags.insert(.maskControl)
            case "option", "alt": flags.insert(.maskAlternate)
            case "shift": flags.insert(.maskShift)
            case "key", "the", "button": continue
            default:
                if let code = namedKeys[word] { key = code }
            }
        }
        guard let key else { return nil }
        return (key, flags)
    }

    static func pressKey(_ key: CGKeyCode, flags: CGEventFlags = []) throws {
        guard AXIsProcessTrusted() else { throw ActionError.accessibilityPermissionRequired }
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw ActionError.executionFailed("could not create event source")
        }

        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// Types a string by posting unicode key events. Only used when the
    /// Accessibility API could not set the field's value directly.
    static func type(_ text: String) throws {
        guard AXIsProcessTrusted() else { throw ActionError.accessibilityPermissionRequired }
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw ActionError.executionFailed("could not create event source")
        }

        for character in text.unicodeScalars {
            var utf16 = Array(String(character).utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { continue }
            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    // MARK: Mouse

    /// Click at a screen point. Used when a control does not implement
    /// `AXPress`, and for explicit coordinate clicks.
    static func click(at point: CGPoint, kind: MouseClickKind) throws {
        guard AXIsProcessTrusted() else { throw ActionError.accessibilityPermissionRequired }
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw ActionError.executionFailed("could not create event source")
        }

        let (downType, upType, button): (CGEventType, CGEventType, CGMouseButton) =
            kind == .right
                ? (.rightMouseDown, .rightMouseUp, .right)
                : (.leftMouseDown, .leftMouseUp, .left)

        // Move first: many apps only update hover state on a real move, and
        // will ignore a click that arrives without one.
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)

        let clickCount = kind == .double ? 2 : 1
        for click in 1...clickCount {
            guard let down = CGEvent(mouseEventSource: source, mouseType: downType,
                                      mouseCursorPosition: point, mouseButton: button),
                  let up = CGEvent(mouseEventSource: source, mouseType: upType,
                                    mouseCursorPosition: point, mouseButton: button)
            else { continue }
            // The click count field is what distinguishes a double-click from
            // two separate clicks.
            down.setIntegerValueField(.mouseEventClickState, value: Int64(click))
            up.setIntegerValueField(.mouseEventClickState, value: Int64(click))
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    static func scroll(direction: String) throws {
        guard AXIsProcessTrusted() else { throw ActionError.accessibilityPermissionRequired }

        switch direction {
        case "top":
            try pressKey(CGKeyCode(kVK_Home), flags: .maskCommand)
            return
        case "bottom":
            try pressKey(CGKeyCode(kVK_End), flags: .maskCommand)
            return
        default:
            break
        }

        let amount: Int32 = direction == "up" ? 10 : -10
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let event = CGEvent(scrollWheelEvent2Source: source,
                                   units: .line,
                                   wheelCount: 1,
                                   wheel1: amount, wheel2: 0, wheel3: 0) else {
            throw ActionError.executionFailed("could not create scroll event")
        }
        event.post(tap: .cghidEventTap)
    }

    // MARK: Screenshot

    /// Captures the screen to ~/Desktop.
    ///
    /// `screencapture` is invoked rather than ScreenCaptureKit because it
    /// handles the Screen Recording permission prompt itself. The executable
    /// path and every argument are compile-time constants — no part of this
    /// command line comes from a transcript or a model.
    static func captureScreen() throws -> URL {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser

        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        let name = "VoiceMac-\(Int(Date().timeIntervalSince1970)).png"
        let destination = desktop.appendingPathComponent(name)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", destination.path]

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ActionError.executionFailed(
                "screencapture failed — Screen Recording permission may be required"
            )
        }
        return destination
    }
}
