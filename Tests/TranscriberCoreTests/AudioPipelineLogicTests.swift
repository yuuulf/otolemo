import Foundation
import Testing
@testable import TranscriberCore

struct AudioBufferQueueTests {
    @Test func deliversInOrderAndCountsDepth() async {
        let queue = AudioBufferQueue<Int>(capacity: 8)
        for value in 1...3 {
            queue.enqueue(value)
        }
        #expect(queue.metrics.depth == 3)
        #expect(queue.metrics.maxDepth == 3)
        queue.finish()
        var received: [Int] = []
        for await value in queue.stream {
            received.append(value)
        }
        #expect(received == [1, 2, 3])
        #expect(queue.metrics.dropped == 0)
    }

    @Test func dropsOldestWhenFullAndCountsDrops() async {
        let queue = AudioBufferQueue<Int>(capacity: 2)
        for value in 1...5 {
            queue.enqueue(value)
        }
        queue.finish()
        var received: [Int] = []
        for await value in queue.stream {
            received.append(value)
        }
        #expect(received == [4, 5])
        #expect(queue.metrics.enqueued == 5)
        #expect(queue.metrics.dropped == 3)
        #expect(queue.metrics.maxDepth == 2)
    }

    @Test func rejectsAfterFinish() {
        let queue = AudioBufferQueue<Int>(capacity: 2)
        queue.finish()
        #expect(queue.enqueue(1) == false)
    }
}

struct AudioLevelTests {
    @Test func silenceIsZero() {
        let samples = [Float](repeating: 0, count: 256)
        samples.withUnsafeBufferPointer { buffer in
            #expect(AudioLevel.normalizedLevel(buffer) == 0)
        }
    }

    @Test func fullScaleSquareWaveIsOne() {
        let samples = (0..<256).map { $0.isMultiple(of: 2) ? Float(1) : -1 }
        samples.withUnsafeBufferPointer { buffer in
            #expect(AudioLevel.rmsDecibels(buffer) == 0)
            #expect(AudioLevel.normalizedLevel(buffer) == 1)
        }
    }

    @Test func minus30DecibelsIsHalf() {
        #expect(AudioLevel.normalized(decibels: -30) == 0.5)
        #expect(AudioLevel.normalized(decibels: -90) == 0)
    }

    @Test func smoothingFallsSlowly() {
        #expect(AudioLevel.smoothed(previous: 0.2, current: 0.8) == 0.8)
        #expect(AudioLevel.smoothed(previous: 1, current: 0) == 0.85)
    }
}
