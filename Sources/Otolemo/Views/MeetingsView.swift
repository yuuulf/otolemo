import AppKit
import SwiftUI
import TranscriberCore

/// 会議履歴。一覧（新しい順）と検索、選んだ会議の全文。
struct MeetingsView: View {
    @Environment(StorageModel.self) private var storage

    @ViewState private var meetings: [Meeting] = []
    @ViewState private var query = ""
    @ViewState private var selection: Meeting.ID?
    @ViewState private var loadError: String?

    var body: some View {
        NavigationSplitView {
            List(meetings, selection: $selection) { meeting in
                MeetingRow(meeting: meeting)
                    .tag(meeting.id)
            }
            .overlay {
                if meetings.isEmpty {
                    if query.isEmpty {
                        ContentUnavailableView("会議はまだありません", systemImage: "tray", description: Text("ライブタブで記録すると、ここに表示されます。"))
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                if storage.recoveredCount > 0 {
                    RecoveryNotice()
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            if let selection, let meeting = meetings.first(where: { $0.id == selection }) {
                MeetingDetailView(meeting: meeting, highlight: query)
                    .id(meeting.id)
            } else {
                ContentUnavailableView("会議を選んでください", systemImage: "text.bubble")
            }
        }
        .searchable(text: $query, placement: .sidebar, prompt: "タイトル・発言を検索")
        .navigationTitle("履歴")
        .task(id: ReloadKey(token: storage.changeToken, query: query)) {
            await reload()
        }
        .alert("読み込めませんでした", isPresented: .constant(loadError != nil)) {
            Button("OK") { loadError = nil }
        } message: {
            Text(loadError ?? "")
        }
    }

    private struct ReloadKey: Equatable {
        var token: Int
        var query: String
    }

    private func reload() async {
        guard let repository = storage.repository else { return }
        do {
            meetings = try await repository.meetings(matching: query)
            if let selection, !meetings.contains(where: { $0.id == selection }) {
                self.selection = nil
            }
        } catch {
            loadError = error.localizedDescription
        }
    }
}

private struct MeetingRow: View {
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(meeting.title)
                .lineLimit(1)
            HStack {
                Text(meeting.startedAt, format: .dateTime.year().month().day().hour().minute())
                Text(meeting.sourceApp)
                if let duration = meeting.duration {
                    Text(ElapsedTimeFormat.string(duration: duration))
                        .monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if meeting.status != .completed {
                Text(meeting.status.displayName)
                    .font(.caption2.bold())
                    .foregroundStyle(meeting.status == .recording ? .red : .orange)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct RecoveryNotice: View {
    @Environment(StorageModel.self) private var storage

    var body: some View {
        HStack {
            Label("前回の異常終了で記録中だった \(storage.recoveredCount) 件の会議を「中断」として保存しました。", systemImage: "exclamationmark.arrow.circlepath")
                .font(.caption)
            Button("閉じる", systemImage: "xmark", action: storage.dismissRecoveryNotice)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
        .padding(8)
        .background(.orange.opacity(0.15), in: .rect(cornerRadius: 8))
        .padding(.horizontal, 8)
    }
}
