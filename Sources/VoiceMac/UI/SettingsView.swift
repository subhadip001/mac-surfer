import AppKit
import Carbon.HIToolbox
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var state: AppState

    @State private var sarvamKeyInput = ""
    @State private var jevKeyInput = ""
    @State private var saveNotice = ""

    private static let hotKeyChoices: [(label: String, combo: HotKeyCombo)] = [
        ("⌘⇧Space", HotKeyCombo(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | shiftKey))),
        ("⌥Space", HotKeyCombo(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))),
        ("⌃Space", HotKeyCombo(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey))),
        ("⌘⇧V", HotKeyCombo(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey))),
        ("⌘⇧A", HotKeyCombo(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(cmdKey | shiftKey))),
    ]

    private static let languages: [(String, String)] = [
        ("English (India)", "en-IN"),
        ("Hindi", "hi-IN"),
        ("Bengali", "bn-IN"),
        ("Tamil", "ta-IN"),
        ("Telugu", "te-IN"),
        ("Marathi", "mr-IN"),
        ("Gujarati", "gu-IN"),
        ("Kannada", "kn-IN"),
        ("Malayalam", "ml-IN"),
        ("Punjabi", "pa-IN"),
        ("Auto-detect", "auto"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                permissions
                apiKeys
                speech
                intelligence
                behaviour
                shortcut
            }
            .padding(20)
        }
        .frame(minWidth: 500, minHeight: 560)
        .onAppear { state.refreshPermissions() }
    }

    // MARK: Permissions

    private var permissions: some View {
        section("Permissions") {
            permissionRow(
                title: "Microphone",
                detail: "Required to capture speech.",
                granted: state.microphoneAuthorized,
                action: { state.requestMicrophoneAccess() }
            )
            permissionRow(
                title: "Accessibility",
                detail: "Required for clicking, typing, and scrolling in other apps.",
                granted: state.accessibilityTrusted,
                action: { state.requestAccessibilityAccess() }
            )
            Text("Opening apps, URLs, and web searches work without Accessibility.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func permissionRow(title: String,
                               detail: String,
                               granted: Bool,
                               action: @escaping () -> Void) -> some View {
        HStack(alignment: .top) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Grant…", action: action).controlSize(.small)
            }
        }
    }

    // MARK: API keys

    private var apiKeys: some View {
        section("API Keys") {
            Text("Keys are stored in the macOS Keychain. They are never written to disk in plain text and never logged.")
                .font(.caption)
                .foregroundStyle(.secondary)

            keyRow(key: .sarvamAPIKey,
                   input: $sarvamKeyInput,
                   note: "Required. Used for streaming speech-to-text and parameter extraction.")

            keyRow(key: .jevAPIKey,
                   input: $jevKeyInput,
                   note: "Optional. Used for typed decisions on commands the local router cannot handle.")

            if !saveNotice.isEmpty {
                Text(saveNotice).font(.caption).foregroundStyle(.green)
            }
        }
    }

    private func keyRow(key: SecretKey,
                        input: Binding<String>,
                        note: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(key.displayName).font(.system(size: 12, weight: .medium))
                if KeychainManager.has(key) {
                    Text(KeychainManager.maskedPreview(key))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                // A plain TextField, not a SecureField: the value is visible so
                // you can check a pasted key character by character. Autocorrect
                // and smart quotes are off because they corrupt API keys.
                TextField("Paste your key here", text: input)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .autocorrectionDisabled()
                    .onSubmit { save(key: key, input: input) }

                // Reads the pasteboard directly, so pasting works even if a
                // keyboard shortcut is swallowed by another app.
                Button("Paste") {
                    if let clipboard = NSPasteboard.general.string(forType: .string) {
                        input.wrappedValue = clipboard
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        saveNotice = "Pasted \(input.wrappedValue.count) characters — click Save."
                    } else {
                        saveNotice = "Clipboard is empty."
                    }
                }
                .controlSize(.small)

                Button("Save") { save(key: key, input: input) }
                    .disabled(input.wrappedValue.isEmpty)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                Button("Clear") {
                    KeychainManager.delete(key)
                    input.wrappedValue = ""
                    saveNotice = "\(key.displayName) removed."
                }
                .controlSize(.small)
            }
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func save(key: SecretKey, input: Binding<String>) {
        guard !input.wrappedValue.isEmpty else { return }
        do {
            try KeychainManager.set(input.wrappedValue, for: key)
            let count = input.wrappedValue.count
            input.wrappedValue = ""
            saveNotice = "\(key.displayName) saved to Keychain (\(count) characters)."
        } catch {
            saveNotice = error.localizedDescription
        }
    }

    // MARK: Speech

    private var speech: some View {
        section("Speech Recognition") {
            Picker("Provider", selection: Binding(
                get: { state.settings.sttProvider },
                set: { state.settings.sttProvider = $0 }
            )) {
                ForEach(STTProviderKind.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }

            Picker("Language", selection: Binding(
                get: { state.settings.language },
                set: { state.settings.language = $0 }
            )) {
                ForEach(Self.languages, id: \.1) { name, code in
                    Text(name).tag(code)
                }
            }

            Picker("Model", selection: Binding(
                get: { state.settings.sttModel },
                set: { state.settings.sttModel = $0 }
            )) {
                Text("saaras:v3-realtime").tag("saaras:v3-realtime")
                Text("saaras:v4").tag("saaras:v4")
            }

            Picker("Partial latency", selection: Binding(
                get: { state.settings.streamType },
                set: { state.settings.streamType = $0 }
            )) {
                Text("Fast — earliest partials").tag("fast")
                Text("Balanced").tag("balanced")
                Text("Simulated").tag("simulated")
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("End-of-turn silence")
                    Spacer()
                    Text("\(state.settings.silenceDurationMs) ms")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: Binding(
                    get: { Double(state.settings.silenceDurationMs) },
                    set: { state.settings.silenceDurationMs = Int($0) }
                ), in: 200...1200, step: 50)
                Text("Lower finishes commands sooner but may cut off mid-sentence pauses.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Intelligence

    private var intelligence: some View {
        section("Intelligence") {
            Toggle("Use Jev", isOn: Binding(
                get: { state.settings.jevEnabled },
                set: { state.settings.jevEnabled = $0 }
            ))
            Text("When Jev is unavailable the app falls back to local commands only.")
                .font(.caption).foregroundStyle(.secondary)

            Picker("Routing", selection: Binding(
                get: { state.settings.routingMode },
                set: { state.settings.routingMode = $0 }
            )) {
                ForEach(RoutingMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .disabled(!state.settings.jevEnabled)
            Text(state.settings.routingMode.detail)
                .font(.caption).foregroundStyle(.secondary)

            LabeledContent("Jev model") {
                TextField("jev-latest", text: Binding(
                    get: { state.settings.jevModel },
                    set: { state.settings.jevModel = $0 }
                ))
                .textFieldStyle(.roundedBorder)
            }

            LabeledContent("Jev base URL") {
                TextField("https://api.typesafe.ai", text: Binding(
                    get: { state.settings.jevBaseURL },
                    set: { state.settings.jevBaseURL = $0 }
                ))
                .textFieldStyle(.roundedBorder)
            }

            Picker("Parameter extraction model", selection: Binding(
                get: { state.settings.llmModel },
                set: { state.settings.llmModel = $0 }
            )) {
                ForEach(Settings.availableLLMModels, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            Text("Jev returns typed answers only, so a text model supplies string parameters such as a search query.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Behaviour

    private var behaviour: some View {
        section("Behaviour") {
            Toggle("Execute safe actions mid-sentence", isOn: Binding(
                get: { state.settings.speculativeExecution },
                set: { state.settings.speculativeExecution = $0 }
            ))
            Text("Turning this off waits for you to stop speaking before doing anything.")
                .font(.caption).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Stability window")
                    Spacer()
                    Text("\(state.settings.stabilityWindow) partials")
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                Slider(value: Binding(
                    get: { Double(state.settings.stabilityWindow) },
                    set: { state.settings.stabilityWindow = Int($0) }
                ), in: 1...4, step: 1)
                Text("How many consecutive partial transcripts must agree before a word is trusted. Higher is safer and slower.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Picker("Search engine", selection: Binding(
                get: { state.settings.searchEngine },
                set: { state.settings.searchEngine = $0 }
            )) {
                ForEach(SearchEngine.allCases) { engine in
                    Text(engine.displayName).tag(engine)
                }
            }

            Toggle("Keep command history", isOn: Binding(
                get: { state.settings.keepHistory },
                set: { state.settings.keepHistory = $0 }
            ))
            VStack(alignment: .leading, spacing: 4) {
                Text("Records each command and the actions it ran to a local file. Nothing is uploaded. The file contains what you said, in plain text.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("Open History") { state.presentHistory?() }
                        .controlSize(.small)
                    Button("Reveal File") { state.revealHistoryInFinder() }
                        .controlSize(.small)
                    Button("Clear History") { state.clearHistory() }
                        .controlSize(.small)
                }
            }

            Toggle("Debug mode (logs transcript content)", isOn: Binding(
                get: { state.settings.debugMode },
                set: { state.settings.debugMode = $0 }
            ))
            Text("When off, spoken content is redacted from logs. API keys are never logged in either mode.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Shortcut

    private var shortcut: some View {
        section("Shortcut") {
            Toggle("Use the fn (Globe) key to listen", isOn: Binding(
                get: { state.settings.useFnKey },
                set: { state.settings.useFnKey = $0 }
            ))

            VStack(alignment: .leading, spacing: 3) {
                Text("Tap fn to start listening, tap again to stop. Hold fn to talk and release when you're done.")
                    .font(.caption).foregroundStyle(.secondary)

                if state.settings.useFnKey && !state.accessibilityTrusted {
                    Label("fn detection needs Accessibility permission — grant it above, then relaunch VoiceMac.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if state.settings.useFnKey {
                    Label("macOS uses fn for its own shortcut. Set System Settings › Keyboard › \"Press 🌐 key to\" to \"Do Nothing\", or the two will fight.",
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open Keyboard Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                }
            }

            if state.settings.useFnKey {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Hold threshold")
                        Spacer()
                        Text("\(state.settings.fnHoldThresholdMs) ms")
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                    Slider(value: Binding(
                        get: { Double(state.settings.fnHoldThresholdMs) },
                        set: { state.settings.fnHoldThresholdMs = Int($0) }
                    ), in: 150...800, step: 50)
                    Text("Held longer than this counts as push-to-talk; shorter is a tap.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Divider().padding(.vertical, 2)

            Picker("Keyboard shortcut", selection: Binding(
                get: { state.settings.listenHotKey.encoded },
                set: { encoded in
                    if let combo = HotKeyCombo(encoded: encoded) {
                        state.settings.listenHotKey = combo
                    }
                }
            )) {
                ForEach(Self.hotKeyChoices, id: \.combo.encoded) { choice in
                    Text(choice.label).tag(choice.combo.encoded)
                }
            }
            Text("Always available as an alternative to fn. Esc cancels, and is only captured globally while a session is active.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Layout

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
