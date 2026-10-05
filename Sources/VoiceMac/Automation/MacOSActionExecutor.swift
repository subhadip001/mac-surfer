import AppKit
import Carbon.HIToolbox
import Foundation

/// Performs validated actions. Replaceable so the pipeline can be tested
/// against a recording executor.
protocol ActionExecutorProtocol: Sendable {
    /// Returns a short human-readable result for the overlay.
    func execute(_ action: ActionRequest) async throws -> String
}

/// The only code in the app that actually touches the system.
///
/// Automation priority, highest first:
///   1. Native API (`NSWorkspace`) — launching, focusing, opening URLs
///   2. Accessibility API — clicking and typing into real controls
///   3. Apple Events — system volume
///   4. Synthetic key/mouse events — fallback only
actor MacOSActionExecutor: ActionExecutorProtocol {
    private let registry: ApplicationRegistry
    private let accessibility: AccessibilityManager
    private var searchEngine: SearchEngine

    /// Bundle ids of apps we opened this session, so a dependent search can be
    /// routed into the browser the user actually asked for.
    private var lastOpenedBundleID: String?

    init(registry: ApplicationRegistry,
         accessibility: AccessibilityManager,
         searchEngine: SearchEngine) {
        self.registry = registry
        self.accessibility = accessibility
        self.searchEngine = searchEngine
    }

    func execute(_ action: ActionRequest) async throws -> String {
        log(.executor, "executing \(action.type.rawValue) \(action.parameters)")

        switch action.type {
        case .openApp:   return try await openApp(action)
        case .focusApp:  return try await focusApp(action)
        case .closeApp:  return try await closeApp(action)
        case .openURL:   return try await openURL(action)
        case .searchWeb: return try await searchWeb(action)
        case .searchInApp: return try await searchInApp(action)
        case .click:       return try await click(action, kind: .single)
        case .doubleClick: return try await click(action, kind: .double)
        case .rightClick:  return try await click(action, kind: .right)
        case .clickAt:     return try clickAt(action)
        case .focusElement: return try await focusElement(action)
        case .menuCommand: return try await menuCommand(action)
        case .clearField:  return try await clearField(action)
        case .typeText:  return try await typeText(action)
        case .pressKey:  return try pressKey(action)
        case .scroll:    return try scroll(action)
        case .screenshot: return try screenshot()
        case .setVolume: return try setVolume(action)
        case .mute:      try AppleEvents.setMuted(true); return "Muted"
        case .unmute:    try AppleEvents.setMuted(false); return "Unmuted"
        case .copy:      try AppleEvents.pressKey(CGKeyCode(kVK_ANSI_C), flags: .maskCommand); return "Copied"
        case .paste:     try AppleEvents.pressKey(CGKeyCode(kVK_ANSI_V), flags: .maskCommand); return "Pasted"
        case .sendMessage:
            // Reaching here means the confirmation gate approved it, but there
            // is no generic "send" primitive — it is app specific.
            throw ActionError.unsupported("sending messages (needs per-app support)")
        }
    }

    /// Bundle id of the most recently opened app — used to target a dependent
    /// search at the right browser.
    func mostRecentlyOpenedBundleID() -> String? { lastOpenedBundleID }

    func updateSearchEngine(_ engine: SearchEngine) { searchEngine = engine }

    /// Clears per-session state so a new command does not inherit the previous
    /// session's browser target.
    func resetSession() { lastOpenedBundleID = nil }

    // MARK: Applications

    private func openApp(_ action: ActionRequest) async throws -> String {
        guard let spoken = action.parameters["app"], !spoken.isEmpty else {
            throw ActionError.missingParameter("app")
        }

        guard let app = await registry.resolve(spoken) else {
            // "open youtube" is a website, not an app.
            if let fallback = action.parameters["urlFallback"],
               let url = URL(string: fallback) {
                NSWorkspace.shared.open(url)
                return "Opened \(url.host ?? fallback)"
            }
            throw ActionError.applicationNotFound(spoken)
        }

        // Already running: activating is instant, relaunching is not.
        if let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: app.bundleIdentifier).first {
            running.activate(options: [])
            lastOpenedBundleID = app.bundleIdentifier
            return "Focused \(app.name)"
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: app.url,
                                                          configuration: configuration)
        lastOpenedBundleID = app.bundleIdentifier
        return "Opened \(app.name)"
    }

    private func focusApp(_ action: ActionRequest) async throws -> String {
        guard let spoken = action.parameters["app"], !spoken.isEmpty else {
            throw ActionError.missingParameter("app")
        }
        guard let app = await registry.resolve(spoken) else {
            throw ActionError.applicationNotFound(spoken)
        }

        if let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: app.bundleIdentifier).first {
            running.activate(options: [])
            lastOpenedBundleID = app.bundleIdentifier
            return "Focused \(app.name)"
        }
        // Not running — focusing something that does not exist yet means launching it.
        return try await openApp(action)
    }

    private func closeApp(_ action: ActionRequest) async throws -> String {
        guard let spoken = action.parameters["app"], !spoken.isEmpty else {
            throw ActionError.missingParameter("app")
        }
        guard let app = await registry.resolve(spoken) else {
            throw ActionError.applicationNotFound(spoken)
        }
        let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: app.bundleIdentifier)
        guard !running.isEmpty else { return "\(app.name) is not running" }

        for instance in running { instance.terminate() }
        return "Quit \(app.name)"
    }

    // MARK: URLs and search

    private func openURL(_ action: ActionRequest) async throws -> String {
        guard let raw = action.parameters["url"], let url = URL(string: raw) else {
            throw ActionError.missingParameter("url")
        }
        try await open(url, preferredBundleID: action.parameters["bundleID"])
        return "Opened \(url.host ?? raw)"
    }

    private func searchWeb(_ action: ActionRequest) async throws -> String {
        guard let query = action.parameters["query"], !query.isEmpty else {
            throw ActionError.missingParameter("query")
        }
        guard let url = searchEngine.url(for: query) else {
            throw ActionError.executionFailed("could not build a search URL")
        }

        // Route into the browser this clause depends on, so "open chrome and
        // search ..." searches in Chrome rather than the default browser.
        let preferred = action.parameters["bundleID"] ?? lastOpenedBundleID
        try await open(url, preferredBundleID: preferred)
        return "Searched for \"\(query)\""
    }

    private func open(_ url: URL, preferredBundleID: String?) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        if let bundleID = preferredBundleID,
           let app = await registry.application(bundleIdentifier: bundleID) {
            do {
                _ = try await NSWorkspace.shared.open([url],
                                                       withApplicationAt: app.url,
                                                       configuration: configuration)
                return
            } catch {
                log(.executor, "could not open URL in \(app.name), falling back to default browser")
            }
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: Accessibility-driven actions

    private func searchInApp(_ action: ActionRequest) async throws -> String {
        guard let query = action.parameters["query"], !query.isEmpty else {
            throw ActionError.missingParameter("query")
        }
        guard AccessibilityManager.isTrusted else {
            throw ActionError.accessibilityPermissionRequired
        }

        let snapshot = await accessibility.snapshotFrontmost()
        guard !snapshot.application.isEmpty else {
            throw ActionError.executionFailed("no frontmost application to search in")
        }

        // Prefer a real search field in the window.
        let searchField = await accessibility.relevantElements(
            for: "search", in: snapshot, limit: 3, threshold: 0.5
        ).first { $0.role == kAXTextFieldRole || $0.role == kAXComboBoxRole }

        if let searchField {
            try await accessibility.focus(searchField.id)
            try await accessibility.setValue(query, on: searchField.id)
            try AppleEvents.pressKey(CGKeyCode(kVK_Return))
            return "Searched \(snapshot.application) for \"\(query)\""
        }

        // Fall back to the app's own find affordance.
        try AppleEvents.pressKey(CGKeyCode(kVK_ANSI_F), flags: .maskCommand)
        try await Task.sleep(for: .milliseconds(120))
        try AppleEvents.type(query)
        return "Searched \(snapshot.application) for \"\(query)\" via Find"
    }

    /// Roles that count as "a button" when the user says "click the X button".
    private static let clickableRoles: Set<String> = [
        kAXButtonRole, kAXMenuItemRole, kAXMenuButtonRole, kAXCheckBoxRole,
        kAXRadioButtonRole, kAXPopUpButtonRole, AccessibilityManager.axLinkRole,
        kAXDisclosureTriangleRole, kAXCellRole, kAXRowRole,
    ]

    private static let textRoles: Set<String> = [
        kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole,
    ]

    private func click(_ action: ActionRequest, kind: MouseClickKind) async throws -> String {
        guard AccessibilityManager.isTrusted else {
            throw ActionError.accessibilityPermissionRequired
        }
        guard let target = action.parameters["target"], !target.isEmpty else {
            throw ActionError.missingParameter("target")
        }

        let verb = kind == .double ? "Double-clicked" : kind == .right ? "Right-clicked" : "Clicked"

        // An element id resolved by the planner takes precedence over the label.
        if let elementID = action.parameters["elementID"],
           await accessibility.hasHandle(elementID) {
            try await accessibility.clickElement(elementID, kind: kind)
            return "\(verb) \(target)"
        }

        let ordinal = action.parameters["ordinal"].flatMap(Int.init)
        let preferRole: Set<String> = action.parameters["role"] == "button"
            ? Self.clickableRoles
            : []

        let snapshot = await accessibility.snapshotFrontmost()
        guard let element = await accessibility.bestMatch(for: target,
                                                           in: snapshot,
                                                           preferredRoles: preferRole,
                                                           ordinal: ordinal) else {
            // Falling back to the menu bar makes "click save as" work even when
            // the command has no on-screen button.
            if kind == .single,
               let command = await accessibility.findMenuCommand(target, inMenu: nil) {
                try await accessibility.runMenuCommand(command)
                return "Ran \(command.displayPath)"
            }
            throw ActionError.elementNotFound(target)
        }

        try await accessibility.clickElement(element.id, kind: kind)
        return "\(verb) \(element.label)"
    }

    private func clickAt(_ action: ActionRequest) throws -> String {
        guard AccessibilityManager.isTrusted else {
            throw ActionError.accessibilityPermissionRequired
        }
        guard let x = action.parameters["x"].flatMap(Double.init),
              let y = action.parameters["y"].flatMap(Double.init) else {
            throw ActionError.missingParameter("x and y")
        }
        try AppleEvents.click(at: CGPoint(x: x, y: y), kind: .single)
        return "Clicked at \(Int(x)), \(Int(y))"
    }

    private func focusElement(_ action: ActionRequest) async throws -> String {
        guard AccessibilityManager.isTrusted else {
            throw ActionError.accessibilityPermissionRequired
        }
        guard let target = action.parameters["target"], !target.isEmpty else {
            throw ActionError.missingParameter("target")
        }

        let snapshot = await accessibility.snapshotFrontmost()
        guard let element = await accessibility.bestMatch(for: target,
                                                           in: snapshot,
                                                           preferredRoles: Self.textRoles) else {
            throw ActionError.elementNotFound(target)
        }

        do {
            try await accessibility.focus(element.id)
        } catch {
            // Some controls only take focus from a real click.
            try await accessibility.clickElement(element.id, kind: .single)
        }
        return "Focused \(element.label)"
    }

    private func menuCommand(_ action: ActionRequest) async throws -> String {
        guard AccessibilityManager.isTrusted else {
            throw ActionError.accessibilityPermissionRequired
        }
        guard let command = action.parameters["command"], !command.isEmpty else {
            throw ActionError.missingParameter("command")
        }

        let menu = action.parameters["menu"]
        guard let match = await accessibility.findMenuCommand(command, inMenu: menu) else {
            throw ActionError.elementNotFound(
                menu.map { "\(command) in the \($0) menu" } ?? "\(command) in the menu bar"
            )
        }
        try await accessibility.runMenuCommand(match)
        return "Ran \(match.displayPath)"
    }

    private func clearField(_ action: ActionRequest) async throws -> String {
        guard AccessibilityManager.isTrusted else {
            throw ActionError.accessibilityPermissionRequired
        }

        let snapshot = await accessibility.snapshotFrontmost()
        let element: AXElementSnapshot?
        if let target = action.parameters["target"], !target.isEmpty {
            element = await accessibility.bestMatch(for: target,
                                                     in: snapshot,
                                                     preferredRoles: Self.textRoles)
        } else {
            element = await accessibility.preferredTextField(in: snapshot)
        }

        guard let element else {
            throw ActionError.elementNotFound(action.parameters["target"] ?? "a text field")
        }

        try? await accessibility.focus(element.id)
        do {
            try await accessibility.clearValue(on: element.id)
        } catch {
            // Read-only AXValue: select all and delete instead.
            try AppleEvents.pressKey(CGKeyCode(kVK_ANSI_A), flags: .maskCommand)
            try AppleEvents.pressKey(CGKeyCode(kVK_Delete))
        }
        return "Cleared \(element.label)"
    }

    private func typeText(_ action: ActionRequest) async throws -> String {
        guard let text = action.parameters["text"], !text.isEmpty else {
            throw ActionError.missingParameter("text")
        }
        guard AccessibilityManager.isTrusted else {
            throw ActionError.accessibilityPermissionRequired
        }

        let snapshot = await accessibility.snapshotFrontmost()

        // "type hello in the message box" targets a named field; plain
        // "type hello" goes wherever the focus already is.
        var field: AXElementSnapshot?
        if let target = action.parameters["target"], !target.isEmpty {
            field = await accessibility.bestMatch(for: target,
                                                   in: snapshot,
                                                   preferredRoles: Self.textRoles)
            if field == nil { throw ActionError.elementNotFound(target) }
        } else {
            field = await accessibility.preferredTextField(in: snapshot)
        }

        if let field {
            do {
                try await accessibility.focus(field.id)
                // Append rather than replace: setting AXValue would wipe
                // anything already in the field.
                let existing = action.parameters["replace"] == "true"
                    ? ""
                    : (field.value ?? "")
                try await accessibility.setValue(existing + text, on: field.id)
                return "Typed into \(field.label)"
            } catch {
                log(.executor, "AX value set failed, falling back to key events")
                try? await accessibility.clickElement(field.id, kind: .single)
            }
        }

        try AppleEvents.type(text)
        return "Typed text"
    }

    // MARK: Input fallbacks

    private func pressKey(_ action: ActionRequest) throws -> String {
        guard let spoken = action.parameters["key"], !spoken.isEmpty else {
            throw ActionError.missingParameter("key")
        }
        guard let shortcut = AppleEvents.parseShortcut(spoken) else {
            throw ActionError.unsupported("key \"\(spoken)\"")
        }
        try AppleEvents.pressKey(shortcut.key, flags: shortcut.flags)
        return "Pressed \(spoken)"
    }

    private func scroll(_ action: ActionRequest) throws -> String {
        let direction = action.parameters["direction"] ?? "down"
        try AppleEvents.scroll(direction: direction)
        return "Scrolled \(direction)"
    }

    private func screenshot() throws -> String {
        let url = try AppleEvents.captureScreen()
        return "Saved \(url.lastPathComponent) to Desktop"
    }

    private func setVolume(_ action: ActionRequest) throws -> String {
        if let level = action.parameters["level"].flatMap(Int.init) {
            try AppleEvents.setOutputVolume(level)
            return "Volume \(level)%"
        }
        let direction = action.parameters["direction"] ?? "up"
        try AppleEvents.adjustVolume(by: direction == "up" ? 12 : -12)
        return "Volume \(direction)"
    }
}
