import Foundation
import SQLite3

public struct DatabaseError: Error, LocalizedError, Equatable {
    public var code: Int32
    public var message: String

    public init(code: Int32, message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? {
        "SQLite エラー (\(code)): \(message)"
    }
}

/// SQLite に保存する値。
public enum SQLValue: Sendable, Equatable {
    case text(String)
    case integer(Int64)
    case null
}

extension SQLValue {
    public static func optionalText(_ value: String?) -> SQLValue {
        value.map(SQLValue.text) ?? .null
    }
}

/// SQLite 接続の薄いラッパー。スレッド安全ではないので、1つの actor の中だけで使う。
public final class Database {
    private var handle: OpaquePointer?

    /// - Parameters:
    ///   - url: DB ファイル。`nil` ならメモリ上の DB。
    ///   - readOnly: 読み取り専用で開く。ファイルを変更しない前提（`immutable=1`）で開くため、
    ///     WAL モードのファイルでも `-wal` / `-shm` を作らずに読める。
    public init(url: URL?, readOnly: Bool = false) throws {
        let path: String
        let flags: Int32
        if let url, readOnly {
            path = url.absoluteString + "?immutable=1"
            flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX
        } else {
            path = url?.path(percentEncoded: false) ?? ":memory:"
            flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        }
        var connection: OpaquePointer?
        let result = sqlite3_open_v2(path, &connection, flags, nil)
        guard result == SQLITE_OK, let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "データベースを開けません"
            sqlite3_close_v2(connection)
            throw DatabaseError(code: result, message: message)
        }
        handle = connection
        sqlite3_busy_timeout(connection, 5_000)
        sqlite3_extended_result_codes(connection, 1)
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    var connection: OpaquePointer {
        guard let handle else { preconditionFailure("Database is closed") }
        return handle
    }

    public func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(connection, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? lastErrorMessage
            sqlite3_free(errorMessage)
            throw DatabaseError(code: result, message: message)
        }
    }

    public func execute(_ sql: String, _ values: [SQLValue]) throws {
        let statement = try prepare(sql)
        try statement.bind(values)
        while try statement.step() {}
    }

    public func prepare(_ sql: String) throws -> Statement {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(connection, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw DatabaseError(code: result, message: lastErrorMessage)
        }
        return Statement(handle: statement, database: self)
    }

    /// 1行1列目の整数を返す。
    public func scalarInteger(_ sql: String, _ values: [SQLValue] = []) throws -> Int64? {
        let statement = try prepare(sql)
        try statement.bind(values)
        guard try statement.step() else { return nil }
        return statement.optionalInteger(0)
    }

    public func scalarText(_ sql: String, _ values: [SQLValue] = []) throws -> String? {
        let statement = try prepare(sql)
        try statement.bind(values)
        guard try statement.step() else { return nil }
        return statement.optionalText(0)
    }

    /// `BEGIN IMMEDIATE` で書き込みトランザクションを開始し、失敗したらロールバックする。
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public var userVersion: Int {
        get throws { Int(try scalarInteger("PRAGMA user_version") ?? 0) }
    }

    public func setUserVersion(_ version: Int) throws {
        try execute("PRAGMA user_version = \(version)")
    }

    public var changes: Int {
        Int(sqlite3_changes(connection))
    }

    /// オンラインバックアップ API で、この DB の内容を `destination` へ書き出す。
    /// バックアップは単独のファイルで完結するよう、ジャーナルを WAL から DELETE に戻す。
    public func backup(to destination: URL) throws {
        let target = try Database(url: destination)
        try Database.copy(from: self, to: target)
        try target.execute("PRAGMA journal_mode = DELETE")
    }

    /// `source` の内容でこの DB を置き換える。
    public func restore(from source: URL) throws {
        let origin = try Database(url: source, readOnly: true)
        try Database.copy(from: origin, to: self)
    }

    private static func copy(from source: Database, to destination: Database) throws {
        guard let backup = sqlite3_backup_init(destination.connection, "main", source.connection, "main") else {
            throw DatabaseError(code: sqlite3_errcode(destination.connection), message: destination.lastErrorMessage)
        }
        let stepResult = sqlite3_backup_step(backup, -1)
        let finishResult = sqlite3_backup_finish(backup)
        guard stepResult == SQLITE_DONE, finishResult == SQLITE_OK else {
            throw DatabaseError(code: stepResult == SQLITE_DONE ? finishResult : stepResult, message: destination.lastErrorMessage)
        }
    }

    var lastErrorMessage: String {
        String(cString: sqlite3_errmsg(connection))
    }
}

/// プリペアドステートメント。
public final class Statement {
    private let handle: OpaquePointer
    private let database: Database

    fileprivate init(handle: OpaquePointer, database: Database) {
        self.handle = handle
        self.database = database
    }

    deinit {
        sqlite3_finalize(handle)
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public func bind(_ values: [SQLValue]) throws {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32 = switch value {
            case .text(let text): sqlite3_bind_text(handle, index, text, -1, Statement.transient)
            case .integer(let number): sqlite3_bind_int64(handle, index, number)
            case .null: sqlite3_bind_null(handle, index)
            }
            guard result == SQLITE_OK else {
                throw DatabaseError(code: result, message: database.lastErrorMessage)
            }
        }
    }

    /// 1行進める。行があれば `true`、終わりなら `false`。
    public func step() throws -> Bool {
        let result = sqlite3_step(handle)
        switch result {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw DatabaseError(code: result, message: database.lastErrorMessage)
        }
    }

    public func text(_ column: Int32) -> String {
        optionalText(column) ?? ""
    }

    public func optionalText(_ column: Int32) -> String? {
        guard sqlite3_column_type(handle, column) != SQLITE_NULL, let pointer = sqlite3_column_text(handle, column) else {
            return nil
        }
        return String(cString: pointer)
    }

    public func integer(_ column: Int32) -> Int64 {
        sqlite3_column_int64(handle, column)
    }

    public func optionalInteger(_ column: Int32) -> Int64? {
        sqlite3_column_type(handle, column) == SQLITE_NULL ? nil : sqlite3_column_int64(handle, column)
    }
}
