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

    /// 最初のチャンネルだけをモノラル（Float32）にコピーする。
    ///
    /// 内蔵マイクは音声処理の有無で 3ch や 7ch の「個別チャンネル」として届く。
    /// これを AVAudioConverter でモノラルへまとめると無音になるため、先に1チャンネルにする。
    /// （音声処理ありでは全チャンネルが同じ内容になる。）
    static func copyingFirstChannel(_ readOnly: AVReadOnlyAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let format = readOnly.format
        guard format.channelCount > 1 else { return copying(readOnly) }
        let frames = AVAudioFrameCount(readOnly.frameLength)
        guard frames > 0,
              format.commonFormat == .pcmFormatFloat32,
              let mono = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1),
              let copy = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: frames),
              let destination = copy.floatChannelData?[0] else {
            return nil
        }
        copy.frameLength = frames
        let channels = Int(format.channelCount)
        let interleaved = format.isInterleaved
        unsafe readOnly.withUnsafeAudioBufferList { list in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
            guard let data = buffers.first?.mData else { return }
            let samples = data.assumingMemoryBound(to: Float.self)
            if interleaved {
                for frame in 0..<Int(frames) {
                    destination[frame] = samples[frame * channels]
                }
            } else {
                destination.update(from: samples, count: Int(frames))
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
