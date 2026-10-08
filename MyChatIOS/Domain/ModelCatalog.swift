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
    var upstreamModelID: String? = nil

    // Product labels for the current Claude routes. Routing IDs stay exact;
    // older generations and user-named endpoints keep their own versions.
    var chatDisplayName: String {
        if let identity = claudeIdentity {
            return identity.family.capitalized + " " + identity.version
        }
        let label = name.hasPrefix("Claude ") ? String(name.dropFirst(7)) : name
        let spaced = label.replacingOccurrences(of: #"([0-9])[-\s]*(?=[A-Za-z])"#,
            with: "$1 ", options: .regularExpression)
        return spaced.replacingOccurrences(of: "-", with: " ")
    }

    var claudeIdentity: (family: String, version: String)? {
        // Custom labels are not routing evidence: use the endpoint's actual
        // model identifier, which was returned with its saved configuration.
        let route = upstreamModelID ?? (endpointID == nil ? id : "")
        let pattern = #"(?:^|/)(?:claude[- ])?(fable|opus|sonnet|haiku)[- ](\d+)(?:[.-](\d{1,2}))?(?=$|[- /])"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = expression.firstMatch(in: route, range: NSRange(route.startIndex..., in: route)),
              let family = Range(match.range(at: 1), in: route),
              let major = Range(match.range(at: 2), in: route) else { return nil }
        let minor = Range(match.range(at: 3), in: route).map { "." + route[$0] } ?? ""
        return (route[family].lowercased(), String(route[major]) + minor)
    }

    static func primaryChatModels(_ models: [Self], selectedID: String?) -> [Self] {
        let targets = [("fable", "5.1"), ("opus", "5.5"), ("sonnet", "5.5"), ("haiku", "5.5")]
        return targets.compactMap { family, version in
            let candidates = models.filter { $0.outputKind == .chat && $0.claudeIdentity?.family == family }
            let exact = candidates.filter { $0.claudeIdentity?.version == version }
            return exact.sorted {
                if $0.isSelectable != $1.isSelectable { return $0.isSelectable }
                if ($0.endpointID != nil) != ($1.endpointID != nil) { return $0.endpointID != nil }
                if ($0.id == selectedID) != ($1.id == selectedID) { return $0.id == selectedID }
                let comparison = $0.chatDisplayName.localizedStandardCompare($1.chatDisplayName)
                if comparison != .orderedSame { return comparison == .orderedDescending }
                return $0.id < $1.id
            }.first
        }
    }

    /// Keep the current four-model product surface complete while an older
    /// catalog deployment is still catching up. The fallback inherits the
    /// same entitlement and capability envelope as Sonnet 5.5. The stable
    /// catalog identifier is resolved by the backend onto the shared Claude
    /// API used by all four primary models.
    static func addingHaiku55Fallback(to models: [Self]) -> [Self] {
        guard !models.contains(where: {
            $0.outputKind == .chat
                && $0.claudeIdentity?.family == "haiku"
                && $0.claudeIdentity?.version == "5.5"
        }), let sonnet = models.first(where: {
            $0.outputKind == .chat
                && $0.claudeIdentity?.family == "sonnet"
                && $0.claudeIdentity?.version == "5.5"
        }) else { return models }

        var result = models
        result.append(Self(
            id: "anthropic/claude-haiku-5.5",
            name: "Claude Haiku 5.5",
            provider: "Anthropic",
            access: sonnet.access,
            outputKind: .chat,
            promptPrice: sonnet.promptPrice,
            completionPrice: sonnet.completionPrice,
            contextLength: sonnet.contextLength,
            vision: sonnet.vision,
            tools: sonnet.tools,
            flagship: true,
            reasoningEfforts: sonnet.reasoningEfforts,
            defaultReasoningEffort: sonnet.defaultReasoningEffort,
            reasoningMandatory: sonnet.reasoningMandatory,
            ownerUnlocked: sonnet.ownerUnlocked,
            trialSelectable: sonnet.trialSelectable,
            trialUnlimited: sonnet.trialUnlimited,
            trialLimit: sonnet.trialLimit,
            trialRemaining: sonnet.trialRemaining,
            endpointID: nil
        ))
        return result
    }

    static func currentChatSelection(_ models: [Self], preferredID: String?) -> Self? {
        let preferred = models.first { $0.id == preferredID && $0.isSelectable }
        let current = primaryChatModels(models, selectedID: preferredID).filter(\.isSelectable)
        let family = preferred?.claudeIdentity?.family
            ?? ["fable", "opus", "sonnet", "haiku"].first { preferredID?.lowercased().contains("claude-" + $0 + "-") == true }
        if let family, let matched = current.first(where: { $0.claudeIdentity?.family == family }) {
            return matched
        }
        return preferred ?? current.first ?? models.first(where: \.isSelectable)
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
