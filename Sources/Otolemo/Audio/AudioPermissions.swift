import AVFAudio
import AppKit

/// マイク・音声キャプチャの権限。
enum AudioPermissions {
    enum MicrophoneState: Equatable {
        case undetermined
        case denied
        case granted

        var displayName: String {
            switch self {
            case .undetermined: "未確認"
            case .denied: "拒否されています"
            case .granted: "許可済み"
            }
        }
    }

    static var microphone: MicrophoneState {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: .granted
        case .denied: .denied
        default: .undetermined
        }
    }

    /// マイク権限を求める。拒否済みならダイアログは出ない。
    static func requestMicrophone() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    /// システム設定のマイクのプライバシー設定を開く。
    @MainActor
    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    /// システム設定の「画面収録とシステムオーディオ録音」を開く。Process Tap の権限はここで管理される。
    @MainActor
    static func openAudioCaptureSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")
    }

    @MainActor
    private static func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}
