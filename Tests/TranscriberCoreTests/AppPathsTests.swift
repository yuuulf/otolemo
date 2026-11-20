import Foundation
import Testing
@testable import TranscriberCore

struct AppPathsTests {
    @Test func databaseLivesInApplicationSupportFolder() {
        let paths = AppPaths.standard
        #expect(paths.databaseURL.lastPathComponent == "meetings.sqlite")
        #expect(paths.baseDirectory.lastPathComponent == "LocalMeetingTranscriber")
        #expect(paths.baseDirectory.path(percentEncoded: false).contains("Library/Application Support"))
    }
}
