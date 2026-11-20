import Foundation
import Observation

/// 利用者の設定。UserDefaults に保存する（端末内のみ）。
@MainActor
@Observable
final class AppSettings {
    private let defaults: UserDefaults

    /// 使用するマイクの UID。`nil` ならシステムの既定。
    var microphoneUID: String? {
        didSet { defaults.set(microphoneUID, forKey: Keys.microphoneUID) }
    }

    var recognizer: RecognizerKind {
        didSet { defaults.set(recognizer.rawValue, forKey: Keys.recognizer) }
    }

    /// 前回選んだ相手側アプリの bundle ID。
    var targetBundleID: String? {
        didSet { defaults.set(targetBundleID, forKey: Keys.targetBundleID) }
    }

    /// デバッグ用に音声をファイル保存する（既定は OFF）。
    var saveDebugAudio: Bool {
        didSet { defaults.set(saveDebugAudio, forKey: Keys.saveDebugAudio) }
    }

    /// デバッグ音声の保存日数。
    var debugAudioRetentionDays: Int {
        didSet { defaults.set(debugAudioRetentionDays, forKey: Keys.debugAudioRetentionDays) }
    }

    /// 診断用の詳細ログ。ON でも文字起こし本文はログに出さない。
    var verboseLogging: Bool {
        didSet { defaults.set(verboseLogging, forKey: Keys.verboseLogging) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        microphoneUID = defaults.string(forKey: Keys.microphoneUID)
        recognizer = defaults.string(forKey: Keys.recognizer).flatMap(RecognizerKind.init(rawValue:)) ?? .speechTranscriber
        targetBundleID = defaults.string(forKey: Keys.targetBundleID)
        saveDebugAudio = defaults.bool(forKey: Keys.saveDebugAudio)
        let retention = defaults.integer(forKey: Keys.debugAudioRetentionDays)
        debugAudioRetentionDays = retention > 0 ? retention : 7
        verboseLogging = defaults.bool(forKey: Keys.verboseLogging)
    }

    private enum Keys {
        static let microphoneUID = "microphoneUID"
        static let recognizer = "recognizer"
        static let targetBundleID = "targetBundleID"
        static let saveDebugAudio = "saveDebugAudio"
        static let debugAudioRetentionDays = "debugAudioRetentionDays"
        static let verboseLogging = "verboseLogging"
    }
}
