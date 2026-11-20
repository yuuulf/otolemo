import Foundation
import Testing
@testable import TranscriberCore

struct ExportTests {
    let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    let meeting = Meeting(
        id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        title: "週次: 定例/進捗",
        sourceApp: "Zoom",
        // 2026-11-20 10:00:00 +09:00
        startedAt: Date(timeIntervalSince1970: 1_795_136_400),
        endedAt: Date(timeIntervalSince1970: 1_795_136_400 + 3_723),
        status: .completed
    )

    var segments: [TranscriptSegment] {
        var edited = TranscriptSegment(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            meetingID: meeting.id,
            source: .system,
            startMS: 83_000,
            endMS: 85_500,
            originalText: "よろしくおねがいします",
            engine: "apple.speech-transcriber"
        )
        edited.editedText = "よろしくお願いします。"
        let mine = TranscriptSegment(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            meetingID: meeting.id,
            source: .microphone,
            startMS: 1_000,
            endMS: 2_000,
            originalText: "始めます。\n議題は2つです。",
            engine: "apple.speech-transcriber"
        )
        // わざと時刻順ではない順で渡す。
        return [edited, mine]
    }

    @Test func markdownListsSegmentsInTimeOrderWithSpeakerLabels() {
        let markdown = ExportService(timeZone: tokyo).markdown(for: meeting, segments: segments)
        let expected = """
        # 週次: 定例/進捗

        - 日時: 2026-11-20 10:00:00+09:00
        - 対象アプリ: Zoom
        - 所要時間: 01:02:03
        - 状態: 完了

        ## 文字起こし

        - **[00:00:01] 自分**: 始めます。 議題は2つです。
        - **[00:01:23] 相手側**: よろしくお願いします。

        """
        #expect(markdown == expected)
    }

    @Test func markdownForEmptyMeeting() {
        var unfinished = meeting
        unfinished.endedAt = nil
        unfinished.status = .interrupted
        let markdown = ExportService(timeZone: tokyo).markdown(for: unfinished, segments: [])
        #expect(markdown.contains("（発言なし）"))
        #expect(!markdown.contains("所要時間"))
        #expect(markdown.contains("- 状態: 中断"))
    }

    @Test func jsonRoundTripsAndKeepsOriginalText() throws {
        let service = ExportService(timeZone: tokyo)
        let data = try service.json(for: meeting, segments: segments)
        let document = try ExportService.decoder.decode(ExportService.Document.self, from: data)

        #expect(document.formatVersion == 1)
        #expect(document.meeting.id == meeting.id)
        #expect(document.meeting.startedAt == meeting.startedAt)
        #expect(document.segments.map(\.source) == [.microphone, .system])
        #expect(document.segments.map(\.speaker) == ["自分", "相手側"])
        #expect(document.segments[1].text == "よろしくお願いします。")
        #expect(document.segments[1].originalText == "よろしくおねがいします")
        #expect(document.segments[1].edited)
        #expect(document.segments[0].edited == false)
        #expect(document == service.document(for: meeting, segments: segments))
    }

    @Test func jsonUsesStableKeys() throws {
        let data = try ExportService().json(for: meeting, segments: segments)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("\"formatVersion\" : 1"))
        #expect(text.contains("\"startedAt\" : \"2026-11-20T01:00:00Z\""))
        #expect(text.contains("\"startMS\" : 1000"))
    }

    @Test func suggestedFileNameIsSafe() {
        let service = ExportService(timeZone: tokyo)
        #expect(service.suggestedFileName(for: meeting, format: .markdown) == "2026-11-20 週次- 定例-進捗.md")
        #expect(service.suggestedFileName(for: meeting, format: .json).hasSuffix(".json"))
    }
}
