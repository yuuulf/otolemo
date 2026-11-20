# otolemo

Zoom / Google Meet の会議を、端末内だけで日本語文字起こしする自分用の macOS アプリ（Local Meeting Transcriber）。
自分のマイクと相手側（会議アプリの出力音声）を別々に取得し、音声・文字起こし・検索データは外部に送信しない。

## 動作環境

- macOS 27 以降（Apple シリコン）
- Swift 6.2 以降（Xcode または Command Line Tools）

## ビルドと起動

```sh
scripts/build-app.sh        # build/LocalMeetingTranscriber.app を作る（release）
open build/LocalMeetingTranscriber.app
```

マイクと音声キャプチャの権限は `.app` として起動したときに求められる。`swift run` だとターミナル側の権限で動くため、権限確認には使わない。

Command Line Tools だけの環境では SwiftUI のマクロプラグインが無く `@State` が使えないため、コードでは別名の `@ViewState` を使っている。

## 使い方

### 1. 診断（初回）

「診断」タブで、日本語（`ja-JP`）のオンデバイス認識が使えるかを確認する。

- モデルが「未導入」なら「ダウンロード」を押す。ネットワークを使うのはこの操作だけ。
- 「オフライン認識テスト」で音声ファイルを選ぶと、端末内だけで認識できるかと処理時間を確認できる。Wi-Fi をオフにして試すとよい。
- 第一候補は `SpeechTranscriber`。使えない・精度が足りない場合は `DictationTranscriber` を使う。

## テスト

```sh
scripts/test.sh
```

Command Line Tools だけの環境では Swift Testing のマクロプラグインが自動で見つからないため、このスクリプトでプラグインの場所を指定している。
