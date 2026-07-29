import Foundation

struct MobileBootstrap: Decodable {
    let supabaseUrl: URL
    let supabaseAnonKey: String
}

struct AuthSession: Codable, Equatable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: TimeInterval?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
    }
}

struct Conversation: Codable, Identifiable, Hashable {
    let id: UUID
    var title: String
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, title
        case updatedAt = "updated_at"
    }
}

struct ChatMessage: Codable, Identifiable, Hashable {
    let id: UUID
    let role: String
    var content: String
    var thinking: String?
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, role, content, thinking
        case createdAt = "created_at"
    }

    init(id: UUID, role: String, content: String, thinking: String? = nil, createdAt: Date?) {
        self.id = id
        self.role = role
        self.content = content
        self.thinking = thinking
        self.createdAt = createdAt
    }
}

struct ChatRequestOptions: Equatable, Hashable {
    var web = false
    var retrieval = false
    var deepResearch = false

    var isEmpty: Bool {
        !web && !retrieval && !deepResearch
    }
}

struct ChatAttachment: Identifiable, Hashable {
    let id: UUID
    let name: String
    let dataURL: String
    let isPDF: Bool
    let text: String?

    init(
        id: UUID = UUID(),
        name: String,
        dataURL: String,
        isPDF: Bool = false,
        text: String? = nil
    ) {
        self.id = id
        self.name = name
        self.dataURL = dataURL
        self.isPDF = isPDF
        self.text = text
    }
}

struct ModelChoice: Identifiable, Hashable {
    enum Selection: Hashable {
        case platform(tier: String)
        case endpoint(id: UUID)
    }

    let id: String
    let name: String
    let detail: String
    let selection: Selection

    static let platform: [ModelChoice] = [
        ModelChoice(id: "platform-deep", name: "深度", detail: "深入思考", selection: .platform(tier: "鸿篇")),
        ModelChoice(id: "platform-balanced", name: "均衡", detail: "思考与速度平衡", selection: .platform(tier: "正构")),
        ModelChoice(id: "platform-fast", name: "快速", detail: "快速响应", selection: .platform(tier: "绝句")),
    ]
}

struct EndpointRow: Decodable {
    let id: UUID
    let name: String
    let model: String
    let outputKind: String?
    let baseURL: String?
    let authType: String?

    enum CodingKeys: String, CodingKey {
        case id, name, model
        case outputKind = "output_kind"
        case baseURL = "base_url"
        case authType = "auth_type"
    }
}

struct ModelEndpointSummary: Codable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let baseURL: String
    let model: String
    let outputKind: String
    let authType: String
    let needsReconnect: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, model, outputKind, authType, needsReconnect
        case baseURL = "baseUrl"
    }
}

struct DiscoveredModel: Codable, Identifiable, Hashable {
    let id: String
    let displayName: String
    let ownedBy: String?
    let chatCompatible: Bool
}

struct MemoryRecord: Codable, Identifiable, Hashable {
    let id: UUID
    var content: String
    let createdAt: Date?
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, content
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct AccountSnapshot: Decodable, Equatable {
    let id: UUID
    let email: String?
}

struct ProfileSnapshot: Decodable, Equatable {
    let memoryEnabled: Bool?
    let customSystemPrompt: String?
    let tokens5h: Int?
    let window5hStart: Date?
    let tokens7d: Int?
    let window7dStart: Date?
    let balance: Int?

    enum CodingKeys: String, CodingKey {
        case memoryEnabled = "memory_enabled"
        case customSystemPrompt = "custom_system_prompt"
        case tokens5h = "tokens_5h"
        case window5hStart = "window_5h_start"
        case tokens7d = "tokens_7d"
        case window7dStart = "window_7d_start"
        case balance
    }
}

struct QuotaSnapshot: Equatable {
    let tokens5h: Int
    let window5hStart: Date
    let tokens7d: Int
    let window7dStart: Date
    let balance: Int
}

struct ChatEnqueueResponse: Decodable {
    let jobId: UUID
    let assistantMessageId: UUID
    let status: String
}
