import Foundation
import Observation
import TranscriberCore

/// 録音開始時の設定。
struct SessionConfiguration: Sendable {
    var title: String
    var microphoneUID: String?
    var recognizer: RecognizerKind
    var saveDebugAudio: Bool
}

/// ライブ画面の状態。音声の取得・認識を開始/停止し、暫定・確定結果を時刻順にまとめる。
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

    var lines: [TranscriptLine] {
        merger?.lines ?? []
    }

    var isRecording: Bool {
        phase == .recording
    }

    private let paths: AppPaths
    private let microphone = MicrophoneCapture()
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
    }

    func start(_ configuration: SessionConfiguration) async {
        guard phase == .idle else { return }
        phase = .starting
        errorMessage = nil
        sourceErrors = [:]
        notices = [:]
        metrics = [:]
        latency = [:]

        if AudioPermissions.microphone == .undetermined {
            _ = await AudioPermissions.requestMicrophone()
        }

        let clock = MeetingClock.startingNow()
        let meeting = Meeting(title: configuration.title, sourceApp: "マイクのみ", startedAt: .now)
        self.clock = clock
        self.configuration = configuration
        self.meeting = meeting
        merger = TranscriptMerger(meetingID: meeting.id, engine: configuration.recognizer.engineIdentifier)

        do {
            try await startMicrophone()
        } catch {
            errorMessage = error.localizedDescription
            await tearDown()
            return
        }
        phase = .recording
        Log.session.info("Session started")
    }

    func stop() async {
        guard phase == .recording else { return }
        phase = .stopping
        microphone.stop()
        await coordinator.finish(source: .microphone)
        if var meeting {
            meeting.endedAt = .now
            meeting.status = .completed
            self.meeting = meeting
        }
        for source in AudioSource.allCases {
            merger?.clearVolatile(for: source)
        }
        phase = .idle
        Log.session.info("Session stopped")
    }

    /// エラーで止まった系統をやり直す。
    func retry(_ source: AudioSource) async {
        guard phase == .recording, source == .microphone else { return }
        sourceErrors[source] = nil
        microphone.stop()
        await coordinator.cancel(source: source)
        do {
            try await startMicrophone()
        } catch {
            sourceErrors[source] = error.localizedDescription
        }
    }

    func clearNotice(_ source: AudioSource) {
        notices[source] = nil
    }

    // MARK: - 内部

    private func startMicrophone() async throws {
        guard let clock, let configuration, let meeting else { return }
        let queue = try microphone.start(deviceUID: configuration.microphoneUID)
        microphoneName = microphone.activeDeviceName
        do {
            try await coordinator.start(
                source: .microphone,
                capture: queue,
                clock: clock,
                engine: AppleSpeechEngine(kind: configuration.recognizer),
                recorder: makeRecorder(for: .microphone, meetingID: meeting.id, enabled: configuration.saveDebugAudio)
            )
        } catch {
            microphone.stop()
            throw error
        }
    }

    private func makeRecorder(for source: AudioSource, meetingID: UUID, enabled: Bool) -> DebugAudioRecorder? {
        guard enabled else { return nil }
        try? paths.createDirectories()
        return DebugAudioRecorder(directory: paths.debugAudioDirectory, meetingID: meetingID, source: source)
    }

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
        merger?.clearVolatile(for: source)
        if source == .microphone {
            microphone.stop()
        }
    }

    private func tearDown() async {
        microphone.stop()
        await coordinator.cancel(source: .microphone)
        meeting = nil
        merger = nil
        phase = .idle
    }
}
