import AVFAudio
import Foundation
import TranscriberCore

/// デバッグ用に、認識エンジンへ渡した音声を系統ごとにファイルへ保存する。
///
/// 本番の音声は保存しないのが既定。設定で明示的に ON にしたときだけ使う。
/// 1つのパイプラインのタスクからだけ使う。
final class DebugAudioRecorder: @unchecked Sendable {
    let url: URL
    private var file: AVAudioFile?
    private var failed = false

    init(directory: URL, meetingID: UUID, source: AudioSource) {
        url = directory.appending(path: "\(meetingID.uuidString)-\(source.rawValue).caf")
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        guard !failed else { return }
        do {
            if file == nil {
                file = try AVAudioFile(
                    forWriting: url,
                    settings: buffer.format.settings,
                    commonFormat: buffer.format.commonFormat,
                    interleaved: buffer.format.isInterleaved
                )
            }
            try file?.write(from: buffer)
        } catch {
            failed = true
            Log.audio.error("Debug audio write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func close() {
        file = nil
    }

    /// 保存期間を過ぎたデバッグ音声を削除する。
    static func removeExpired(in directory: URL, olderThan days: Int, now: Date = .now) {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for file in files where file.pathExtension == "caf" {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            if modified < cutoff {
                try? fileManager.removeItem(at: file)
            }
        }
    }

    /// デバッグ音声をすべて削除する。
    static func removeAll(in directory: URL) {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "caf" {
            try? fileManager.removeItem(at: file)
        }
    }

    static func totalSize(in directory: URL) -> Int64 {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        return files.filter { $0.pathExtension == "caf" }.reduce(into: Int64(0)) { total, file in
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }
}
