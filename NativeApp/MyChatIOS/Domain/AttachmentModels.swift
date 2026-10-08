import Foundation

enum ChatPendingAttachmentKind: String, Codable, Sendable {
    case image
    case textFile
    case pdf
}

struct ChatFileAttachment: Codable, Equatable, Sendable {
    let name: String
    let dataURL: String
    let isPDF: Bool
    let text: String?
    let pageImages: [String]?

    private enum CodingKeys: String, CodingKey {
        case name
        case dataURL = "dataUrl"
        case isPDF = "isPdf"
        case text
        case pageImages
    }
}

struct ChatPendingAttachment: Identifiable, Equatable, Sendable {
    let id: UUID
    let kind: ChatPendingAttachmentKind
    let name: String
    let imageDataURL: String?
    let file: ChatFileAttachment?
    var preview: ChatFilePreview? = nil

    init(
        id: UUID = UUID(),
        kind: ChatPendingAttachmentKind,
        name: String,
        imageDataURL: String? = nil,
        file: ChatFileAttachment? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.imageDataURL = imageDataURL
        self.file = file
    }
}

/// Local originals stay on this phone. The model request still carries the
/// extracted text/page images; presentation metadata does not change inference.
struct ChatFilePreview: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let contentType: String
    let byteCount: Int
    let relativePath: String
    var fileURL: URL? {
        let parts = relativePath.split(separator: "/")
        guard parts.count == 2, UUID(uuidString: String(parts[0])) == id,
              ![".", ".."].contains(String(parts[1])) else { return nil }
        let root = URL.documentsDirectory.appendingPathComponent("MyChatAttachments", isDirectory: true)
        let url = root.appendingPathComponent(relativePath).standardizedFileURL
        guard url.path.hasPrefix(root.path + "/"), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
    var typeLabel: String { (name as NSString).pathExtension.uppercased().isEmpty ? "FILE" : (name as NSString).pathExtension.uppercased() }
    var sizeLabel: String { ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file) }
    static func save(data: Data, name: String, contentType: String) throws -> ChatFilePreview {
        let id = UUID()
        let root = URL.documentsDirectory.appendingPathComponent("MyChatAttachments", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileName = URL(fileURLWithPath: name).lastPathComponent
        let safeName = fileName.isEmpty || fileName == "." || fileName == ".." ? "Attachment" : fileName
        let file = root.appendingPathComponent(safeName)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
        return ChatFilePreview(id: id, name: safeName, contentType: contentType, byteCount: data.count,
            relativePath: id.uuidString + "/" + safeName)
    }
}
