import Foundation

struct ProjectRecord: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var name: String
    var instructions: String
    let createdAt: String?
    var updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case instructions
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct ProjectFileRecord: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let projectID: String
    var name: String
    var content: String
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case projectID = "project_id"
        case name
        case content
        case createdAt = "created_at"
    }
}

struct MemoryRecord: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var content: String
    var topic: String?
    var sensitive: Bool?
    let createdAt: String?
    var updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case content
        case topic
        case sensitive
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct MemorySettingsRecord: Equatable, Sendable {
    let enabled: Bool
    let sensitiveEnabled: Bool
}

struct MCPConnectorToolRecord: Codable, Equatable, Identifiable, Sendable {
    let name: String
    var title: String
    var description: String
    var readOnly: Bool

    var id: String { name }
}

struct MCPConnectorRecord: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var name: String
    var serverURL: String
    var enabled: Bool
    var hasAccessToken: Bool
    var authType: String? = nil
    var authorizationStatus: String? = nil
    var toolCount: Int
    var tools: [MCPConnectorToolRecord]
    var createdAt: String
    var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, name, enabled, tools
        case serverURL = "serverUrl"
        case hasAccessToken, authType, authorizationStatus
        case toolCount
        case createdAt
        case updatedAt
    }
}

struct MCPDirectoryEntry: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let description: String
    let serverUrl: String
    let websiteUrl: String?
    let authType: String
}

struct MCPDirectoryResponse: Decodable, Sendable {
    let entries: [MCPDirectoryEntry]
    let nextCursor: String?
}

struct MCPOAuthStartResponse: Decodable, Sendable {
    let connectorId: String
    let attemptId: String
    let authorizationUrl: URL
    let expiresIn: Int

    func validateCallback(_ url: URL) throws {
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = parts?.queryItems ?? []
        func single(_ key: String) -> String? {
            let matches = items.filter { $0.name == key }
            return matches.count == 1 ? matches.first?.value : nil
        }
        guard url.scheme == "mychat", url.host == "connectors", url.path == "/oauth",
              single("connectorId") == connectorId,
              single("attemptId") == attemptId else {
            throw AccountSettingsError.invalidInput("授权未完成或已失效，请重新连接")
        }
        if single("status") == "error" {
            throw AccountSettingsError.invalidInput("服务方未完成授权，请检查 OAuth 配置后重试")
        }
        guard single("status") == "success" else {
            throw AccountSettingsError.invalidInput("授权未完成或已失效，请重新连接")
        }
    }
}

struct MemoryImportResult: Equatable, Sendable {
    let memories: [MemoryRecord]
    let skippedDuplicates: Int
}

struct MemoryImportEntry: Codable, Equatable, Sendable {
    let content: String
    let topic: String
    var sensitive: Bool? = nil

    init(content: String, topic: String = "Imported", sensitive: Bool? = nil) {
        self.content = content
        self.topic = topic
        self.sensitive = sensitive
    }
}

enum MemoryImportParser {
    private struct BackupDocument: Codable {
        let format: String
        let version: Int
        let exportedAt: String
        let memories: [MemoryImportEntry]
    }

    static func parse(_ source: String) -> [MemoryImportEntry] {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 256 * 1024 else { return [] }

        if let data = text.data(using: .utf8) {
            if let document = try? JSONDecoder().decode(BackupDocument.self, from: data),
               document.format == "mychat-memory", document.version == 1 {
                return normalized(document.memories)
            }
            if let entries = try? JSONDecoder().decode([MemoryImportEntry].self, from: data) {
                return normalized(entries)
            }
        }
        return parseMarkdown(text)
    }

    static func export(_ memories: [MemoryRecord], now: Date = Date()) -> String {
        let entries = memories.map { memory in
            MemoryImportEntry(
                content: memory.content,
                topic: normalizedTopic(memory.topic ?? "General"),
                sensitive: memory.sensitive
            )
        }
        let document = BackupDocument(
            format: "mychat-memory",
            version: 1,
            exportedAt: ISO8601DateFormatter().string(from: now),
            memories: entries
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(document),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    private static func parseMarkdown(_ text: String) -> [MemoryImportEntry] {
        var entries: [MemoryImportEntry] = []
        var topic = "Imported"
        var current: String?

        func flush() {
            guard let content = current?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !content.isEmpty else {
                current = nil
                return
            }
            entries.append(MemoryImportEntry(content: content, topic: topic))
            current = nil
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("```") else { continue }

            if line.hasPrefix("#") {
                flush()
                let heading = String(line.drop(while: { $0 == "#" || $0.isWhitespace }))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                topic = normalizedTopic(heading)
                continue
            }

            if let bullet = listContent(from: line) {
                flush()
                let item = stripSavedDate(from: bullet)
                if !item.isEmpty { current = item }
                continue
            }

            if current == nil {
                let lower = line.lowercased()
                if entries.isEmpty && (lower.hasPrefix("here are your memories")
                    || lower.hasPrefix("memory export")
                    || line == "Claude memories") {
                    continue
                }
                current = line
            } else {
                current?.append("\n" + line)
            }
        }
        flush()
        return normalized(entries)
    }

    private static func listContent(from line: String) -> String? {
        for marker in ["- ", "* ", "• ", "· "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        var index = line.startIndex
        while index < line.endIndex, line[index].isNumber { index = line.index(after: index) }
        guard index > line.startIndex, index < line.endIndex,
              line[index] == "." || line[index] == ")" else { return nil }
        let next = line.index(after: index)
        guard next < line.endIndex, line[next].isWhitespace else { return nil }
        return String(line[line.index(after: next)...]).trimmingCharacters(in: .whitespaces)
    }

    private static func stripSavedDate(from value: String) -> String {
        guard value.first == "[", let close = value.firstIndex(of: "]") else { return value }
        let date = value[value.index(after: value.startIndex)..<close]
        guard date.count >= 10, date.prefix(4).allSatisfy(\.isNumber),
              date.dropFirst(4).first == "-" else { return value }
        let remainder = String(value[value.index(after: close)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard remainder.first == "-" else { return value }
        return remainder.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalized(_ values: [MemoryImportEntry]) -> [MemoryImportEntry] {
        var seen = Set<String>()
        return values.compactMap { value in
            let content = value.content.trimmingCharacters(in: .whitespacesAndNewlines)
            let topic = normalizedTopic(value.topic)
            guard !content.isEmpty, content.utf16.count <= 20_000,
                  topic.utf16.count <= 80 else { return nil }
            let key = "\(topic.lowercased())\u{0}\(content)"
            guard seen.insert(key).inserted else { return nil }
            return MemoryImportEntry(content: content, topic: topic, sensitive: value.sensitive)
        }
    }

    private static func normalizedTopic(_ value: String) -> String {
        let normalized = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let lowered = normalized.lowercased()
        guard !normalized.isEmpty,
              !["memories", "memory", "claude memories", "saved memories"].contains(lowered) else {
            return "Imported"
        }
        return String(normalized.prefix(80))
    }
}

struct ProjectMemoryRecord: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let projectID: String
    var content: String
    var topic: String?
    var sensitive: Bool?
    let createdAt: String?
    var updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case projectID = "project_id"
        case content
        case topic
        case sensitive
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct ArtifactRecord: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var title: String
    var raw: String
    let conversationID: String?
    let messageID: String?
    let projectID: String?
    let createdAt: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case raw
        case conversationID = "conversation_id"
        case messageID = "message_id"
        case projectID = "project_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct CodeSessionRecord: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var repository: String
    var title: String
    let createdAt: String?
    var updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case repository = "repo"
        case title
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct CodeMessageRecord: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let sessionID: String
    let role: String
    var content: String
    var metadata: JSONValue?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "session_id"
        case role
        case content
        case metadata = "meta"
        case createdAt = "created_at"
    }
}

struct CodeMemoryRecord: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let repository: String
    var content: String
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case repository = "repo"
        case content
        case createdAt = "created_at"
    }
}

struct CodeTaskRecord: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let goal: String
    let repository: String?
    let status: String
    let error: String?
    let createdAt: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, goal, status, error
        case repository = "repo"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct GitHubConnectionStatus: Codable, Equatable, Sendable {
    let connected: Bool
    let login: String?
}

struct GitHubRepositoryRecord: Codable, Equatable, Identifiable, Sendable {
    let name: String
    let fullName: String
    let isPrivate: Bool
    let description: String

    var id: String { fullName }

    enum CodingKeys: String, CodingKey {
        case name
        case fullName = "full_name"
        case isPrivate = "private"
        case description
    }
}

struct GitHubRepositoryPayload: Codable, Equatable, Sendable {
    let repos: [GitHubRepositoryRecord]
}

struct CodeContextMessage: Codable, Equatable, Sendable {
    let role: String
    let content: String
}

struct CodeChatCommand: Equatable, Sendable {
    let repository: String
    let modelID: String
    let endpointID: UUID?
    let reasoningEffort: String?
    let messages: [CodeContextMessage]
    let taskID: UUID?
    let responseID: UUID
    let sessionID: UUID
}

struct CodeAdmission: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let jobID: UUID
    let taskID: UUID
    let responseID: UUID?
    let status: String
    let created: Bool
    let streamURL: URL
    let trialRemaining: Int?
    let trialLimit: Int?

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case jobID = "jobId"
        case taskID = "taskId"
        case responseID = "responseId"
        case status
        case created
        case streamURL = "streamUrl"
        case trialRemaining
        case trialLimit
    }
}

struct CodeTurnStart: Equatable, Sendable {
    let userMessage: CodeMessageRecord
    let admission: CodeAdmission
}

struct CodeSessionStart: Equatable, Sendable {
    let session: CodeSessionRecord
    let turn: CodeTurnStart
}

struct CodeAgentStep: Codable, Equatable, Sendable {
    let kind: String
    let label: String
}

struct CodePlanAction: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case createRepository = "create_repo"
        case writeFile = "write_file"
        case deleteFile = "delete_file"
        case enablePages = "enable_pages"
    }

    let id: UUID
    let kind: Kind
    let name: String?
    let description: String?
    let isPrivate: Bool?
    let path: String?
    let oldContent: String?
    let newContent: String?

    init(
        id: UUID = UUID(),
        kind: Kind,
        name: String? = nil,
        description: String? = nil,
        isPrivate: Bool? = nil,
        path: String? = nil,
        oldContent: String? = nil,
        newContent: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.description = description
        self.isPrivate = isPrivate
        self.path = path
        self.oldContent = oldContent
        self.newContent = newContent
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case name
        case description
        case isPrivate = "private"
        case path
        case oldContent
        case newContent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID()
        kind = try container.decode(Kind.self, forKey: .kind)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        isPrivate = try container.decodeIfPresent(Bool.self, forKey: .isPrivate)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        oldContent = try container.decodeIfPresent(String.self, forKey: .oldContent)
        newContent = try container.decodeIfPresent(String.self, forKey: .newContent)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(isPrivate, forKey: .isPrivate)
        try container.encodeIfPresent(path, forKey: .path)
        try container.encodeIfPresent(oldContent, forKey: .oldContent)
        try container.encodeIfPresent(newContent, forKey: .newContent)
    }

    var summary: String {
        switch kind {
        case .createRepository:
            return "Create repository \(name ?? "")".trimmingCharacters(in: .whitespaces)
        case .writeFile:
            return "Write \(path ?? "file")"
        case .deleteFile:
            return "Delete \(path ?? "file")"
        case .enablePages:
            return "Enable GitHub Pages"
        }
    }
}

struct CodeApplyCommand: Equatable, Sendable {
    enum Mode: String, Codable, Sendable {
        case workspacePullRequest = "workspace_pr"
        case directPush = "direct_push"
    }

    let repository: String?
    let actions: [CodePlanAction]
    let message: String
    let taskID: UUID
    let mode: Mode
    let confirmationID: UUID?
    let confirmationToken: String?
}

struct CodeConfirmationRequest: Codable, Equatable, Identifiable, Sendable {
    struct Risk: Codable, Equatable, Sendable {
        let level: String
        let blocked: Bool
        let needsConfirmation: Bool
        let reason: String
        let files: [String]
        let operation: String
        let title: String
    }

    let taskID: UUID
    let confirmationID: UUID
    let confirmationToken: String
    let operation: String
    let expiresAt: String
    let risk: Risk

    var id: UUID { confirmationID }

    enum CodingKeys: String, CodingKey {
        case taskID = "taskId"
        case confirmationID = "confirmationId"
        case confirmationToken
        case operation
        case expiresAt
        case risk
    }
}

struct CodeOperationReceipt: Codable, Equatable, Sendable {
    let mode: String
    let taskID: UUID?
    let repository: String?
    let repositoryURL: URL?
    let pagesURL: URL?
    let commitSHA: String?
    let branch: String?
    let pullRequestURL: URL?
    let pullRequestNumber: Int?
    let merged: Bool?
    let mergeCommitSHA: String?
    let pagesStatus: String?
    let changedFiles: [String]?

    enum CodingKeys: String, CodingKey {
        case mode
        case taskID = "taskId"
        case repository = "repo"
        case repositoryURL = "repoUrl"
        case pagesURL = "pagesUrl"
        case commitSHA = "commitSha"
        case branch
        case pullRequestURL = "pullRequestUrl"
        case pullRequestNumber
        case merged
        case mergeCommitSHA = "mergeCommitSha"
        case pagesStatus
        case changedFiles
    }
}

enum CodeApplyResponse: Equatable, Sendable {
    case confirmation(CodeConfirmationRequest)
    case accepted(CodeAdmission)
}

struct ChatArtifactBlock: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case vega
        case mermaid
        case functionPlot = "function-plot"
        case inlineArtifact = "inline-artifact"
        case artifact
        case document

        var displayName: String {
            switch self {
            case .vega: return "Chart"
            case .mermaid: return "Diagram"
            case .functionPlot: return "Function plot"
            case .inlineArtifact: return "Graphic"
            case .artifact: return "Artifact"
            case .document: return "Document"
            }
        }
    }

    let id: UUID
    let kind: Kind
    let raw: String
    let isComplete: Bool

    init(id: UUID = UUID(), kind: Kind, raw: String, isComplete: Bool) {
        self.id = id
        self.kind = kind
        self.raw = raw
        self.isComplete = isComplete
    }
}

struct ParsedChatArtifacts: Equatable, Sendable {
    enum Part: Equatable, Sendable {
        case text(String)
        case artifact(ChatArtifactBlock)
    }
    let displayText: String
    let blocks: [ChatArtifactBlock]
    var parts: [Part] = []
}

enum ChatArtifactParser {
    private struct Tag {
        let kind: ChatArtifactBlock.Kind
        let open: String
        let close: String
    }

    private static let tags: [Tag] = ChatArtifactBlock.Kind.allCases.map {
        Tag(kind: $0, open: "<\($0.rawValue)>", close: "</\($0.rawValue)>")
    }

    static func parse(_ source: String) -> ParsedChatArtifacts {
        guard let first = nextTag(in: source, from: source.startIndex) else {
            return ParsedChatArtifacts(
                displayText: trimTrailingTagPrelude(source),
                blocks: [],
                parts: [.text(trimTrailingTagPrelude(source))]
            )
        }

        var display: [String] = []
        var blocks: [ChatArtifactBlock] = []
        var parts: [ParsedChatArtifacts.Part] = []
        var cursor = source.startIndex
        var next: (tag: Tag, range: Range<String.Index>)? = first

        while let current = next {
            let before = source[cursor..<current.range.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !before.isEmpty {
                display.append(before)
                parts.append(.text(before))
            }

            let bodyStart = current.range.upperBound
            if let closeRange = source.range(
                of: current.tag.close,
                options: [.caseInsensitive],
                range: bodyStart..<source.endIndex
            ) {
                let raw = source[bodyStart..<closeRange.lowerBound]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                blocks.append(ChatArtifactBlock(
                    id: stableID(at: blocks.count),
                    kind: resolvedKind(current.tag.kind, raw: raw),
                    raw: raw,
                    isComplete: true
                ))
                cursor = closeRange.upperBound
                next = nextTag(in: source, from: cursor)
            } else {
                blocks.append(ChatArtifactBlock(
                    id: stableID(at: blocks.count),
                    kind: resolvedKind(
                        current.tag.kind,
                        raw: String(source[bodyStart...]),
                        allowUnclosedSVG: true
                    ),
                    raw: String(source[bodyStart...]),
                    isComplete: false
                ))
                cursor = source.endIndex
                next = nil
            }
            if let block = blocks.last { parts.append(.artifact(block)) }
        }

        if cursor < source.endIndex {
            let trailing = trimTrailingTagPrelude(String(source[cursor...]))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !trailing.isEmpty {
                display.append(trailing)
                parts.append(.text(trailing))
            }
        }

        return ParsedChatArtifacts(
            displayText: display.joined(separator: "\n\n"),
            blocks: blocks,
            parts: parts
        )
    }

    static func completePackage(in source: String) -> (title: String, raw: String)? {
        let blocks = parse(source).blocks.filter { $0.isComplete && !$0.raw.isEmpty }
        guard let first = blocks.first else { return nil }
        // Preserve old HTML records; every other supported format retains its
        // tag so reopening selects the same renderer as the original reply.
        let raw = blocks.count == 1 && first.kind == .artifact ? first.raw
            : blocks.map { "<\($0.kind.rawValue)>" + $0.raw + "</\($0.kind.rawValue)>" }.joined(separator: "\n")
        return (title(for: first), raw)
    }

    static func title(for block: ChatArtifactBlock) -> String {
        if block.kind == .document { return ChatDocument.from(block)?.title ?? "Document" }
        if block.kind == .artifact || block.kind == .inlineArtifact {
            for pattern in [
                #"<title[^>]*>([^<]+)</title>"#,
                #"<h[1-3][^>]*>([\s\S]*?)</h[1-3]>"#,
            ] {
                guard let expression = try? NSRegularExpression(
                    pattern: pattern,
                    options: [.caseInsensitive]
                ) else { continue }
                let fullRange = NSRange(block.raw.startIndex..., in: block.raw)
                guard let match = expression.firstMatch(
                    in: block.raw,
                    options: [],
                    range: fullRange
                ), match.numberOfRanges > 1,
                let valueRange = Range(match.range(at: 1), in: block.raw) else { continue }
                let value = block.raw[valueRange]
                    .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return String(value.prefix(40)) }
            }
        }
        return block.kind.displayName
    }

    private static func stableID(at index: Int) -> UUID {
        // The ordinal is scoped to one message. Content grows during streaming;
        // using a new UUID for each parse destroys its live rendering surface.
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012llx", UInt64(index)))!
    }

    private static func nextTag(
        in source: String,
        from index: String.Index
    ) -> (tag: Tag, range: Range<String.Index>)? {
        var candidate: (tag: Tag, range: Range<String.Index>)?
        for tag in tags {
            guard let range = source.range(
                of: tag.open,
                options: [.caseInsensitive],
                range: index..<source.endIndex
            ) else {
                continue
            }
            if candidate == nil || range.lowerBound < candidate!.range.lowerBound {
                candidate = (tag, range)
            }
        }
        return candidate
    }

    private static func trimTrailingTagPrelude(_ source: String) -> String {
        guard let start = source.lastIndex(of: "<") else { return source }
        let tail = String(source[start...])
        let normalizedTail = tail.lowercased()
        if tags.contains(where: { $0.open.hasPrefix(normalizedTail) }) {
            return String(source[..<start]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return source
    }

    private static func resolvedKind(
        _ kind: ChatArtifactBlock.Kind,
        raw: String,
        allowUnclosedSVG: Bool = false
    ) -> ChatArtifactBlock.Kind {
        guard kind == .artifact else { return kind }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.hasPrefix("<svg"), allowUnclosedSVG || value.hasSuffix("</svg>") else {
            return kind
        }
        return .inlineArtifact
    }
}

extension Notification.Name {
    static let myChatDismissComposer = Notification.Name("mychat.dismissComposer")
    static let myChatModalVisibilityChanged = Notification.Name("mychat.modalVisibilityChanged")
}

/// Presentation-only normalization. API payloads and stored transcripts retain
/// their original source; utility labels never expose transport markup.
enum PresentationText {
    private static let expressions = NSCache<NSString, NSRegularExpression>()

    private static func replace(_ value: String, _ pattern: String, _ template: String) -> String {
        let key = pattern as NSString
        let expression: NSRegularExpression
        if let cached = expressions.object(forKey: key) { expression = cached }
        else {
            guard let compiled = try? NSRegularExpression(pattern: pattern) else { return value }
            expressions.setObject(compiled, forKey: key)
            expression = compiled
        }
        return expression.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: template)
    }

    static func rich(_ source: String) -> String {
        var value = source.replacingOccurrences(of: "\r\n", with: "\n")
        // Preserve math commands before decoding transport escapes: \\theta
        // and \\nabla are not a tab and a newline. The message renderer parses
        // these spans after normalization.
        var mathSpans: [String] = []
        if let math = try? NSRegularExpression(pattern: #"(?s)\\\[.*?\\\]|\\\(.*?\\\)|(?<!\\)\$\$.*?(?<!\\)\$\$|(?<!\\)\$(?!\s)(?:\\.|[^$\\\n])*?(?<!\\)\$(?!\$)"#) {
            for match in math.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
                guard let range = Range(match.range, in: value) else { continue }
                let index = mathSpans.count
                mathSpans.append(String(value[range]))
                value.replaceSubrange(range, with: "\u{E000}\(index)\u{E001}")
            }
        }
        value = value.replacingOccurrences(of: #"\n"#, with: "\n").replacingOccurrences(of: #"\t"#, with: " ")
        value = replace(value, #"\\([\\`*#_{}<>~:!])"#, "$1")
        for (entity, character) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
            ("&apos;", "'"), ("&#39;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
            value = value.replacingOccurrences(of: entity, with: character)
        }
        if let expression = try? NSRegularExpression(pattern: #"&#(x[0-9a-fA-F]+|[0-9]+);"#) {
            for match in expression.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
                guard let range = Range(match.range(at: 1), in: value), let full = Range(match.range, in: value) else { continue }
                let code = String(value[range])
                let integer = code.first == "x" ? UInt32(code.dropFirst(), radix: 16) : UInt32(code)
                if let integer, let scalar = UnicodeScalar(integer) { value.replaceSubrange(full, with: String(scalar)) }
            }
        }
        value = replace(value, #"(?is)<(?:script|style)\b[^>]*>.*?</(?:script|style)\s*>"#, "")
        value = replace(value, #"(?is)\{\{.*?\}\}|\{%.*?%\}|<%.*?%>|\$\{[^{}]*\}|<\|[^|]*\|>|\[\[.*?\]\]|\[/?(?:INST|SYS|SYSTEM|ASSISTANT|USER)\]"#, "")
        value = replace(value, #"(?m)\{\{[^}\n]*$|\{%[^%\n]*$"#, "")
        value = replace(value, #"(?i)<br\s*/?>|</(?:p|div|li|h[1-6])\s*>"#, "\n")
        value = replace(value, #"(?i)<li\b[^>]*>"#, "- ")
        value = replace(value, #"(?is)<(?:b|strong)\b[^>]*>(.*?)</(?:b|strong)\s*>"#, "**$1**")
        value = replace(value, #"(?is)<(?:em|i)\b[^>]*>(.*?)</(?:em|i)\s*>"#, "*$1*")
        value = replace(value, #"(?i)</?[a-z][^>]*>|<!--.*?-->"#, "")
        value = replace(value, #"(?m)<[/!a-zA-Z][^>\n]*$"#, "")
        value = value.replacingOccurrences(of: #"\n"#, with: "\n").replacingOccurrences(of: #"\t"#, with: " ")
        value = replace(value, #"(?m)^[ \t]{0,3}>+[ \t]*"#, "")
        value = replace(value, #"(?m)^[ \t]*~~~"#, "```")
        value = replace(value, #"(?m)^\s*#{4,6}\s+"#, "### ")
        value = replace(value, #"(?m)^[ \t]*[:：]+[ \t]*|[ \t]*[:：]+[ \t]*$"#, "")
        // Incomplete emphasis and inline-code delimiters in a live thought
        // appear as ordinary text until their matching delimiter arrives.
        var insideFence = false
        value = value.components(separatedBy: .newlines).map { line in
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { insideFence.toggle(); return line }
            if insideFence { return line }
            var clean = line
            for delimiter in ["**", "__", "~~", "`", "*"] {
                let count = clean.components(separatedBy: delimiter).count - 1
                if count % 2 == 1, let last = clean.range(of: delimiter, options: .backwards) {
                    clean.removeSubrange(last)
                }
            }
            if clean.components(separatedBy: "_").count % 2 == 0 {
                clean = replace(clean, #"(?<![\p{L}\p{N}])_(?!_)"#, "")
            }
            return clean
        }.joined(separator: "\n")
        for (index, math) in mathSpans.enumerated() {
            value = value.replacingOccurrences(of: "\u{E000}\(index)\u{E001}", with: math)
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func plain(_ source: String) -> String {
        var value = rich(source)
        // Utility labels have no math renderer. Keep a readable label instead
        // of leaking TeX commands into a one-line status or thought summary.
        value = replace(value, #"(?s)\\\[.*?\\\]|\\\(.*?\\\)|\$\$.*?\$\$|(?<!\\)\$(?!\s)(?:\\.|[^$\\\n])*?(?<!\\)\$(?!\$)"#, "数学公式")
        value = replace(value, #"(?m)^\s*`{3,}[^\n]*$|^\s*(?:---+|\*\*\*+|___+)\s*$"#, "")
        value = replace(value, #"!\[([^\]]*)\]\([^)]*\)|\[([^\]]+)\]\([^)]*\)"#, "$1$2")
        value = replace(value, #"(?m)^\s{0,3}(?:#{1,6}\s*|>+\s*|[-*+]\s+|[0-9]+[.)]\s+)"#, "")
        if let parsed = try? AttributedString(markdown: value,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            value = String(parsed.characters)
        }
        value = replace(value, #"[`*#~]|\*\*|__|\\(?=[^\p{L}\p{N}])"#, "")
        value = replace(value, #"(?m)^[ \t]*[:：]+[ \t]*|[ \t]*[:：]+[ \t]*$"#, "")
        value = replace(value, #"[ \t]{2,}"#, " ")
        value = replace(value, #"\n{3,}"#, "\n\n")
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct RenderedMessage: Equatable, Sendable {
    var blocks: [MessageMarkdownBlock] = []
    var artifacts: [ChatArtifactBlock] = []
}

/// One retained parsed document per message, with a bounded memory budget.
/// Parsing history is completed before it becomes visible, so entering a row
/// never starts with an empty document and a second, different height.
enum ChatPresentationCache {
    private final class Entry: NSObject {
        let source: String
        let streaming: Bool
        let document: RenderedMessage
        init(_ source: String, _ streaming: Bool, _ document: RenderedMessage) {
            self.source = source; self.streaming = streaming; self.document = document
        }
    }
    private static let entries: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 1_024
        cache.totalCostLimit = 32 * 1_024 * 1_024
        return cache
    }()

    static func key(messageID: UUID?, source: String, thinking: Bool = false) -> String {
        "\(messageID?.uuidString ?? String(source.hashValue)):\(thinking ? "thought" : "body")"
    }

    static func document(key: String, source: String, streaming: Bool) -> RenderedMessage {
        if let entry = entries.object(forKey: key as NSString), entry.source == source, entry.streaming == streaming {
            return entry.document
        }
        let parsed = ChatArtifactParser.parse(source)
        let blocks = parsed.parts.flatMap { part -> [MessageMarkdownBlock] in
            switch part {
            case .text(let text):
                return MessageMarkdownParser.parse(text, suppressIncompleteDisplayMath: streaming)
            case .artifact(let artifact): return [.artifact(artifact)]
            }
        }
        let document = RenderedMessage(blocks: blocks, artifacts: parsed.blocks)
        MessageInlinePresentationCache.prime(document)
        entries.setObject(Entry(source, streaming, document), forKey: key as NSString, cost: source.utf8.count * 3 + 256)
        return document
    }

    static func prime(_ messages: [ChatMessage]) async {
        let task = Task.detached(priority: .userInitiated) {
            for message in messages where message.role == .assistant {
                guard !Task.isCancelled else { return }
                _ = document(key: key(messageID: message.id, source: message.content), source: message.content, streaming: false)
                if let thinking = message.thinking, !thinking.isEmpty {
                    let clean = PresentationText.rich(thinking)
                    _ = document(key: key(messageID: message.id, source: clean, thinking: true), source: clean, streaming: false)
                }
            }
        }
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
}

enum MarkdownTableAlignment: Equatable, Sendable {
    case leading
    case center
    case trailing
}

enum MessageMarkdownBlock: Equatable, Sendable {
    case artifact(ChatArtifactBlock)
    case paragraph(String)
    case heading(level: Int, text: String)
    case bullets([String])
    case numbered(start: Int, items: [String], loose: Bool)
    case quote(String)
    case table(headers: [String], alignments: [MarkdownTableAlignment], rows: [[String]])
    case code(language: String?, text: String)
    case imageGallery([MessageImageReference])
    case math(String)
    case mathPending
    case mathIncomplete
    case divider
}

struct MessageImageReference: Equatable, Identifiable, Sendable {
    let url: String
    let alt: String
    var id: String { url }
}

enum MessageMarkdownParser {
    static func parse(
        _ source: String,
        suppressIncompleteDisplayMath: Bool = false
    ) -> [MessageMarkdownBlock] {
        let lines = source.components(separatedBy: .newlines)
        var blocks: [MessageMarkdownBlock] = []
        var paragraphLines: [String] = []
        var codeLines: [String] = []
        var codeLanguage: String?
        var isInsideCodeBlock = false
        var index = 0

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            let paragraph = paragraphLines.joined(separator: "\n")
            if let opening = incompleteDisplayMathOpening(in: paragraph) {
                let visible = String(paragraph[..<opening.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !visible.isEmpty {
                    blocks.append(.paragraph(visible))
                }
                // Do not flash raw TeX while a streamed display formula has
                // emitted its opening fence but not its closing fence yet.
                // If the stream finishes without a matching close, preserve
                // the same clean surface rather than leaving a raw $$ block
                // or KaTeX error text in the response.
                blocks.append(suppressIncompleteDisplayMath ? .mathPending : .mathIncomplete)
            } else {
                blocks.append(contentsOf: splitInlineImages(paragraph))
            }
            paragraphLines.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if isInsideCodeBlock {
                    blocks.append(.code(language: codeLanguage, text: codeLines.joined(separator: "\n")))
                    codeLines.removeAll(keepingCapacity: true)
                    codeLanguage = nil
                    isInsideCodeBlock = false
                } else {
                    flushParagraph()
                    let language = String(trimmed.dropFirst(3))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    codeLanguage = language.isEmpty ? nil : language
                    isInsideCodeBlock = true
                }
                index += 1
                continue
            }

            if isInsideCodeBlock {
                codeLines.append(line)
                index += 1
                continue
            }

            if let expression = completeSingleLineMath(trimmed) {
                flushParagraph()
                blocks.append(.math(normalizedDisplayMath(expression)))
                index += 1
                continue
            }

            if let mathBlock = delimitedMathBlock(in: lines, startingAt: index) {
                flushParagraph()
                if let leading = mathBlock.leading, !leading.isEmpty {
                    blocks.append(.paragraph(leading))
                }
                blocks.append(.math(normalizedDisplayMath(mathBlock.expression)))
                if let trailing = mathBlock.trailing, !trailing.isEmpty {
                    blocks.append(.paragraph(trailing))
                }
                index = mathBlock.nextIndex
                continue
            }

            if startsUnclosedDisplayMath(trimmed) {
                flushParagraph()
                // Never hand an unclosed $$ / \\[ block to KaTeX.  During a
                // stream, the parser will receive the completed source again
                // on the next delta; after terminal, retain a clean fallback
                // instead of showing red raw LaTeX in the conversation.
                blocks.append(suppressIncompleteDisplayMath ? .mathPending : .mathIncomplete)
                index = lines.count
                continue
            }

            if let expression = bareMathLine(trimmed) {
                flushParagraph()
                blocks.append(.math(expression))
                index += 1
                continue
            }

            if let closing = mathClosingDelimiter(for: trimmed),
               let closingIndex = lines[(index + 1)...].firstIndex(where: {
                   $0.trimmingCharacters(in: .whitespaces) == closing
               }) {
                flushParagraph()
                let expression = lines[(index + 1)..<closingIndex]
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !expression.isEmpty {
                    blocks.append(.math(normalizedDisplayMath(expression)))
                }
                index = closingIndex + 1
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if let cells = tableCells(from: trimmed),
               index + 1 < lines.count,
               let alignments = tableAlignments(from: lines[index + 1]),
               cells.count == alignments.count {
                flushParagraph()
                let headers = cells
                index += 2
                var rows: [[String]] = []
                while index < lines.count,
                      !lines[index].trimmingCharacters(in: .whitespaces).isEmpty,
                      let row = tableCells(from: lines[index]) {
                    var normalized = Array(row.prefix(headers.count))
                    if normalized.count < headers.count {
                        normalized.append(contentsOf: repeatElement("", count: headers.count - normalized.count))
                    }
                    rows.append(normalized)
                    index += 1
                }
                blocks.append(.table(headers: headers, alignments: alignments, rows: rows))
                continue
            }

            if let quote = quoteContent(from: line) {
                flushParagraph()
                var quotedLines = [quote]
                index += 1
                while index < lines.count, let nextQuote = quoteContent(from: lines[index]) {
                    quotedLines.append(nextQuote)
                    index += 1
                }
                blocks.append(.quote(quotedLines.joined(separator: "\n")))
                continue
            }

            if let heading = heading(from: trimmed) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if isDivider(trimmed) {
                flushParagraph()
                blocks.append(.divider)
                index += 1
                continue
            }

            if bulletText(from: trimmed) != nil {
                flushParagraph()
                var items: [String] = []
                while index < lines.count,
                      let item = bulletText(from: lines[index].trimmingCharacters(in: .whitespaces)) {
                    items.append(item)
                    index += 1
                }
                blocks.append(.bullets(items))
                continue
            }

            if let first = numberedItem(from: trimmed) {
                flushParagraph()
                var items: [String] = []
                var loose = false
                while index < lines.count {
                    if let item = numberedItem(from: lines[index].trimmingCharacters(in: .whitespaces)) {
                        items.append(item.text)
                        index += 1
                        continue
                    }
                    // An empty line separates items in a loose Markdown list;
                    // it does not restart the numbering or create a paragraph.
                    var next = index
                    while next < lines.count, lines[next].trimmingCharacters(in: .whitespaces).isEmpty {
                        next += 1
                    }
                    if next > index, next < lines.count,
                       numberedItem(from: lines[next].trimmingCharacters(in: .whitespaces)) != nil {
                        loose = true
                        index = next
                    } else {
                        break
                    }
                }
                blocks.append(.numbered(start: first.number, items: items, loose: loose))
                continue
            }

            paragraphLines.append(line)
            index += 1
        }

        flushParagraph()
        if isInsideCodeBlock {
            blocks.append(.code(language: codeLanguage, text: codeLines.joined(separator: "\n")))
        }
        return blocks.isEmpty ? [.paragraph(source)] : blocks
    }

    private static func splitInlineImages(_ source: String) -> [MessageMarkdownBlock] {
        guard let expression = try? NSRegularExpression(
            pattern: #"!\[([^\]]*)\]\((https://[^\s)]+)(?:\s+"[^"]*")?\)"#
        ) else { return [.paragraph(source)] }
        let matches = expression.matches(in: source, range: NSRange(source.startIndex..., in: source))
        guard !matches.isEmpty else { return [.paragraph(source)] }

        var blocks: [MessageMarkdownBlock] = []
        var images: [MessageImageReference] = []
        var cursor = source.startIndex

        func flushImages() {
            guard !images.isEmpty else { return }
            blocks.append(.imageGallery(images))
            images.removeAll(keepingCapacity: true)
        }

        for match in matches {
            guard let fullRange = Range(match.range, in: source),
                  let urlRange = Range(match.range(at: 2), in: source),
                  let altRange = Range(match.range(at: 1), in: source),
                  let url = URL(string: String(source[urlRange])),
                  url.scheme?.lowercased() == "https",
                  let host = url.host?.lowercased(),
                  host != "localhost", !host.hasSuffix(".local"),
                  host != "127.0.0.1", host != "::1" else { continue }

            let preceding = String(source[cursor..<fullRange.lowerBound])
            if !preceding.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                flushImages()
                blocks.append(.paragraph(preceding))
            }
            images.append(MessageImageReference(url: url.absoluteString, alt: String(source[altRange])))
            cursor = fullRange.upperBound
        }

        if cursor == source.startIndex { return [.paragraph(source)] }
        flushImages()
        let trailing = String(source[cursor...])
        if !trailing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks.append(.paragraph(trailing))
        }
        return blocks.isEmpty ? [.paragraph(source)] : blocks
    }

    private static func heading(from line: String) -> (level: Int, text: String)? {
        let level = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level) else { return nil }
        let remainder = line.dropFirst(level)
        guard remainder.first == " " else { return nil }
        return (level, remainder.trimmingCharacters(in: .whitespaces))
    }

    private static func quoteContent(from line: String) -> String? {
        let indentation = line.prefix(while: { $0 == " " }).count
        guard indentation <= 3 else { return nil }
        let content = line.dropFirst(indentation)
        guard content.first == ">" else { return nil }
        var quote = content.dropFirst()
        if quote.first == " " { quote = quote.dropFirst() }
        return String(quote)
    }

    private static func tableCells(from line: String) -> [String]? {
        guard line.contains("|") else { return nil }
        var cells: [String] = []
        var cell = ""
        var insideCode = false
        var escaped = false

        for character in line {
            if character == "\\", !escaped {
                cell.append(character)
                escaped = true
                continue
            }
            if character == "`", !escaped {
                insideCode.toggle()
                cell.append(character)
            } else if character == "|", !insideCode, !escaped {
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell.removeAll(keepingCapacity: true)
            } else if character == "|", !insideCode, escaped {
                cell.removeLast()
                cell.append("|")
            } else {
                cell.append(character)
            }
            escaped = false
        }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        if cells.first?.isEmpty == true { cells.removeFirst() }
        if cells.last?.isEmpty == true { cells.removeLast() }
        return cells.count >= 2 ? cells : nil
    }

    private static func tableAlignments(from line: String) -> [MarkdownTableAlignment]? {
        guard let cells = tableCells(from: line) else { return nil }
        let alignments = cells.compactMap { cell -> MarkdownTableAlignment? in
            let value = cell.trimmingCharacters(in: .whitespaces)
            let leading = value.first == ":"
            let trailing = value.last == ":"
            var hyphens = Array(value)
            if leading { hyphens.removeFirst() }
            if trailing, !hyphens.isEmpty { hyphens.removeLast() }
            guard hyphens.count >= 3, hyphens.allSatisfy({ $0 == "-" }) else { return nil }
            if leading && trailing { return .center }
            if trailing { return .trailing }
            return .leading
        }
        return alignments.count == cells.count ? alignments : nil
    }

    private static func bulletText(from line: String) -> String? {
        for prefix in ["- ", "* ", "• "] where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count))
        }
        return nil
    }

    private static func numberedItem(from line: String) -> (number: Int, text: String)? {
        guard let dot = line.firstIndex(of: ".") else { return nil }
        let number = line[..<dot]
        guard !number.isEmpty, number.count <= 9,
              number.allSatisfy(\.isNumber), let start = Int(number) else { return nil }
        let remainder = line[line.index(after: dot)...]
        guard remainder.first == " " else { return nil }
        return (start, remainder.trimmingCharacters(in: .whitespaces))
    }

    private static func isDivider(_ line: String) -> Bool {
        line == "---" || line == "***" || line == "___"
    }

    private static func completeSingleLineMath(_ line: String) -> String? {
        for (opening, closing) in [("$$", "$$"), (#"\["#, #"\]"#), (#"\("#, #"\)"#)] {
            guard line.hasPrefix(opening), line.hasSuffix(closing),
                  line.count > opening.count + closing.count else { continue }
            let start = line.index(line.startIndex, offsetBy: opening.count)
            let end = line.index(line.endIndex, offsetBy: -closing.count)
            let expression = line[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            return expression.isEmpty ? nil : expression
        }
        return nil
    }

    private static func delimitedMathBlock(
        in lines: [String],
        startingAt startIndex: Int
    ) -> (leading: String?, expression: String, trailing: String?, nextIndex: Int)? {
        let openingLine = lines[startIndex].trimmingCharacters(in: .whitespaces)
        let delimiters = [("$$", "$$"), (#"\["#, #"\]"#)]
        guard let (opening, closing) = delimiters.first(where: {
            openingLine.range(of: $0.0) != nil
        }) else {
            return nil
        }

        var pieces: [String] = []
        let openingRange = openingLine.range(of: opening)!
        let leading = String(openingLine[..<openingRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let firstContent = String(openingLine[openingRange.upperBound...])
        if let closingRange = firstContent.range(of: closing) {
            pieces.append(String(firstContent[..<closingRange.lowerBound]))
            let trailing = String(firstContent[closingRange.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let expression = pieces.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !expression.isEmpty else { return nil }
            return (
                leading.isEmpty ? nil : leading,
                expression,
                trailing.isEmpty ? nil : trailing,
                startIndex + 1
            )
        }
        pieces.append(firstContent)

        var cursor = startIndex + 1
        while cursor < lines.count {
            let candidate = lines[cursor]
            if let closingRange = candidate.range(of: closing) {
                pieces.append(String(candidate[..<closingRange.lowerBound]))
                let trailing = String(candidate[closingRange.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let expression = pieces.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !expression.isEmpty else { return nil }
                return (
                    leading.isEmpty ? nil : leading,
                    expression,
                    trailing.isEmpty ? nil : trailing,
                    cursor + 1
                )
            }
            pieces.append(candidate)
            cursor += 1
        }
        // A streamed answer may reach this parser after the opening delimiter
        // but before the matching close.  Rendering that partial LaTeX causes
        // MathML error text to flash in the conversation.  Keep it as ordinary
        // response text until the model has emitted a complete display block.
        return nil
    }

    private static func normalizedDisplayMath(_ source: String) -> String {
        source
            .replacingOccurrences(of: #";\Longleftrightarrow;"#, with: #"\;\Longleftrightarrow\;"#)
            .replacingOccurrences(of: #";\Rightarrow;"#, with: #"\;\Rightarrow\;"#)
            .replacingOccurrences(of: #";\Leftarrow;"#, with: #"\;\Leftarrow\;"#)
            .replacingOccurrences(of: "$$", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func incompleteDisplayMathOpening(in source: String) -> Range<String.Index>? {
        let candidates = [
            lastUnpairedDelimiter(in: source, delimiter: "$$"),
            lastUnclosedDelimiter(in: source, opening: #"\["#, closing: #"\]"#)
        ]
        return candidates
            .compactMap { $0 }
            .max { $0.lowerBound < $1.lowerBound }
    }

    private static func lastUnpairedDelimiter(
        in source: String,
        delimiter: String
    ) -> Range<String.Index>? {
        var cursor = source.startIndex
        var unmatched: Range<String.Index>?

        while let range = source.range(of: delimiter, range: cursor..<source.endIndex) {
            unmatched = unmatched == nil ? range : nil
            cursor = range.upperBound
        }
        return unmatched
    }

    private static func lastUnclosedDelimiter(
        in source: String,
        opening: String,
        closing: String
    ) -> Range<String.Index>? {
        var cursor = source.startIndex
        var unmatched: Range<String.Index>?

        while cursor < source.endIndex {
            let nextOpening = source.range(of: opening, range: cursor..<source.endIndex)
            let nextClosing = source.range(of: closing, range: cursor..<source.endIndex)

            switch (nextOpening, nextClosing) {
            case let (openingRange?, closingRange?) where openingRange.lowerBound < closingRange.lowerBound:
                unmatched = openingRange
                cursor = openingRange.upperBound
            case let (_, closingRange?):
                unmatched = nil
                cursor = closingRange.upperBound
            case let (openingRange?, nil):
                unmatched = openingRange
                cursor = openingRange.upperBound
            case (nil, nil):
                cursor = source.endIndex
            }
        }
        return unmatched
    }

    private static func bareMathLine(_ line: String) -> String? {
        guard !line.isEmpty, line.utf8.count <= 4_000,
              line.range(of: #"\p{Han}"#, options: .regularExpression) == nil,
              !startsUnclosedDisplayMath(line) else {
            return nil
        }
        let hasEquationStructure = line.contains("=")
            && (line.contains("^") || line.contains("_") || line.contains("\\")
                || line.contains("+") || line.contains("−") || line.contains("-"))
        guard hasEquationStructure else { return nil }
        return line
    }

    private static func startsUnclosedDisplayMath(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("$$") || trimmed.contains(#"\["#)
    }

    private static func mathClosingDelimiter(for line: String) -> String? {
        switch line {
        case "$$": return "$$"
        case #"\["#: return #"\]"#
        default: return nil
        }
    }
}
