import SwiftUI
import TranscriberCore

/// 会話の1行（相対時刻・話者・本文）。暫定テキストは薄く表示する。
struct TranscriptLineRow: View {
    let source: AudioSource
    let startMS: Int64
    let text: String
    let isFinal: Bool
    var isEdited = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(ElapsedTimeFormat.string(milliseconds: startMS))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            SourceBadge(source: source)
            Text(text)
                .foregroundStyle(isFinal ? .primary : .secondary)
                .italic(!isFinal)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !isFinal {
                Text("認識中")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if isEdited {
                Image(systemName: "pencil")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("修正済み")
            }
        }
    }
}

struct SourceBadge: View {
    let source: AudioSource

    var body: some View {
        Text(source.displayName)
            .font(.caption.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(source.tint.opacity(0.15), in: .capsule)
            .foregroundStyle(source.tint)
    }
}

extension AudioSource {
    var tint: Color {
        switch self {
        case .microphone: .blue
        case .system: .orange
        }
    }
}
