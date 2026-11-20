import AVFAudio
import Foundation
import TranscriberCore

/// 認識エンジンへ渡す、変換済みの音声。
struct EngineInput: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    /// 会議経過秒で表した開始時刻。連続していれば `nil`。
    let startSeconds: Double?
}

/// 1系統の音声処理の計測値。
struct PipelineMetrics: Sendable, Equatable {
    var level: Float = 0
    var processedBuffers = 0
    var processedSeconds: Double = 0
    /// 入力の途切れ（スリープ・デバイス切替など）の回数と合計秒数。
    var gaps = 0
    var gapSeconds: Double = 0
    var restarts = 0
    var conversionErrors = 0
    /// 連続して無音だった秒数（権限が無いと無音が届くため、その検出に使う）。
    var silentSeconds: Double = 0
    var queue = AudioBufferQueue<CaptureEvent>.Metrics()
}

/// 取得した音声を、認識エンジンの形式に変換し会議の時間軸に合わせて渡す。
///
/// 音声コールバックとは別のタスクで動き、重い処理（形式変換・ファイル書き込み）はここで行う。
struct AudioPipeline: Sendable {
    let source: AudioSource
    let targetFormat: AudioFormatBox
    let clock: MeetingClock

    /// 無音とみなすレベル（-50dBFS 未満）。
    static let silenceThreshold: Float = AudioLevel.normalized(decibels: -50)

    func run(
        events: AsyncStream<CaptureEvent>,
        queueMetrics: @escaping @Sendable () -> AudioBufferQueue<CaptureEvent>.Metrics,
        output: AsyncStream<EngineInput>.Continuation,
        recorder: DebugAudioRecorder?,
        report: @escaping @Sendable (PipelineMetrics) -> Void
    ) async {
        var timeline = StreamTimeline(clock: clock)
        var converter: AVAudioConverter?
        var metrics = PipelineMetrics()
        var lastReport = ContinuousClock.now
        let format = targetFormat.format

        for await event in events {
            switch event {
            case .discontinuity:
                timeline.markDiscontinuity()
                metrics.restarts += 1

            case .audio(let captured):
                let buffer = captured.buffer
                let duration = Double(buffer.frameLength) / buffer.format.sampleRate
                let level = Self.measureLevel(buffer)
                metrics.level = AudioLevel.smoothed(previous: metrics.level, current: level)
                metrics.silentSeconds = level < Self.silenceThreshold ? metrics.silentSeconds + duration : 0

                let placement = timeline.place(
                    hostTime: captured.hostTime,
                    frameCount: Int(buffer.frameLength),
                    sampleRate: buffer.format.sampleRate
                )
                if placement.gapSeconds > 0 {
                    metrics.gaps += 1
                    metrics.gapSeconds += placement.gapSeconds
                }

                if converter?.inputFormat != buffer.format {
                    converter = AVAudioConverter(from: buffer.format, to: format)
                }
                guard let converter, let converted = Self.convert(buffer, using: converter, to: format) else {
                    metrics.conversionErrors += 1
                    continue
                }
                recorder?.write(converted)
                output.yield(EngineInput(buffer: converted, startSeconds: placement.explicitStartSeconds))
                metrics.processedBuffers += 1
                metrics.processedSeconds += duration
            }

            let now = ContinuousClock.now
            if now - lastReport >= .milliseconds(100) {
                lastReport = now
                metrics.queue = queueMetrics()
                report(metrics)
            }
        }

        recorder?.close()
        output.finish()
        metrics.level = 0
        metrics.queue = queueMetrics()
        report(metrics)
    }

    static func measureLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return 0 }
        let count = Int(buffer.frameLength) * (buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1)
        return AudioLevel.normalizedLevel(UnsafeBufferPointer(start: channels[0], count: count))
    }

    /// 形式を変換する。変換器はサンプルレート変換の状態を持つので、系統ごとに使い回す。
    static func convert(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        let feed = SingleBufferFeed(buffer)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            feed.next(inputStatus)
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        return output
    }
}

/// 変換器へ1つのバッファを1回だけ渡す。
private final class SingleBufferFeed: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard let buffer else {
            status.pointee = .noDataNow
            return nil
        }
        self.buffer = nil
        status.pointee = .haveData
        return buffer
    }
}

/// `AVAudioFormat` をタスク間で渡すための入れ物（生成後は変更しない）。
struct AudioFormatBox: @unchecked Sendable {
    let format: AVAudioFormat
}
