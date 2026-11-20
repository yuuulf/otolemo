import AppKit
import SwiftUI
import TranscriberCore
import UniformTypeIdentifiers

/// 設定画面（⌘,）。
struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(SpeechModelManager.self) private var models
    @Environment(StorageModel.self) private var storage
    @Environment(LiveSessionModel.self) private var session

    @ViewState private var microphones: [AudioInputDevice] = []
    @ViewState private var debugAudioSize: Int64 = 0
    @ViewState private var message: String?
    @ViewState private var pendingRestore: URL?

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("入力") {
                Toggle("自分のマイクも文字起こしする", isOn: $settings.useMicrophone)
                Picker("マイク", selection: $settings.microphoneUID) {
                    Text("システムの既定").tag(String?.none)
                    ForEach(microphones) { device in
                        Text(device.name).tag(Optional(device.uid))
                    }
                }
                LabeledContent("相手側の対象アプリ") {
                    Text("ライブタブで選びます")
                        .foregroundStyle(.secondary)
                }
            }

            Section("音声認識") {
                Picker("認識エンジン", selection: $settings.recognizer) {
                    ForEach(RecognizerKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                LabeledContent("日本語モデル") {
                    Text(models.status(for: settings.recognizer).installation.displayName)
                }
                Text("モデルのダウンロードと動作確認は「診断」タブで行います。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("保存場所") {
                LabeledContent("データベース") {
                    Text(storage.paths.databaseURL.path(percentEncoded: false))
                        .textSelection(.enabled)
                        .font(.caption)
                }
                HStack {
                    Button("Finder で表示") {
                        NSWorkspace.shared.activateFileViewerSelecting([storage.paths.databaseURL])
                    }
                    Button("今すぐバックアップ") {
                        Task { await backup() }
                    }
                    Button("バックアップから復元…") {
                        chooseRestoreFile()
                    }
                    .disabled(session.phase != .idle)
                }
            }

            Section {
                Toggle("デバッグ用に音声を保存する", isOn: $settings.saveDebugAudio)
                Stepper("保存期間: \(settings.debugAudioRetentionDays) 日", value: $settings.debugAudioRetentionDays, in: 1...90)
                HStack {
                    Text("保存中: \(debugAudioSize.formatted(.byteCount(style: .file)))")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Finder で表示") {
                        try? storage.paths.createDirectories()
                        NSWorkspace.shared.open(storage.paths.debugAudioDirectory)
                    }
                    Button("すべて削除", role: .destructive) {
                        DebugAudioRecorder.removeAll(in: storage.paths.debugAudioDirectory)
                        refreshDebugAudioSize()
                    }
                }
            } header: {
                Text("デバッグ")
            } footer: {
                Text("通常は OFF にしてください。ON にすると、認識に渡した音声を会議ごとに端末内へ保存します。保存期間を過ぎたファイルは起動時に削除します。")
            }

            Section {
                Toggle("詳細なログを出す", isOn: $settings.verboseLogging)
            } header: {
                Text("ログ")
            } footer: {
                Text("ON でも、音声や文字起こしの本文はログに出しません（遅延・欠落などの計測値だけ）。")
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .frame(minHeight: 520)
        .task {
            microphones = AudioDevices.inputDevices()
            refreshDebugAudioSize()
            await models.refresh()
        }
        .onChange(of: settings.verboseLogging, initial: true) { _, verbose in
            Log.setVerbose(verbose)
        }
        .confirmationDialog(
            "バックアップから復元しますか？",
            isPresented: .constant(pendingRestore != nil)
        ) {
            Button("復元", role: .destructive) {
                if let url = pendingRestore {
                    Task { await restore(from: url) }
                }
                pendingRestore = nil
            }
            Button("キャンセル", role: .cancel) {
                pendingRestore = nil
            }
        } message: {
            Text("現在のデータはバックアップの内容に置き換わります。念のため、復元前に現在のデータを自動でバックアップします。")
        }
        .alert("お知らせ", isPresented: .constant(message != nil)) {
            Button("OK") { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    private func refreshDebugAudioSize() {
        debugAudioSize = DebugAudioRecorder.totalSize(in: storage.paths.debugAudioDirectory)
    }

    private func backup() async {
        guard let repository = storage.repository else { return }
        do {
            let url = try await repository.backup(to: storage.paths.backupsDirectory)
            message = "バックアップを作成しました: \(url.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            message = "バックアップできませんでした: \(error.localizedDescription)"
        }
    }

    private func chooseRestoreFile() {
        let panel = NSOpenPanel()
        panel.directoryURL = storage.paths.backupsDirectory
        panel.allowedContentTypes = [UTType(filenameExtension: "sqlite") ?? .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pendingRestore = url
    }

    private func restore(from url: URL) async {
        guard let repository = storage.repository, session.phase == .idle else { return }
        do {
            _ = try await repository.backup(to: storage.paths.backupsDirectory)
            try await repository.restore(from: url)
            storage.didChange()
            message = "復元しました。"
        } catch {
            message = "復元できませんでした: \(error.localizedDescription)"
        }
    }
}
