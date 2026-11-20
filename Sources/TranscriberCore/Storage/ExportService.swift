import Foundation

public enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case markdown
    case json

    public var id: String { rawValue }

    public var fileExtension: String {
        switch self {
        case .markdown: "md"
        case .json: "json"
        }
    }

    public var displayName: String {
        switch self {
        case .markdown: "Markdown"
        case .json: "JSON"
        }
    }
}

/// 会議の文字起こしを Markdown / JSON に書き出す。
public struct ExportService: Sendable {
    public var timeZone: TimeZone

    public init(timeZone: TimeZone = .current) {
        self.timeZone = timeZone
    }

    public func data(for meeting: Meeting, segments: [TranscriptSegment], format: ExportFormat) throws -> Data {
        switch format {
        case .markdown: Data(markdown(for: meeting, segments: segments).utf8)
        case .json: try json(for: meeting, segments: segments)
        }
    }

    /// 書き出しファイルの既定の名前（例: `2026-11-20 定例.md`）。ファイル名に使えない文字は置き換える。
    public func suggestedFileName(for meeting: Meeting, format: ExportFormat) -> String {
        let day = meeting.startedAt.formatted(Date.ISO8601FormatStyle(timeZone: timeZone).year().month().day())
        let forbidden = CharacterSet(charactersIn: "/:\\\0")
        let title = String(meeting.title.unicodeScalars.map { forbidden.contains($0) ? "-" : Character($0) })
        return "\(day) \(title).\(format.fileExtension)"
    }

    // MARK: - Markdown

    public func markdown(for meeting: Meeting, segments: [TranscriptSegment]) -> String {
        var lines: [String] = []
        lines.append("# \(singleLine(meeting.title))")
        lines.append("")
        lines.append("- 日時: \(localDateTime(meeting.startedAt))")
        lines.append("- 対象アプリ: \(singleLine(meeting.sourceApp))")
        if let duration = meeting.duration {
            lines.append("- 所要時間: \(ElapsedTimeFormat.string(duration: duration))")
        }
        lines.append("- 状態: \(meeting.status.displayName)")
        lines.append("")
        lines.append("## 文字起こし")
        lines.append("")
        let ordered = segments.sorted(by: TranscriptSegment.timelineOrder)
        if ordered.isEmpty {
            lines.append("（発言なし）")
        }
        for segment in ordered {
            let time = ElapsedTimeFormat.string(milliseconds: segment.startMS)
            lines.append("- **[\(time)] \(segment.source.displayName)**: \(singleLine(segment.text))")
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func localDateTime(_ date: Date) -> String {
        var style = Date.ISO8601FormatStyle(timeZone: timeZone).year().month().day().time(includingFractionalSeconds: false)
        style = style.dateTimeSeparator(.space).timeZone(separator: .colon)
        return date.formatted(style)
    }

    private func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    // MARK: - JSON

    public struct Document: Codable, Equatable, Sendable {
        public static let currentFormatVersion = 1

        public struct MeetingInfo: Codable, Equatable, Sendable {
            public var id: UUID
            public var title: String
            public var sourceApp: String
            public var startedAt: Date
            public var endedAt: Date?
            public var status: MeetingStatus
        }

        public struct Segment: Codable, Equatable, Sendable {
            public var id: UUID
            public var source: AudioSource
            public var speaker: String
            public var startMS: Int64
            public var endMS: Int64
            public var text: String
            public var originalText: String
            public var edited: Bool
            public var engine: String
        }

        public var formatVersion: Int
        public var meeting: MeetingInfo
        public var segments: [Segment]
    }

    public func document(for meeting: Meeting, segments: [TranscriptSegment]) -> Document {
        Document(
            formatVersion: Document.currentFormatVersion,
            meeting: .init(
                id: meeting.id,
                title: meeting.title,
                sourceApp: meeting.sourceApp,
                startedAt: meeting.startedAt,
                endedAt: meeting.endedAt,
                status: meeting.status
            ),
            segments: segments.sorted(by: TranscriptSegment.timelineOrder).map { segment in
                .init(
                    id: segment.id,
                    source: segment.source,
                    speaker: segment.source.displayName,
                    startMS: segment.startMS,
                    endMS: segment.endMS,
                    text: segment.text,
                    originalText: segment.originalText,
                    edited: segment.isEdited,
                    engine: segment.engine
                )
            }
        )
    }

    public func json(for meeting: Meeting, segments: [TranscriptSegment]) throws -> Data {
        try Self.encoder.encode(document(for: meeting, segments: segments))
    }

    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
