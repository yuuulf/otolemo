/// 確定発言を、届いた順に1つずつではなく、まとまった単位でトランザクション保存する。
///
/// 保存に失敗した発言は捨てずに残し、次の書き込みか `flush()` で再試行する。
public actor SegmentWriter {
    private let repository: MeetingRepository
    private var pending: [TranscriptSegment] = []
    private var isWriting = false

    public private(set) var writtenCount = 0
    public private(set) var failureCount = 0
    public private(set) var lastError: String?

    public init(repository: MeetingRepository) {
        self.repository = repository
    }

    public var pendingCount: Int {
        pending.count
    }

    /// 発言を保存待ちに加え、保存を試みる。保存待ちが残っていなければ `true`。
    @discardableResult
    public func enqueue(_ segment: TranscriptSegment) async -> Bool {
        pending.append(segment)
        await drain()
        return pending.isEmpty
    }

    /// 保存待ちをすべて書き込む。全件保存できたら `true`。
    public func flush(maxAttempts: Int = 3) async -> Bool {
        var attempts = 0
        while true {
            while isWriting {
                await Task.yield()
            }
            if pending.isEmpty { return true }
            guard attempts < maxAttempts else { return false }
            attempts += 1
            await drain()
        }
    }

    private func drain() async {
        guard !isWriting else { return }
        isWriting = true
        defer { isWriting = false }
        while !pending.isEmpty {
            let batch = pending
            pending.removeAll()
            do {
                try await repository.insert(batch)
                writtenCount += batch.count
                lastError = nil
            } catch {
                pending.insert(contentsOf: batch, at: 0)
                failureCount += 1
                lastError = String(describing: error)
                return
            }
        }
    }
}
