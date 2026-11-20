import AVFoundation
import Foundation
import Speech

/// 音声ファイルを認識して、オフラインで動くか・どの程度の精度かを確認する（Phase 0 / 精度評価用）。
enum FileTranscriptionTest {
    struct Outcome: Sendable {
        var text: String
        var audioSeconds: Double
        var processingSeconds: Double
        var segmentCount: Int
    }

    static func run(fileURL: URL, kind: RecognizerKind) async throws -> Outcome {
        guard let locale = await kind.supportedLocale() else {
            throw RecognitionError.localeUnsupported
        }
        let accessing = fileURL.startAccessingSecurityScopedResource()
        defer {
            if accessing { fileURL.stopAccessingSecurityScopedResource() }
        }

        let file = try AVAudioFile(forReading: fileURL)
        let audioSeconds = Double(file.length) / file.processingFormat.sampleRate
        let module = kind.makeLiveModule(locale: locale)
        let analyzer = SpeechAnalyzer(modules: [module])
        let started = ContinuousClock.now

        let collector = Task {
            var finals: [String] = []
            for try await result in SpeechModuleResults.stream(of: module) where result.isFinal {
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { finals.append(text) }
            }
            return finals
        }

        do {
            if let end = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: end)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            throw error
        }

        let finals = try await collector.value
        let elapsed = ContinuousClock.now - started
        return Outcome(
            text: finals.joined(separator: "\n"),
            audioSeconds: audioSeconds,
            processingSeconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
            segmentCount: finals.count
        )
    }
}

enum RecognitionError: LocalizedError {
    case localeUnsupported
    case modelNotInstalled
    case noCompatibleAudioFormat

    var errorDescription: String? {
        switch self {
        case .localeUnsupported: "この認識モデルは日本語（ja-JP）に対応していません。"
        case .modelNotInstalled: "日本語の音声認識モデルが導入されていません。診断タブからダウンロードしてください。"
        case .noCompatibleAudioFormat: "認識モデルが受け付ける音声形式を取得できませんでした。"
        }
    }
}
