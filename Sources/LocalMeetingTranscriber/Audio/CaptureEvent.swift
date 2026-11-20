import AVFAudio
import Darwin

/// 音声コールバックから処理側へ渡す1バッファ。コールバックの外で使えるようコピー済み。
struct CapturedAudio: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    /// バッファ先頭の host time（mach_absolute_time 基準）。
    let hostTime: UInt64
}

enum CaptureEvent: Sendable {
    case audio(CapturedAudio)
    /// 入力を作り直した（デバイス切替など）。時刻を合わせ直す。
    case discontinuity
}

/// 1系統あたりのキュー容量。4096 フレーム/48kHz で約 3 分ぶん。
let captureQueueCapacity = 2_048

extension AVAudioPCMBuffer {
    /// 中身をコピーした新しいバッファを返す。
    func deepCopy() -> AVAudioPCMBuffer? {
        guard frameLength > 0, let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else {
            return nil
        }
        copy.frameLength = frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, destination) {
            guard let fromData = from.mData, let toData = to.mData else { continue }
            memcpy(toData, fromData, Int(min(from.mDataByteSize, to.mDataByteSize)))
        }
        return copy
    }
}

extension AVAudioPCMBuffer {
    /// 読み取り専用バッファの中身をコピーした、書き込み可能なバッファを返す。
    static func copying(_ readOnly: AVReadOnlyAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(readOnly.frameLength)
        guard frames > 0, let copy = AVAudioPCMBuffer(pcmFormat: readOnly.format, frameCapacity: frames) else {
            return nil
        }
        copy.frameLength = frames
        unsafe readOnly.withUnsafeAudioBufferList { list in
            let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
            let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            for (from, to) in zip(source, destination) {
                guard let fromData = from.mData, let toData = to.mData else { continue }
                memcpy(toData, fromData, Int(min(from.mDataByteSize, to.mDataByteSize)))
            }
        }
        return copy
    }
}

extension AVAudioTime {
    /// host time が有効ならそれを、無効なら現在時刻を返す。
    var hostTimeOrNow: UInt64 {
        isHostTimeValid ? hostTime : mach_absolute_time()
    }
}
