import Foundation
import Observation
import Speech

/// 音声認識モデルの対応状況。
struct SpeechModelStatus: Equatable, Sendable {
    enum Installation: Equatable, Sendable {
        case unknown
        case unsupported
        case downloadable
        case downloading
        case installed

        var displayName: String {
            switch self {
            case .unknown: "確認中"
            case .unsupported: "非対応"
            case .downloadable: "未導入（ダウンロード可能）"
            case .downloading: "ダウンロード中"
            case .installed: "導入済み"
            }
        }
    }

    var isAvailableOnDevice = false
    var locale: Locale?
    var installation: Installation = .unknown

    var isReady: Bool {
        isAvailableOnDevice && locale != nil && installation == .installed
    }
}

/// Phase 0: `ja-JP` のオンデバイス認識が使えるかを確認し、必要ならモデルを取得する。
@MainActor
@Observable
final class SpeechModelManager {
    private(set) var statuses: [RecognizerKind: SpeechModelStatus] = [:]
    private(set) var downloadingKind: RecognizerKind?
    private(set) var downloadProgress: Double = 0
    private(set) var lastError: String?
    private(set) var isRefreshing = false

    func status(for kind: RecognizerKind) -> SpeechModelStatus {
        statuses[kind] ?? SpeechModelStatus()
    }

    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        for kind in RecognizerKind.allCases {
            statuses[kind] = await Self.loadStatus(for: kind)
        }
    }

    /// 利用者の操作でモデルをダウンロードする。この操作だけがネットワークを使う。
    func download(_ kind: RecognizerKind) async {
        guard downloadingKind == nil else { return }
        lastError = nil
        guard let locale = await kind.supportedLocale() else {
            lastError = "\(kind.displayName) は日本語に対応していません。"
            return
        }
        downloadingKind = kind
        downloadProgress = 0
        defer {
            downloadingKind = nil
        }
        do {
            _ = try? await AssetInventory.reserve(locale: locale)
            let module = kind.makeLiveModule(locale: locale)
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                let progress = request.progress
                let monitor = Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        self?.downloadProgress = progress.fractionCompleted
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                }
                defer { monitor.cancel() }
                try await request.downloadAndInstall()
            }
            downloadProgress = 1
            Log.recognition.info("Speech model installed for \(kind.rawValue, privacy: .public)")
        } catch {
            lastError = "モデルを取得できませんでした: \(error.localizedDescription)"
            Log.recognition.error("Model download failed: \(error.localizedDescription, privacy: .public)")
        }
        statuses[kind] = await Self.loadStatus(for: kind)
    }

    nonisolated private static func loadStatus(for kind: RecognizerKind) async -> SpeechModelStatus {
        var status = SpeechModelStatus()
        status.isAvailableOnDevice = kind.isAvailableOnDevice
        guard let locale = await kind.supportedLocale() else {
            status.installation = .unsupported
            return status
        }
        status.locale = locale
        let module = kind.makeLiveModule(locale: locale)
        status.installation = switch await AssetInventory.status(forModules: [module]) {
        case .unsupported: .unsupported
        case .supported: .downloadable
        case .downloading: .downloading
        case .installed: .installed
        @unknown default: .unknown
        }
        return status
    }
}
