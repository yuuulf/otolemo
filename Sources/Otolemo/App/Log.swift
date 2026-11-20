import os
import Synchronization

/// ログの出し先。生音声や文字起こし本文はログに出さない（出す場合も `privacy: .private`）。
enum Log {
    static let subsystem = "io.github.yuuulf.Otolemo"

    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let recognition = Logger(subsystem: subsystem, category: "recognition")
    static let storage = Logger(subsystem: subsystem, category: "storage")
    static let session = Logger(subsystem: subsystem, category: "session")

    private static let verbose = Atomic<Bool>(false)

    /// 設定「詳細なログを出す」。計測値などを追加で出す。
    static var isVerbose: Bool {
        verbose.load(ordering: .relaxed)
    }

    static func setVerbose(_ enabled: Bool) {
        verbose.store(enabled, ordering: .relaxed)
    }
}
