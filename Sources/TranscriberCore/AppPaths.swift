import Foundation

/// アプリが端末内に保存するファイルの場所。
public struct AppPaths: Sendable {
    public static let folderName = "Otolemo"
    /// 改名前のフォルダ名。既存のデータを引き継ぐために使う。
    public static let legacyFolderName = "LocalMeetingTranscriber"

    /// `~/Library/Application Support/Otolemo`
    public let baseDirectory: URL
    /// 改名前の保存先。`baseDirectory` がまだないときだけ、ここから移す。
    public let legacyDirectory: URL?

    public init(baseDirectory: URL, legacyDirectory: URL? = nil) {
        self.baseDirectory = baseDirectory
        self.legacyDirectory = legacyDirectory
    }

    public static var standard: AppPaths {
        AppPaths(
            baseDirectory: URL.applicationSupportDirectory.appending(path: folderName, directoryHint: .isDirectory),
            legacyDirectory: URL.applicationSupportDirectory.appending(path: legacyFolderName, directoryHint: .isDirectory)
        )
    }

    public var databaseURL: URL {
        baseDirectory.appending(path: "meetings.sqlite")
    }

    public var backupsDirectory: URL {
        baseDirectory.appending(path: "Backups", directoryHint: .isDirectory)
    }

    public var debugAudioDirectory: URL {
        baseDirectory.appending(path: "DebugAudio", directoryHint: .isDirectory)
    }

    /// 新しい保存先がまだなく、改名前の保存先があれば、フォルダごと移す。移したら `true`。
    @discardableResult
    public func migrateLegacyDirectoryIfNeeded() throws -> Bool {
        let fileManager = FileManager.default
        guard let legacyDirectory,
              !fileManager.fileExists(atPath: baseDirectory.path(percentEncoded: false)),
              fileManager.fileExists(atPath: legacyDirectory.path(percentEncoded: false)) else {
            return false
        }
        try fileManager.createDirectory(at: baseDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: legacyDirectory, to: baseDirectory)
        return true
    }

    public func createDirectories() throws {
        let fileManager = FileManager.default
        for directory in [baseDirectory, backupsDirectory, debugAudioDirectory] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}
