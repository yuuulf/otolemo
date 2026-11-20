import SwiftUI
import TranscriberCore

@main
struct LocalMeetingTranscriberApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Local Meeting Transcriber") {
            RootView()
                .environment(appDelegate.models)
                .environment(appDelegate.network)
                .environment(appDelegate.settings)
                .environment(appDelegate.storage)
                .environment(appDelegate.session)
                .frame(minWidth: 760, minHeight: 520)
        }
        Settings {
            SettingsView()
                .environment(appDelegate.models)
                .environment(appDelegate.settings)
                .environment(appDelegate.storage)
                .environment(appDelegate.session)
        }
    }
}

struct RootView: View {
    @Environment(StorageModel.self) private var storage

    var body: some View {
        TabView {
            Tab("ライブ", systemImage: "waveform") {
                NavigationStack {
                    LiveView()
                }
            }
            Tab("履歴", systemImage: "clock.arrow.circlepath") {
                MeetingsView()
            }
            Tab("診断", systemImage: "stethoscope") {
                NavigationStack {
                    DiagnosticsView()
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let error = storage.openError {
                Label(error, systemImage: "externaldrive.badge.exclamationmark")
                    .padding()
                    .background(.red.opacity(0.15), in: .rect(cornerRadius: 8))
                    .padding()
            }
        }
    }
}
