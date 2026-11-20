import SwiftUI
import TranscriberCore

/// ライブ画面。入力の選択、録音の開始/停止、入力レベル、逐次の文字起こしを表示する。
struct LiveView: View {
    @Environment(LiveSessionModel.self) private var session
    @Environment(AppSettings.self) private var settings
    @Environment(SpeechModelManager.self) private var models

    @ViewState private var title = ""
    @ViewState private var microphones: [AudioInputDevice] = []

    var body: some View {
        VStack(spacing: 0) {
            controls
                .padding()
            Divider()
            statusArea
            TranscriptListView(lines: session.lines)
        }
        .navigationTitle("ライブ")
        .task {
            microphones = AudioDevices.inputDevices()
            await models.refresh()
        }
    }

    // MARK: - 操作

    private var controls: some View {
        @Bindable var settings = settings
        return VStack(alignment: .leading) {
            HStack {
                TextField("会議タイトル（空欄なら日時）", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .disabled(session.phase != .idle)
                RecordButton()
            }
            HStack {
                Picker("マイク", selection: $settings.microphoneUID) {
                    Text("システムの既定").tag(String?.none)
                    ForEach(microphones) { device in
                        Text(device.name).tag(Optional(device.uid))
                    }
                }
                .frame(maxWidth: 320)
                .disabled(session.phase != .idle)
                Button("更新", systemImage: "arrow.clockwise") {
                    microphones = AudioDevices.inputDevices()
                }
                .labelStyle(.iconOnly)
                Spacer()
                ModelStatusLabel(status: models.status(for: settings.recognizer), kind: settings.recognizer)
            }
            VStack {
                LevelMeterView(label: AudioSource.microphone.displayName, level: session.metrics[.microphone]?.level ?? 0, tint: AudioSource.microphone.tint)
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private var statusArea: some View {
        VStack(alignment: .leading, spacing: 4) {
            if session.isRecording {
                RecordingBanner()
            }
            if let message = session.errorMessage {
                ErrorRow(message: message, retry: nil)
            }
            ForEach(AudioSource.allCases) { source in
                if let message = session.sourceErrors[source] {
                    ErrorRow(message: "\(source.displayName): \(message)") {
                        Task { await session.retry(source) }
                    }
                }
                if let notice = session.notices[source] {
                    Label(notice, systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, session.isRecording || session.errorMessage != nil || !session.sourceErrors.isEmpty ? 8 : 0)
    }
}

/// 録音の開始/停止ボタン。
private struct RecordButton: View {
    @Environment(LiveSessionModel.self) private var session
    @Environment(AppSettings.self) private var settings
    @Environment(SpeechModelManager.self) private var models

    var body: some View {
        switch session.phase {
        case .idle:
            Button("開始", systemImage: "record.circle") {
                Task { await session.start(configuration) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!models.status(for: settings.recognizer).isReady)
        case .starting:
            ProgressView()
                .controlSize(.small)
        case .recording:
            Button("終了", systemImage: "stop.circle.fill") {
                Task { await session.stop() }
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        case .stopping:
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("確定中…")
            }
        }
    }

    private var configuration: SessionConfiguration {
        SessionConfiguration(
            title: "",
            microphoneUID: settings.microphoneUID,
            recognizer: settings.recognizer,
            saveDebugAudio: settings.saveDebugAudio
        )
    }
}

/// 録音中であることを明示し、参加者への周知を促す。
private struct RecordingBanner: View {
    @Environment(LiveSessionModel.self) private var session

    var body: some View {
        HStack {
            Image(systemName: "record.circle.fill")
                .foregroundStyle(.red)
                .symbolEffect(.pulse)
            if let startedAt = session.meeting?.startedAt {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text("記録中 \(ElapsedTimeFormat.string(milliseconds: Int64(context.date.timeIntervalSince(startedAt) * 1000)))")
                        .monospacedDigit()
                }
            }
            Text("参加者に録音・文字起こししていることを知らせてください。")
                .foregroundStyle(.secondary)
            Spacer()
            MetricsSummary()
        }
        .font(.callout)
    }
}

/// 遅延と欠落の簡易表示。
private struct MetricsSummary: View {
    @Environment(LiveSessionModel.self) private var session

    var body: some View {
        HStack {
            ForEach(AudioSource.allCases) { source in
                if let metrics = session.metrics[source] {
                    let stats = session.latency[source]
                    Text("\(source.displayName): 遅延 \(Self.seconds(stats?.mean)) / p95 \(Self.seconds(stats?.p95))・欠落 \(metrics.queue.dropped)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(metrics.queue.dropped > 0 ? .red : .secondary)
                }
            }
        }
    }

    private static func seconds(_ milliseconds: Int64?) -> String {
        guard let milliseconds else { return "-" }
        return (Double(milliseconds) / 1000).formatted(.number.precision(.fractionLength(1))) + "秒"
    }
}

private struct ErrorRow: View {
    let message: String
    let retry: (() -> Void)?

    var body: some View {
        HStack {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Spacer()
            if let retry {
                Button("再試行", action: retry)
            }
        }
        .font(.callout)
    }
}

private struct ModelStatusLabel: View {
    let status: SpeechModelStatus
    let kind: RecognizerKind

    var body: some View {
        if status.isReady {
            Label("日本語モデル: 準備完了", systemImage: "checkmark.seal")
                .foregroundStyle(.green)
                .font(.callout)
        } else {
            Label("日本語モデル: \(status.installation.displayName)（診断タブで確認）", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .font(.callout)
        }
    }
}

/// 会話一覧。新しい行が増えると下端に追従する。
struct TranscriptListView: View {
    let lines: [TranscriptLine]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(lines) { line in
                    TranscriptLineRow(source: line.source, startMS: line.startMS, text: line.text, isFinal: line.isFinal)
                }
            }
            .padding()
        }
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .overlay {
            if lines.isEmpty {
                ContentUnavailableView("まだ発言はありません", systemImage: "text.bubble", description: Text("「開始」を押すと、ここに文字起こしが表示されます。"))
            }
        }
    }
}
