import Foundation
import Testing
@testable import TranscriberCore

struct AudioTargetGroupingTests {
    let apps = [
        RunningAppInfo(pid: 100, bundleID: "com.google.Chrome", name: "Google Chrome"),
        RunningAppInfo(pid: 200, bundleID: "us.zoom.xos", name: "zoom.us"),
        RunningAppInfo(pid: 300, bundleID: "com.apple.TextEdit", name: "テキストエディット"),
        RunningAppInfo(pid: 999, bundleID: "io.github.yuuulf.LocalMeetingTranscriber", name: "Local Meeting Transcriber")
    ]

    @Test func groupsChromeHelpersUnderChromeByParentProcess() throws {
        let processes = [
            AudioProcessInfo(objectID: 11, pid: 101, bundleID: "com.google.Chrome.helper", isRunningOutput: true, ancestorPIDs: [100, 1]),
            AudioProcessInfo(objectID: 12, pid: 100, bundleID: "com.google.Chrome", isRunningOutput: false)
        ]
        let targets = AudioTargetGrouping.targets(processes: processes, runningApps: apps)
        let chrome = try #require(targets.first { $0.bundleID == "com.google.Chrome" })
        #expect(chrome.name == "Google Chrome")
        #expect(Set(chrome.processObjectIDs) == [11, 12])
        #expect(chrome.isPlayingAudio)
    }

    @Test func groupsByBundlePrefixWhenParentIsUnknown() throws {
        let processes = [
            AudioProcessInfo(objectID: 21, pid: 555, bundleID: "com.google.Chrome.helper.audio", isRunningOutput: true)
        ]
        let targets = AudioTargetGrouping.targets(processes: processes, runningApps: apps)
        let chrome = try #require(targets.first { $0.bundleID == "com.google.Chrome" })
        #expect(chrome.processObjectIDs == [21])
    }

    @Test func playingAppsComeFirstThenMeetingApps() {
        let processes = [
            AudioProcessInfo(objectID: 31, pid: 300, bundleID: "com.apple.TextEdit", isRunningOutput: true)
        ]
        let targets = AudioTargetGrouping.targets(processes: processes, runningApps: apps)
        #expect(targets.map(\.name).prefix(3) == ["テキストエディット", "Google Chrome", "zoom.us"])
    }

    @Test func includesIdleAppsSoTheyCanBeSelectedBeforeTheMeeting() throws {
        let targets = AudioTargetGrouping.targets(processes: [], runningApps: apps)
        let zoom = try #require(targets.first { $0.bundleID == "us.zoom.xos" })
        #expect(zoom.processObjectIDs.isEmpty)
        #expect(!zoom.isPlayingAudio)
    }

    @Test func excludesOwnProcessAndItsChildren() {
        let processes = [
            AudioProcessInfo(objectID: 41, pid: 999, bundleID: "io.github.yuuulf.LocalMeetingTranscriber", isRunningOutput: true),
            AudioProcessInfo(objectID: 42, pid: 1_000, bundleID: nil, isRunningOutput: true, ancestorPIDs: [999])
        ]
        let targets = AudioTargetGrouping.targets(processes: processes, runningApps: apps, excludingPID: 999)
        #expect(!targets.contains { $0.processObjectIDs.contains(41) || $0.processObjectIDs.contains(42) })
        #expect(!targets.contains { $0.pid == 999 })
    }

    @Test func skipsSilentProcessesThatBelongToNoApp() {
        let processes = [
            AudioProcessInfo(objectID: 61, pid: 888, bundleID: "com.apple.assistantd", isRunningOutput: false)
        ]
        let targets = AudioTargetGrouping.targets(processes: processes, runningApps: [])
        #expect(targets.isEmpty)
    }

    @Test func unknownProcessBecomesItsOwnTarget() throws {
        let processes = [
            AudioProcessInfo(objectID: 51, pid: 777, bundleID: nil, isRunningOutput: true)
        ]
        let targets = AudioTargetGrouping.targets(processes: processes, runningApps: [])
        let target = try #require(targets.first)
        #expect(target.name == "PID 777")
        #expect(target.processObjectIDs == [51])
    }
}
