import Foundation
import Testing
@testable import TranscriberCore

/// host time 1 tick = 1ns として扱う時計。
private func nanosecondClock(start: UInt64 = 1_000_000_000) -> MeetingClock {
    MeetingClock(startHostTime: start, timebase: (1, 1))
}

private func hostTime(_ seconds: Double, start: UInt64 = 1_000_000_000) -> UInt64 {
    start + UInt64(seconds * 1_000_000_000)
}

struct MeetingClockTests {
    @Test func convertsHostTimeToElapsedMilliseconds() {
        let clock = nanosecondClock()
        #expect(clock.elapsedMilliseconds(atHostTime: hostTime(1.5)) == 1500)
        #expect(clock.elapsedMilliseconds(atHostTime: hostTime(3600)) == 3_600_000)
    }

    @Test func clampsTimesBeforeStartToZero() {
        let clock = nanosecondClock()
        #expect(clock.elapsedMilliseconds(atHostTime: 10) == 0)
    }

    @Test func appliesTimebase() {
        // Apple シリコンの典型値: 125/3 (24MHz)
        let clock = MeetingClock(startHostTime: 0, timebase: (125, 3))
        #expect(clock.elapsedMilliseconds(atHostTime: 24_000_000) == 1000)
    }
}

struct StreamTimelineTests {
    @Test func firstBufferGetsExplicitStartFromHostTime() {
        var timeline = StreamTimeline(clock: nanosecondClock())
        let placement = timeline.place(hostTime: hostTime(2.0), frameCount: 4800, sampleRate: 48_000)
        #expect(placement.startSeconds == 2.0)
        #expect(placement.explicitStartSeconds == 2.0)
        #expect(timeline.expectedNextStartSeconds == 2.1)
    }

    @Test func contiguousBuffersUseSampleTimeWithoutExplicitStart() {
        var timeline = StreamTimeline(clock: nanosecondClock())
        _ = timeline.place(hostTime: hostTime(2.0), frameCount: 4800, sampleRate: 48_000)
        // host time が少し揺れても、サンプル数による連続時刻を使う。
        let second = timeline.place(hostTime: hostTime(2.13), frameCount: 4800, sampleRate: 48_000)
        #expect(second.startSeconds == 2.1)
        #expect(second.explicitStartSeconds == nil)
        #expect(second.gapSeconds == 0)
    }

    @Test func resyncsAfterLargeGap() {
        var timeline = StreamTimeline(clock: nanosecondClock())
        _ = timeline.place(hostTime: hostTime(2.0), frameCount: 4800, sampleRate: 48_000)
        // スリープ復帰などで 10 秒飛んだ。
        let resumed = timeline.place(hostTime: hostTime(12.1), frameCount: 4800, sampleRate: 48_000)
        #expect(resumed.startSeconds == 12.1)
        #expect(resumed.explicitStartSeconds == 12.1)
        #expect(abs(resumed.gapSeconds - 10.0) < 0.000_001)
    }

    @Test func discontinuityNeverMovesTimeBackwards() {
        var timeline = StreamTimeline(clock: nanosecondClock())
        _ = timeline.place(hostTime: hostTime(5.0), frameCount: 48_000, sampleRate: 48_000)
        timeline.markDiscontinuity()
        // 新しいデバイスの host time が予定より前に見えても、前には戻さない。
        let placement = timeline.place(hostTime: hostTime(5.8), frameCount: 4800, sampleRate: 16_000)
        #expect(placement.startSeconds == 6.0)
        #expect(placement.explicitStartSeconds == 6.0)
        #expect(timeline.expectedNextStartSeconds == 6.3)
    }
}

struct TranscriptMergerTests {
    let meetingID = UUID()

    private func update(_ source: AudioSource, _ text: String, _ start: Int64, _ end: Int64, final: Bool) -> TranscriptUpdate {
        TranscriptUpdate(source: source, text: text, startMS: start, endMS: end, isFinal: final)
    }

    @Test func volatileResultsReplaceEachOtherPerSource() {
        var merger = TranscriptMerger(meetingID: meetingID, engine: "test")
        merger.apply(update(.microphone, "こん", 0, 500, final: false))
        merger.apply(update(.microphone, "こんにちは", 0, 900, final: false))
        #expect(merger.lines.count == 1)
        #expect(merger.lines.first?.text == "こんにちは")
        #expect(merger.lines.first?.isFinal == false)
        #expect(merger.finalized.isEmpty)
    }

    @Test func finalResultIsReturnedForPersistenceAndClearsVolatile() {
        var merger = TranscriptMerger(meetingID: meetingID, engine: "test")
        merger.apply(update(.system, "よろしく", 1000, 1500, final: false))
        let saved = merger.apply(update(.system, "よろしくお願いします。", 1000, 2200, final: true))
        #expect(saved?.originalText == "よろしくお願いします。")
        #expect(saved?.source == .system)
        #expect(saved?.meetingID == meetingID)
        #expect(saved?.engine == "test")
        #expect(merger.volatile[.system] == nil)
        #expect(merger.lines.map(\.isFinal) == [true])
    }

    @Test func volatileLaterThanFinalStaysVisible() {
        var merger = TranscriptMerger(meetingID: meetingID, engine: "test")
        merger.apply(update(.microphone, "次の発言", 3000, 3500, final: false))
        merger.apply(update(.microphone, "前の発言。", 0, 2000, final: true))
        #expect(merger.volatile[.microphone]?.text == "次の発言")
    }

    @Test func sourcesStaySeparatedAndOrderedByTime() {
        var merger = TranscriptMerger(meetingID: meetingID, engine: "test")
        // 相手側の確定が後から届いても、時刻順に並ぶ。
        merger.apply(update(.microphone, "B", 2000, 3000, final: true))
        merger.apply(update(.system, "A", 500, 1800, final: true))
        merger.apply(update(.microphone, "D", 6000, 7000, final: true))
        merger.apply(update(.system, "C", 4000, 6500, final: true))
        #expect(merger.finalized.map(\.originalText) == ["A", "B", "C", "D"])
        #expect(merger.finalized.map(\.source) == [.system, .microphone, .system, .microphone])
    }

    @Test func simultaneousSpeechKeepsBothSources() {
        var merger = TranscriptMerger(meetingID: meetingID, engine: "test")
        merger.apply(update(.microphone, "自分", 1000, 2000, final: true))
        merger.apply(update(.system, "相手", 1000, 2000, final: true))
        #expect(merger.finalized.count == 2)
        #expect(Set(merger.finalized.map(\.source)) == [.microphone, .system])
    }

    @Test func emptyFinalIsDropped() {
        var merger = TranscriptMerger(meetingID: meetingID, engine: "test")
        merger.apply(update(.microphone, "えー", 0, 300, final: false))
        let saved = merger.apply(update(.microphone, "  ", 0, 300, final: true))
        #expect(saved == nil)
        #expect(merger.lines.isEmpty)
    }

    @Test func volatileLinesFollowFinalLinesAtSameTime() {
        var merger = TranscriptMerger(meetingID: meetingID, engine: "test")
        merger.apply(update(.system, "途中", 1000, 1200, final: false))
        merger.apply(update(.microphone, "確定", 1000, 1500, final: true))
        #expect(merger.lines.map(\.text) == ["確定", "途中"])
    }

    @Test func replaceKeepsOrder() throws {
        var merger = TranscriptMerger(meetingID: meetingID, engine: "test")
        merger.apply(update(.microphone, "一", 0, 100, final: true))
        let saved = merger.apply(update(.system, "に", 200, 300, final: true))
        var edited = try #require(saved)
        edited.editedText = "二"
        merger.replace(edited)
        #expect(merger.lines.map(\.text) == ["一", "二"])
    }
}

struct ElapsedTimeFormatTests {
    @Test func formatsHoursMinutesSeconds() {
        #expect(ElapsedTimeFormat.string(milliseconds: 0) == "00:00:00")
        #expect(ElapsedTimeFormat.string(milliseconds: 83_999) == "00:01:23")
        #expect(ElapsedTimeFormat.string(milliseconds: 3_723_000) == "01:02:03")
        #expect(ElapsedTimeFormat.string(duration: .seconds(65)) == "00:01:05")
    }
}

struct LatencyStatsTests {
    @Test func computesMeanAndP95() {
        var stats = LatencyStats(window: 100)
        for value in 1...100 {
            stats.record(milliseconds: Int64(value * 10))
        }
        #expect(stats.mean == 505)
        #expect(stats.p95 == 950)
        #expect(stats.totalCount == 100)
    }

    @Test func keepsOnlyRecentWindow() {
        var stats = LatencyStats(window: 2)
        stats.record(milliseconds: 10_000)
        stats.record(milliseconds: 100)
        stats.record(milliseconds: 300)
        #expect(stats.samples == [100, 300])
        #expect(stats.mean == 200)
        #expect(stats.totalCount == 3)
    }

    @Test func emptyHasNoValues() {
        let stats = LatencyStats()
        #expect(stats.mean == nil)
        #expect(stats.p95 == nil)
    }
}
