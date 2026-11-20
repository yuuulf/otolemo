import Foundation

/// 検索でヒットした発言。
public struct SegmentSearchHit: Identifiable, Hashable, Sendable {
    public var meeting: Meeting
    public var segment: TranscriptSegment

    public var id: UUID { segment.id }
}

/// 会議と確定発言の保存先。SQLite 接続を1つだけ持ち、すべての操作を直列に行う。
public actor MeetingRepository {
    private let database: Database
    public nonisolated let databaseURL: URL?

    /// - Parameter url: DB ファイル。`nil` ならメモリ上（テスト用）。
    public init(url: URL?) throws {
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let database = try Database(url: url)
        if url != nil {
            try database.execute("PRAGMA journal_mode = WAL")
        }
        try database.execute("PRAGMA synchronous = FULL")
        try database.execute("PRAGMA foreign_keys = ON")
        try Schema.migrate(database)
        self.database = database
        self.databaseURL = url
    }

    public var schemaVersion: Int {
        get throws { try database.userVersion }
    }

    // MARK: - 会議

    public func createMeeting(_ meeting: Meeting) throws {
        try database.transaction {
            try database.execute(
                """
                INSERT INTO meetings (id, title, source_app, started_at_utc, ended_at_utc, status)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(meeting.id.uuidString),
                    .text(meeting.title),
                    .text(meeting.sourceApp),
                    .text(DateCoding.string(from: meeting.startedAt)),
                    .optionalText(meeting.endedAt.map(DateCoding.string(from:))),
                    .text(meeting.status.rawValue)
                ]
            )
        }
    }

    public func finishMeeting(id: UUID, endedAt: Date, status: MeetingStatus = .completed) throws {
        try database.execute(
            "UPDATE meetings SET ended_at_utc = ?, status = ? WHERE id = ?",
            [.text(DateCoding.string(from: endedAt)), .text(status.rawValue), .text(id.uuidString)]
        )
    }

    public func renameMeeting(id: UUID, title: String) throws {
        try database.execute("UPDATE meetings SET title = ? WHERE id = ?", [.text(title), .text(id.uuidString)])
    }

    /// 会議と、その発言をすべて削除する。
    public func deleteMeeting(id: UUID) throws {
        try database.transaction {
            try database.execute("DELETE FROM meetings WHERE id = ?", [.text(id.uuidString)])
        }
    }

    public func meeting(id: UUID) throws -> Meeting? {
        let statement = try database.prepare("SELECT \(Columns.meeting) FROM meetings WHERE id = ?")
        try statement.bind([.text(id.uuidString)])
        guard try statement.step() else { return nil }
        return try Self.meeting(from: statement)
    }

    /// 会議一覧（新しい順）。`query` があれば、タイトルか発言本文に含むものだけ。
    public func meetings(matching query: String = "") throws -> [Meeting] {
        let pattern = SearchPattern.like(query)
        let statement: Statement
        if let pattern {
            statement = try database.prepare(
                """
                SELECT \(Columns.meeting) FROM meetings
                WHERE title LIKE ?1 ESCAPE '\\'
                   OR id IN (
                     SELECT meeting_id FROM segments
                     WHERE COALESCE(edited_text, original_text) LIKE ?1 ESCAPE '\\'
                   )
                ORDER BY started_at_utc DESC
                """
            )
            try statement.bind([.text(pattern)])
        } else {
            statement = try database.prepare("SELECT \(Columns.meeting) FROM meetings ORDER BY started_at_utc DESC")
        }
        var result: [Meeting] = []
        while try statement.step() {
            result.append(try Self.meeting(from: statement))
        }
        return result
    }

    /// 異常終了で `recording` のまま残った会議を `interrupted` にする。
    /// 終了時刻は最後の確定発言の時刻（無ければ開始時刻）にする。
    @discardableResult
    public func recoverUnfinishedMeetings() throws -> [UUID] {
        let unfinished = try database.prepare(
            """
            SELECT m.id, m.started_at_utc, MAX(s.end_ms)
            FROM meetings m LEFT JOIN segments s ON s.meeting_id = m.id
            WHERE m.status = 'recording'
            GROUP BY m.id
            """
        )
        var updates: [(UUID, Date)] = []
        while try unfinished.step() {
            guard let id = UUID(uuidString: unfinished.text(0)) else { continue }
            let startedAt = try DateCoding.date(from: unfinished.text(1))
            let lastMS = unfinished.optionalInteger(2) ?? 0
            updates.append((id, startedAt.addingTimeInterval(Double(lastMS) / 1000)))
        }
        try database.transaction {
            for (id, endedAt) in updates {
                try database.execute(
                    "UPDATE meetings SET status = 'interrupted', ended_at_utc = ? WHERE id = ?",
                    [.text(DateCoding.string(from: endedAt)), .text(id.uuidString)]
                )
            }
        }
        return updates.map(\.0)
    }

    // MARK: - 発言

    /// 確定発言を1件保存する。
    public func insert(_ segment: TranscriptSegment) throws {
        try insert([segment])
    }

    /// 確定発言をまとめて1トランザクションで保存する。
    public func insert(_ segments: [TranscriptSegment]) throws {
        guard !segments.isEmpty else { return }
        try database.transaction {
            let statement = try database.prepare(
                """
                INSERT INTO segments
                  (id, meeting_id, source, start_ms, end_ms, original_text, edited_text, engine, created_at_utc)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """
            )
            for segment in segments {
                try statement.bind([
                    .text(segment.id.uuidString),
                    .text(segment.meetingID.uuidString),
                    .text(segment.source.rawValue),
                    .integer(segment.startMS),
                    .integer(segment.endMS),
                    .text(segment.originalText),
                    .optionalText(segment.editedText),
                    .text(segment.engine),
                    .text(DateCoding.string(from: segment.createdAt))
                ])
                while try statement.step() {}
            }
        }
    }

    /// 会議の発言を時刻順に返す。
    public func segments(meetingID: UUID) throws -> [TranscriptSegment] {
        let statement = try database.prepare(
            "SELECT \(Columns.segment) FROM segments WHERE meeting_id = ? ORDER BY start_ms, end_ms, id"
        )
        try statement.bind([.text(meetingID.uuidString)])
        var result: [TranscriptSegment] = []
        while try statement.step() {
            result.append(try Self.segment(from: statement, offset: 0))
        }
        return result
    }

    public func segmentCount(meetingID: UUID) throws -> Int {
        Int(try database.scalarInteger("SELECT COUNT(*) FROM segments WHERE meeting_id = ?", [.text(meetingID.uuidString)]) ?? 0)
    }

    /// 本文を修正する。`nil`、空文字、元の本文と同じなら修正を取り消す。
    public func updateEditedText(segmentID: UUID, editedText: String?) throws {
        let trimmed = editedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        try database.execute(
            """
            UPDATE segments
            SET edited_text = CASE WHEN ?1 IS NULL OR ?1 = '' OR ?1 = original_text THEN NULL ELSE ?1 END
            WHERE id = ?2
            """,
            [.optionalText(trimmed), .text(segmentID.uuidString)]
        )
    }

    /// 発言本文（修正後を優先）の部分一致検索。新しい会議から、会議内は時刻順。
    public func searchSegments(_ query: String, limit: Int = 500) throws -> [SegmentSearchHit] {
        guard let pattern = SearchPattern.like(query) else { return [] }
        let statement = try database.prepare(
            """
            SELECT \(Columns.meeting), \(Columns.segment)
            FROM segments JOIN meetings ON meetings.id = segments.meeting_id
            WHERE COALESCE(segments.edited_text, segments.original_text) LIKE ? ESCAPE '\\'
            ORDER BY meetings.started_at_utc DESC, segments.start_ms, segments.id
            LIMIT ?
            """
        )
        try statement.bind([.text(pattern), .integer(Int64(limit))])
        var result: [SegmentSearchHit] = []
        while try statement.step() {
            result.append(SegmentSearchHit(
                meeting: try Self.meeting(from: statement),
                segment: try Self.segment(from: statement, offset: Columns.meetingCount)
            ))
        }
        return result
    }

    // MARK: - バックアップ

    /// DB を `directory` にバックアップし、作ったファイルを返す。
    public func backup(to directory: URL, now: Date = .now) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = now.formatted(
            .iso8601.year().month().day().dateSeparator(.omitted).time(includingFractionalSeconds: false).timeSeparator(.omitted)
        )
        var destination = directory.appending(path: "meetings-\(stamp).sqlite")
        var suffix = 1
        while FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
            destination = directory.appending(path: "meetings-\(stamp)-\(suffix).sqlite")
            suffix += 1
        }
        try database.backup(to: destination)
        return destination
    }

    /// バックアップの内容で DB を置き換える。古いスキーマのバックアップはマイグレーションする。
    public func restore(from backup: URL) throws {
        let candidate = try Database(url: backup, readOnly: true)
        guard try candidate.scalarText("PRAGMA quick_check") == "ok" else {
            throw DatabaseError(code: -1, message: "バックアップファイルが壊れています")
        }
        let version = try candidate.userVersion
        guard version >= 1, version <= Schema.currentVersion else {
            throw DatabaseError(code: -1, message: "対応していないバックアップです（スキーマ v\(version)）")
        }
        try database.restore(from: backup)
        try Schema.migrate(database)
    }

    // MARK: - 行の読み取り

    private enum Columns {
        static let meeting = "meetings.id, meetings.title, meetings.source_app, meetings.started_at_utc, meetings.ended_at_utc, meetings.status"
        static let meetingCount: Int32 = 6
        static let segment = "segments.id, segments.meeting_id, segments.source, segments.start_ms, segments.end_ms, segments.original_text, segments.edited_text, segments.engine, segments.created_at_utc"
    }

    private static func meeting(from statement: Statement) throws -> Meeting {
        guard let id = UUID(uuidString: statement.text(0)) else {
            throw DatabaseError(code: -1, message: "会議 ID が不正です")
        }
        return Meeting(
            id: id,
            title: statement.text(1),
            sourceApp: statement.text(2),
            startedAt: try DateCoding.date(from: statement.text(3)),
            endedAt: try statement.optionalText(4).map(DateCoding.date(from:)),
            status: MeetingStatus(rawValue: statement.text(5)) ?? .interrupted
        )
    }

    private static func segment(from statement: Statement, offset: Int32) throws -> TranscriptSegment {
        guard let id = UUID(uuidString: statement.text(offset)),
              let meetingID = UUID(uuidString: statement.text(offset + 1)),
              let source = AudioSource(rawValue: statement.text(offset + 2)) else {
            throw DatabaseError(code: -1, message: "発言データが不正です")
        }
        return TranscriptSegment(
            id: id,
            meetingID: meetingID,
            source: source,
            startMS: statement.integer(offset + 3),
            endMS: statement.integer(offset + 4),
            originalText: statement.text(offset + 5),
            editedText: statement.optionalText(offset + 6),
            engine: statement.text(offset + 7),
            createdAt: try DateCoding.date(from: statement.text(offset + 8))
        )
    }
}

/// UTC の ISO 8601（ミリ秒付き）で日時を保存する。固定長なので文字列の並びが時刻順になる。
enum DateCoding {
    static let style = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    static func string(from date: Date) -> String {
        // フォーマッタは小数秒を切り捨てるので、ミリ秒に丸めてから半ミリ秒ずらして渡す。
        let milliseconds = (date.timeIntervalSince1970 * 1000).rounded()
        return Date(timeIntervalSince1970: (milliseconds + 0.5) / 1000).formatted(style)
    }

    static func date(from string: String) throws -> Date {
        try Date(string, strategy: style)
    }
}

/// 単純な部分一致検索（LIKE）のパターン。FTS5 trigram は 3 文字未満の日本語に向かないため、まずはこちらを使う。
enum SearchPattern {
    static func like(_ query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var escaped = ""
        for character in trimmed {
            if character == "\\" || character == "%" || character == "_" {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return "%\(escaped)%"
    }
}
