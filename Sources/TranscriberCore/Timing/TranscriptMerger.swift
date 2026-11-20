import Foundation

/// 認識エンジンからの1件の結果。暫定（volatile）か確定（final）か。
public struct TranscriptUpdate: Sendable, Equatable {
    public var source: AudioSource
    public var text: String
    public var startMS: Int64
    public var endMS: Int64
    public var isFinal: Bool

    public init(source: AudioSource, text: String, startMS: Int64, endMS: Int64, isFinal: Bool) {
        self.source = source
        self.text = text
        self.startMS = max(0, startMS)
        self.endMS = max(self.startMS, endMS)
        self.isFinal = isFinal
    }
}

/// 画面に並べる1行。確定した発言か、置き換わりうる暫定テキスト。
public struct TranscriptLine: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case final(TranscriptSegment)
        case volatile
    }

    public var id: String
    public var source: AudioSource
    public var startMS: Int64
    public var endMS: Int64
    public var text: String
    public var kind: Kind

    public var isFinal: Bool {
        if case .final = kind { true } else { false }
    }
}

/// 2系統の暫定・確定結果を受け取り、会議の時刻順に並べる。
///
/// - 暫定結果は系統ごとに最新の1件だけを持ち、次の結果で置き換える。
/// - 確定結果は時刻順に挿入し、重なる暫定結果を消す。
/// - 永続化するのは確定結果だけ（`apply` の戻り値）。
public struct TranscriptMerger: Sendable {
    public let meetingID: UUID
    public let engine: String

    public private(set) var finalized: [TranscriptSegment] = []
    public private(set) var volatile: [AudioSource: TranscriptUpdate] = [:]

    public init(meetingID: UUID, engine: String, finalized: [TranscriptSegment] = []) {
        self.meetingID = meetingID
        self.engine = engine
        self.finalized = finalized.sorted(by: TranscriptSegment.timelineOrder)
    }

    /// 結果を反映する。確定した場合は保存すべき発言を返す。空の確定結果は捨てる。
    @discardableResult
    public mutating func apply(_ update: TranscriptUpdate, now: Date = .now) -> TranscriptSegment? {
        let trimmed = update.text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard update.isFinal else {
            volatile[update.source] = trimmed.isEmpty ? nil : update
            return nil
        }

        if let pending = volatile[update.source], pending.startMS <= update.endMS {
            volatile[update.source] = nil
        }
        guard !trimmed.isEmpty else { return nil }

        let segment = TranscriptSegment(
            meetingID: meetingID,
            source: update.source,
            startMS: update.startMS,
            endMS: update.endMS,
            originalText: trimmed,
            engine: engine,
            createdAt: now
        )
        insert(segment)
        return segment
    }

    /// 系統の認識が止まったときに、残っている暫定結果を捨てる。
    public mutating func clearVolatile(for source: AudioSource) {
        volatile[source] = nil
    }

    /// 本文修正などで確定済みの発言を差し替える。
    public mutating func replace(_ segment: TranscriptSegment) {
        guard let index = finalized.firstIndex(where: { $0.id == segment.id }) else { return }
        finalized.remove(at: index)
        insert(segment)
    }

    /// 確定発言と暫定テキストを時刻順に並べた表示用の行。
    public var lines: [TranscriptLine] {
        var result = finalized.map { segment in
            TranscriptLine(
                id: segment.id.uuidString,
                source: segment.source,
                startMS: segment.startMS,
                endMS: segment.endMS,
                text: segment.text,
                kind: .final(segment)
            )
        }
        for source in AudioSource.allCases {
            guard let pending = volatile[source] else { continue }
            result.append(TranscriptLine(
                id: "volatile-\(source.rawValue)",
                source: source,
                startMS: pending.startMS,
                endMS: pending.endMS,
                text: pending.text.trimmingCharacters(in: .whitespacesAndNewlines),
                kind: .volatile
            ))
        }
        return result.sorted { lhs, rhs in
            if lhs.startMS != rhs.startMS { return lhs.startMS < rhs.startMS }
            if lhs.isFinal != rhs.isFinal { return lhs.isFinal }
            return lhs.id < rhs.id
        }
    }

    private mutating func insert(_ segment: TranscriptSegment) {
        let index = finalized.firstIndex { TranscriptSegment.timelineOrder(segment, $0) } ?? finalized.endIndex
        finalized.insert(segment, at: index)
    }
}
