import Foundation

/// 音量メーター用のレベル計算。
public enum AudioLevel {
    /// この dBFS 以下は 0 として表示する。
    public static let floorDecibels: Float = -60

    /// サンプルの RMS を dBFS で返す。無音なら `-infinity`。
    public static func rmsDecibels(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return -.infinity }
        var sum: Float = 0
        for sample in samples {
            sum += sample * sample
        }
        let rms = (sum / Float(samples.count)).squareRoot()
        return rms > 0 ? 20 * log10(rms) : -.infinity
    }

    /// dBFS を 0...1 のメーター値にする（-60dB → 0、0dB → 1）。
    public static func normalized(decibels: Float) -> Float {
        guard decibels.isFinite else { return 0 }
        return min(1, max(0, (decibels - floorDecibels) / -floorDecibels))
    }

    public static func normalizedLevel(_ samples: UnsafeBufferPointer<Float>) -> Float {
        normalized(decibels: rmsDecibels(samples))
    }

    /// 表示用に、上がるときは即座に、下がるときはゆっくり追従させる。
    public static func smoothed(previous: Float, current: Float, decay: Float = 0.85) -> Float {
        current >= previous ? current : max(current, previous * decay)
    }
}
