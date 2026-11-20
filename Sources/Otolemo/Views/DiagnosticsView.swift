import SwiftUI
import UniformTypeIdentifiers

/// Phase 0 の診断画面。日本語のオンデバイス認識が使えるかと、モデルの導入状態を確認する。
struct DiagnosticsView: View {
    @Environment(SpeechModelManager.self) private var models
    @Environment(NetworkStatus.self) private var network

    @ViewState private var microphone = AudioPermissions.microphone
    @ViewState private var testKind: RecognizerKind = .speechTranscriber
    @ViewState private var isImporting = false
    @ViewState private var isTesting = false
    @ViewState private var testOutcome: FileTranscriptionTest.Outcome?
    @ViewState private var testError: String?

    var body: some View {
        Form {
            Section("環境") {
                LabeledContent("ネットワーク") {
                    Label(network.isOnline ? "接続中" : "オフライン", systemImage: network.isOnline ? "wifi" : "wifi.slash")
                }
                LabeledContent("マイク権限") {
                    HStack {
                        Text(microphone.displayName)
                        if microphone == .undetermined {
                            Button("許可を求める") {
                                Task {
                                    _ = await AudioPermissions.requestMicrophone()
                                    microphone = AudioPermissions.microphone
                                }
                            }
                        } else if microphone == .denied {
                            Button("システム設定を開く", action: AudioPermissions.openMicrophoneSettings)
                        }
                    }
                }
                LabeledContent("相手側音声の権限") {
                    HStack {
                        Text("録音開始時に確認されます")
                            .foregroundStyle(.secondary)
                        Button("システム設定を開く", action: AudioPermissions.openAudioCaptureSettings)
                    }
                }
            }

            ForEach(RecognizerKind.allCases) { kind in
                ModelStatusSection(kind: kind)
            }

            if let error = models.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }

            Section {
                Picker("認識モデル", selection: $testKind) {
                    ForEach(RecognizerKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                HStack {
                    Button("音声ファイルを選んで認識…") {
                        isImporting = true
                    }
                    .disabled(isTesting || !models.status(for: testKind).isReady)
                    if isTesting {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                if let testOutcome {
                    LabeledContent("音声の長さ", value: testOutcome.audioSeconds.formatted(.number.precision(.fractionLength(1))) + " 秒")
                    LabeledContent("処理時間", value: testOutcome.processingSeconds.formatted(.number.precision(.fractionLength(1))) + " 秒")
                    LabeledContent("確定した発言", value: testOutcome.segmentCount.formatted())
                    Text(testOutcome.text.isEmpty ? "（認識結果なし）" : testOutcome.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let testError {
                    Label(testError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            } header: {
                Text("オフライン認識テスト")
            } footer: {
                Text("モデル導入後に Wi-Fi をオフにして実行すると、端末内だけで認識できるかを確認できます。")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("診断")
        .toolbar {
            Button("再確認", systemImage: "arrow.clockwise") {
                Task { await models.refresh() }
            }
            .disabled(models.isRefreshing)
        }
        .task {
            microphone = AudioPermissions.microphone
            await models.refresh()
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.audio]) { result in
            switch result {
            case .success(let url):
                runTest(url)
            case .failure(let error):
                testError = error.localizedDescription
            }
        }
    }

    private func runTest(_ url: URL) {
        isTesting = true
        testError = nil
        testOutcome = nil
        let kind = testKind
        Task {
            do {
                testOutcome = try await FileTranscriptionTest.run(fileURL: url, kind: kind)
            } catch {
                testError = error.localizedDescription
            }
            isTesting = false
        }
    }
}

private struct ModelStatusSection: View {
    @Environment(SpeechModelManager.self) private var models
    let kind: RecognizerKind

    var body: some View {
        let status = models.status(for: kind)
        Section(kind.displayName) {
            LabeledContent("この Mac で利用可能") {
                StatusMark(ok: status.isAvailableOnDevice)
            }
            LabeledContent("日本語（ja-JP）") {
                if let locale = status.locale {
                    Text(locale.identifier(.bcp47))
                } else {
                    StatusMark(ok: false)
                }
            }
            LabeledContent("モデル") {
                HStack {
                    Text(status.installation.displayName)
                    if status.installation == .downloadable {
                        Button("ダウンロード") {
                            Task { await models.download(kind) }
                        }
                        .disabled(models.downloadingKind != nil)
                    }
                }
            }
            if models.downloadingKind == kind {
                ProgressView(value: models.downloadProgress)
            }
        }
    }
}

private struct StatusMark: View {
    let ok: Bool

    var body: some View {
        Label(ok ? "はい" : "いいえ", systemImage: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
            .foregroundStyle(ok ? .green : .red)
    }
}
