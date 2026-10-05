import SwiftUI

/// Developer panel: the latency breakdown and the structured log.
struct DebugView: View {
    @EnvironmentObject private var state: AppState
    @State private var categoryFilter: LogCategory?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            latencyPanel
            Divider()
            transcriptPanel
            Divider()
            logPanel
        }
        .frame(minWidth: 640, minHeight: 560)
    }

    // MARK: Latency

    private var latencyPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Latency").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("voice start → first useful action is the metric that matters")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack(spacing: 18) {
                headline("First transcript", state.latency.timeToFirstTranscript)
                headline("First decision", state.latency.timeToFirstDecision)
                headline("First action", state.latency.timeToFirstAction, emphasised: true)
                headline("Action done", state.latency.totalCommandLatency)
            }

            let marks = LatencyMark.allCases.filter { state.latency.marks[$0] != nil }
            if marks.isEmpty {
                Text("No session recorded yet. Press \(state.settings.listenHotKey.displayString) and speak a command.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(marks, id: \.rawValue) { mark in
                        HStack {
                            Text(mark.rawValue)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(state.latency.ms(mark))
                                .font(.system(size: 11, design: .monospaced))
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
        .padding(16)
    }

    private func headline(_ title: String,
                          _ value: TimeInterval?,
                          emphasised: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value.map { "\(Int($0)) ms" } ?? "—")
                .font(.system(size: emphasised ? 20 : 16, weight: .semibold, design: .rounded))
                .foregroundStyle(emphasised ? Color.accentColor : .primary)
                .monospacedDigit()
        }
    }

    // MARK: Transcript and actions

    private var transcriptPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Transcript").font(.system(size: 13, weight: .semibold))

            VStack(alignment: .leading, spacing: 4) {
                labelled("stable", state.stableText.isEmpty ? "—" : state.stableText)
                labelled("full", state.fullText.isEmpty ? "—" : state.fullText)
                labelled("final", state.transcriptIsFinal ? "yes" : "no")
            }

            Text("Jev").font(.system(size: 13, weight: .semibold)).padding(.top, 4)
            if state.jevConsultations.isEmpty {
                Text("Not consulted this session. Routing is \"\(state.settings.routingMode.displayName)\" — switch to Shadow in Settings to call Jev on every command.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(state.jevConsultations) { call in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack {
                            Text("\(call.chosenAction ?? "—")")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(call.applied ? .purple : .primary)
                            if let confidence = call.confidence {
                                Text("conf \(String(format: "%.2f", confidence))")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let ms = call.latencyMs {
                                Text("\(ms) ms")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(call.outcome)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        if !call.rankedOptions.isEmpty {
                            Text(call.rankedOptions
                                .map { "\($0.0) \(String(format: "%.2f", $0.1))" }
                                .joined(separator: "  ·  "))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            if !state.actions.isEmpty {
                Text("Action graph").font(.system(size: 13, weight: .semibold))
                    .padding(.top, 4)
                ForEach(state.actions) { action in
                    HStack {
                        Text(action.summary).font(.system(size: 11, design: .monospaced))
                        Spacer()
                        Text(action.statusLabel)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func labelled(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(key)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            Text(value).font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
            Spacer()
        }
    }

    // MARK: Log

    private var logPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Log").font(.system(size: 13, weight: .semibold))
                Spacer()
                Picker("", selection: $categoryFilter) {
                    Text("All").tag(nil as LogCategory?)
                    ForEach(LogCategory.allCategories, id: \.rawValue) { category in
                        Text(category.rawValue).tag(category as LogCategory?)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
                Button("Clear") { state.clearLogs() }.controlSize(.small)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(filteredLines) { line in
                            HStack(alignment: .top, spacing: 6) {
                                Text(line.category.rawValue)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(color(for: line.category))
                                    .frame(width: 70, alignment: .leading)
                                Text(line.message)
                                    .font(.system(size: 10, design: .monospaced))
                                    .textSelection(.enabled)
                                Spacer()
                            }
                            .id(line.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: filteredLines.count) {
                    if let last = filteredLines.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(16)
        .frame(maxHeight: .infinity)
    }

    private var filteredLines: [LogLine] {
        guard let categoryFilter else { return state.logLines }
        return state.logLines.filter { $0.category == categoryFilter }
    }

    private func color(for category: LogCategory) -> Color {
        switch category {
        case .stt, .transcript: return .blue
        case .router, .planner: return .purple
        case .jev, .llm: return .teal
        case .executor, .accessibility: return .green
        case .latency: return .orange
        case .permission: return .red
        default: return .secondary
        }
    }
}

extension LogCategory {
    static var allCategories: [LogCategory] {
        [.app, .audio, .stt, .transcript, .router, .planner, .jev, .llm,
         .executor, .accessibility, .permission, .latency, .hotkey]
    }
}
