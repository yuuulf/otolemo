import Foundation
import Testing
@testable import TranscriberCore

private func temporaryDirectory() throws -> URL {
    let url = URL.temporaryDirectory.appending(path: "LMT-Tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private let referenceDate = Date(timeIntervalSince1970: 1_795_000_000.5)

private func makeMeeting(title: String = "定例", startedAt: Date = referenceDate) -> Meeting {
    Meeting(title: title, sourceApp: "Zoom", startedAt: startedAt)
}

private func makeSegment(_ meeting: Meeting, _ source: AudioSource, _ start: Int64, _ text: String) -> TranscriptSegment {
    TranscriptSegment(
        meetingID: meeting.id,
        source: source,
        startMS: start,
        endMS: start + 800,
        originalText: text,
        engine: "test",
        createdAt: referenceDate.addingTimeInterval(Double(start) / 1000)
    )
}

struct PersistenceTests {
    @Test func createsSchemaVersion1() async throws {
        let repository = try MeetingRepository(url: nil)
        #expect(try await repository.schemaVersion == Schema.currentVersion)
    }

    @Test func restoresMeetingsAndSegmentsAfterReopen() async throws {
        let directory = try temporaryDirectory()
        let url = directory.appending(path: "meetings.sqlite")
        let meeting = makeMeeting()
        let segments = [
            makeSegment(meeting, .system, 2_000, "相手の発言"),
            makeSegment(meeting, .microphone, 500, "自分の発言"),
            makeSegment(meeting, .system, 9_000, "最後の発言")
        ]

        do {
            let repository = try MeetingRepository(url: url)
            try await repository.createMeeting(meeting)
            for segment in segments {
                try await repository.insert(segment)
            }
            try await repository.finishMeeting(id: meeting.id, endedAt: referenceDate.addingTimeInterval(1800))
        }

        let reopened = try MeetingRepository(url: url)
        let meetings = try await reopened.meetings()
        #expect(meetings.count == 1)
        let restored = try #require(meetings.first)
        #expect(restored.id == meeting.id)
        #expect(restored.status == .completed)
        #expect(restored.startedAt == meeting.startedAt)
        #expect(restored.duration == .seconds(1800))

        let restoredSegments = try await reopened.segments(meetingID: meeting.id)
        #expect(restoredSegments.map(\.originalText) == ["自分の発言", "相手の発言", "最後の発言"])
        #expect(restoredSegments.map(\.source) == [.microphone, .system, .system])
        #expect(restoredSegments.map(\.startMS) == [500, 2_000, 9_000])
        #expect(restoredSegments.first?.createdAt == segments[1].createdAt)
    }

    @Test func usesWriteAheadLogging() async throws {
        let url = try temporaryDirectory().appending(path: "meetings.sqlite")
        _ = try MeetingRepository(url: url)
        let database = try Database(url: url)
        #expect(try database.scalarText("PRAGMA journal_mode") == "wal")
    }

    @Test func marksUnfinishedMeetingsAsInterrupted() async throws {
        let url = try temporaryDirectory().appending(path: "meetings.sqlite")
        let meeting = makeMeeting()
        do {
            // 記録中のまま終了（強制終了を想定）。
            let repository = try MeetingRepository(url: url)
            try await repository.createMeeting(meeting)
            try await repository.insert(makeSegment(meeting, .microphone, 61_000, "途中まで"))
        }
        let reopened = try MeetingRepository(url: url)
        let recovered = try await reopened.recoverUnfinishedMeetings()
        #expect(recovered == [meeting.id])
        let restored = try #require(try await reopened.meeting(id: meeting.id))
        #expect(restored.status == .interrupted)
        // 最後の発言の終了時刻（61.8 秒）を終了時刻にする。
        #expect(restored.duration == .milliseconds(61_800))
        #expect(try await reopened.segments(meetingID: meeting.id).count == 1)
    }

    @Test func deletingMeetingCascadesToSegments() async throws {
        let repository = try MeetingRepository(url: nil)
        let meeting = makeMeeting()
        try await repository.createMeeting(meeting)
        try await repository.insert([makeSegment(meeting, .microphone, 0, "a"), makeSegment(meeting, .system, 10, "b")])
        try await repository.deleteMeeting(id: meeting.id)
        #expect(try await repository.meetings().isEmpty)
        #expect(try await repository.segmentCount(meetingID: meeting.id) == 0)
    }

    @Test func batchInsertIsAtomic() async throws {
        let repository = try MeetingRepository(url: nil)
        let meeting = makeMeeting()
        try await repository.createMeeting(meeting)
        let good = makeSegment(meeting, .microphone, 0, "ok")
        // 同じ ID の発言を含むので、まとめて失敗する。
        await #expect(throws: DatabaseError.self) {
            try await repository.insert([good, good])
        }
        #expect(try await repository.segmentCount(meetingID: meeting.id) == 0)
    }

    @Test func rejectsSegmentForUnknownMeeting() async throws {
        let repository = try MeetingRepository(url: nil)
        let orphan = makeSegment(makeMeeting(), .microphone, 0, "孤立")
        await #expect(throws: DatabaseError.self) {
            try await repository.insert(orphan)
        }
    }

    @Test func editsTextAndKeepsOriginal() async throws {
        let repository = try MeetingRepository(url: nil)
        let meeting = makeMeeting()
        let segment = makeSegment(meeting, .system, 0, "こんにちわ")
        try await repository.createMeeting(meeting)
        try await repository.insert(segment)

        try await repository.updateEditedText(segmentID: segment.id, editedText: "こんにちは")
        var stored = try #require(try await repository.segments(meetingID: meeting.id).first)
        #expect(stored.originalText == "こんにちわ")
        #expect(stored.text == "こんにちは")

        // 元の本文に戻したら修正なし扱い。
        try await repository.updateEditedText(segmentID: segment.id, editedText: "こんにちわ")
        stored = try #require(try await repository.segments(meetingID: meeting.id).first)
        #expect(stored.editedText == nil)
    }

    @Test func renamesMeeting() async throws {
        let repository = try MeetingRepository(url: nil)
        let meeting = makeMeeting()
        try await repository.createMeeting(meeting)
        try await repository.renameMeeting(id: meeting.id, title: "週次レビュー")
        #expect(try await repository.meeting(id: meeting.id)?.title == "週次レビュー")
    }

    @Test func listsMeetingsNewestFirst() async throws {
        let repository = try MeetingRepository(url: nil)
        let older = makeMeeting(title: "古い", startedAt: referenceDate)
        let newer = makeMeeting(title: "新しい", startedAt: referenceDate.addingTimeInterval(86_400))
        try await repository.createMeeting(older)
        try await repository.createMeeting(newer)
        #expect(try await repository.meetings().map(\.title) == ["新しい", "古い"])
    }

    @Test func searchesJapaneseTextIncludingShortQueries() async throws {
        let repository = try MeetingRepository(url: nil)
        let first = makeMeeting(title: "予算会議")
        let second = makeMeeting(title: "雑談", startedAt: referenceDate.addingTimeInterval(60))
        try await repository.createMeeting(first)
        try await repository.createMeeting(second)
        let edited = makeSegment(second, .system, 0, "けんとうします")
        try await repository.insert([
            makeSegment(first, .microphone, 0, "来期の予算を確認します"),
            makeSegment(first, .system, 1000, "承知しました"),
            edited
        ])
        try await repository.updateEditedText(segmentID: edited.id, editedText: "検討します")

        // 2 文字の日本語でも部分一致する。
        #expect(try await repository.searchSegments("予算").map(\.segment.originalText) == ["来期の予算を確認します"])
        // 修正後の本文で検索できる。
        #expect(try await repository.searchSegments("検討").map(\.segment.id) == [edited.id])
        // 会議一覧の絞り込みはタイトルと本文の両方を見る。
        #expect(try await repository.meetings(matching: "予算").map(\.id) == [first.id])
        #expect(try await repository.meetings(matching: "雑談").map(\.id) == [second.id])
        #expect(try await repository.meetings(matching: "しま").count == 2)
        #expect(try await repository.meetings(matching: " ").count == 2)
    }

    @Test func searchTreatsWildcardsLiterally() async throws {
        let repository = try MeetingRepository(url: nil)
        let meeting = makeMeeting()
        try await repository.createMeeting(meeting)
        try await repository.insert([
            makeSegment(meeting, .microphone, 0, "達成率は100%です"),
            makeSegment(meeting, .microphone, 1000, "達成率は1000です")
        ])
        #expect(try await repository.searchSegments("100%").count == 1)
        #expect(try await repository.searchSegments("_").isEmpty)
    }

    @Test func backupAndRestore() async throws {
        let directory = try temporaryDirectory()
        let repository = try MeetingRepository(url: directory.appending(path: "meetings.sqlite"))
        let kept = makeMeeting(title: "残す会議")
        try await repository.createMeeting(kept)
        try await repository.insert(makeSegment(kept, .microphone, 0, "大事な発言"))

        let backup = try await repository.backup(to: directory.appending(path: "Backups"), now: referenceDate)
        #expect(FileManager.default.fileExists(atPath: backup.path(percentEncoded: false)))

        // バックアップ後の変更は、リストアで消える。
        try await repository.deleteMeeting(id: kept.id)
        try await repository.createMeeting(makeMeeting(title: "後から作った会議"))

        try await repository.restore(from: backup)
        #expect(try await repository.meetings().map(\.title) == ["残す会議"])
        #expect(try await repository.segments(meetingID: kept.id).map(\.text) == ["大事な発言"])
    }

    @Test func backupFileNamesDoNotCollide() async throws {
        let directory = try temporaryDirectory()
        let repository = try MeetingRepository(url: directory.appending(path: "meetings.sqlite"))
        let first = try await repository.backup(to: directory, now: referenceDate)
        let second = try await repository.backup(to: directory, now: referenceDate)
        #expect(first != second)
    }

    @Test func refusesRestoreFromNonDatabase() async throws {
        let directory = try temporaryDirectory()
        let bogus = directory.appending(path: "bogus.sqlite")
        try Data("not a database".utf8).write(to: bogus)
        let repository = try MeetingRepository(url: directory.appending(path: "meetings.sqlite"))
        let meeting = makeMeeting()
        try await repository.createMeeting(meeting)
        await #expect(throws: (any Error).self) {
            try await repository.restore(from: bogus)
        }
        #expect(try await repository.meetings().count == 1)
    }

    @Test func refusesNewerSchema() throws {
        let url = try temporaryDirectory().appending(path: "meetings.sqlite")
        do {
            let database = try Database(url: url)
            try database.setUserVersion(Schema.currentVersion + 1)
        }
        #expect(throws: Schema.NewerSchemaError.self) {
            _ = try MeetingRepository(url: url)
        }
    }
}

struct DateCodingTests {
    @Test func roundsToNearestMillisecond() throws {
        let date = Date(timeIntervalSince1970: 1_795_000_062.299_999_95)
        #expect(DateCoding.string(from: date) == "2026-11-18T11:07:42.300Z")
        #expect(try DateCoding.date(from: DateCoding.string(from: date)).timeIntervalSince1970 == 1_795_000_062.3)
    }
}
