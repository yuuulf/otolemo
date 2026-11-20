import AppKit
import TranscriberCore

/// アプリ全体で共有する状態を持ち、終了時に録音中なら確定・保存してから終わる。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = AppSettings()
    let models = SpeechModelManager()
    let network = NetworkStatus()
    let storage = StorageModel(paths: .standard)
    lazy var session = LiveSessionModel(storage: storage)

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.setVerbose(settings.verboseLogging)
        Task {
            await storage.recoverUnfinishedMeetings()
        }
        DebugAudioRecorder.removeExpired(in: storage.paths.debugAudioDirectory, olderThan: settings.debugAudioRetentionDays)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard session.phase == .recording || session.phase == .stopping else {
            return .terminateNow
        }
        Task {
            await session.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
