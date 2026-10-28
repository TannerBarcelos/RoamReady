import Foundation
import SQLite3
import CSQLiteVec

public enum DocumentSearchError: Error, Equatable, Sendable {
    /// SQLite reported a failure; `code` is its primary result code.
    case sqlite(code: Int32, message: String)
    /// The system SQLite lacks FTS5, or sqlite-vec could not be registered.
    case unsupportedBuild(String)
    /// The file was written by a newer schema than this build understands.
    case newerSchema(Int)
    /// The file was written by an older layout. The index is disposable: delete it and index again.
    case outdatedSchema(Int)
    case closed
    case invalidInput(String)
}

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A thin, single-connection wrapper. Every statement is prepared with bound parameters;
/// no caller-supplied text is ever spliced into SQL.
final class SQLiteDatabase {
    private var handle: OpaquePointer?

    init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        handle = db
        guard rc == SQLITE_OK else {
            let error = Self.error(db, rc)
            sqlite3_close(db)
            handle = nil
            throw error
        }
        var message: UnsafeMutablePointer<CChar>?
        let vecRC = csqlitevec_register(db, &message)
        defer { sqlite3_free(message) }
        guard vecRC == SQLITE_OK else {
            sqlite3_close(db)
            handle = nil
            throw DocumentSearchError.unsupportedBuild("sqlite-vec: " + (message.map { String(cString: $0) } ?? "code \(vecRC)"))
        }
        sqlite3_busy_timeout(db, 2_000)
    }

    deinit { close() }

    func close() {
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
    }

    var isOpen: Bool { handle != nil }

    private static func error(_ db: OpaquePointer?, _ rc: Int32) -> DocumentSearchError {
        .sqlite(code: rc, message: db.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(rc)")
    }

    enum Value: Sendable {
        case null
        case int(Int64)
        case text(String)
        case blob(Data)
    }

    /// Runs a statement that returns no rows.
    func run(_ sql: String, _ values: [Value] = []) throws {
        _ = try query(sql, values) { _ in }
    }

    /// Runs a statement and maps each row.
    @discardableResult
    func query<T>(_ sql: String, _ values: [Value] = [], _ row: (Row) throws -> T) throws -> [T] {
        guard let handle else { throw DocumentSearchError.closed }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw Self.error(handle, sqlite3_errcode(handle))
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let rc: Int32
            switch value {
            case .null: rc = sqlite3_bind_null(statement, index)
            case .int(let number): rc = sqlite3_bind_int64(statement, index, number)
            case .text(let text):
                // Embedded NULs would silently truncate the value.
                let clean = text.contains("\0") ? text.replacingOccurrences(of: "\0", with: " ") : text
                rc = sqlite3_bind_text(statement, index, clean, -1, transient)
            case .blob(let data):
                rc = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) }
            }
            guard rc == SQLITE_OK else { throw Self.error(handle, rc) }
        }
        var rows: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: rows.append(try row(Row(statement: statement)))
            case SQLITE_DONE: return rows
            default: throw Self.error(handle, sqlite3_errcode(handle))
            }
        }
    }

    func scalarInt(_ sql: String, _ values: [Value] = []) throws -> Int64? {
        try query(sql, values) { $0.int(0) }.first
    }

    /// Runs `body` in a transaction that rolls back if it throws.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try run("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try run("COMMIT")
            return result
        } catch {
            try? run("ROLLBACK")
            throw error
        }
    }

    struct Row {
        fileprivate let statement: OpaquePointer?
        func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
        func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
        func text(_ column: Int32) -> String {
            sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
        }
        func optionalText(_ column: Int32) -> String? { isNull(column) ? nil : text(column) }
        func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
    }
}
