import Foundation
import Speech

/// 使用する Apple の音声認識モジュール。
enum RecognizerKind: String, CaseIterable, Identifiable, Sendable {
    /// 長い会話向けの新しいモデル（第一候補）。
    case speechTranscriber
    /// 従来の音声入力モデル（代替）。
    case dictationTranscriber

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .speechTranscriber: "SpeechTranscriber（推奨）"
        case .dictationTranscriber: "DictationTranscriber（代替）"
        }
    }

    /// DB の `segments.engine` に保存する識別子。
    var engineIdentifier: String {
        switch self {
        case .speechTranscriber: "apple.speech-transcriber"
        case .dictationTranscriber: "apple.dictation-transcriber"
        }
    }

    static let requestedLocale = Locale(identifier: "ja-JP")

    /// このモデルが `ja-JP` に対応していれば、対応するロケールを返す。
    func supportedLocale(equivalentTo locale: Locale = requestedLocale) async -> Locale? {
        switch self {
        case .speechTranscriber: await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        case .dictationTranscriber: await DictationTranscriber.supportedLocale(equivalentTo: locale)
        }
    }

    var isAvailableOnDevice: Bool {
        switch self {
        case .speechTranscriber: SpeechTranscriber.isAvailable
        case .dictationTranscriber: true
        }
    }

    func installedLocales() async -> [Locale] {
        switch self {
        case .speechTranscriber: await SpeechTranscriber.installedLocales
        case .dictationTranscriber: await DictationTranscriber.installedLocales
        }
    }

    /// 会議の逐次表示向けの設定（暫定結果あり、時刻付き）で認識モジュールを作る。
    func makeLiveModule(locale: Locale) -> any SpeechModule {
        switch self {
        case .speechTranscriber:
            SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults, .fastResults],
                attributeOptions: [.audioTimeRange]
            )
        case .dictationTranscriber:
            DictationTranscriber(
                locale: locale,
                contentHints: [],
                transcriptionOptions: [.punctuation],
                reportingOptions: [.volatileResults, .frequentFinalization],
                attributeOptions: [.audioTimeRange]
            )
        }
    }
}
