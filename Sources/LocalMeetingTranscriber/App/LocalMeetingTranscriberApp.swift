import SwiftUI
import TranscriberCore

@main
struct LocalMeetingTranscriberApp: App {
    @ViewState private var models = SpeechModelManager()
    @ViewState private var network = NetworkStatus()
    @ViewState private var settings = AppSettings()
    @ViewState private var session = LiveSessionModel(paths: .standard)

    var body: some Scene {
        WindowGroup("Local Meeting Transcriber") {
            RootView()
                .environment(models)
                .environment(network)
                .environment(settings)
                .environment(session)
                .frame(minWidth: 760, minHeight: 520)
        }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            Tab("ライブ", systemImage: "waveform") {
                NavigationStack {
                    LiveView()
                }
            }
            Tab("診断", systemImage: "stethoscope") {
                NavigationStack {
                    DiagnosticsView()
                }
            }
        }
    }
}
