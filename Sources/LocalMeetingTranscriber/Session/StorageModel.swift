import Foundation
import Observation
import TranscriberCore

/// 端末内の SQLite データベースを開き、画面に変更を知らせる。
@MainActor
@Observable
final class StorageModel {
    let paths: AppPaths
    private(set) var repository: MeetingRepository?
    private(set) var openError: String?
    /// 前回の異常終了で「中断」にした会議の数。
    private(set) var recoveredCount = 0
    /// 会議の追加・変更・削除のたびに増える。一覧の再読み込みに使う。
    private(set) var changeToken = 0

    init(paths: AppPaths) {
        self.paths = paths
        open()
    }

    func open() {
        do {
            try paths.createDirectories()
            repository = try MeetingRepository(url: paths.databaseURL)
            openError = nil
            Log.storage.info("Database opened")
        } catch {
            repository = nil
            openError = "データベースを開けませんでした: \(error.localizedDescription)"
            Log.storage.error("Database open failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 起動時に、記録中のまま残った会議を「中断」にする。
    func recoverUnfinishedMeetings() async {
        guard let repository else { return }
        do {
            recoveredCount = try await repository.recoverUnfinishedMeetings().count
            if recoveredCount > 0 {
                Log.storage.info("Recovered \(self.recoveredCount, privacy: .public) interrupted meetings")
                didChange()
            }
        } catch {
            Log.storage.error("Recovery failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func dismissRecoveryNotice() {
        recoveredCount = 0
    }

    func didChange() {
        changeToken += 1
    }
}
