import Foundation

struct AccountQuotaSnapshot: Codable, Equatable, Sendable {
    static let fiveHourLimit: Int64 = 500_000
    static let sevenDayLimit: Int64 = 10_000_000

    let tokens5h: Int64
    let window5hStart: String
    let tokens7d: Int64
    let window7dStart: String
    let balance: Int64
}

struct InvitationRedemption: Equatable, Sendable {
    let tokensAdded: Int64
    let newBalance: Int64
}

enum CustomEndpointOutputKind: String, Codable, CaseIterable, Sendable {
    case chat
    case image
    case video

    var title: String {
        switch self {
        case .chat: return "对话"
        case .image: return "图片"
        case .video: return "视频"
        }
    }
}

enum CustomEndpointAuthType: String, Codable, CaseIterable, Sendable {
    case auto
    case bearer
    case xAPIKey = "x-api-key"
    case apiKey = "api-key"
    case none

    var title: String {
        switch self {
        case .auto: return "自动检测"
        case .bearer: return "Bearer"
        case .xAPIKey: return "X-API-Key"
        case .apiKey: return "API-Key"
        case .none: return "无鉴权"
        }
    }
}

struct CustomModelEndpoint: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let baseURL: String
    let model: String
    let outputKind: CustomEndpointOutputKind
    let authType: CustomEndpointAuthType
    let needsReconnect: Bool
    var reasoningEfforts: [String]? = nil
    var reasoningMandatory: Bool? = nil
    var defaultReasoningEffort: String? = nil
    let createdAt: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case baseURL = "baseUrl"
        case model
        case outputKind
        case authType
        case needsReconnect
        case reasoningEfforts
        case reasoningMandatory
        case defaultReasoningEffort
        case createdAt
        case updatedAt
    }
}

struct DiscoveredCustomModel: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let displayName: String
    let ownedBy: String?
    let chatCompatible: Bool
}

struct CustomModelDiscovery: Equatable, Sendable {
    let baseURL: String
    let authType: CustomEndpointAuthType
    let models: [DiscoveredCustomModel]
}

struct CustomEndpointDraft: Equatable, Sendable {
    let baseURL: String
    let apiKey: String
    let model: String
    let displayName: String
    let outputKind: CustomEndpointOutputKind
    let authType: CustomEndpointAuthType
}
