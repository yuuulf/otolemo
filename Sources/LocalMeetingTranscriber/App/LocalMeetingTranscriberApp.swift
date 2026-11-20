import SwiftUI

@main
struct LocalMeetingTranscriberApp: App {
    @ViewState private var models = SpeechModelManager()
    @ViewState private var network = NetworkStatus()

    var body: some Scene {
        WindowGroup("Local Meeting Transcriber") {
            RootView()
                .environment(models)
                .environment(network)
                .frame(minWidth: 720, minHeight: 480)
        }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            Tab("診断", systemImage: "stethoscope") {
                NavigationStack {
                    DiagnosticsView()
                }
            }
        }
    }
}
