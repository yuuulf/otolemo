import Foundation
import Observation
import TranscriberCore

/// 録音開始時の設定。
struct SessionConfiguration: Sendable {
    var title: String
    var useMicrophone: Bool
    var microphoneUID: String?
    /// 相手側の音声を取得するアプリ。`nil` ならマイクのみ。
    var target: AudioTargetApp?
    var recognizer: RecognizerKind
    var saveDebugAudio: Bool
}

/// ライブ画面の状態。2系統（自分のマイク・相手側アプリ）の取得と認識を開始/停止し、
/// 暫定・確定結果を会議の時刻順にまとめる。
///
/// 系統ごとに独立して開始・失敗・再試行できる。片方が失敗しても、もう片方は続ける。
@MainActor
@Observable
final class LiveSessionModel {
    enum Phase: Equatable {
        case idle
        case starting
        case recording
        case stopping
    }

    private(set) var phase: Phase = .idle
    private(set) var meeting: Meeting?
    private(set) var merger: TranscriptMerger?
    private(set) var metrics: [AudioSource: PipelineMetrics] = [:]
    private(set) var latency: [AudioSource: LatencyStats] = [:]
    private(set) var sourceErrors: [AudioSource: String] = [:]
    private(set) var notices: [AudioSource: String] = [:]
    private(set) var errorMessage: String?
    private(set) var microphoneName: String?
    private(set) var activeSources: Set<AudioSource> = []

    var lines: [TranscriptLine] {
        merger?.lines ?? []
    }

    var isRecording: Bool {
        phase == .recording
    }

    private let paths: AppPaths
    private let microphone = MicrophoneCapture()
    private let systemAudio = ProcessAudioCapture()
    private let coordinator = RecognitionCoordinator()
    private var clock: MeetingClock?
    private var configuration: SessionConfiguration?

    init(paths: AppPaths) {
        self.paths = paths
        coordinator.onUpdate = { [weak self] update in self?.apply(update) }
        coordinator.onMetrics = { [weak self] source, metrics in self?.metrics[source] = metrics }
        coordinator.onError = { [weak self] source, error in self?.handleRecognitionFailure(source, error) }
        microphone.onRestart = { [weak self] name in
            self?.microphoneName = name
            self?.notices[.microphone] = "マイクを再接続しました（\(name)）"
        }
        microphone.onFailure = { [weak self] error in
            self?.sourceErrors[.microphone] = error.localizedDescription
        }
        systemAudio.onNotice = { [weak self] message in
            self?.notices[.system] = message
        }
        systemAudio.onFailure = { [weak self] error in
            self?.sourceErrors[.system] = error.localizedDescription
        }
    }

    func start(_ configuration: SessionConfiguration) async {
        guard phase == .idle else { return }
        guard configuration.useMicrophone || configuration.target != nil else {
            errorMessage = "マイクか相手側のアプリのどちらかを選んでください。"
            return
        }
        phase = .starting
        errorMessage = nil
        sourceErrors = [:]
        notices = [:]
        metrics = [:]
        latency = [:]
        activeSources = []

        if configuration.useMicrophone, AudioPermissions.microphone == .undetermined {
            _ = await AudioPermissions.requestMicrophone()
        }

        let startedAt = Date.now
        let title = configuration.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let meeting = Meeting(
            title: title.isEmpty ? Self.defaultTitle(for: startedAt) : title,
            sourceApp: configuration.target?.name ?? "マイクのみ",
            startedAt: startedAt
        )
        clock = MeetingClock.startingNow()
        self.configuration = configuration
        self.meeting = meeting
        merger = TranscriptMerger(meetingID: meeting.id, engine: configuration.recognizer.engineIdentifier)

        // 相手側を先に開始する（2系統目の認識が資源不足で失敗した場合でも、相手側を優先して残す）。
        var sources: [AudioSource] = []
        if configuration.target != nil { sources.append(.system) }
        if configuration.useMicrophone { sources.append(.microphone) }
        for source in sources {
            do {
                try await startSource(source)
            } catch {
                sourceErrors[source] = error.localizedDescription
            }
        }

        guard !activeSources.isEmpty else {
            errorMessage = "音声を取得できませんでした。"
            await tearDown()
            return
        }
        phase = .recording
        Log.session.info("Session started with \(self.activeSources.count, privacy: .public) sources")
    }

    func stop() async {
        guard phase == .recording else { return }
        phase = .stopping
        microphone.stop()
        systemAudio.stop()
        async let microphoneDone: Void = coordinator.finish(source: .microphone)
        async let systemDone: Void = coordinator.finish(source: .system)
        _ = await (microphoneDone, systemDone)
        activeSources = []
        for source in AudioSource.allCases {
            merger?.clearVolatile(for: source)
        }
        if var meeting {
            meeting.endedAt = .now
            meeting.status = .completed
            self.meeting = meeting
        }
        phase = .idle
        Log.session.info("Session stopped")
    }

    /// 失敗した系統をやり直す。
    func retry(_ source: AudioSource) async {
        guard phase == .recording else { return }
        sourceErrors[source] = nil
        await stopSource(source, discardingPending: true)
        do {
            try await startSource(source)
        } catch {
            sourceErrors[source] = error.localizedDescription
        }
    }

    func clearNotice(_ source: AudioSource) {
        notices[source] = nil
    }

    static func defaultTitle(for date: Date) -> String {
        "会議 " + date.formatted(date: .numeric, time: .shortened)
    }

    // MARK: - 系統ごとの開始・停止

    private func startSource(_ source: AudioSource) async throws {
        guard let clock, let configuration, let meeting else { return }
        let queue: AudioBufferQueue<CaptureEvent>
        switch source {
        case .microphone:
            queue = try microphone.start(deviceUID: configuration.microphoneUID)
            microphoneName = microphone.activeDeviceName
        case .system:
            guard let target = configuration.target else { return }
            queue = try systemAudio.start(target: target)
        }
        do {
            try await coordinator.start(
                source: source,
                capture: queue,
                clock: clock,
                engine: AppleSpeechEngine(kind: configuration.recognizer),
                recorder: makeRecorder(for: source, meetingID: meeting.id, enabled: configuration.saveDebugAudio)
            )
        } catch {
            stopCapture(source)
            throw error
        }
        activeSources.insert(source)
    }

    private func stopSource(_ source: AudioSource, discardingPending: Bool) async {
        stopCapture(source)
        if discardingPending {
            await coordinator.cancel(source: source)
        } else {
            await coordinator.finish(source: source)
        }
        activeSources.remove(source)
        merger?.clearVolatile(for: source)
    }

    private func stopCapture(_ source: AudioSource) {
        switch source {
        case .microphone: microphone.stop()
        case .system: systemAudio.stop()
        }
    }

    private func makeRecorder(for source: AudioSource, meetingID: UUID, enabled: Bool) -> DebugAudioRecorder? {
        guard enabled else { return nil }
        try? paths.createDirectories()
        return DebugAudioRecorder(directory: paths.debugAudioDirectory, meetingID: meetingID, source: source)
    }

    // MARK: - 結果

    private func apply(_ update: TranscriptUpdate) {
        guard merger != nil else { return }
        if update.isFinal, let clock {
            latency[update.source, default: LatencyStats()].record(
                milliseconds: clock.elapsedMillisecondsNow() - update.endMS
            )
        }
        merger?.apply(update)
    }

    private func handleRecognitionFailure(_ source: AudioSource, _ error: any Error) {
        sourceErrors[source] = "音声認識が停止しました: \(error.localizedDescription)"
        stopCapture(source)
        activeSources.remove(source)
        merger?.clearVolatile(for: source)
    }

    private func tearDown() async {
        for source in AudioSource.allCases {
            stopCapture(source)
            await coordinator.cancel(source: source)
        }
        activeSources = []
        meeting = nil
        merger = nil
        phase = .idle
    }
}
