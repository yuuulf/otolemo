import AVFAudio
import AudioToolbox
import Foundation
import TranscriberCore

enum CaptureError: LocalizedError {
    case microphonePermissionDenied
    case noInputDevice
    case engineStartFailed(String)
    case processNotFound
    case tapCreationFailed(String)
    case aggregateDeviceFailed(String)
    case ioStartFailed(String)

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied: "マイクの使用が許可されていません。システム設定で許可してください。"
        case .noInputDevice: "使用できるマイクが見つかりません。"
        case .engineStartFailed(let detail): "マイクを開始できませんでした（\(detail)）。"
        case .processNotFound: "対象アプリの音声プロセスが見つかりません。アプリで音声を再生中か確認してください。"
        case .tapCreationFailed(let detail): "相手側の音声を取得できませんでした（\(detail)）。「画面収録とシステムオーディオ録音」の許可を確認してください。"
        case .aggregateDeviceFailed(let detail): "音声取得用のデバイスを作れませんでした（\(detail)）。"
        case .ioStartFailed(let detail): "相手側の音声取得を開始できませんでした（\(detail)）。"
        }
    }
}

/// AVAudioEngine で自分のマイク音声を取得する。
///
/// エコーキャンセルを有効にすると、macOS の音声処理（Voice Processing）を通す。
/// スピーカーから出た相手の声がマイクに回り込んでも、自分の発言として認識されにくくなる。
///
/// タップのコールバックではバッファをコピーしてキューに積むだけにする。
/// デバイスの抜き差しなどで構成が変わったら、自動で入力を作り直す。
@MainActor
final class MicrophoneCapture {
    private var engine = AVAudioEngine()
    private var queue: AudioBufferQueue<CaptureEvent>?
    private var preferredDeviceUID: String?
    private var echoCancellation = true
    private var configurationObserver: (any NSObjectProtocol)?
    /// タップを入れたか。未使用のエンジンで `inputNode` に触れると入力ユニットが初期化されてしまうため。
    private var isTapInstalled = false

    /// 再接続に失敗したときに呼ばれる。
    var onFailure: ((any Error) -> Void)?
    /// 再接続したときに呼ばれる（表示用のデバイス名）。
    var onRestart: ((String) -> Void)?

    private(set) var activeDeviceName: String?
    /// エコーキャンセルが実際に有効になっているか。
    private(set) var isEchoCancellationActive = false

    func start(deviceUID: String?, echoCancellation: Bool) throws -> AudioBufferQueue<CaptureEvent> {
        stop()
        guard AudioPermissions.microphone != .denied else {
            throw CaptureError.microphonePermissionDenied
        }
        preferredDeviceUID = deviceUID
        self.echoCancellation = echoCancellation
        let queue = AudioBufferQueue<CaptureEvent>(capacity: captureQueueCapacity)
        self.queue = queue
        do {
            try startEngine(queue: queue)
        } catch {
            self.queue = nil
            queue.finish()
            throw error
        }
        observeConfigurationChanges()
        return queue
    }

    func stop() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        stopEngine()
        queue?.finish()
        queue = nil
        activeDeviceName = nil
        isEchoCancellationActive = false
    }

    private func startEngine(queue: AudioBufferQueue<CaptureEvent>) throws {
        // デバイスを切り替えるたびに作り直すと、入力フォーマットの変化に確実に追従できる。
        engine = AVAudioEngine()
        let input = engine.inputNode
        // 音声処理を有効にすると入力ユニットが差し替わるため、デバイスの選択より先に行う。
        isEchoCancellationActive = echoCancellation && enableVoiceProcessing(on: input)
        let device = selectDevice(on: input)
        activeDeviceName = device?.name

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.noInputDevice
        }
        do {
            try input.installAudioTap(onBus: 0, bufferSize: 4_096, format: format, tapProvider: Self.makeTapProvider(queue: queue))
            isTapInstalled = true
        } catch {
            throw CaptureError.engineStartFailed(error.localizedDescription)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            stopEngine()
            throw CaptureError.engineStartFailed(error.localizedDescription)
        }
        Log.audio.info("Microphone started: \(format.sampleRate, privacy: .public) Hz, \(format.channelCount, privacy: .public) ch, echo cancellation \(self.isEchoCancellationActive, privacy: .public)")
    }

    private func stopEngine() {
        guard isTapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isTapInstalled = false
    }

    /// 音声処理（エコーキャンセル・雑音抑制）を有効にする。失敗したら処理なしで続ける。
    ///
    /// 有効にすると入力は同じ内容の複数チャンネルになることがあるが、変換時にモノラルへまとめる。
    /// 既定では他のアプリの音量を下げる（ダッキング）ため、会議の音声が小さくならないよう最小にする。
    private func enableVoiceProcessing(on input: AVAudioInputNode) -> Bool {
        do {
            try input.setVoiceProcessingEnabled(true)
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
            return true
        } catch {
            Log.audio.error("Failed to enable voice processing: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// 指定のマイクを使う。見つからなければシステムの既定の入力を使う。
    private func selectDevice(on input: AVAudioInputNode) -> AudioInputDevice? {
        let fallback = AudioDevices.defaultInputDevice()
        guard let uid = preferredDeviceUID,
              let device = AudioDevices.inputDevices().first(where: { $0.uid == uid }) else {
            return fallback
        }
        var deviceID = device.id
        let status = input.withAudioUnit { unit -> OSStatus in
            guard let unit else { return kAudioUnitErr_Uninitialized }
            return AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &deviceID,
                UInt32(MemoryLayout<AudioObjectID>.size)
            )
        }
        if status != noErr {
            Log.audio.error("Failed to select input device: \(status, privacy: .public)")
            return fallback
        }
        return device
    }

    private func observeConfigurationChanges() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let sender = (notification.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, sender == ObjectIdentifier(self.engine) else { return }
                self.restartAfterConfigurationChange()
            }
        }
    }

    private func restartAfterConfigurationChange() {
        guard let queue else { return }
        Log.audio.info("Audio engine configuration changed; restarting microphone")
        stopEngine()
        queue.enqueue(.discontinuity)
        do {
            try startEngine(queue: queue)
            onRestart?(activeDeviceName ?? "既定のマイク")
        } catch {
            Log.audio.error("Microphone restart failed: \(error.localizedDescription, privacy: .public)")
            onFailure?(error)
        }
    }

    /// 音声スレッドで呼ばれるため、MainActor から切り離して作る。
    nonisolated private static func makeTapProvider(
        queue: AudioBufferQueue<CaptureEvent>
    ) -> @Sendable (AVReadOnlyAudioPCMBuffer, AVAudioTime) -> Void {
        { buffer, time in
            guard let copy = AVAudioPCMBuffer.copying(buffer) else { return }
            queue.enqueue(.audio(CapturedAudio(buffer: copy, hostTime: time.hostTimeOrNow)))
        }
    }
}
