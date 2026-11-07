import Foundation

// What English Reader's word-book API sends and receives (docs/vocab-sync-v1.md). The words themselves are the shared
// format's entries (docs/shared-vocab-format.md), unchanged.

/// The site account a device key belongs to.
nonisolated struct SiteUser: Codable, Equatable, Sendable {
    var email: String
    var name: String?
}

/// The answer to trading a sign-in's one-time code for a device key (§2.3).
nonisolated struct SiteDeviceGrant: Decodable, Equatable, Sendable {
    struct Device: Decodable, Equatable, Sendable {
        var id: String
    }

    var deviceToken: String
    var device: Device?
    var user: SiteUser

    enum CodingKeys: String, CodingKey {
        case deviceToken = "device_token"
        case device, user
    }
}

// MARK: - Everyday changes (§4)

/// A change made on this iPhone, on its way to the site.
nonisolated enum VocabChange: Codable, Equatable, Sendable {
    case upsert(VocabEntry)
    case delete(key: String, deletedAt: Int64)

    var key: String {
        switch self {
        case .upsert(let entry): entry.key
        case .delete(let key, _): key
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, entry, key, deletedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if try container.decode(String.self, forKey: .type) == "delete" {
            self = .delete(
                key: try container.decode(String.self, forKey: .key),
                deletedAt: try container.decode(Int64.self, forKey: .deletedAt)
            )
        } else {
            self = .upsert(try container.decode(VocabEntry.self, forKey: .entry))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .upsert(let entry):
            try container.encode("upsert", forKey: .type)
            try container.encode(entry, forKey: .entry)
        case .delete(let key, let deletedAt):
            try container.encode("delete", forKey: .type)
            try container.encode(key, forKey: .key)
            try container.encode(deletedAt, forKey: .deletedAt)
        }
    }
}

/// One push. Sent again unchanged while it isn't known whether it arrived: the site recognizes `requestId`.
nonisolated struct VocabPushBatch: Codable, Equatable, Sendable {
    var requestId: String
    var changes: [VocabChange]
}

/// What the site did with one change.
nonisolated enum VocabPushStatus: Decodable, Equatable, Sendable {
    case created, merged, unchanged, deleted
    /// A delete, but the word was changed later on another device: it stays.
    case keptNewer
    /// A save, but the word was deleted later on another device: it goes.
    case deletedElsewhere
    case invalidEntry
    /// A time too far in the future: this iPhone's clock is probably wrong.
    case clockSkew
    case other(String)

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "created": self = .created
        case "merged": self = .merged
        case "unchanged": self = .unchanged
        case "deleted": self = .deleted
        case "kept_newer": self = .keptNewer
        case "deleted_elsewhere": self = .deletedElsewhere
        case "invalid_entry": self = .invalidEntry
        case "clock_skew": self = .clockSkew
        default: self = .other(value)
        }
    }
}

nonisolated struct VocabPushResult: Decodable, Equatable, Sendable {
    var key: String
    var status: VocabPushStatus
    var entry: VocabEntry?
    var deletedAt: Int64?
    var message: String?
}

nonisolated struct VocabPushResponse: Decodable, Equatable, Sendable {
    var results: [VocabPushResult]
}

nonisolated struct VocabDeletion: Decodable, Equatable, Sendable {
    var key: String
    var deletedAt: Int64
}

/// What changed on the site after a cursor, one page of it.
nonisolated struct VocabChangesPage: Decodable, Equatable, Sendable {
    var entries: [VocabEntry]
    var deleted: [VocabDeletion]
    /// Opaque: kept and sent back as it is.
    var cursor: String
    var more: Bool

    private enum CodingKeys: String, CodingKey {
        case entries, deleted, cursor, more
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entries = try container.decodeIfPresent([VocabEntry].self, forKey: .entries) ?? []
        deleted = try container.decodeIfPresent([VocabDeletion].self, forKey: .deleted) ?? []
        cursor = try container.decode(String.self, forKey: .cursor)
        more = try container.decodeIfPresent(Bool.self, forKey: .more) ?? false
    }
}

// MARK: - Full sync (§5)

/// The five ways of settling a full sync.
nonisolated enum VocabSyncOption: String, CaseIterable, Hashable, Sendable {
    case merge
    case serverToDeviceAdd = "serverToDevice.add"
    case serverToDeviceOverwrite = "serverToDevice.overwrite"
    case deviceToServerAdd = "deviceToServer.add"
    case deviceToServerOverwrite = "deviceToServer.overwrite"
}

/// The site's comparison of the two books. Every number comes from the site, so all clients show the same ones.
nonisolated struct VocabSyncPreview: Decodable, Equatable, Sendable {
    struct Counts: Decodable, Equatable, Sendable {
        var device: Int
        var server: Int
        var same: Int
        var differ: Int
        var deviceNewer: Int
        var serverNewer: Int
        var deviceOnly: Int
        var deviceOnlyDeletedOnServer: Int
        var serverOnly: Int
        var serverOnlyDeletedOnDevice: Int

        /// Whether the two books already say the same.
        var match: Bool {
            differ == 0 && deviceOnly == 0 && deviceOnlyDeletedOnServer == 0 && serverOnly == 0 && serverOnlyDeletedOnDevice == 0
        }
    }

    struct Word: Decodable, Equatable, Sendable, Identifiable {
        var key: String
        var term: String
        var id: String { key }
    }

    /// At most 200 of each kind: `Counts` has how many there really are.
    struct Words: Decodable, Equatable, Sendable {
        var differ: [Word]
        var deviceOnly: [Word]
        var deviceOnlyDeletedOnServer: [Word]
        var serverOnly: [Word]
        var serverOnlyDeletedOnDevice: [Word]

        private enum CodingKeys: String, CodingKey {
            case differ, deviceOnly, deviceOnlyDeletedOnServer, serverOnly, serverOnlyDeletedOnDevice
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            differ = try container.decodeIfPresent([Word].self, forKey: .differ) ?? []
            deviceOnly = try container.decodeIfPresent([Word].self, forKey: .deviceOnly) ?? []
            deviceOnlyDeletedOnServer = try container.decodeIfPresent([Word].self, forKey: .deviceOnlyDeletedOnServer) ?? []
            serverOnly = try container.decodeIfPresent([Word].self, forKey: .serverOnly) ?? []
            serverOnlyDeletedOnDevice = try container.decodeIfPresent([Word].self, forKey: .serverOnlyDeletedOnDevice) ?? []
        }
    }

    /// What one way of settling does to one side.
    struct Side: Decodable, Equatable, Sendable {
        var after: Int
        var add: Int
        var remove: Int
        var update: Int

        var changesNothing: Bool { add == 0 && remove == 0 && update == 0 }
    }

    struct Choice: Decodable, Equatable, Sendable {
        var device: Side
        var server: Side
    }

    /// A word the site left out of the comparison because something about it is wrong: no choice touches it, on
    /// either side.
    struct Rejected: Decodable, Equatable, Sendable {
        var key: String
        var status: VocabPushStatus
        var message: String?
    }

    var previewId: String
    var counts: Counts
    var words: Words
    var options: [String: Choice]
    var rejected: [Rejected]?

    func choice(_ option: VocabSyncOption) -> Choice? {
        options[option.rawValue]
    }

    /// The words a choice removes from this device, as far as the site listed them.
    func wordsRemovedHere(by option: VocabSyncOption) -> [Word] {
        switch option {
        case .merge: words.deviceOnlyDeletedOnServer
        case .serverToDeviceOverwrite: words.deviceOnly + words.deviceOnlyDeletedOnServer
        case .serverToDeviceAdd, .deviceToServerAdd, .deviceToServerOverwrite: []
        }
    }

    /// The words a choice deletes from the site, as far as the site listed them.
    func wordsRemovedOnSite(by option: VocabSyncOption) -> [Word] {
        switch option {
        case .merge: words.serverOnlyDeletedOnDevice
        case .deviceToServerOverwrite: words.serverOnly + words.serverOnlyDeletedOnDevice
        case .serverToDeviceAdd, .serverToDeviceOverwrite, .deviceToServerAdd: []
        }
    }
}

/// How many words the user agreed to lose: the site refuses anything but the numbers it showed.
nonisolated struct VocabSyncConfirmation: Encodable, Equatable, Sendable {
    var deviceRemove: Int
    var serverRemove: Int
}

nonisolated struct VocabSyncApplied: Decodable, Equatable, Sendable {
    struct Size: Decodable, Equatable, Sendable {
        var after: Int
    }

    struct Sizes: Decodable, Equatable, Sendable {
        var device: Size
        var server: Size
    }

    var result: Sizes
    /// What this device's book becomes, all of it. None when this device doesn't change.
    var book: VocabFile?
    var cursor: String
    /// When the site changed and can be put back.
    var undoId: String?
    var undoUntil: Int64?
}

nonisolated struct VocabSyncUndone: Decodable, Equatable, Sendable {
    struct Skipped: Decodable, Equatable, Sendable {
        var key: String
    }

    var skipped: [Skipped]?
    /// Past the changes the undoing itself made.
    var cursor: String
}
