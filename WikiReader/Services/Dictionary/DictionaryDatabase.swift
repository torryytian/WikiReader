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

    /// Every lemma the dictionary records, by lower-cased word: the "0:" item of `exchange` ("studies" → "study"),
    /// from the first row with one in binary order of `word` (docs/shared-vocab-format.md §4). About 58,000 rows,
    /// read in one go so marking a whole article's words doesn't ask the file once per word.
    func lemmaTable() -> [String: String] {
        guard let url else { return [:] }
        var connection: OpaquePointer?
        guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(connection)
            return [:]
        }
        defer { sqlite3_close(connection) }
        var statement: OpaquePointer?
        let sql = "SELECT lower, exchange FROM entries WHERE exchange LIKE '%0:%' ORDER BY lower, word"
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(statement) }
        var table: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let lower = sqlite3_column_text(statement, 0).map({ String(cString: $0) }), table[lower] == nil,
                  let exchange = sqlite3_column_text(statement, 1).map({ String(cString: $0) }),
                  let lemma = Self.lemma(inExchange: exchange)
            else { continue }
            table[lower] = lemma
        }
        return table
    }

    /// The base form the dictionary gives for one key (§4 of docs/shared-vocab-format.md), the same as
    /// `lemmaTable()[key]` without reading the whole table.
    func lemma(of key: String) -> String? {
        let rows = query(
            "SELECT word, phonetic, definition, translation, collins, oxford, tag, exchange FROM entries WHERE lower = ?1 ORDER BY word",
            bind: key
        )
        return rows.lazy.compactMap { Self.lemma(inExchange: $0.exchange) }.first
    }

    /// The "0:" item of an `exchange` value ("0:study/1:s3" → "study"), if it has one.
    static func lemma(inExchange exchange: String) -> String? {
        for item in exchange.split(separator: "/") where item.hasPrefix("0:") && item.count > 2 {
            return String(item.dropFirst(2))
        }
        return nil
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
