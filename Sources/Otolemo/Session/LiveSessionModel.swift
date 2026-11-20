import AppKit
import Foundation
import Observation
import TranscriberCore

/// 録音開始時の設定。
struct SessionConfiguration: Sendable {
    var title: String
    var useMicrophone: Bool
    var microphoneUID: String?
    /// マイク入力にエコーキャンセルをかける。
    var echoCancellation = true
    /// 相手側の音声を取得するアプリ。`nil` ならマイクのみ。
    var target: AudioTargetApp?
    var recognizer: RecognizerKind
    var saveDebugAudio: Bool
}

/// ライブ画面の状態。2系統（自分のマイク・相手側アプリ）の取得と認識を開始/停止し、
/// 暫定・確定結果を会議の時刻順にまとめる。
///
/// 系統ごとに独立して開始・失敗・再試行できる。片方が失敗しても、もう片方は続ける。
/// 確定した発言だけを SQLite に随時保存する（暫定結果は保存しない）。
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
    /// 保存に失敗して再試行待ちの発言がある場合のメッセージ。
    private(set) var saveError: String?
    private(set) var savedCount = 0

    var lines: [TranscriptLine] {
        merger?.lines ?? []
    }

    var isRecording: Bool {
        phase == .recording
    }

    private let storage: StorageModel
    private let microphone = MicrophoneCapture()
    private let systemAudio = ProcessAudioCapture()
    private let coordinator = RecognitionCoordinator()
    private var clock: MeetingClock?
    private var configuration: SessionConfiguration?
    private var writer: SegmentWriter?
    /// 確定発言の保存を直列につないだ最後のタスク。停止時にこれを待ってから flush する。
    private var lastSave: Task<Void, Never>?
    private var workspaceObservers: [any NSObjectProtocol] = []

    init(storage: StorageModel) {
        self.storage = storage
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
        observeSleepAndWake()
    }

    func start(_ configuration: SessionConfiguration) async {
        guard phase == .idle else { return }
        guard configuration.useMicrophone || configuration.target != nil else {
            errorMessage = "マイクか相手側のアプリのどちらかを選んでください。"
            return
        }
        guard let repository = storage.repository else {
            errorMessage = storage.openError ?? "データベースを開けません。"
            return
        }
        phase = .starting
        errorMessage = nil
        saveError = nil
        savedCount = 0
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
        do {
            // 音声を取得する前に会議を作る（`recording` 状態）。異常終了しても確定済みの発言は残る。
            try await repository.createMeeting(meeting)
        } catch {
            errorMessage = "会議を保存できませんでした: \(error.localizedDescription)"
            phase = .idle
            return
        }
        storage.didChange()
        writer = SegmentWriter(repository: repository)
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
            await tearDown(deleting: meeting.id)
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
            await saveEnd(of: meeting)
        }
        phase = .idle
        Log.session.info("Session stopped")
    }

    /// 残りの発言を保存し、会議を「完了」にする。
    private func saveEnd(of meeting: Meeting) async {
        await lastSave?.value
        lastSave = nil
        if let writer, await writer.flush() == false {
            let pending = await writer.pendingCount
            saveError = "\(pending) 件の発言を保存できませんでした。"
            Log.storage.error("Failed to flush \(pending, privacy: .public) segments")
        }
        do {
            try await storage.repository?.finishMeeting(id: meeting.id, endedAt: meeting.endedAt ?? .now, status: .completed)
        } catch {
            saveError = "会議の終了を保存できませんでした: \(error.localizedDescription)"
        }
        if let writer {
            savedCount = await writer.writtenCount
        }
        storage.didChange()
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
            queue = try microphone.start(deviceUID: configuration.microphoneUID, echoCancellation: configuration.echoCancellation)
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
        try? storage.paths.createDirectories()
        return DebugAudioRecorder(directory: storage.paths.debugAudioDirectory, meetingID: meetingID, source: source)
    }

    // MARK: - 結果

    private func apply(_ update: TranscriptUpdate) {
        guard merger != nil else { return }
        if update.isFinal, let clock {
            let delay = clock.elapsedMillisecondsNow() - update.endMS
            latency[update.source, default: LatencyStats()].record(milliseconds: delay)
            if Log.isVerbose {
                // 本文は出さず、長さと遅延だけを記録する。
                let dropped = metrics[update.source]?.queue.dropped ?? 0
                Log.session.info("final \(update.source.rawValue, privacy: .public) len=\(update.text.count, privacy: .public) delay=\(delay, privacy: .public)ms dropped=\(dropped, privacy: .public)")
            }
        }
        guard let segment = merger?.apply(update), let writer else { return }
        let previous = lastSave
        lastSave = Task {
            await previous?.value
            let saved = await writer.enqueue(segment)
            let pending = await writer.pendingCount
            savedCount = await writer.writtenCount
            saveError = saved ? nil : "\(pending) 件の発言が保存待ちです（自動で再試行します）。"
        }
    }

    private func handleRecognitionFailure(_ source: AudioSource, _ error: any Error) {
        sourceErrors[source] = "音声認識が停止しました: \(error.localizedDescription)"
        stopCapture(source)
        activeSources.remove(source)
        merger?.clearVolatile(for: source)
    }

    /// 開始に失敗したときの後始末。何も記録していない会議は消す。
    private func tearDown(deleting meetingID: UUID) async {
        for source in AudioSource.allCases {
            stopCapture(source)
            await coordinator.cancel(source: source)
        }
        try? await storage.repository?.deleteMeeting(id: meetingID)
        storage.didChange()
        activeSources = []
        meeting = nil
        merger = nil
        writer = nil
        phase = .idle
    }

    // MARK: - スリープ

    /// スリープ中は音声が届かない。復帰したら、動いていた系統を作り直す（確定済みの結果は保持）。
    private func observeSleepAndWake() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.phase == .recording else { return }
                Log.session.info("System will sleep during recording")
                self.notices[.microphone] = "スリープ中は記録が止まります"
            }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.phase == .recording else { return }
                Task { await self.restartAfterWake() }
            }
        })
    }

    private func restartAfterWake() async {
        Log.session.info("Restarting sources after wake")
        for source in activeSources.sorted(by: { $0.rawValue > $1.rawValue }) {
            await stopSource(source, discardingPending: false)
            do {
                try await startSource(source)
                notices[source] = "スリープから復帰し、記録を再開しました"
            } catch {
                sourceErrors[source] = error.localizedDescription
            }
        }
    }
}
