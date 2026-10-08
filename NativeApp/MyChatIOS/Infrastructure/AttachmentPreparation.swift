import Foundation
import PDFKit
import UIKit

enum AttachmentPreparationError: LocalizedError, Equatable, Sendable {
    case invalidImage
    case imageTooLarge
    case fileTooLarge
    case unsupportedFile(String)
    case unreadableFile
    case pdfTooLong

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "无法读取这张图片"
        case .imageTooLarge:
            return "图片压缩后仍然过大，请选择尺寸更小的图片"
        case .fileTooLarge:
            return "文件过大，单个文件不能超过 20 MB"
        case let .unsupportedFile(extensionName):
            return "暂不支持 \(extensionName) 文件，请上传 PDF 或文本文件"
        case .unreadableFile:
            return "无法读取这个文件"
        case .pdfTooLong:
            return "扫描 PDF 最多支持 18 页"
        }
    }
}

enum AttachmentPreparation {
    private static let maximumRawBytes = 20 * 1_024 * 1_024
    private static let maximumImageCharacters = 8_000_000
    private static let maximumTextCharacters = 80_000
    private static let maximumScanPages = 18
    private static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "csv", "json", "log", "xml", "yaml", "yml",
        "html", "htm", "css", "js", "ts", "tsx", "jsx", "py", "java", "c",
        "cpp", "h", "go", "rs", "rb", "php", "sh", "sql", "ini", "conf", "toml",
    ]

    static func prepareImage(data: Data, name: String) throws -> ChatPendingAttachment {
        guard data.count <= maximumRawBytes, let source = UIImage(data: data) else {
            throw data.count > maximumRawBytes
                ? AttachmentPreparationError.fileTooLarge
                : AttachmentPreparationError.invalidImage
        }

        let resized = resizedImage(source, maximumDimension: 2_048)
        guard let encoded = resized.jpegData(compressionQuality: 0.82) else {
            throw AttachmentPreparationError.invalidImage
        }
        let dataURL = "data:image/jpeg;base64,\(encoded.base64EncodedString())"
        guard dataURL.count <= maximumImageCharacters else {
            throw AttachmentPreparationError.imageTooLarge
        }
        return ChatPendingAttachment(
            kind: .image,
            name: sanitizedName(name, fallback: "照片.jpg"),
            imageDataURL: dataURL
        )
    }

    static func prepareFile(data: Data, name: String, mimeType: String?) throws -> ChatPendingAttachment {
        guard data.count <= maximumRawBytes else { throw AttachmentPreparationError.fileTooLarge }
        let safeName = sanitizedName(name, fallback: "附件")
        let fileExtension = (safeName as NSString).pathExtension.lowercased()
        let isPDF = mimeType == "application/pdf" || fileExtension == "pdf"
        if isPDF {
            var prepared = try preparePDF(data: data, name: safeName)
            prepared.preview = try ChatFilePreview.save(data: data, name: safeName, contentType: "application/pdf")
            return prepared
        }
        guard mimeType?.hasPrefix("text/") == true || textExtensions.contains(fileExtension) else {
            throw AttachmentPreparationError.unsupportedFile(fileExtension.isEmpty ? "该类型" : fileExtension.uppercased())
        }
        guard let decoded = decodeText(data) else { throw AttachmentPreparationError.unreadableFile }
        let text = String(decoded.prefix(maximumTextCharacters))
        var prepared = ChatPendingAttachment(
            kind: .textFile,
            name: safeName,
            file: ChatFileAttachment(
                name: safeName,
                dataURL: "",
                isPDF: false,
                text: text,
                pageImages: nil
            )
        )
        prepared.preview = try ChatFilePreview.save(data: data, name: safeName, contentType: mimeType ?? "text/plain")
        return prepared
    }

    private static func preparePDF(data: Data, name: String) throws -> ChatPendingAttachment {
        guard let document = PDFDocument(data: data) else {
            throw AttachmentPreparationError.unreadableFile
        }
        var pages: [String] = []
        pages.reserveCapacity(document.pageCount)
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let value = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !value.isEmpty { pages.append(value) }
        }

        if !pages.isEmpty {
            return ChatPendingAttachment(
                kind: .pdf,
                name: name,
                file: ChatFileAttachment(
                    name: name,
                    dataURL: "",
                    isPDF: true,
                    text: String(pages.joined(separator: "\n\n").prefix(maximumTextCharacters)),
                    pageImages: nil
                )
            )
        }

        guard document.pageCount <= maximumScanPages else {
            throw AttachmentPreparationError.pdfTooLong
        }
        var pageImages: [String] = []
        pageImages.reserveCapacity(document.pageCount)
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let maximumDimension: CGFloat = 1_400
            let scale = min(maximumDimension / max(bounds.width, bounds.height), 1.5)
            let size = CGSize(
                width: max(1, bounds.width * scale),
                height: max(1, bounds.height * scale)
            )
            let image = page.thumbnail(of: size, for: .mediaBox)
            guard let encoded = image.jpegData(compressionQuality: 0.72) else {
                throw AttachmentPreparationError.unreadableFile
            }
            let dataURL = "data:image/jpeg;base64,\(encoded.base64EncodedString())"
            guard dataURL.count <= maximumImageCharacters else {
                throw AttachmentPreparationError.imageTooLarge
            }
            pageImages.append(dataURL)
        }
        return ChatPendingAttachment(
            kind: .pdf,
            name: name,
            file: ChatFileAttachment(
                name: name,
                dataURL: "",
                isPDF: true,
                text: "（扫描件，识别中…）",
                pageImages: pageImages
            )
        )
    }

    private static func resizedImage(_ source: UIImage, maximumDimension: CGFloat) -> UIImage {
        let longest = max(source.size.width, source.size.height)
        guard longest > maximumDimension else { return source }
        let ratio = maximumDimension / longest
        let target = CGSize(width: source.size.width * ratio, height: source.size.height * ratio)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: target))
            source.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    private static func decodeText(_ data: Data) -> String? {
        for encoding in [String.Encoding.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian, .isoLatin1] {
            if let value = String(data: data, encoding: encoding) { return value }
        }
        return nil
    }

    private static func sanitizedName(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let bounded = String(trimmed.prefix(255))
        return bounded.isEmpty ? fallback : bounded
    }
}
