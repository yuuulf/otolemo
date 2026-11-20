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
/// タップのコールバックではバッファをコピーしてキューに積むだけにする。
/// デバイスの抜き差しなどで構成が変わったら、自動で入力を作り直す。
@MainActor
final class MicrophoneCapture {
    private var engine = AVAudioEngine()
    private var queue: AudioBufferQueue<CaptureEvent>?
    private var preferredDeviceUID: String?
    private var configurationObserver: (any NSObjectProtocol)?

    /// 再接続に失敗したときに呼ばれる。
    var onFailure: ((any Error) -> Void)?
    /// 再接続したときに呼ばれる（表示用のデバイス名）。
    var onRestart: ((String) -> Void)?

    private(set) var activeDeviceName: String?

    func start(deviceUID: String?) throws -> AudioBufferQueue<CaptureEvent> {
        stop()
        guard AudioPermissions.microphone != .denied else {
            throw CaptureError.microphonePermissionDenied
        }
        preferredDeviceUID = deviceUID
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
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        queue?.finish()
        queue = nil
        activeDeviceName = nil
    }

    private func startEngine(queue: AudioBufferQueue<CaptureEvent>) throws {
        // デバイスを切り替えるたびに作り直すと、入力フォーマットの変化に確実に追従できる。
        engine = AVAudioEngine()
        let input = engine.inputNode
        let device = selectDevice(on: input)
        activeDeviceName = device?.name

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.noInputDevice
        }
        do {
            try input.installAudioTap(onBus: 0, bufferSize: 4_096, format: format, tapProvider: Self.makeTapProvider(queue: queue))
        } catch {
            throw CaptureError.engineStartFailed(error.localizedDescription)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureError.engineStartFailed(error.localizedDescription)
        }
        Log.audio.info("Microphone started: \(format.sampleRate, privacy: .public) Hz, \(format.channelCount, privacy: .public) ch")
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
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
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
