import CoreMedia
import Foundation
import Speech

/// 認識モジュールの結果を、モジュールの種類によらない形にしたもの。
struct RecognizedText: Sendable {
    var text: String
    var range: CMTimeRange
    var isFinal: Bool
}

extension RecognizedText {
    /// 会議の時間軸（秒）上の範囲をミリ秒にする。
    var startMS: Int64 {
        Self.milliseconds(range.start)
    }

    var endMS: Int64 {
        Self.milliseconds(CMTimeRangeGetEnd(range))
    }

    private static func milliseconds(_ time: CMTime) -> Int64 {
        guard time.isValid, time.isNumeric else { return 0 }
        return Int64((time.seconds * 1000).rounded())
    }
}

enum SpeechModuleResults {
    /// SpeechTranscriber / DictationTranscriber の結果を `RecognizedText` の列として読む。
    static func stream(of module: any SpeechModule) -> AsyncThrowingStream<RecognizedText, any Error> {
        if let transcriber = module as? SpeechTranscriber {
            return map(transcriber.results) { RecognizedText(text: String($0.text.characters), range: $0.range, isFinal: $0.isFinal) }
        }
        if let dictation = module as? DictationTranscriber {
            return map(dictation.results) { RecognizedText(text: String($0.text.characters), range: $0.range, isFinal: $0.isFinal) }
        }
        return AsyncThrowingStream { $0.finish() }
    }

    private static func map<S: AsyncSequence & Sendable>(
        _ sequence: S,
        transform: @escaping @Sendable (S.Element) -> RecognizedText
    ) -> AsyncThrowingStream<RecognizedText, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await element in sequence {
                        continuation.yield(transform(element))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
