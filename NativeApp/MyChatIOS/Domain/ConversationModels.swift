import Foundation

enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case integer(Int64)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value):
            try container.encode(value)
        case let .integer(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .bool(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

struct ConversationRecord: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let updatedAt: String
    let projectID: String?
    let starred: Bool
    let pinned: Bool
    let memoryEnabled: Bool

    init(
        id: String,
        title: String,
        updatedAt: String,
        projectID: String?,
        starred: Bool,
        pinned: Bool,
        memoryEnabled: Bool = true
    ) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
        self.projectID = projectID
        self.starred = starred
        self.pinned = pinned
        self.memoryEnabled = memoryEnabled
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case updatedAt = "updated_at"
        case projectID = "project_id"
        case starred
        case pinned
        case memoryEnabled = "memory_enabled"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        updatedAt = try values.decode(String.self, forKey: .updatedAt)
        projectID = try values.decodeIfPresent(String.self, forKey: .projectID)
        starred = try values.decode(Bool.self, forKey: .starred)
        pinned = try values.decode(Bool.self, forKey: .pinned)
        // Cached conversation lists from older builds have no per-chat setting.
        memoryEnabled = try values.decodeIfPresent(Bool.self, forKey: .memoryEnabled) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(title, forKey: .title)
        try values.encode(updatedAt, forKey: .updatedAt)
        try values.encodeIfPresent(projectID, forKey: .projectID)
        try values.encode(starred, forKey: .starred)
        try values.encode(pinned, forKey: .pinned)
        try values.encode(memoryEnabled, forKey: .memoryEnabled)
    }
}

struct ConversationHistoryPage: Sendable {
    let records: [ConversationRecord]
    let nextOffset: Int
    let hasMore: Bool
}

enum ConversationMessageRole: String, Codable, Equatable, Sendable {
    case user
    case assistant
}

struct ConversationMessageRecord: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let role: ConversationMessageRole
    let content: String?
    let images: JSONValue?
    let thinking: String?
    let createdAt: String?
    let sequence: Int64
    var filePreviews: [ChatFilePreview]? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case role
        case content
        case images
        case thinking
        case createdAt = "created_at"
        case sequence = "seq"
        case filePreviews = "file_previews"
    }
}

struct ConversationToolHistory: Equatable, Sendable {
    var processEntries: [UUID: [ChatProcessEntry]] = [:]
    var searches: [UUID: [ChatToolSearch]] = [:]
    var memoryChanges: [UUID: [ChatMemoryEvent]] = [:]
    var toolActivities: [UUID: [ChatToolActivity]] = [:]
    var connectorApps: [UUID: [ChatConnectorAppEvent]] = [:]
}

extension JSONValue {
    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var objectValue: [String: JSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }
}

extension ConversationMessageRecord {
    var sourceImages: [String] {
        guard
            let object = images?.objectValue,
            let values = object["refs"]?.arrayValue
        else { return [] }
        return values.compactMap(\.stringValue).prefix(8).map { $0 }
    }

    var generatedMedia: [ChatGeneratedMedia] {
        guard
            let object = images?.objectValue,
            let values = object["generated_media"]?.arrayValue
        else { return [] }

        var seen = Set<String>()
        var media: [ChatGeneratedMedia] = []
        for value in values {
            guard
                let item = value.objectValue,
                let rawType = item["type"]?.stringValue,
                let type = ChatGeneratedMedia.MediaType(rawValue: rawType),
                let url = item["url"]?.stringValue,
                !url.isEmpty
            else { continue }
            let identity = "\(type.rawValue):\(url)"
            guard seen.insert(identity).inserted else { continue }
            media.append(ChatGeneratedMedia(
                type: type,
                url: url,
                mimeType: item["mimeType"]?.stringValue,
                alt: item["alt"]?.stringValue
            ))
            if media.count == 8 { break }
        }
        return media
    }
}
