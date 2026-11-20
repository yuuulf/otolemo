import AppKit
import SwiftUI
import TranscriberCore
import UniformTypeIdentifiers

/// 1つの会議の全文。タイトル・本文の修正、コピー、書き出し、削除ができる。
struct MeetingDetailView: View {
    let meeting: Meeting
    /// 履歴の検索語。含む発言を強調する。
    let highlight: String

    @Environment(StorageModel.self) private var storage

    @ViewState private var title = ""
    @ViewState private var segments: [TranscriptSegment] = []
    @ViewState private var editingID: TranscriptSegment.ID?
    @ViewState private var draft = ""
    @ViewState private var isConfirmingDelete = false
    @ViewState private var message: String?
    @ViewState private var showOnlyMatches = false

    private let exporter = ExportService()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding()
            Divider()
            List {
                ForEach(visibleSegments) { segment in
                    if editingID == segment.id {
                        SegmentEditor(segment: segment, draft: $draft, save: { save(segment) }, cancel: { editingID = nil })
                    } else {
                        TranscriptLineRow(source: segment.source, startMS: segment.startMS, text: segment.text, isFinal: true, isEdited: segment.isEdited)
                            .listRowBackground(matches(segment) ? Color.yellow.opacity(0.15) : nil)
                            .help(segment.isEdited ? "認識結果: \(segment.originalText)" : "")
                            .contextMenu {
                                Button("本文を修正", systemImage: "pencil") { beginEditing(segment) }
                                Button("コピー", systemImage: "doc.on.doc") { copy(segment.text) }
                                if segment.isEdited {
                                    Button("認識結果に戻す", systemImage: "arrow.uturn.backward") { revert(segment) }
                                }
                            }
                    }
                }
            }
            .overlay {
                if segments.isEmpty {
                    ContentUnavailableView("発言はありません", systemImage: "text.bubble")
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button("全文をコピー", systemImage: "doc.on.doc") {
                    copy(exporter.markdown(for: currentMeeting, segments: segments))
                }
                Menu("書き出し", systemImage: "square.and.arrow.up") {
                    ForEach(ExportFormat.allCases) { format in
                        Button(format.displayName) { export(format) }
                    }
                }
                Button("保存先を表示", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([storage.paths.databaseURL])
                }
                Button("削除", systemImage: "trash", role: .destructive) {
                    isConfirmingDelete = true
                }
            }
        }
        .confirmationDialog("「\(currentMeeting.title)」を削除しますか？", isPresented: $isConfirmingDelete) {
            Button("削除", role: .destructive) {
                Task { await delete() }
            }
        } message: {
            Text("会議と、すべての発言が削除されます。この操作は取り消せません。")
        }
        .alert("お知らせ", isPresented: .constant(message != nil)) {
            Button("OK") { message = nil }
        } message: {
            Text(message ?? "")
        }
        .task {
            title = meeting.title
            await load()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("タイトル", text: $title)
                .font(.title2)
                .textFieldStyle(.plain)
                .onSubmit { Task { await rename() } }
            HStack {
                Text(meeting.startedAt, format: .dateTime.year().month().day().hour().minute())
                Text("・\(meeting.sourceApp)")
                if let duration = meeting.duration {
                    Text("・\(ElapsedTimeFormat.string(duration: duration))")
                        .monospacedDigit()
                }
                Text("・\(meeting.status.displayName)")
                Text("・発言 \(segments.count) 件")
                Spacer()
                if !highlight.trimmingCharacters(in: .whitespaces).isEmpty {
                    Toggle("一致した発言だけ", isOn: $showOnlyMatches)
                        .toggleStyle(.checkbox)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            Text("右クリックで本文の修正・コピーができます。タイトルは編集して Return で保存します。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var currentMeeting: Meeting {
        var current = meeting
        current.title = title
        return current
    }

    private var visibleSegments: [TranscriptSegment] {
        showOnlyMatches ? segments.filter(matches) : segments
    }

    private func matches(_ segment: TranscriptSegment) -> Bool {
        let query = highlight.trimmingCharacters(in: .whitespaces)
        return !query.isEmpty && segment.text.localizedStandardContains(query)
    }

    // MARK: - 操作

    private func load() async {
        do {
            segments = try await storage.repository?.segments(meetingID: meeting.id) ?? []
        } catch {
            message = "発言を読み込めませんでした: \(error.localizedDescription)"
        }
    }

    private func rename() async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            title = meeting.title
            return
        }
        do {
            try await storage.repository?.renameMeeting(id: meeting.id, title: trimmed)
            storage.didChange()
        } catch {
            message = "タイトルを保存できませんでした: \(error.localizedDescription)"
        }
    }

    private func beginEditing(_ segment: TranscriptSegment) {
        draft = segment.text
        editingID = segment.id
    }

    private func save(_ segment: TranscriptSegment) {
        let text = draft
        editingID = nil
        Task {
            do {
                try await storage.repository?.updateEditedText(segmentID: segment.id, editedText: text)
                await load()
            } catch {
                message = "修正を保存できませんでした: \(error.localizedDescription)"
            }
        }
    }

    private func revert(_ segment: TranscriptSegment) {
        Task {
            try? await storage.repository?.updateEditedText(segmentID: segment.id, editedText: nil)
            await load()
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func export(_ format: ExportFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = exporter.suggestedFileName(for: currentMeeting, format: format)
        panel.allowedContentTypes = [format == .json ? .json : UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try exporter.data(for: currentMeeting, segments: segments, format: format).write(to: url, options: .atomic)
        } catch {
            message = "書き出せませんでした: \(error.localizedDescription)"
        }
    }

    private func delete() async {
        do {
            try await storage.repository?.deleteMeeting(id: meeting.id)
            storage.didChange()
        } catch {
            message = "削除できませんでした: \(error.localizedDescription)"
        }
    }
}

private struct SegmentEditor: View {
    let segment: TranscriptSegment
    @Binding var draft: String
    let save: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(ElapsedTimeFormat.string(milliseconds: segment.startMS))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                SourceBadge(source: segment.source)
                Text("認識結果: \(segment.originalText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            TextField("本文", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("キャンセル", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("保存", action: save)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
