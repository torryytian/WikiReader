import Foundation

/// Why a backup file couldn't be written or read.
nonisolated enum BackupError: Error, Equatable {
    /// Not a WikiReader backup (wrong header, or cut short).
    case notABackup
    /// Written by a newer version of the app.
    case unsupportedVersion(Int)
    /// A part the index promises isn't there.
    case missingEntry(String)
    case io(String)

    var message: String {
        switch self {
        case .notABackup: "This file is not a WikiReader backup, or it is damaged."
        case .unsupportedVersion: "This backup was made by a newer version of WikiReader. Update the app and try again."
        case .missingEntry(let path): "The backup is incomplete (\(path) is missing)."
        case .io(let reason): "The file could not be read or written: \(reason)"
        }
    }
}

/// One file holding many named files, so a backup is a single thing to AirDrop or put in the Files app.
///
/// Layout: 8 bytes of magic, every entry's bytes one after another, then a JSON index of
/// `(path, offset, length)`, then the index's length as 8 bytes (little endian). The index goes last so the
/// writer can stream large audio files straight to disk without knowing the total size up front.
nonisolated enum ArchiveFormat {
    static let magic = Data("WIKIRDR1".utf8)
    static let trailerSize = 8

    struct Entry: Codable, Equatable, Sendable {
        var path: String
        var offset: UInt64
        var length: UInt64
    }
}

nonisolated final class ArchiveWriter {
    private let handle: FileHandle
    private var entries: [ArchiveFormat.Entry] = []
    private var offset = UInt64(ArchiveFormat.magic.count)
    private var isFinished = false

    init(url: URL) throws(BackupError) {
        do {
            try? FileManager.default.removeItem(at: url)
            guard FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil) else {
                throw BackupError.io("cannot create the file")
            }
            handle = try FileHandle(forWritingTo: url)
            try handle.write(contentsOf: ArchiveFormat.magic)
        } catch let error as BackupError {
            throw error
        } catch {
            throw .io(error.localizedDescription)
        }
    }

    func add(_ data: Data, path: String) throws(BackupError) {
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw .io(error.localizedDescription)
        }
        record(path: path, length: UInt64(data.count))
    }

    /// Copies a file in pieces, so a long audio file is never held in memory whole.
    func addFile(at url: URL, path: String) throws(BackupError) {
        var length: UInt64 = 0
        do {
            let source = try FileHandle(forReadingFrom: url)
            defer { try? source.close() }
            while let piece = try source.read(upToCount: 1 << 20), !piece.isEmpty {
                try handle.write(contentsOf: piece)
                length += UInt64(piece.count)
            }
        } catch {
            throw .io(error.localizedDescription)
        }
        record(path: path, length: length)
    }

    private func record(path: String, length: UInt64) {
        entries.append(ArchiveFormat.Entry(path: path, offset: offset, length: length))
        offset += length
    }

    /// Writes the index and closes the file. Nothing is readable before this.
    func finish() throws(BackupError) {
        guard !isFinished else { return }
        isFinished = true
        do {
            let index = try JSONEncoder().encode(entries)
            try handle.write(contentsOf: index)
            var size = UInt64(index.count).littleEndian
            try handle.write(contentsOf: Data(bytes: &size, count: ArchiveFormat.trailerSize))
            try handle.close()
        } catch {
            throw .io(error.localizedDescription)
        }
    }
}

nonisolated final class ArchiveReader {
    private let handle: FileHandle
    private let entries: [String: ArchiveFormat.Entry]

    var paths: [String] { entries.keys.sorted() }

    init(url: URL) throws(BackupError) {
        do {
            handle = try FileHandle(forReadingFrom: url)
            let fileSize = try handle.seekToEnd()
            let magicSize = UInt64(ArchiveFormat.magic.count)
            guard fileSize >= magicSize + UInt64(ArchiveFormat.trailerSize) else { throw BackupError.notABackup }

            try handle.seek(toOffset: 0)
            guard try handle.read(upToCount: ArchiveFormat.magic.count) == ArchiveFormat.magic else {
                throw BackupError.notABackup
            }

            try handle.seek(toOffset: fileSize - UInt64(ArchiveFormat.trailerSize))
            guard let trailer = try handle.read(upToCount: ArchiveFormat.trailerSize), trailer.count == ArchiveFormat.trailerSize else {
                throw BackupError.notABackup
            }
            let indexLength = trailer.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
            guard indexLength <= fileSize - magicSize - UInt64(ArchiveFormat.trailerSize) else { throw BackupError.notABackup }

            let indexStart = fileSize - UInt64(ArchiveFormat.trailerSize) - indexLength
            try handle.seek(toOffset: indexStart)
            guard let indexData = try handle.read(upToCount: Int(indexLength)), indexData.count == Int(indexLength),
                  let list = try? JSONDecoder().decode([ArchiveFormat.Entry].self, from: indexData)
            else { throw BackupError.notABackup }

            // Every entry must lie inside the payload area, before the index.
            guard list.allSatisfy({ $0.offset >= magicSize && $0.offset + $0.length <= indexStart }) else {
                throw BackupError.notABackup
            }
            entries = Dictionary(list.map { ($0.path, $0) }, uniquingKeysWith: { _, last in last })
        } catch let error as BackupError {
            throw error
        } catch {
            throw .io(error.localizedDescription)
        }
    }

    deinit {
        try? handle.close()
    }

    func contains(_ path: String) -> Bool {
        entries[path] != nil
    }

    func data(at path: String) throws(BackupError) -> Data {
        guard let entry = entries[path] else { throw .missingEntry(path) }
        do {
            try handle.seek(toOffset: entry.offset)
            return try handle.read(upToCount: Int(entry.length)) ?? Data()
        } catch {
            throw .io(error.localizedDescription)
        }
    }

    /// Writes an entry to `destination` in pieces, through a temporary file, so an interrupted copy never leaves
    /// a half-written file that looks complete.
    func copy(_ path: String, to destination: URL) throws(BackupError) {
        guard let entry = entries[path] else { throw .missingEntry(path) }
        let temporary = destination.deletingLastPathComponent().appending(path: ".import-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: temporary.path(percentEncoded: false), contents: nil) else {
                throw BackupError.io("cannot create the file")
            }
            let output = try FileHandle(forWritingTo: temporary)
            defer { try? output.close() }
            try handle.seek(toOffset: entry.offset)
            var remaining = entry.length
            while remaining > 0 {
                guard let piece = try handle.read(upToCount: Int(min(remaining, 1 << 20))), !piece.isEmpty else {
                    throw BackupError.notABackup
                }
                try output.write(contentsOf: piece)
                remaining -= UInt64(piece.count)
            }
            try output.close()
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch let error as BackupError {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw .io(error.localizedDescription)
        }
    }
}
