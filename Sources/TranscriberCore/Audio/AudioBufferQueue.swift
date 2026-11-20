import Synchronization

/// 音声コールバックから処理側へ要素を渡すキュー。
///
/// コールバック側は `enqueue` するだけで、変換・認識・保存は処理側のタスクで行う。
/// 容量を超えた場合は古い要素から捨てる（取得を止めない）。捨てた数と滞留数を計測する。
public final class AudioBufferQueue<Element: Sendable>: Sendable {
    public struct Metrics: Sendable, Equatable {
        public var enqueued: Int = 0
        public var dropped: Int = 0
        /// 直近の enqueue 時点で処理を待っていた要素数。
        public var depth: Int = 0
        public var maxDepth: Int = 0

        public init() {}
    }

    public let capacity: Int
    public let stream: AsyncStream<Element>

    private let continuation: AsyncStream<Element>.Continuation
    private let state = Mutex(Metrics())

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        (stream, continuation) = AsyncStream.makeStream(of: Element.self, bufferingPolicy: .bufferingNewest(self.capacity))
    }

    /// 要素を積む。終了済みなら `false`。
    @discardableResult
    public func enqueue(_ element: Element) -> Bool {
        let result = continuation.yield(element)
        return state.withLock { metrics in
            switch result {
            case .enqueued(let remaining):
                metrics.enqueued += 1
                metrics.depth = capacity - remaining
                metrics.maxDepth = max(metrics.maxDepth, metrics.depth)
                return true
            case .dropped:
                metrics.enqueued += 1
                metrics.dropped += 1
                metrics.depth = capacity
                metrics.maxDepth = capacity
                return true
            case .terminated:
                return false
            @unknown default:
                return false
            }
        }
    }

    /// これ以上積まない。処理側は残りを読み切ってから終わる。
    public func finish() {
        continuation.finish()
    }

    public var metrics: Metrics {
        state.withLock { $0 }
    }
}
