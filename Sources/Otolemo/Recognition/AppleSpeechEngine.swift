import AVFAudio
import CoreMedia
import Foundation
import Speech

/// SpeechAnalyzer + SpeechTranscriber（または DictationTranscriber）による端末内の音声認識。
/// 1系統につき1つ作り、系統ごとに独立したセッションで認識する。
actor AppleSpeechEngine: TranscriptionEngine {
    nonisolated let kind: RecognizerKind
    nonisolated var identifier: String { kind.engineIdentifier }

    private var module: (any SpeechModule)?
    private var analyzer: SpeechAnalyzer?
    private var forwarding: Task<Void, Never>?

    init(kind: RecognizerKind) {
        self.kind = kind
    }

    func prepare() async throws -> AudioFormatBox {
        guard let locale = await kind.supportedLocale() else {
            throw RecognitionError.localeUnsupported
        }
        let module = kind.makeLiveModule(locale: locale)
        // モデルのダウンロードは診断画面で利用者が行う。ここでは導入済みかだけを確認する。
        // 導入済みでも AssetInventory が `supported` を返すことがあるため、導入済みロケールも見る。
        let installedLocales = await kind.installedLocales()
        let isInstalled = installedLocales.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
        let assetStatus = await AssetInventory.status(forModules: [module])
        guard isInstalled || assetStatus == .installed else {
            throw RecognitionError.modelNotInstalled
        }
        _ = try? await AssetInventory.reserve(locale: locale)

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw RecognitionError.noCompatibleAudioFormat
        }
        let analyzer = SpeechAnalyzer(
            modules: [module],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
        )
        try await analyzer.prepareToAnalyze(in: format)
        self.module = module
        self.analyzer = analyzer
        return AudioFormatBox(format: format)
    }

    func start(input: AsyncStream<EngineInput>) async throws -> AsyncThrowingStream<RecognizedText, any Error> {
        guard let module, let analyzer else {
            throw RecognitionError.modelNotInstalled
        }
        let results = SpeechModuleResults.stream(of: module)
        let (analyzerInput, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        forwarding = Task {
            for await item in input {
                let startTime = item.startSeconds.map { CMTime(seconds: $0, preferredTimescale: 1_000_000) }
                continuation.yield(AnalyzerInput(buffer: item.buffer, bufferStartTime: startTime))
            }
            continuation.finish()
        }
        try await analyzer.start(inputSequence: analyzerInput)
        return results
    }

    func finish() async {
        await forwarding?.value
        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            Log.recognition.error("Finalize failed: \(error.localizedDescription, privacy: .public)")
            await analyzer?.cancelAndFinishNow()
        }
    }

    func cancel() async {
        forwarding?.cancel()
        await analyzer?.cancelAndFinishNow()
    }
}
