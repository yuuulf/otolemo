import SwiftUI
import TranscriberCore

/// ライブ画面。入力の選択、録音の開始/停止、入力レベル、逐次の文字起こしを表示する。
struct LiveView: View {
    @Environment(LiveSessionModel.self) private var session
    @Environment(AppSettings.self) private var settings
    @Environment(SpeechModelManager.self) private var models

    @ViewState private var title = ""
    @ViewState private var microphones: [AudioInputDevice] = []
    @ViewState private var targets: [AudioTargetApp] = []

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
            refreshDevices()
            await models.refresh()
        }
    }

    private func refreshDevices() {
        microphones = AudioDevices.inputDevices()
        targets = AudioProcessList.targets()
    }

    private var selectedTarget: AudioTargetApp? {
        targets.first { $0.id == settings.targetID }
    }

    // MARK: - 操作

    private var controls: some View {
        @Bindable var settings = settings
        return VStack(alignment: .leading) {
            HStack {
                TextField("会議タイトル（空欄なら日時）", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .disabled(session.phase != .idle)
                RecordButton(title: title, target: selectedTarget)
            }
            HStack {
                Picker("相手側", selection: $settings.targetID) {
                    Text("なし（マイクのみ）").tag(String?.none)
                    ForEach(targets) { target in
                        Text(target.isPlayingAudio ? "\(target.name) ♪" : target.name).tag(Optional(target.id))
                    }
                }
                .frame(maxWidth: 320)
                Toggle("自分のマイク", isOn: $settings.useMicrophone)
                Picker("マイク", selection: $settings.microphoneUID) {
                    Text("システムの既定").tag(String?.none)
                    ForEach(microphones) { device in
                        Text(device.name).tag(Optional(device.uid))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
                .disabled(!settings.useMicrophone)
                Button("更新", systemImage: "arrow.clockwise", action: refreshDevices)
                    .labelStyle(.iconOnly)
                    .help("アプリとマイクの一覧を更新")
            }
            .disabled(session.phase != .idle)
            HStack {
                Text("相手側はアプリの出力全体を取得します（通知音や別タブの音声も含まれます）。♪ は音声を再生中のアプリです。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                ModelStatusLabel(status: models.status(for: settings.recognizer), kind: settings.recognizer)
            }
            VStack {
                LevelMeterView(label: AudioSource.microphone.displayName, level: session.metrics[.microphone]?.level ?? 0, tint: AudioSource.microphone.tint)
                LevelMeterView(label: AudioSource.system.displayName, level: session.metrics[.system]?.level ?? 0, tint: AudioSource.system.tint)
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
            if session.activeSources.contains(.system), let silent = session.metrics[.system]?.silentSeconds, silent > 30 {
                Label("相手側の音声が \(Int(silent)) 秒以上無音です。対象アプリと「画面収録とシステムオーディオ録音」の許可を確認してください。", systemImage: "speaker.slash")
                    .font(.callout)
                    .foregroundStyle(.orange)
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
    let title: String
    let target: AudioTargetApp?

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
            .disabled(!models.status(for: settings.recognizer).isReady || (!settings.useMicrophone && target == nil))
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
            title: title,
            useMicrophone: settings.useMicrophone,
            microphoneUID: settings.microphoneUID,
            target: target,
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
