import Darwin

/// マイクと相手側の音声は別々の時計で動くため、共通の単調時計（mach host time）を基準に
/// 「会議開始からの経過ミリ秒」へ変換する。
public struct MeetingClock: Sendable, Equatable {
    public let startHostTime: UInt64
    private let numer: UInt64
    private let denom: UInt64

    /// - Parameters:
    ///   - startHostTime: 会議開始時点の host time。
    ///   - timebase: host time からナノ秒への換算比（テストで差し替える）。
    public init(startHostTime: UInt64, timebase: (numer: UInt32, denom: UInt32) = MeetingClock.systemTimebase) {
        self.startHostTime = startHostTime
        self.numer = UInt64(max(1, timebase.numer))
        self.denom = UInt64(max(1, timebase.denom))
    }

    public static func startingNow() -> MeetingClock {
        MeetingClock(startHostTime: mach_absolute_time())
    }

    public static var systemTimebase: (numer: UInt32, denom: UInt32) {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (info.numer, info.denom)
    }

    public static func == (lhs: MeetingClock, rhs: MeetingClock) -> Bool {
        lhs.startHostTime == rhs.startHostTime && lhs.numer == rhs.numer && lhs.denom == rhs.denom
    }

    /// host time を会議開始からの経過秒に変換する。開始前の時刻は 0 に丸める。
    public func elapsedSeconds(atHostTime hostTime: UInt64) -> Double {
        guard hostTime > startHostTime else { return 0 }
        let ticks = hostTime - startHostTime
        let nanos = ticks.multipliedFullWidth(by: numer)
        let (quotient, _) = denom.dividingFullWidth(nanos)
        return Double(quotient) / 1_000_000_000
    }

    public func elapsedMilliseconds(atHostTime hostTime: UInt64) -> Int64 {
        Int64((elapsedSeconds(atHostTime: hostTime) * 1000).rounded())
    }

    public func elapsedMillisecondsNow() -> Int64 {
        elapsedMilliseconds(atHostTime: mach_absolute_time())
    }
}
