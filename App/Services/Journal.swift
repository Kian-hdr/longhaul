import Foundation

struct HistoryEntry: Identifiable, Codable, Sendable {
    var id: Int64
    var date: Date
    var category: String
    var message: String
}

actor Journal {
    private var database: OpaquePointer?
    private let url: URL
    init(url: URL) { self.url = url }
    private func open() throws {
        if database != nil { return }
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw JournalError.failed }
        try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; CREATE TABLE IF NOT EXISTS events (id INTEGER PRIMARY KEY, time REAL NOT NULL, category TEXT NOT NULL, message TEXT NOT NULL);")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw JournalError.failed }
    }
    func append(category: String, message: String) throws {
        try open()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "INSERT INTO events(time, category, message) VALUES(?,?,?)", -1, &statement, nil) == SQLITE_OK else { throw JournalError.failed }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 2, category, -1, transient)
        sqlite3_bind_text(statement, 3, String(message.prefix(1000)), -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw JournalError.failed }
        try execute("DELETE FROM events WHERE id NOT IN (SELECT id FROM events ORDER BY id DESC LIMIT 3000)")
    }
    func recent() throws -> [HistoryEntry] {
        try open()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT id,time,category,message FROM events ORDER BY id DESC LIMIT 300", -1, &statement, nil) == SQLITE_OK else { throw JournalError.failed }
        defer { sqlite3_finalize(statement) }
        var rows: [HistoryEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let category = sqlite3_column_text(statement, 2), let message = sqlite3_column_text(statement, 3) else { continue }
            rows.append(HistoryEntry(id: sqlite3_column_int64(statement, 0), date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)), category: String(cString: category), message: String(cString: message)))
        }
        return rows
    }
    enum JournalError: Error { case failed }
}
