import Foundation

enum ModelAccess: String, Codable {
    case quota
    case trial
    case premium
}

enum ModelOutputKind: String, Codable {
    case chat
    case image
    case video
}

struct ModelCatalogItem: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let provider: String
    let access: ModelAccess
    let outputKind: ModelOutputKind
    let promptPrice: Double
    let completionPrice: Double
    let contextLength: Int
    let vision: Bool
    let tools: Bool
    let flagship: Bool
    let reasoningEfforts: [String]
    let defaultReasoningEffort: String?
    let reasoningMandatory: Bool
    let ownerUnlocked: Bool?
    let trialSelectable: Bool?
    let trialUnlimited: Bool?
    let trialLimit: Int?
    let trialRemaining: Int?
    let endpointID: String?

    // Product labels for the current Claude routes. Routing IDs stay exact;
    // older generations and user-named endpoints keep their own versions.
    var chatDisplayName: String {
        let route = id.lowercased().split(separator: "/").last.map(String.init) ?? id.lowercased()
        if endpointID == nil {
            switch route {
            case "claude-fable-5", "claude-fable-5.1", "claude-fable-5-1": return "Fable 5.1"
            case "claude-opus-5", "claude-opus-5.5", "claude-opus-5-5": return "Opus 5.5"
            case "claude-sonnet-5", "claude-sonnet-5.5", "claude-sonnet-5-5": return "Sonnet 5.5"
            case "claude-haiku-4.5", "claude-haiku-4-5": return "Haiku 4.5"
            default: break
            }
        }
        return name.hasPrefix("Claude ") ? String(name.dropFirst(7)) : name
    }

    var isSelectable: Bool {
        access == .quota
            || ownerUnlocked == true
            || trialSelectable == true
            || trialUnlimited == true
    }
}

struct ModelCatalogPayload: Codable {
    let schemaVersion: Int
    let configured: Bool
    let owner: Bool
    let trialLimit: Int
    let trialRemaining: Int?
    let models: [ModelCatalogItem]
    let error: String?
}
