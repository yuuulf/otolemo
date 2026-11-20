import AVFAudio

/// 音声認識エンジンの抽象化。Apple の音声認識の代わりに WhisperKit などへ差し替えられるようにする。
///
/// 使い方: `prepare()` で受け付ける音声形式を得る → `start(input:)` で結果の列を受け取る →
/// 入力を終えたら `finish()` で残りを確定させる。
protocol TranscriptionEngine: AnyObject, Sendable {
    /// DB の `segments.engine` に保存する識別子。
    var identifier: String { get }

    /// モデルを読み込み、受け付ける音声形式を返す。ネットワークは使わない。
    func prepare() async throws -> AudioFormatBox

    /// 音声の入力を始める。結果は暫定・確定の両方が届く。
    func start(input: AsyncStream<EngineInput>) async throws -> AsyncThrowingStream<RecognizedText, any Error>

    /// 入力の終わりまで認識を確定させてから終了する。
    func finish() async

    /// 残りを捨ててすぐに終了する。
    func cancel() async
}
