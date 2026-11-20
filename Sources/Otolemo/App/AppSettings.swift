import Foundation
import Observation

/// 利用者の設定。UserDefaults に保存する（端末内のみ）。
@MainActor
@Observable
final class AppSettings {
    private let defaults: UserDefaults

    /// 自分のマイクも文字起こしする。OFF なら相手側だけ。
    var useMicrophone: Bool {
        didSet { defaults.set(useMicrophone, forKey: Keys.useMicrophone) }
    }

    /// 使用するマイクの UID。`nil` ならシステムの既定。
    var microphoneUID: String? {
        didSet { defaults.set(microphoneUID, forKey: Keys.microphoneUID) }
    }

    /// マイク入力にエコーキャンセルをかける。スピーカーから出た相手の声を自分の発言として拾わないようにする。
    var echoCancellation: Bool {
        didSet { defaults.set(echoCancellation, forKey: Keys.echoCancellation) }
    }

    var recognizer: RecognizerKind {
        didSet { defaults.set(recognizer.rawValue, forKey: Keys.recognizer) }
    }

    /// 前回選んだ相手側アプリ（`AudioTargetApp.id`、通常は bundle ID）。`nil` ならマイクのみ。
    var targetID: String? {
        didSet { defaults.set(targetID, forKey: Keys.targetID) }
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
        useMicrophone = defaults.object(forKey: Keys.useMicrophone) as? Bool ?? true
        microphoneUID = defaults.string(forKey: Keys.microphoneUID)
        echoCancellation = defaults.object(forKey: Keys.echoCancellation) as? Bool ?? true
        recognizer = defaults.string(forKey: Keys.recognizer).flatMap(RecognizerKind.init(rawValue:)) ?? .speechTranscriber
        targetID = defaults.string(forKey: Keys.targetID)
        saveDebugAudio = defaults.bool(forKey: Keys.saveDebugAudio)
        let retention = defaults.integer(forKey: Keys.debugAudioRetentionDays)
        debugAudioRetentionDays = retention > 0 ? retention : 7
        verboseLogging = defaults.bool(forKey: Keys.verboseLogging)
    }

    private enum Keys {
        static let useMicrophone = "useMicrophone"
        static let microphoneUID = "microphoneUID"
        static let echoCancellation = "echoCancellation"
        static let recognizer = "recognizer"
        static let targetID = "targetID"
        static let saveDebugAudio = "saveDebugAudio"
        static let debugAudioRetentionDays = "debugAudioRetentionDays"
        static let verboseLogging = "verboseLogging"
    }
}
