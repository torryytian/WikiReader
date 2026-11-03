import Foundation

/// Any JSON value, kept as it was read, so fields this version of the app doesn't know (or the Chrome extension's
/// own data) survive being read and written back.
nonisolated enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

/// A coding key for any field name, for reading the fields a type doesn't declare.
nonisolated struct AnyCodingKey: CodingKey, Hashable {
    var stringValue: String
    var intValue: Int? { nil }

    init(_ string: String) {
        stringValue = string
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        nil
    }
}

extension KeyedDecodingContainer where Key == AnyCodingKey {
    /// The fields not in `known`, nulls left out (a null is the same as no field).
    nonisolated func otherFields(excluding known: Set<String>) throws -> [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        for key in allKeys where !known.contains(key.stringValue) {
            let value = try decode(JSONValue.self, forKey: key)
            if value != .null { fields[key.stringValue] = value }
        }
        return fields
    }
}

extension KeyedEncodingContainer where Key == AnyCodingKey {
    nonisolated mutating func encode(otherFields fields: [String: JSONValue]) throws {
        for (name, value) in fields {
            try encode(value, forKey: AnyCodingKey(name))
        }
    }
}
