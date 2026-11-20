import Foundation

/// 確定した1発言。暫定結果は保存しない。
public struct TranscriptSegment: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var meetingID: UUID
    public var source: AudioSource
    /// 会議開始からの経過ミリ秒。
    public var startMS: Int64
    public var endMS: Int64
    /// 認識エンジンの確定結果。
    public var originalText: String
    /// 利用者が修正した本文。未修正なら `nil`。
    public var editedText: String?
    /// 認識エンジンの識別子（例: "apple.speech-transcriber"）。
    public var engine: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        meetingID: UUID,
        source: AudioSource,
        startMS: Int64,
        endMS: Int64,
        originalText: String,
        editedText: String? = nil,
        engine: String,
        createdAt: Date = .now
    ) {
        self.id = id
        self.meetingID = meetingID
        self.source = source
        self.startMS = max(0, startMS)
        self.endMS = max(self.startMS, endMS)
        self.originalText = originalText
        self.editedText = editedText
        self.engine = engine
        self.createdAt = createdAt
    }

    /// 表示・書き出しに使う本文。修正済みなら修正後の本文。
    public var text: String {
        editedText ?? originalText
    }

    public var isEdited: Bool {
        editedText != nil
    }
}

extension TranscriptSegment {
    /// 会議内での並び順。開始時刻、同時刻なら終了時刻、最後に ID で決める。
    public static func timelineOrder(_ lhs: TranscriptSegment, _ rhs: TranscriptSegment) -> Bool {
        if lhs.startMS != rhs.startMS { return lhs.startMS < rhs.startMS }
        if lhs.endMS != rhs.endMS { return lhs.endMS < rhs.endMS }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
