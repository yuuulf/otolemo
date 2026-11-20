/// スキーマとマイグレーション。`PRAGMA user_version` に適用済みのバージョンを記録する。
enum Schema {
    /// 添字 + 1 がそのマイグレーション適用後のバージョン。追加はできるが、既存の要素は変更しない。
    static let migrations: [String] = [
        // v1: 初期スキーマ
        """
        CREATE TABLE meetings (
          id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          source_app TEXT NOT NULL,
          started_at_utc TEXT NOT NULL,
          ended_at_utc TEXT,
          status TEXT NOT NULL CHECK (status IN ('recording','completed','interrupted'))
        );

        CREATE TABLE segments (
          id TEXT PRIMARY KEY,
          meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
          source TEXT NOT NULL CHECK (source IN ('microphone','system')),
          start_ms INTEGER NOT NULL CHECK (start_ms >= 0),
          end_ms INTEGER NOT NULL CHECK (end_ms >= start_ms),
          original_text TEXT NOT NULL,
          edited_text TEXT,
          engine TEXT NOT NULL,
          created_at_utc TEXT NOT NULL
        );

        CREATE INDEX idx_segments_meeting_time
          ON segments(meeting_id, start_ms, id);

        CREATE INDEX idx_meetings_started
          ON meetings(started_at_utc);
        """
    ]

    static var currentVersion: Int { migrations.count }

    struct NewerSchemaError: Error, CustomStringConvertible {
        var found: Int
        var supported: Int

        var description: String {
            "このデータベースは新しいバージョンのアプリで作られています（スキーマ v\(found)、対応は v\(supported) まで）。"
        }
    }

    static func migrate(_ database: Database) throws {
        let version = try database.userVersion
        guard version <= currentVersion else {
            throw NewerSchemaError(found: version, supported: currentVersion)
        }
        for index in version..<currentVersion {
            try database.transaction {
                try database.execute(migrations[index])
                try database.setUserVersion(index + 1)
            }
        }
    }
}
