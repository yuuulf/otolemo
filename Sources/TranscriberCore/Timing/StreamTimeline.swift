/// 1つの入力系統について、認識エンジンへ渡す音声の時刻を会議の時間軸に合わせる。
///
/// 認識エンジンは連続した音声を前提とし、時刻が前に戻ると失敗する。そこで、
/// - 最初のバッファは host time から求めた会議経過秒を開始時刻として明示する。
/// - 以降はサンプル数から求めた連続時刻を使い、開始時刻は明示しない。
/// - スリープ復帰などで host time がサンプル時刻より大きく進んだときと、
///   入力を作り直した直後（`markDiscontinuity()`）だけ、開始時刻を明示して合わせ直す。
/// - どの場合も時刻は前に戻さない。
public struct StreamTimeline: Sendable {
    public struct Placement: Sendable, Equatable {
        /// このバッファの開始時刻（会議経過秒）。
        public var startSeconds: Double
        /// 認識エンジンへ明示的に渡すべき開始時刻。連続していれば `nil`。
        public var explicitStartSeconds: Double?
        /// 直前のバッファの終わりから空いた秒数（中断の計測用）。
        public var gapSeconds: Double

        public init(startSeconds: Double, explicitStartSeconds: Double?, gapSeconds: Double) {
            self.startSeconds = startSeconds
            self.explicitStartSeconds = explicitStartSeconds
            self.gapSeconds = gapSeconds
        }
    }

    public let clock: MeetingClock
    /// host time とサンプル時刻のずれがこれを超えたら合わせ直す。
    public let resyncThresholdSeconds: Double

    private var nextStartSeconds: Double?
    private var needsResync = true

    public init(clock: MeetingClock, resyncThresholdSeconds: Double = 0.5) {
        self.clock = clock
        self.resyncThresholdSeconds = resyncThresholdSeconds
    }

    /// 次のバッファの連続時刻。まだ何も受け取っていなければ `nil`。
    public var expectedNextStartSeconds: Double? { nextStartSeconds }

    public mutating func place(hostTime: UInt64, frameCount: Int, sampleRate: Double) -> Placement {
        let hostSeconds = clock.elapsedSeconds(atHostTime: hostTime)
        let duration = sampleRate > 0 ? Double(max(0, frameCount)) / sampleRate : 0

        let placement: Placement
        if let expected = nextStartSeconds {
            let drift = hostSeconds - expected
            if needsResync || drift > resyncThresholdSeconds {
                let start = max(hostSeconds, expected)
                placement = Placement(startSeconds: start, explicitStartSeconds: start, gapSeconds: start - expected)
            } else {
                placement = Placement(startSeconds: expected, explicitStartSeconds: nil, gapSeconds: 0)
            }
        } else {
            placement = Placement(startSeconds: hostSeconds, explicitStartSeconds: hostSeconds, gapSeconds: 0)
        }

        nextStartSeconds = placement.startSeconds + duration
        needsResync = false
        return placement
    }

    /// 入力を作り直したとき（デバイス切替など）に呼ぶ。次のバッファで host time に合わせ直す。
    public mutating func markDiscontinuity() {
        needsResync = true
    }
}
