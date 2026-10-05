import SwiftUI

/// Local log of past spoken commands and what each one actually did.
struct HistoryView: View {
    @EnvironmentObject private var state: AppState
    @State private var expanded: Set<UUID> = []
    @State private var searchText = ""

    private var filtered: [CommandRecord] {
        guard !searchText.isEmpty else { return state.history }
        let needle = Fuzzy.normalize(searchText)
        return state.history.filter { record in
            Fuzzy.normalize(record.transcript).contains(needle)
                || record.actions.contains { Fuzzy.normalize($0.summary).contains(needle) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            if filtered.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filtered) { record in
                            row(record)
                            Divider()
                        }
                    }
                }
            }

            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 520)
        .onAppear { state.reloadHistory() }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text("Command History").font(.system(size: 13, weight: .semibold))

            TextField("Filter", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)

            Spacer()

            Button("Refresh") { state.reloadHistory() }.controlSize(.small)
            Button("Reveal File") { state.revealHistoryInFinder() }.controlSize(.small)
            Button("Clear") { state.clearHistory() }
                .controlSize(.small)
                .disabled(state.history.isEmpty)
        }
        .padding(12)
    }

    // MARK: Row

    private func row(_ record: CommandRecord) -> some View {
        let isExpanded = expanded.contains(record.id)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .frame(width: 10)

                VStack(alignment: .leading, spacing: 3) {
                    Text(record.transcript.isEmpty ? "(no transcript)" : record.transcript)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(isExpanded ? nil : 1)

                    HStack(spacing: 8) {
                        Text(record.startedAt.formatted(date: .abbreviated, time: .standard))
                        badge(record)
                        if let first = record.timeToFirstActionMs {
                            Label("\(Int(first)) ms to first action", systemImage: "bolt")
                        }
                        if record.executedMidSentence {
                            Label("mid-sentence", systemImage: "waveform")
                                .foregroundStyle(.blue)
                        }
                        // Visible at a glance, without expanding the row.
                        if record.jevConsultations.contains(where: { $0.applied }) {
                            Label("Jev", systemImage: "brain.head.profile")
                                .foregroundStyle(.purple)
                        } else if !record.jevConsultations.isEmpty {
                            Label("Jev asked", systemImage: "brain")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if isExpanded { expanded.remove(record.id) } else { expanded.insert(record.id) }
            }

            if isExpanded { detail(record) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func badge(_ record: CommandRecord) -> some View {
        let text: String
        let colour: Color
        if record.actions.isEmpty {
            text = "no action"; colour = .secondary
        } else if record.failedCount > 0 {
            text = "\(record.failedCount) failed"; colour = .red
        } else {
            text = "\(record.succeededCount) action\(record.succeededCount == 1 ? "" : "s")"
            colour = .green
        }
        return Text(text)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(colour.opacity(0.15), in: Capsule())
            .foregroundStyle(colour)
    }

    private func detail(_ record: CommandRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let stable = record.stablePrefixAtFirstAction, !stable.isEmpty {
                // The evidence that execution began before the sentence ended.
                Text("Acted on: \"\(stable)\"")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.blue)
            }

            ForEach(record.actions) { action in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: icon(for: action.status))
                            .font(.system(size: 9))
                            .foregroundStyle(colour(for: action.status))
                        Text(action.summary)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                        Text(action.risk)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Text("via \(action.origin)")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                        Spacer()
                        if let duration = action.durationMs {
                            Text("\(duration) ms")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let message = action.message, !message.isEmpty {
                        Text(message)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 15)
                    }
                    if !action.dependsOn.isEmpty {
                        Text("waits for \(action.dependsOn.count) earlier action\(action.dependsOn.count == 1 ? "" : "s")")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 15)
                    }
                }
            }

            jevSection(record)

            HStack(spacing: 12) {
                if let t = record.timeToFirstTranscriptMs {
                    metric("first transcript", t)
                }
                if let t = record.timeToFirstActionMs {
                    metric("first action", t)
                }
                if let t = record.totalMs {
                    metric("action done", t)
                }
                Text("outcome: \(record.outcome)")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, 18)
        .padding(.top, 2)
    }

    /// Jev's involvement — or an explicit statement that it was not involved,
    /// which is otherwise indistinguishable from it having declined.
    @ViewBuilder
    private func jevSection(_ record: CommandRecord) -> some View {
        if record.jevConsultations.isEmpty {
            Label("Jev not consulted — the local router handled this command",
                  systemImage: "bolt.slash")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        } else {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(record.jevConsultations) { call in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Image(systemName: call.applied
                                  ? "brain.head.profile" : "brain")
                                .font(.system(size: 9))
                                .foregroundStyle(call.applied ? .purple : .secondary)
                            Text("Jev → \(call.chosenAction ?? "—")")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                            if let confidence = call.confidence {
                                Text("conf \(String(format: "%.2f", confidence))")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            if let risk = call.risk {
                                Text(risk).font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let ms = call.latencyMs {
                                Text("\(ms) ms")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Text("asked because: \(call.reason)")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 15)

                        Text(call.outcome)
                            .font(.system(size: 10))
                            .foregroundStyle(call.applied ? .purple : .secondary)
                            .padding(.leading, 15)

                        if !call.rankedOptions.isEmpty {
                            // What Jev weighed up, not just what it picked.
                            Text(call.rankedOptions
                                .map { "\($0.0) \(String(format: "%.2f", $0.1))" }
                                .joined(separator: "  ·  "))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 15)
                        }

                        if let needsMore = call.needsMoreSpeech, let safe = call.safeToSpeculate {
                            Text("needs_more_speech \(needsMore ? "yes" : "no")  ·  safe_to_speculate \(safe ? "yes" : "no")")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 15)
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func metric(_ label: String, _ value: Double) -> some View {
        Text("\(label) \(Int(value)) ms")
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(.secondary)
    }

    private func icon(for status: String) -> String {
        if status == "completed" { return "checkmark.circle.fill" }
        if status.hasPrefix("failed") { return "xmark.circle.fill" }
        if status == "cancelled" { return "minus.circle" }
        if status == "running" { return "arrow.triangle.2.circlepath" }
        return "clock"
    }

    private func colour(for status: String) -> Color {
        if status == "completed" { return .green }
        if status.hasPrefix("failed") { return .red }
        if status == "cancelled" { return .secondary }
        return .orange
    }

    // MARK: Chrome

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text(state.history.isEmpty ? "No commands recorded yet." : "No matches.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if state.history.isEmpty && !state.settings.keepHistory {
                Text("History is turned off in Settings.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Text("\(state.history.count) command\(state.history.count == 1 ? "" : "s") · \(sizeText)")
            Spacer()
            Text("Stored locally at \(CommandHistory.fileURL.path)")
                .lineLimit(1)
                .truncationMode(.head)
        }
        .font(.system(size: 9))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var sizeText: String {
        let bytes = state.historySizeBytes
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024) KB" }
        return String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }
}
