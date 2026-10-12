import Foundation
import SQLite3

/// Read-only access to the bundled dictionary (`ecdict.sqlite`, built by `tools/make_dictionary.py`).
///
/// Each call opens the file, asks, and closes it: opening a read-only SQLite file takes well under a
/// millisecond, and it means there is no shared connection to guard, so lookups can come from anywhere.
nonisolated struct DictionaryDatabase: Sendable {
    let url: URL?

    /// The database inside the app bundle.
    static let bundled = DictionaryDatabase(url: Bundle.main.url(forResource: "ecdict", withExtension: "sqlite"))

    /// All entries for a term, the exact spelling first ("March" before "march" when asked for "March").
    func entries(for term: String) -> [DictionaryEntry] {
        let wanted = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return [] }
        let entries = query(
            "SELECT word, phonetic, definition, translation, collins, oxford, tag, exchange FROM entries WHERE lower = ?1",
            bind: wanted.lowercased()
        )
        return entries.sorted { lhs, rhs in
            (lhs.word == wanted) && (rhs.word != wanted)
        }
    }

    /// The entry to show for a term: the exact spelling if there is one, else the first entry with that spelling in any case.
    func entry(for term: String) -> DictionaryEntry? {
        entries(for: term).first
    }

    func contains(_ term: String) -> Bool {
        entry(for: term) != nil
    }

    private func query(_ sql: String, bind text: String) -> [DictionaryEntry] {
        guard let url else { return [] }
        var connection: OpaquePointer?
        guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(connection)
            return []
        }
        defer { sqlite3_close(connection) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        // SQLITE_TRANSIENT: SQLite copies the string, because Swift's temporary buffer goes away after this call.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, text, -1, transient)

        func string(_ column: Int32) -> String {
            sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
        }
        var result: [DictionaryEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(DictionaryEntry(
                word: string(0), phonetic: string(1), englishDefinition: string(2), chineseTranslation: string(3),
                collins: Int(sqlite3_column_int(statement, 4)), isOxford3000: sqlite3_column_int(statement, 5) == 1,
                tags: string(6), exchange: string(7)
            ))
        }
        return result
    }
}
