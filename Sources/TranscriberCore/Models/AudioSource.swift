import Foundation

/// 音声の入力系統。
///
/// `system` は「相手側」として扱うが、実際は対象アプリの出力全体なので、
/// 複数人の声や通知音などが含まれうる。
public enum AudioSource: String, Codable, Sendable, CaseIterable, Identifiable {
    case microphone
    case system

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .microphone: "自分"
        case .system: "相手側"
        }
    }
}
