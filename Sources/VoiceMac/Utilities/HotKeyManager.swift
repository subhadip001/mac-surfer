import AppKit
import Carbon.HIToolbox

/// Global hot keys via Carbon `RegisterEventHotKey`.
///
/// Carbon hot keys are used rather than a `CGEventTap` because they work
/// system-wide without requiring Accessibility permission, so the listen
/// shortcut is live the moment the app launches.
@MainActor
final class HotKeyManager {
    static let shared = HotKeyManager()

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private var installedHandler = false

    private init() {}

    func installHandlerIfNeeded() {
        guard !installedHandler else { return }
        installedHandler = true

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))

        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &hotKeyID)
            guard status == noErr else { return status }
            let id = hotKeyID.id
            HotKeyCallbackStore.shared.fire(id)
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// Registers a global hot key. Returns a token for `unregister`.
    @discardableResult
    func register(_ combo: HotKeyCombo, action: @escaping @MainActor () -> Void) -> UInt32? {
        installHandlerIfNeeded()

        let id = nextID
        nextID += 1

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x564D4143), id: id) // 'VMAC'
        let status = RegisterEventHotKey(combo.keyCode,
                                        combo.modifiers,
                                        hotKeyID,
                                        GetApplicationEventTarget(),
                                        0,
                                        &ref)

        guard status == noErr, let ref else {
            log(.hotkey, "failed to register \(combo.displayString) (status \(status)) — another app may own it")
            return nil
        }

        refs[id] = ref
        HotKeyCallbackStore.shared.set(id) { action() }
        log(.hotkey, "registered \(combo.displayString)")
        return id
    }

    func unregister(_ id: UInt32) {
        if let ref = refs.removeValue(forKey: id) {
            UnregisterEventHotKey(ref)
        }
        HotKeyCallbackStore.shared.remove(id)
    }

    func unregisterAll() {
        for id in Array(refs.keys) { unregister(id) }
    }
}

/// Bridges the C event handler back to Swift closures.
final class HotKeyCallbackStore: @unchecked Sendable {
    static let shared = HotKeyCallbackStore()
    private let lock = NSLock()
    private var callbacks: [UInt32: () -> Void] = [:]

    func set(_ id: UInt32, _ callback: @escaping () -> Void) {
        lock.withLock { callbacks[id] = callback }
    }

    func remove(_ id: UInt32) {
        lock.withLock { callbacks[id] = nil }
    }

    func fire(_ id: UInt32) {
        let callback = lock.withLock { callbacks[id] }
        guard let callback else { return }
        DispatchQueue.main.async { callback() }
    }
}
