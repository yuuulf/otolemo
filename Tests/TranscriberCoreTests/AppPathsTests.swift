import Foundation
import Testing
@testable import TranscriberCore

struct AppPathsTests {
    @Test func databaseLivesInApplicationSupportFolder() {
        let paths = AppPaths.standard
        #expect(paths.databaseURL.lastPathComponent == "meetings.sqlite")
        #expect(paths.baseDirectory.lastPathComponent == "Otolemo")
        #expect(paths.legacyDirectory?.lastPathComponent == "LocalMeetingTranscriber")
        #expect(paths.baseDirectory.path(percentEncoded: false).contains("Library/Application Support"))
    }

    @Test func movesLegacyFolderWhenNewFolderIsMissing() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appending(path: "Legacy", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("db".utf8).write(to: legacy.appending(path: "meetings.sqlite"))
        let paths = AppPaths(baseDirectory: root.appending(path: "New", directoryHint: .isDirectory), legacyDirectory: legacy)

        #expect(try paths.migrateLegacyDirectoryIfNeeded())
        #expect(try Data(contentsOf: paths.databaseURL) == Data("db".utf8))
        #expect(!FileManager.default.fileExists(atPath: legacy.path(percentEncoded: false)))
    }

    @Test func keepsBothFoldersWhenNewFolderExists() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appending(path: "Legacy", directoryHint: .isDirectory)
        let paths = AppPaths(baseDirectory: root.appending(path: "New", directoryHint: .isDirectory), legacyDirectory: legacy)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try paths.createDirectories()

        #expect(try !paths.migrateLegacyDirectoryIfNeeded())
        #expect(FileManager.default.fileExists(atPath: legacy.path(percentEncoded: false)))
    }

    @Test func doesNothingWithoutLegacyDirectory() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(baseDirectory: root.appending(path: "New", directoryHint: .isDirectory))

        #expect(try !paths.migrateLegacyDirectoryIfNeeded())
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = URL.temporaryDirectory.appending(path: "AppPathsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
