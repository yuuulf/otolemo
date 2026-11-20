import AppKit
import TranscriberCore

/// アプリ全体で共有する状態を持ち、終了時に録音中なら確定・保存してから終わる。
/// 会議中に文字起こしが相手へ見えないよう、すべてのウィンドウを画面共有・画面収録の対象外にする。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = AppSettings()
    let models = SpeechModelManager()
    let network = NetworkStatus()
    let storage = StorageModel(paths: .standard)
    lazy var session = LiveSessionModel(storage: storage)
    private var windowObservation: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.setVerbose(settings.verboseLogging)
        excludeWindowsFromScreenCapture()
        Task {
            await storage.recoverUnfinishedMeetings()
        }
        DebugAudioRecorder.removeExpired(in: storage.paths.debugAudioDirectory, olderThan: settings.debugAudioRetentionDays)
    }

    /// 既存のウィンドウと、あとから開くウィンドウ（設定・シートなど）を画面共有の対象外にする。
    /// 新しいウィンドウは表示されるとキーウィンドウになるので、そのたびに全ウィンドウへ適用し直す。
    private func excludeWindowsFromScreenCapture() {
        Self.applyScreenCaptureExclusion()
        windowObservation = Task { @MainActor in
            for await _ in NotificationCenter.default.notifications(named: NSWindow.didBecomeKeyNotification) {
                Self.applyScreenCaptureExclusion()
            }
        }
    }

    private static func applyScreenCaptureExclusion() {
        for window in NSApp.windows where window.sharingType != .none {
            window.sharingType = .none
        }
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
