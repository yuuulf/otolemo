/// 字幕の遅延（発話の終わりから結果が届くまで）の計測。直近の一定件数で平均と p95 を出す。
public struct LatencyStats: Sendable, Equatable {
    public let window: Int
    public private(set) var samples: [Int64] = []
    public private(set) var totalCount = 0

    public init(window: Int = 200) {
        self.window = max(1, window)
    }

    public mutating func record(milliseconds: Int64) {
        samples.append(max(0, milliseconds))
        if samples.count > window {
            samples.removeFirst(samples.count - window)
        }
        totalCount += 1
    }

    public var mean: Int64? {
        guard !samples.isEmpty else { return nil }
        return samples.reduce(0, +) / Int64(samples.count)
    }

    /// 95 パーセンタイル（最近傍順位法）。
    public var p95: Int64? {
        percentile(0.95)
    }

    public func percentile(_ fraction: Double) -> Int64? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        return sorted[min(sorted.count - 1, max(0, rank - 1))]
    }
}
