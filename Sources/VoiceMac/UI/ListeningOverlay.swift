import SwiftUI

/// The floating indicator shown while listening.
///
/// Shows the transcript split into the part we trust (the stable prefix, which
/// drives execution) and the part still in flight, so the mid-sentence
/// behaviour is visible rather than mysterious.
struct ListeningOverlay: View {
    @EnvironmentObject private var state: AppState

    private var pendingTail: String {
        let full = state.fullText
        let stable = state.stableText
        guard full.count > stable.count, full.hasPrefix(stable) else {
            return state.transcriptIsFinal ? "" : full == stable ? "" : full
        }
        return String(full.dropFirst(stable.count))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if state.stableText.isEmpty && state.fullText.isEmpty {
                Text(state.isListening ? "Listening…" : "Ready")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            } else {
                transcript
            }

            if let confirmation = state.pendingConfirmation {
                confirmationPrompt(confirmation.summary)
            }

            if let jev = state.lastJevConsultation {
                HStack(spacing: 6) {
                    Image(systemName: jev.applied ? "brain.head.profile" : "brain")
                        .font(.system(size: 10))
                        .foregroundStyle(jev.applied ? .purple : .secondary)
                    Text("Jev: \(jev.chosenAction ?? "—") — \(jev.outcome)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let ms = jev.latencyMs {
                        Text("\(ms) ms")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            if !state.actions.isEmpty {
                actionList
            }

            footer
        }
        .padding(16)
        .frame(width: 460, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 9, height: 9)

            Text(state.sessionState.label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            Spacer()

            levelMeter
        }
    }

    private var indicatorColor: Color {
        switch state.sessionState {
        case .idle: return .secondary
        case .starting: return .yellow
        case .listening, .transcribing: return .red
        case .understanding: return .blue
        case .executing: return .green
        case .failed: return .orange
        }
    }

    private var levelMeter: some View {
        HStack(spacing: 2) {
            ForEach(0..<14, id: \.self) { index in
                let threshold = Float(index) / 14.0
                RoundedRectangle(cornerRadius: 1)
                    .fill(state.level > threshold ? Color.accentColor : Color.secondary.opacity(0.2))
                    .frame(width: 3, height: 4 + CGFloat(index) * 0.7)
            }
        }
        .frame(height: 14, alignment: .bottom)
    }

    private var transcript: some View {
        // Stable text is rendered solid, the unstable tail dimmed — the dimmed
        // part is precisely what has not been allowed to trigger anything yet.
        (Text(state.stableText)
            .foregroundStyle(.primary)
         + Text(pendingTail)
            .foregroundStyle(.secondary))
            .font(.system(size: 16, weight: .medium))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func confirmationPrompt(_ summary: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(.orange)
                Text(summary)
                    .font(.system(size: 13, weight: .semibold))
            }
            Text("This action is not reversible, so it needs your confirmation.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("Confirm") { state.confirmPending() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Discard") { state.rejectPending() }
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private var actionList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(state.actions) { action in
                HStack(spacing: 7) {
                    Image(systemName: icon(for: action.status))
                        .font(.system(size: 10))
                        .foregroundStyle(color(for: action.status))
                        .frame(width: 12)
                    Text(action.summary)
                        .font(.system(size: 12, weight: .medium))
                    Text(action.statusLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                }
            }
        }
    }

    private func icon(for status: ActionStatus) -> String {
        switch status {
        case .pending: return "circle.dotted"
        case .waiting: return "clock"
        case .awaitingConfirmation: return "exclamationmark.circle"
        case .running: return "arrow.triangle.2.circlepath"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "minus.circle"
        }
    }

    private func color(for status: ActionStatus) -> Color {
        switch status {
        case .completed: return .green
        case .failed: return .red
        case .running: return .blue
        case .awaitingConfirmation: return .orange
        default: return .secondary
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let first = state.latency.timeToFirstAction {
                Label("\(Int(first)) ms to first action", systemImage: "bolt")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            if !state.lastError.isEmpty {
                Text(state.lastError)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            } else if !state.lastMessage.isEmpty {
                Text(state.lastMessage)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if state.isListening {
                Text("Esc to cancel")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
