import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = AppState()

    private var statusItem: NSStatusItem?
    private var overlayPanel: NSPanel?
    private var settingsWindow: NSWindow?
    private var debugWindow: NSWindow?
    private var historyWindow: NSWindow?

    private var listenHotKeyToken: UInt32?
    private var cancelHotKeyToken: UInt32?
    private let fnMonitor = FnKeyMonitor()
    /// True while a Fn press is still deciding between tap and hold.
    private var fnStartedSession = false
    private var cancellables: Set<AnyCancellable> = []
    private var hideOverlayWork: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        log(.app, "VoiceMac starting")

        // Resolve secrets now, so any Keychain authorisation prompt happens at
        // launch rather than the moment the user presses the listen key.
        KeychainManager.warmUp()

        state.presentHistory = { [weak self] in self?.showHistory() }

        setUpMainMenu()
        setUpStatusItem()
        setUpOverlay()
        registerListenHotKey()
        configureFnKey()
        observeState()

        if !state.microphoneAuthorized {
            // Ask immediately: the first thing a user does is press the hotkey,
            // and a denied mic at that point looks like the app is broken.
            state.requestMicrophoneAccess()
        }
        if !state.accessibilityTrusted {
            log(.permission, "Accessibility not granted — click/type/scroll actions will be unavailable")
        }
        if !state.hasRequiredKeys {
            log(.app, "no Sarvam API key — opening Settings")
            showSettings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotKeyManager.shared.unregisterAll()
    }

    // MARK: Main menu

    /// Installs an Edit menu so ⌘C / ⌘V / ⌘A work in our windows.
    ///
    /// An `LSUIElement` app has no visible menu bar, and without a main menu
    /// `NSApplication` has nothing to match key equivalents against — so
    /// pasting into a text field silently does nothing. The menu is never
    /// drawn; it exists purely so these shortcuts resolve.
    private func setUpMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…",
                        action: #selector(showSettings),
                        keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide VoiceMac",
                        action: #selector(NSApplication.hide(_:)),
                        keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit VoiceMac",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo",
                         action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo",
                         action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut",
                         action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy",
                         action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste",
                         action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: Status item

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "VoiceMac")
        item.button?.image?.isTemplate = true
        item.menu = buildMenu()
        statusItem = item
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let statusLine = NSMenuItem(title: "Idle", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        statusLine.tag = 100
        menu.addItem(statusLine)

        menu.addItem(.separator())

        let listen = NSMenuItem(title: "Start Listening",
                                action: #selector(toggleListening),
                                keyEquivalent: "")
        listen.target = self
        listen.tag = 101
        menu.addItem(listen)

        let cancel = NSMenuItem(title: "Cancel", action: #selector(cancelSession), keyEquivalent: "")
        cancel.target = self
        menu.addItem(cancel)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let history = NSMenuItem(title: "Command History…", action: #selector(showHistory), keyEquivalent: "y")
        history.target = self
        menu.addItem(history)

        let debug = NSMenuItem(title: "Debug & Latency…", action: #selector(showDebug), keyEquivalent: "d")
        debug.target = self
        menu.addItem(debug)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit VoiceMac", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    // MARK: Hot keys

    private func registerListenHotKey() {
        if let token = listenHotKeyToken {
            HotKeyManager.shared.unregister(token)
        }
        listenHotKeyToken = HotKeyManager.shared.register(state.settings.listenHotKey) { [weak self] in
            self?.toggleListening()
        }
    }

    /// Fn (Globe) does double duty, decided by how long you hold it:
    ///   * tap   — toggles listening on, and a second tap stops it
    ///   * hold  — push-to-talk; listening starts on press, ends on release
    ///
    /// Listening always starts on *press* rather than release, because waiting
    /// for the release would add the entire hold duration to time-to-first-action.
    private func configureFnKey() {
        fnMonitor.onPress = { [weak self] in
            guard let self else { return }

            // A tap while already listening is the "off" half of the toggle.
            if self.state.isListening && !self.fnStartedSession {
                self.state.toggleListening()
                return
            }

            self.fnStartedSession = true
            self.state.startListening()
        }

        fnMonitor.onRelease = { [weak self] held in
            guard let self, self.fnStartedSession else { return }
            self.fnStartedSession = false

            let threshold = Duration.milliseconds(self.state.settings.fnHoldThresholdMs)
            if held >= threshold {
                // Held: treat the release as "I've finished speaking".
                self.state.finishListening()
            }
            // Tapped: leave the session running until the next tap or silence.
        }

        applyFnPreference()
    }

    private func applyFnPreference() {
        if state.settings.useFnKey {
            fnMonitor.start()
        } else {
            fnMonitor.stop()
        }
    }

    /// Esc is only claimed globally while a session is live, so it stays
    /// available to every other app the rest of the time.
    private func setCancelHotKey(active: Bool) {
        if active, cancelHotKeyToken == nil {
            cancelHotKeyToken = HotKeyManager.shared.register(
                HotKeyCombo(keyCode: UInt32(kVK_Escape), modifiers: 0)
            ) { [weak self] in
                self?.cancelSession()
            }
        } else if !active, let token = cancelHotKeyToken {
            HotKeyManager.shared.unregister(token)
            cancelHotKeyToken = nil
        }
    }

    // MARK: Observation

    private func observeState() {
        state.$sessionState
            .receive(on: RunLoop.main)
            .sink { [weak self] sessionState in
                self?.applySessionState(sessionState)
            }
            .store(in: &cancellables)

        state.settings.$listenHotKey
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.registerListenHotKey() }
            .store(in: &cancellables)

        state.settings.$useFnKey
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyFnPreference() }
            .store(in: &cancellables)
    }

    private func applySessionState(_ sessionState: SessionState) {
        let symbol: String
        switch sessionState {
        case .idle: symbol = "mic"
        case .starting: symbol = "mic.badge.plus"
        case .listening, .transcribing: symbol = "mic.fill"
        case .understanding: symbol = "waveform"
        case .executing: symbol = "bolt.fill"
        case .failed: symbol = "exclamationmark.triangle"
        }
        statusItem?.button?.image = NSImage(systemSymbolName: symbol,
                                            accessibilityDescription: sessionState.label)
        statusItem?.button?.image?.isTemplate = true

        if let menu = statusItem?.menu {
            menu.item(withTag: 100)?.title = sessionState.label
            let trigger = state.settings.useFnKey
                ? "fn"
                : state.settings.listenHotKey.displayString
            menu.item(withTag: 101)?.title = sessionState.isActive
                ? "Stop Listening"
                : "Start Listening (\(trigger))"
        }

        // If the session ended on its own while Fn was held, the eventual
        // release must not be read as a push-to-talk finish.
        if !sessionState.isActive { fnStartedSession = false }

        setCancelHotKey(active: sessionState.isActive)

        if sessionState.isActive {
            showOverlay()
        } else {
            // Leave the result on screen briefly rather than snapping away.
            scheduleOverlayHide(after: 2.5)
        }
    }

    // MARK: Overlay

    private func setUpOverlay() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 150),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false

        let root = ListeningOverlay().environmentObject(state)
        let hosting = NSHostingView(rootView: root)
        hosting.translatesAutoresizingMaskIntoConstraints = true
        panel.contentView = hosting

        overlayPanel = panel
    }

    private func showOverlay() {
        hideOverlayWork?.cancel()
        guard let panel = overlayPanel else { return }
        positionOverlay(panel)
        panel.orderFrontRegardless()
    }

    private func scheduleOverlayHide(after delay: TimeInterval) {
        hideOverlayWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.state.isListening else { return }
            // Keep it up while a confirmation is outstanding.
            if self.state.pendingConfirmation != nil { return }
            self.overlayPanel?.orderOut(nil)
        }
        hideOverlayWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func positionOverlay(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(x: visible.midX - size.width / 2,
                             y: visible.minY + 120)
        panel.setFrameOrigin(origin)
    }

    // MARK: Actions

    @objc private func toggleListening() {
        state.toggleListening()
    }

    @objc private func cancelSession() {
        state.cancel()
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            settingsWindow = makeWindow(title: "VoiceMac Settings",
                                         size: NSSize(width: 520, height: 600),
                                         view: SettingsView().environmentObject(state))
        }
        present(settingsWindow)
    }

    @objc private func showHistory() {
        if historyWindow == nil {
            historyWindow = makeWindow(title: "VoiceMac Command History",
                                        size: NSSize(width: 720, height: 560),
                                        view: HistoryView().environmentObject(state))
        }
        state.reloadHistory()
        present(historyWindow)
    }

    @objc private func showDebug() {
        if debugWindow == nil {
            debugWindow = makeWindow(title: "VoiceMac Debug",
                                      size: NSSize(width: 680, height: 620),
                                      view: DebugView().environmentObject(state))
        }
        present(debugWindow)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func makeWindow<Content: View>(title: String,
                                           size: NSSize,
                                           view: Content) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = title
        window.contentView = NSHostingView(rootView: view)
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    private func present(_ window: NSWindow?) {
        guard let window else { return }
        // An accessory app must activate explicitly for its windows to focus.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
