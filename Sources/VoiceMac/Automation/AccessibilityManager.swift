import AppKit
import ApplicationServices
import Foundation

/// A UI element reduced to the fields a decision needs.
struct AXElementSnapshot: Sendable, Identifiable, Codable {
    let id: String
    let role: String
    let subrole: String?
    let title: String?
    let value: String?
    let help: String?
    let identifier: String?
    let enabled: Bool
    /// Centre of the element in screen coordinates, when it has a frame.
    /// Used to synthesise a mouse click for controls that do not implement
    /// `AXPress` — web content and canvas-drawn UI, mostly.
    var centre: CGPoint?

    /// Best single human-readable label for matching and display.
    var label: String {
        for candidate in [title, identifier, help, value] {
            if let candidate, !candidate.isEmpty { return candidate }
        }
        return role
    }

    /// Compact form for the model payload — omits empty fields entirely so we
    /// are not spending tokens on nulls.
    private enum CodingKeys: String, CodingKey {
        case id, role, subrole, title, value, help, identifier, enabled
    }

    var compact: [String: String] {
        var out = ["id": id, "role": shortRole]
        if let title, !title.isEmpty { out["title"] = title }
        if let value, !value.isEmpty { out["value"] = String(value.prefix(120)) }
        if let help, !help.isEmpty { out["description"] = help }
        if let identifier, !identifier.isEmpty { out["identifier"] = identifier }
        if !enabled { out["enabled"] = "false" }
        return out
    }

    var shortRole: String {
        role.hasPrefix("AX") ? String(role.dropFirst(2)).lowercasedFirst : role
    }
}

struct AXWindowSnapshot: Sendable {
    let application: String
    let bundleIdentifier: String?
    let window: String?
    let elements: [AXElementSnapshot]

    static let empty = AXWindowSnapshot(application: "", bundleIdentifier: nil,
                                        window: nil, elements: [])
}

/// Reads and drives the frontmost app through the Accessibility API.
///
/// Tree walking is bounded (depth and element count) because a full AX tree of
/// a Slack or browser window can be thousands of nodes — enough to stall the
/// pipeline and far too much to ever send to a model.
actor AccessibilityManager {
    /// `kAXLinkRole` is not exported to Swift, unlike the other role constants.
    static let axLinkRole = "AXLink"

    /// Roles worth exposing; containers are traversed but not reported.
    private static let actionableRoles: Set<String> = [
        kAXButtonRole, kAXTextFieldRole, kAXTextAreaRole, kAXCheckBoxRole,
        kAXRadioButtonRole, kAXPopUpButtonRole, kAXMenuItemRole,
        kAXMenuButtonRole, kAXComboBoxRole, axLinkRole, kAXTabGroupRole,
        kAXCellRole, kAXRowRole, kAXSliderRole, kAXIncrementorRole,
        kAXDisclosureTriangleRole, kAXStaticTextRole,
    ]

    private static let maxDepth = 14
    private static let maxElements = 400
    /// Apps that stop answering AX queries must not stall the pipeline.
    private static let messagingTimeout: Float = 0.4

    /// Live element handles from the most recent snapshot, keyed by snapshot id.
    private var handles: [String: AXUIElement] = [:]

    // MARK: Permission

    nonisolated static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that deep-links to the Accessibility pane.
    nonisolated static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: Snapshot

    /// Inspects the frontmost application's focused window.
    func snapshotFrontmost() -> AXWindowSnapshot {
        guard Self.isTrusted else {
            log(.accessibility, "snapshot skipped — Accessibility permission not granted")
            return .empty
        }
        guard let frontmost = NSWorkspace.shared.frontmostApplication else {
            return .empty
        }

        let appElement = AXUIElementCreateApplication(frontmost.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, Self.messagingTimeout)

        let window = Self.copyElement(appElement, kAXFocusedWindowAttribute)
            ?? Self.copyElement(appElement, kAXMainWindowAttribute)

        guard let window else {
            return AXWindowSnapshot(application: frontmost.localizedName ?? "",
                                     bundleIdentifier: frontmost.bundleIdentifier,
                                     window: nil,
                                     elements: [])
        }

        var collected: [AXElementSnapshot] = []
        var newHandles: [String: AXUIElement] = [:]
        var counter = 0

        walk(window, depth: 0, counter: &counter,
             collected: &collected, handles: &newHandles)

        handles = newHandles

        let snapshot = AXWindowSnapshot(
            application: frontmost.localizedName ?? "",
            bundleIdentifier: frontmost.bundleIdentifier,
            window: Self.copyString(window, kAXTitleAttribute),
            elements: collected
        )
        log(.accessibility, "snapshot \(snapshot.application): \(collected.count) elements")
        return snapshot
    }

    private func walk(_ element: AXUIElement,
                      depth: Int,
                      counter: inout Int,
                      collected: inout [AXElementSnapshot],
                      handles: inout [String: AXUIElement]) {
        guard depth <= Self.maxDepth, counter < Self.maxElements else { return }

        let role = Self.copyString(element, kAXRoleAttribute) ?? ""

        if Self.actionableRoles.contains(role) {
            let title = Self.copyString(element, kAXTitleAttribute)
            let value = Self.copyString(element, kAXValueAttribute)
            let help = Self.copyString(element, kAXDescriptionAttribute)
                ?? Self.copyString(element, kAXHelpAttribute)
            let identifier = Self.copyString(element, kAXIdentifierAttribute)

            let hasLabel = [title, value, help, identifier]
                .contains { ($0?.isEmpty == false) }

            // Static text is only interesting when it labels something; an
            // unlabelled one is decoration.
            let worthKeeping = hasLabel && !(role == kAXStaticTextRole && (title?.isEmpty ?? true) && (value?.isEmpty ?? true))

            if worthKeeping {
                counter += 1
                let id = "e\(counter)"
                let enabled = Self.copyBool(element, kAXEnabledAttribute) ?? true
                collected.append(AXElementSnapshot(
                    id: id,
                    role: role,
                    subrole: Self.copyString(element, kAXSubroleAttribute),
                    title: title,
                    value: value,
                    help: help,
                    identifier: identifier,
                    enabled: enabled,
                    centre: Self.centre(of: element)
                ))
                handles[id] = element
            }
        }

        guard let children = Self.copyElements(element, kAXChildrenAttribute) else { return }
        for child in children {
            guard counter < Self.maxElements else { return }
            walk(child, depth: depth + 1, counter: &counter,
                 collected: &collected, handles: &handles)
        }
    }

    // MARK: Filtering

    /// The elements relevant to a spoken target, best first.
    ///
    /// This is the filter that keeps the AX tree out of the model payload: the
    /// caller sends these few elements, never `snapshot.elements`.
    func relevantElements(for query: String,
                          in snapshot: AXWindowSnapshot,
                          limit: Int = 8,
                          threshold: Double = 0.45) -> [AXElementSnapshot] {
        guard !query.isEmpty else { return Array(snapshot.elements.prefix(limit)) }

        let scored = snapshot.elements.map { element -> (AXElementSnapshot, Double) in
            var best = 0.0
            for field in [element.title, element.identifier, element.help, element.value] {
                guard let field, !field.isEmpty else { continue }
                best = max(best, Fuzzy.score(query: query, candidate: field))
            }
            // Mild preference for things you can actually click.
            if element.role == kAXButtonRole || element.role == Self.axLinkRole
                || element.role == kAXMenuItemRole {
                best *= 1.05
            }
            return (element, min(best, 1.0))
        }

        return scored
            .filter { $0.1 >= threshold }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { $0.0 }
    }

    /// First element whose label matches well enough to act on without asking.
    ///
    /// `preferredRoles` biases toward the kind of thing the user named — "click
    /// the Send button" should prefer an actual button over a label that
    /// happens to read "Send". `ordinal` is 1-based and selects among equally
    /// good matches, for "click the second tab".
    /// Generic UI words people add when naming a control. An element titled
    /// "Search" should still match "the search field".
    static let genericUINouns: Set<String> = [
        "field", "box", "button", "bar", "area", "input", "menu", "tab",
        "icon", "link", "control", "item", "option", "textbox", "textfield",
        "window", "panel", "section",
    ]

    /// Drops generic UI nouns, or nil if that would leave nothing or change
    /// nothing.
    static func strippingGenericNouns(_ query: String) -> String? {
        let words = Fuzzy.normalize(query).split(separator: " ").map(String.init)
        let kept = words.filter { !genericUINouns.contains($0) }
        guard !kept.isEmpty, kept.count != words.count else { return nil }
        return kept.joined(separator: " ")
    }

    func bestMatch(for query: String,
                   in snapshot: AXWindowSnapshot,
                   preferredRoles: Set<String> = [],
                   ordinal: Int? = nil) -> AXElementSnapshot? {
        let threshold = ordinal == nil ? 0.62 : 0.3
        var ranked = relevantElements(for: query,
                                       in: snapshot,
                                       limit: 25,
                                       threshold: threshold)

        // "search field" finds nothing when the control is just called
        // "Search" — retry on the meaningful words alone.
        if ranked.isEmpty, let stripped = Self.strippingGenericNouns(query) {
            ranked = relevantElements(for: stripped,
                                       in: snapshot,
                                       limit: 25,
                                       threshold: threshold)
        }

        if !preferredRoles.isEmpty {
            let preferred = ranked.filter { preferredRoles.contains($0.role) }
            if !preferred.isEmpty { ranked = preferred }
        }

        if let ordinal, ordinal >= 1 {
            guard ranked.count >= ordinal else { return nil }
            return ranked[ordinal - 1]
        }
        return ranked.first
    }

    /// All elements of the given roles, in tree order — the basis for
    /// "click the third button" when no label was spoken.
    func elements(ofRoles roles: Set<String>,
                  in snapshot: AXWindowSnapshot) -> [AXElementSnapshot] {
        snapshot.elements.filter { roles.contains($0.role) && $0.enabled }
    }

    /// A text field we can type into: the focused one, else the best search field.
    func preferredTextField(in snapshot: AXWindowSnapshot) -> AXElementSnapshot? {
        if let focused = snapshot.elements.first(where: {
            ($0.role == kAXTextFieldRole || $0.role == kAXTextAreaRole)
                && handles[$0.id].map { Self.copyBool($0, kAXFocusedAttribute) == true } == true
        }) {
            return focused
        }
        return snapshot.elements.first {
            $0.role == kAXTextFieldRole || $0.role == kAXTextAreaRole
        }
    }

    // MARK: Menu bar

    /// A single runnable menu command, e.g. File ▸ New Window.
    struct MenuCommand: Sendable {
        let menu: String
        let title: String
        let enabled: Bool
        /// Path below the top-level menu, for display.
        let path: [String]

        var displayPath: String { ([menu] + path).joined(separator: " ▸ ") }
    }

    private var menuHandles: [String: AXUIElement] = [:]

    /// Reads the frontmost app's whole menu bar.
    ///
    /// Most of an application's functionality is reachable from its menus, and
    /// AX menu traversal is far more reliable than hunting for toolbar buttons
    /// — the titles are stable, localised, and already describe the command.
    func menuCommands(limitPerMenu: Int = 120) -> [MenuCommand] {
        guard Self.isTrusted,
              let frontmost = NSWorkspace.shared.frontmostApplication else { return [] }

        let appElement = AXUIElementCreateApplication(frontmost.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, Self.messagingTimeout)

        guard let menuBar = Self.copyElement(appElement, kAXMenuBarAttribute),
              let topLevel = Self.copyElements(menuBar, kAXChildrenAttribute) else { return [] }

        var commands: [MenuCommand] = []
        var handles: [String: AXUIElement] = [:]

        for menuItem in topLevel {
            guard let menuTitle = Self.copyString(menuItem, kAXTitleAttribute),
                  // The Apple menu is not part of the app's own command set.
                  menuTitle != "Apple" else { continue }

            var count = 0
            // The submenu holding the actual items.
            guard let submenus = Self.copyElements(menuItem, kAXChildrenAttribute),
                  let submenu = submenus.first else { continue }

            collectMenuItems(submenu,
                             menu: menuTitle,
                             path: [],
                             depth: 0,
                             count: &count,
                             limit: limitPerMenu,
                             commands: &commands,
                             handles: &handles)
        }

        menuHandles = handles
        return commands
    }

    private func collectMenuItems(_ menu: AXUIElement,
                                  menu menuTitle: String,
                                  path: [String],
                                  depth: Int,
                                  count: inout Int,
                                  limit: Int,
                                  commands: inout [MenuCommand],
                                  handles: inout [String: AXUIElement]) {
        guard depth <= 4, count < limit else { return }
        guard let items = Self.copyElements(menu, kAXChildrenAttribute) else { return }

        for item in items {
            guard count < limit else { return }
            guard let title = Self.copyString(item, kAXTitleAttribute),
                  !title.isEmpty else { continue }   // separators have no title

            // A submenu is a child menu on the item; a leaf has none.
            if let children = Self.copyElements(item, kAXChildrenAttribute),
               let child = children.first,
               Self.copyString(child, kAXRoleAttribute) == kAXMenuRole,
               (Self.copyElements(child, kAXChildrenAttribute)?.isEmpty == false) {
                collectMenuItems(child,
                                 menu: menuTitle,
                                 path: path + [title],
                                 depth: depth + 1,
                                 count: &count,
                                 limit: limit,
                                 commands: &commands,
                                 handles: &handles)
                continue
            }

            count += 1
            let enabled = Self.copyBool(item, kAXEnabledAttribute) ?? true
            let key = Self.menuKey(menu: menuTitle, path: path + [title])
            commands.append(MenuCommand(menu: menuTitle,
                                        title: title,
                                        enabled: enabled,
                                        path: path + [title]))
            handles[key] = item
        }
    }

    private static func menuKey(menu: String, path: [String]) -> String {
        ([menu] + path).map { Fuzzy.normalize($0) }.joined(separator: "/")
    }

    /// Finds a menu command by spoken name, optionally scoped to one menu.
    func findMenuCommand(_ spoken: String, inMenu menu: String?) -> MenuCommand? {
        let commands = menuCommands()
        guard !commands.isEmpty else { return nil }

        let candidates: [MenuCommand]
        if let menu, !menu.isEmpty {
            let scoped = commands.filter {
                Fuzzy.score(query: menu, candidate: $0.menu) >= 0.8
            }
            candidates = scoped.isEmpty ? commands : scoped
        } else {
            candidates = commands
        }

        // Disabled items are real matches but cannot run, so rank them last
        // rather than dropping them — it produces a better error message.
        let scored = candidates
            .map { ($0, Fuzzy.score(query: spoken, candidate: $0.title) * ($0.enabled ? 1.0 : 0.6)) }
            .sorted { $0.1 > $1.1 }

        guard let best = scored.first, best.1 >= 0.62 else { return nil }
        return best.0
    }

    func runMenuCommand(_ command: MenuCommand) throws {
        let key = Self.menuKey(menu: command.menu, path: command.path)
        guard let element = menuHandles[key] else {
            throw ActionError.elementNotFound(command.displayPath)
        }
        guard command.enabled else {
            throw ActionError.executionFailed("\(command.displayPath) is currently unavailable")
        }
        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        guard result == .success else {
            throw ActionError.executionFailed("could not run \(command.displayPath)")
        }
    }

    // MARK: Acting

    func centre(of elementID: String) -> CGPoint? {
        guard let element = handles[elementID] else { return nil }
        return Self.centre(of: element)
    }

    /// Clicks an element, falling back to a synthetic mouse click at its centre
    /// when the control does not implement `AXPress`. Web pages and
    /// canvas-drawn interfaces frequently do not.
    func clickElement(_ elementID: String, kind: MouseClickKind) throws {
        guard let element = handles[elementID] else {
            throw ActionError.elementNotFound(elementID)
        }

        if kind == .single {
            if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
                return
            }
        }

        guard let point = Self.centre(of: element) else {
            throw ActionError.executionFailed("element has no screen position to click")
        }
        try AppleEvents.click(at: point, kind: kind)
    }

    /// Erases a text field by setting its value directly — no key events, so
    /// nothing is left behind if the field rejects the change.
    func clearValue(on elementID: String) throws {
        guard let element = handles[elementID] else {
            throw ActionError.elementNotFound(elementID)
        }
        let result = AXUIElementSetAttributeValue(
            element, kAXValueAttribute as CFString, "" as CFTypeRef
        )
        guard result == .success else {
            throw ActionError.executionFailed("could not clear the field")
        }
    }

    func press(_ elementID: String) throws {
        guard let element = handles[elementID] else {
            throw ActionError.elementNotFound(elementID)
        }
        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        guard result == .success else {
            throw ActionError.executionFailed("AXPress failed (\(result.rawValue))")
        }
    }

    func focus(_ elementID: String) throws {
        guard let element = handles[elementID] else {
            throw ActionError.elementNotFound(elementID)
        }
        let result = AXUIElementSetAttributeValue(
            element, kAXFocusedAttribute as CFString, kCFBooleanTrue
        )
        guard result == .success else {
            throw ActionError.executionFailed("could not focus element")
        }
    }

    /// Sets a text field's value directly — far more reliable and faster than
    /// synthesising one key event per character.
    func setValue(_ text: String, on elementID: String) throws {
        guard let element = handles[elementID] else {
            throw ActionError.elementNotFound(elementID)
        }
        let result = AXUIElementSetAttributeValue(
            element, kAXValueAttribute as CFString, text as CFTypeRef
        )
        guard result == .success else {
            throw ActionError.executionFailed("could not set element value")
        }
    }

    func hasHandle(_ elementID: String) -> Bool { handles[elementID] != nil }

    // MARK: Attribute helpers

    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let value = copyAttribute(element, attribute) else { return nil }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func copyBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        guard let value = copyAttribute(element, attribute) else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    private static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copyAttribute(element, attribute) else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func copyElements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        guard let value = copyAttribute(element, attribute) else { return nil }
        return value as? [AXUIElement]
    }

    /// Screen-coordinate centre of an element, if it reports a frame.
    static func centre(of element: AXUIElement) -> CGPoint? {
        guard let positionValue = copyAttribute(element, kAXPositionAttribute),
              let sizeValue = copyAttribute(element, kAXSizeAttribute),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
              size.width > 0, size.height > 0 else { return nil }

        return CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
    }
}

extension String {
    var lowercasedFirst: String {
        guard let first else { return self }
        return first.lowercased() + dropFirst()
    }
}
