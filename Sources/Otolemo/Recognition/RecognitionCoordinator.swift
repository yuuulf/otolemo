import Foundation
import TranscriberCore

/// 系統ごとに「取得キュー → 変換 → 認識エンジン → 結果」をつなぐ。
/// 各系統は独立した認識セッションを持ち、互いの音声を混ぜない。
@MainActor
final class RecognitionCoordinator {
    private struct Channel {
        let engine: any TranscriptionEngine
        let pipelineTask: Task<Void, Never>
        let resultsTask: Task<Void, Never>
    }

    private var channels: [AudioSource: Channel] = [:]

    var onUpdate: ((TranscriptUpdate) -> Void)?
    var onMetrics: ((AudioSource, PipelineMetrics) -> Void)?
    var onError: ((AudioSource, any Error) -> Void)?

    var activeSources: Set<AudioSource> {
        Set(channels.keys)
    }

    func start(
        source: AudioSource,
        capture queue: AudioBufferQueue<CaptureEvent>,
        clock: MeetingClock,
        engine: any TranscriptionEngine,
        recorder: DebugAudioRecorder?
    ) async throws {
        await cancel(source: source)

        let format = try await engine.prepare()
        let (input, inputContinuation) = AsyncStream.makeStream(of: EngineInput.self)
        let results: AsyncThrowingStream<RecognizedText, any Error>
        do {
            results = try await engine.start(input: input)
        } catch {
            inputContinuation.finish()
            throw error
        }

        let pipeline = AudioPipeline(source: source, targetFormat: format, clock: clock)
        let pipelineTask = Task.detached(priority: .userInitiated) { [weak self] in
            await pipeline.run(
                events: queue.stream,
                queueMetrics: { queue.metrics },
                output: inputContinuation,
                recorder: recorder
            ) { metrics in
                Task { @MainActor in
                    self?.onMetrics?(source, metrics)
                }
            }
        }

        let resultsTask = Task { [weak self] in
            do {
                for try await result in results {
                    self?.onUpdate?(TranscriptUpdate(
                        source: source,
                        text: result.text,
                        startMS: result.startMS,
                        endMS: result.endMS,
                        isFinal: result.isFinal
                    ))
                }
            } catch is CancellationError {
                return
            } catch {
                Log.recognition.error("Recognition failed for \(source.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
                self?.onError?(source, error)
            }
        }

        channels[source] = Channel(engine: engine, pipelineTask: pipelineTask, resultsTask: resultsTask)
        Log.recognition.info("Recognition started for \(source.rawValue, privacy: .public) with \(engine.identifier, privacy: .public)")
    }

    /// 取得キューが閉じられた後に呼ぶ。残りの音声を認識し、確定結果をすべて受け取ってから戻る。
    func finish(source: AudioSource) async {
        guard let channel = channels.removeValue(forKey: source) else { return }
        await channel.pipelineTask.value
        await channel.engine.finish()
        await channel.resultsTask.value
    }

    /// 残りを捨てて止める。
    func cancel(source: AudioSource) async {
        guard let channel = channels.removeValue(forKey: source) else { return }
        await channel.engine.cancel()
        channel.resultsTask.cancel()
        await channel.pipelineTask.value
    }
}
