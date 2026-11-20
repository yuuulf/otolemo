import AVFAudio
import AppKit
import CoreAudio
import Foundation
import TranscriberCore

/// Core Audio Process Tap で、選んだアプリ（Zoom / Chrome など）の出力音声を取得する。
///
/// 構成: Process Tap → 非公開の Aggregate Device → IOProc（専用キュー）→ キュー。
/// 取得されるのは対象アプリの出力全体なので、複数人の声や通知音も含まれうる。
///
/// - タップはプロセスオブジェクトの ID で指定する（bundle ID 指定では音声が届かなかったため）。
/// - Chrome は音声用のヘルパーを後から起動するので、プロセス一覧の変化を監視して
///   対象アプリのプロセスが増減したらタップの対象を更新する。アプリの再起動にも追従する。
/// - 既定の出力デバイスが変わったら作り直す。
@MainActor
final class ProcessAudioCapture {
    private var tap: AudioHardwareTap?
    private var aggregate: AudioHardwareAggregateDevice?
    private var ioProcID: AudioDeviceIOProcID?
    private var queue: AudioBufferQueue<CaptureEvent>?
    private var target: AudioTargetApp?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var processListListener: AudioObjectPropertyListenerBlock?
    private var terminationObserver: (any NSObjectProtocol)?
    private let ioQueue = DispatchQueue(label: "ProcessAudioCapture.io", qos: .userInteractive)

    /// 作り直しに失敗したときに呼ばれる。
    var onFailure: ((any Error) -> Void)?
    /// 状況の変化（出力デバイス切替・対象アプリ終了）を知らせる。
    var onNotice: ((String) -> Void)?

    private(set) var formatDescription: String?

    func start(target: AudioTargetApp) throws -> AudioBufferQueue<CaptureEvent> {
        stop()
        self.target = target
        let queue = AudioBufferQueue<CaptureEvent>(capacity: captureQueueCapacity)
        self.queue = queue
        do {
            try build(target: target, queue: queue)
        } catch {
            tearDownDevices()
            self.queue = nil
            self.target = nil
            queue.finish()
            throw error
        }
        observeOutputDevice()
        observeProcessList()
        observeTermination(of: target)
        return queue
    }

    func stop() {
        removeObservers()
        tearDownDevices()
        queue?.finish()
        queue = nil
        target = nil
        formatDescription = nil
    }

    // MARK: - 構成

    private func build(target: AudioTargetApp, queue: AudioBufferQueue<CaptureEvent>) throws {
        let system = AudioHardwareSystem.shared

        let description = CATapDescription(stereoMixdownOfProcesses: target.processObjectIDs)
        description.name = "LocalMeetingTranscriber: \(target.name)"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted

        let tap: AudioHardwareTap
        do {
            guard let created = try system.makeProcessTap(description: description) else {
                throw CaptureError.tapCreationFailed("タップを作成できません")
            }
            tap = created
        } catch let error as CaptureError {
            throw error
        } catch {
            throw CaptureError.tapCreationFailed(error.localizedDescription)
        }
        self.tap = tap

        var streamDescription = try tap.format
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            throw CaptureError.tapCreationFailed("音声形式を読み取れません")
        }
        formatDescription = "\(Int(format.sampleRate)) Hz / \(format.channelCount) ch"

        guard let outputUID = AudioDevices.defaultOutputDeviceUID() else {
            throw CaptureError.aggregateDeviceFailed("出力デバイスが見つかりません")
        }
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "LocalMeetingTranscriber Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: try tap.uid
            ]]
        ]
        do {
            guard let device = try system.makeAggregateDevice(description: aggregateDescription) else {
                throw CaptureError.aggregateDeviceFailed("作成できません")
            }
            aggregate = device
        } catch let error as CaptureError {
            throw error
        } catch {
            throw CaptureError.aggregateDeviceFailed(error.localizedDescription)
        }
        guard let aggregate else { return }

        var procID: AudioDeviceIOProcID?
        let block = Self.makeIOBlock(format: AudioFormatBox(format: format), queue: queue)
        var status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate.id, ioQueue, block)
        guard status == noErr, let procID else {
            throw CaptureError.ioStartFailed("IOProc \(status)")
        }
        ioProcID = procID
        status = AudioDeviceStart(aggregate.id, procID)
        guard status == noErr else {
            throw CaptureError.ioStartFailed("開始 \(status)")
        }
        Log.audio.info("Process tap started: \(format.sampleRate, privacy: .public) Hz, \(format.channelCount, privacy: .public) ch, \(target.processObjectIDs.count, privacy: .public) processes")
    }

    private func tearDownDevices() {
        let system = AudioHardwareSystem.shared
        if let aggregate, let ioProcID {
            AudioDeviceStop(aggregate.id, ioProcID)
            AudioDeviceDestroyIOProcID(aggregate.id, ioProcID)
        }
        ioProcID = nil
        if let aggregate {
            try? system.destroyAggregateDevice(aggregate)
        }
        aggregate = nil
        if let tap {
            try? system.destroyProcessTap(tap)
        }
        tap = nil
    }

    /// 既定の出力デバイスが変わったら、新しいデバイスで作り直す。
    private func rebuild() {
        guard let target, let queue else { return }
        Log.audio.info("Rebuilding process tap")
        tearDownDevices()
        queue.enqueue(.discontinuity)
        do {
            // 作り直す時点のプロセス一覧で対象を更新する。
            let refreshed = AudioProcessList.targets().first { $0.id == target.id } ?? target
            self.target = refreshed
            try build(target: refreshed, queue: queue)
            onNotice?("出力デバイスの変更に合わせて、相手側の音声取得を再開しました")
        } catch {
            Log.audio.error("Process tap rebuild failed: \(error.localizedDescription, privacy: .public)")
            onFailure?(error)
        }
    }

    /// 対象アプリのプロセス（ヘルパーを含む）が増減したら、タップの対象を更新する。
    private func refreshTappedProcesses() {
        guard let target, let tap, let current = AudioProcessList.targets().first(where: { $0.id == target.id }) else {
            return
        }
        guard Set(current.processObjectIDs) != Set(target.processObjectIDs) else { return }
        do {
            let description = try tap.description
            description.processes = current.processObjectIDs
            try tap.setDescription(description)
            self.target = current
            Log.audio.info("Process tap updated: \(current.processObjectIDs.count, privacy: .public) processes")
        } catch {
            Log.audio.error("Process tap update failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - 監視

    private func observeOutputDevice() {
        outputListener = addSystemListener(kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
            self?.rebuild()
        }
    }

    private func observeProcessList() {
        processListListener = addSystemListener(kAudioHardwarePropertyProcessObjectList) { [weak self] in
            self?.refreshTappedProcesses()
        }
    }

    private func addSystemListener(
        _ selector: AudioObjectPropertySelector,
        action: @escaping @MainActor () -> Void
    ) -> AudioObjectPropertyListenerBlock? {
        var address = PropertyAddress(selector)
        let listener = Self.makeListener(action)
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        return status == noErr ? listener : nil
    }

    private func removeSystemListener(_ selector: AudioObjectPropertySelector, _ listener: AudioObjectPropertyListenerBlock?) {
        guard let listener else { return }
        var address = PropertyAddress(selector)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
    }

    private func observeTermination(of target: AudioTargetApp) {
        guard let pid = target.pid else { return }
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let terminatedPID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                guard terminatedPID == pid, let self else { return }
                self.onNotice?("\(target.name) が終了しました。再起動すると自動で取得を再開します")
            }
        }
    }

    private func removeObservers() {
        removeSystemListener(kAudioHardwarePropertyDefaultOutputDevice, outputListener)
        outputListener = nil
        removeSystemListener(kAudioHardwarePropertyProcessObjectList, processListListener)
        processListListener = nil
        if let terminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver)
        }
        terminationObserver = nil
    }

    // MARK: - コールバック（MainActor の外で呼ばれる）

    nonisolated private static func makeListener(_ action: @escaping @MainActor () -> Void) -> AudioObjectPropertyListenerBlock {
        { _, _ in
            Task { @MainActor in action() }
        }
    }

    /// IOProc。専用キューで呼ばれる。バッファをコピーしてキューに積むだけにする。
    nonisolated private static func makeIOBlock(format: AudioFormatBox, queue: AudioBufferQueue<CaptureEvent>) -> AudioDeviceIOBlock {
        { _, inputData, inputTime, _, _ in
            guard let source = AVAudioPCMBuffer(pcmFormat: format.format, bufferListNoCopy: inputData, deallocator: nil),
                  let copy = source.deepCopy() else { return }
            let timestamp = inputTime.pointee
            let hostTime = timestamp.mFlags.contains(.hostTimeValid) ? timestamp.mHostTime : mach_absolute_time()
            queue.enqueue(.audio(CapturedAudio(buffer: copy, hostTime: hostTime)))
        }
    }
}
