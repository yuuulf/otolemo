import Foundation

public enum MeetingStatus: String, Codable, Sendable, CaseIterable {
    case recording
    case completed
    case interrupted

    public var displayName: String {
        switch self {
        case .recording: "記録中"
        case .completed: "完了"
        case .interrupted: "中断"
        }
    }
}

public struct Meeting: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var title: String
    /// 相手側音声の取得元アプリ名（例: "Zoom", "Google Chrome"）。マイクのみなら "マイクのみ"。
    public var sourceApp: String
    public var startedAt: Date
    public var endedAt: Date?
    public var status: MeetingStatus

    public init(
        id: UUID = UUID(),
        title: String,
        sourceApp: String,
        startedAt: Date,
        endedAt: Date? = nil,
        status: MeetingStatus = .recording
    ) {
        self.id = id
        self.title = title
        self.sourceApp = sourceApp
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.status = status
    }

    /// 所要時間。終了していなければ `nil`。
    public var duration: Duration? {
        guard let endedAt else { return nil }
        return .milliseconds(max(0, Int64((endedAt.timeIntervalSince(startedAt) * 1000).rounded())))
    }
}
