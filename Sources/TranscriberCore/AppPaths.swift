import Foundation

/// アプリが端末内に保存するファイルの場所。
public struct AppPaths: Sendable {
    public static let folderName = "LocalMeetingTranscriber"

    /// `~/Library/Application Support/LocalMeetingTranscriber`
    public let baseDirectory: URL

    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    public static var standard: AppPaths {
        AppPaths(baseDirectory: URL.applicationSupportDirectory.appending(path: folderName, directoryHint: .isDirectory))
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

    public func createDirectories() throws {
        let fileManager = FileManager.default
        for directory in [baseDirectory, backupsDirectory, debugAudioDirectory] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}
