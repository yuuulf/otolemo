import os

/// ログの出し先。生音声や文字起こし本文は既定でログに出さない（`privacy: .private`）。
enum Log {
    static let subsystem = "io.github.yuuulf.LocalMeetingTranscriber"

    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let recognition = Logger(subsystem: subsystem, category: "recognition")
    static let storage = Logger(subsystem: subsystem, category: "storage")
    static let session = Logger(subsystem: subsystem, category: "session")
}
