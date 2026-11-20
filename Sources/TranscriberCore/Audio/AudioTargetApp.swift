import Foundation

/// 音声を出しているプロセス（Core Audio のプロセスオブジェクト）。
public struct AudioProcessInfo: Sendable, Equatable {
    public var objectID: UInt32
    public var pid: Int32
    public var bundleID: String?
    public var isRunningOutput: Bool
    /// 親プロセスをたどった PID の列（近い順）。ヘルパープロセスを本体アプリにまとめるのに使う。
    public var ancestorPIDs: [Int32]

    public init(objectID: UInt32, pid: Int32, bundleID: String?, isRunningOutput: Bool, ancestorPIDs: [Int32] = []) {
        self.objectID = objectID
        self.pid = pid
        self.bundleID = bundleID
        self.isRunningOutput = isRunningOutput
        self.ancestorPIDs = ancestorPIDs
    }
}

/// 起動中のアプリ。
public struct RunningAppInfo: Sendable, Equatable {
    public var pid: Int32
    public var bundleID: String?
    public var name: String

    public init(pid: Int32, bundleID: String?, name: String) {
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
    }
}

/// 相手側の音声を取得する対象アプリ。ヘルパープロセスも含めて1つにまとめたもの。
public struct AudioTargetApp: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var bundleID: String?
    public var pid: Int32?
    /// このアプリに属する、Core Audio のプロセスオブジェクト（ヘルパーを含む）。
    public var processObjectIDs: [UInt32]
    public var isPlayingAudio: Bool

    public init(
        id: String,
        name: String,
        bundleID: String?,
        pid: Int32?,
        processObjectIDs: [UInt32],
        isPlayingAudio: Bool
    ) {
        self.id = id
        self.name = name
        self.bundleID = bundleID
        self.pid = pid
        self.processObjectIDs = processObjectIDs
        self.isPlayingAudio = isPlayingAudio
    }

    /// 会議でよく使うアプリか（一覧の上に出す）。
    public var isKnownMeetingApp: Bool {
        guard let bundleID else { return false }
        return AudioTargetGrouping.knownMeetingBundleIDs.contains(bundleID)
    }
}

public enum AudioTargetGrouping {
    public static let knownMeetingBundleIDs: Set<String> = [
        "us.zoom.xos",
        "com.google.Chrome",
        "com.apple.Safari",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",
        "org.mozilla.firefox",
        "com.brave.Browser",
        "com.microsoft.teams2",
        "com.tinyspeck.slackmacgap",
        "com.cisco.webexmeetingsapp"
    ]

    /// 音声プロセスを起動中のアプリにまとめる。
    ///
    /// 対応づけの順序: PID が一致 → 親プロセスがアプリ → bundle ID がアプリの bundle ID で始まる
    /// （例: `com.google.Chrome.helper` → `com.google.Chrome`）。
    /// どのアプリにも属さないプロセスは、音声を出しているときだけ単独の候補にする（常駐デーモンを並べないため）。
    /// 起動中のアプリは、音声を出していなくても候補に含める（会議前に選べるように）。
    public static func targets(
        processes: [AudioProcessInfo],
        runningApps: [RunningAppInfo],
        excludingPID ownPID: Int32? = nil
    ) -> [AudioTargetApp] {
        var targets: [String: AudioTargetApp] = [:]
        var order: [String] = []

        func key(for app: RunningAppInfo) -> String {
            app.bundleID ?? "pid-\(app.pid)"
        }

        for app in runningApps where app.pid != ownPID {
            let id = key(for: app)
            guard targets[id] == nil else { continue }
            targets[id] = AudioTargetApp(
                id: id,
                name: app.name,
                bundleID: app.bundleID,
                pid: app.pid,
                processObjectIDs: [],
                isPlayingAudio: false
            )
            order.append(id)
        }

        for process in processes where process.pid != ownPID && !process.ancestorPIDs.contains(where: { $0 == ownPID }) {
            let owner = owningApp(of: process, in: runningApps)
            guard owner != nil || process.isRunningOutput else { continue }
            let id = owner.map(key(for:)) ?? process.bundleID ?? "pid-\(process.pid)"
            if targets[id] == nil {
                targets[id] = AudioTargetApp(
                    id: id,
                    name: owner?.name ?? process.bundleID ?? "PID \(process.pid)",
                    bundleID: owner?.bundleID ?? process.bundleID,
                    pid: owner?.pid ?? process.pid,
                    processObjectIDs: [],
                    isPlayingAudio: false
                )
                order.append(id)
            }
            targets[id]?.processObjectIDs.append(process.objectID)
            if process.isRunningOutput {
                targets[id]?.isPlayingAudio = true
            }
        }

        return order.compactMap { targets[$0] }.sorted { lhs, rhs in
            if lhs.isPlayingAudio != rhs.isPlayingAudio { return lhs.isPlayingAudio }
            if lhs.isKnownMeetingApp != rhs.isKnownMeetingApp { return lhs.isKnownMeetingApp }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    static func owningApp(of process: AudioProcessInfo, in apps: [RunningAppInfo]) -> RunningAppInfo? {
        if let app = apps.first(where: { $0.pid == process.pid }) {
            return app
        }
        for ancestor in process.ancestorPIDs where ancestor > 1 {
            if let app = apps.first(where: { $0.pid == ancestor }) {
                return app
            }
        }
        guard let bundleID = process.bundleID else { return nil }
        return apps
            .filter { app in
                guard let appID = app.bundleID else { return false }
                return bundleID.hasPrefix(appID + ".")
            }
            .max { ($0.bundleID?.count ?? 0) < ($1.bundleID?.count ?? 0) }
    }
}
