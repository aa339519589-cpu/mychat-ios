import Combine
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct ChatDocument: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let filename: String
    let content: String
    let isMarkdown: Bool
    var summary: String? = nil
    var typeLabel: String { "Document · " + (filename as NSString).pathExtension.uppercased() }
    static func from(_ block: ChatArtifactBlock) -> ChatDocument? {
        guard block.kind == .document || block.kind == .artifact else { return nil }
        if block.kind == .artifact {
            let title = ChatArtifactParser.title(for: block)
            return ChatDocument(id: block.id.uuidString, title: title, filename: safeFilename(title + ".html"), content: block.raw, isMarkdown: false)
        }
        var lines = block.raw.components(separatedBy: .newlines)
        var title: String?, filename: String?, summary: String?
        while let line = lines.first {
            if line.hasPrefix("title:") { title = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces); lines.removeFirst() }
            else if line.hasPrefix("summary:") { summary = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces); lines.removeFirst() }
            else if line.hasPrefix("filename:") { filename = String(line.dropFirst(9)).trimmingCharacters(in: .whitespaces); lines.removeFirst() }
            else if line.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
            else { break }
        }
        let content = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let heading = lines.first(where: { $0.hasPrefix("# ") }).map { String($0.dropFirst(2)) }
        let resolvedTitle = title.flatMap { $0.isEmpty ? nil : $0 } ?? heading ?? "Document"
        return ChatDocument(id: block.id.uuidString, title: resolvedTitle, filename: safeFilename(filename ?? resolvedTitle + ".md"), content: content, isMarkdown: true, summary: summary)
    }
    static func documents(in source: String, namespace: String) -> [ChatDocument] {
        ChatArtifactParser.parse(source).blocks.filter(\.isComplete).compactMap { block in
            guard let document = from(block) else { return nil }
            return ChatDocument(id: namespace + "-" + document.id, title: document.title,
                filename: document.filename, content: document.content,
                isMarkdown: document.isMarkdown, summary: document.summary)
        }
    }
    private static func safeFilename(_ proposed: String) -> String {
        let name = String(URL(fileURLWithPath: proposed).lastPathComponent.prefix(160))
        guard !name.isEmpty, name != ".", name != ".." else { return "Document.md" }
        return ["md", "markdown", "txt", "pdf", "html"].contains((name as NSString).pathExtension.lowercased()) ? name : name + ".md"
    }
    func downloadURL() throws -> URL {
        let directory = URL.temporaryDirectory.appendingPathComponent("MyChatDocuments", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(filename)
        let bytes = (filename as NSString).pathExtension.lowercased() == "pdf" ? Self.pdf(content: content) : Data(content.utf8)
        try bytes.write(to: file, options: .atomic)
        return file
    }
    private static func pdf(content: String) -> Data {
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)
        let text = NSAttributedString(string: PresentationText.plain(content), attributes: [
            .font: MyChatSystemFont.appUIFont(size: 14), .foregroundColor: UIColor.black,
            .paragraphStyle: { let p = NSMutableParagraphStyle(); p.lineSpacing = 5; p.paragraphSpacing = 10; return p }()
        ])
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager(); storage.addLayoutManager(layout)
        return UIGraphicsPDFRenderer(bounds: page).pdfData { context in
            var glyph = 0
            while glyph < layout.numberOfGlyphs {
                let container = NSTextContainer(size: CGSize(width: 507, height: 754)); container.lineFragmentPadding = 0
                layout.addTextContainer(container)
                let range = layout.glyphRange(for: container)
                guard range.length > 0 else { break }
                context.beginPage()
                layout.drawBackground(forGlyphRange: range, at: CGPoint(x: 44, y: 44))
                layout.drawGlyphs(forGlyphRange: range, at: CGPoint(x: 44, y: 44))
                glyph = NSMaxRange(range)
            }
        }
    }
}

struct DocumentGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 5, y: 2)); p.addLine(to: CGPoint(x: 14, y: 2)); p.addLine(to: CGPoint(x: 20, y: 8))
        p.addLine(to: CGPoint(x: 20, y: 22)); p.addLine(to: CGPoint(x: 5, y: 22)); p.closeSubpath()
        p.move(to: CGPoint(x: 14, y: 2)); p.addLine(to: CGPoint(x: 14, y: 8)); p.addLine(to: CGPoint(x: 20, y: 8))
        for y: CGFloat in [12, 16, 19] {
            p.move(to: CGPoint(x: 8, y: y)); p.addLine(to: CGPoint(x: 10, y: y - 1)); p.addLine(to: CGPoint(x: 12, y: y + 1))
            p.addLine(to: CGPoint(x: 14, y: y - 1)); p.addLine(to: CGPoint(x: 16, y: y))
        }
        return p.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24))
    }
}

struct DocumentThoughtRow: View {
    let summary: String?
    let reasoningSummary: String?
    let isGenerating: Bool
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() } } label: {
                HStack(spacing: 12) {
                    if isGenerating { ThinkingOrbitalIndicator() }
                    else { Image(systemName: "clock.arrow.circlepath").font(MyChatSystemFont.appFont(size: 19)).frame(width: 24) }
                    Text(summary ?? (isGenerating ? "Thinking…" : "Finished thinking"))
                        .font(MyChatTypography.navigation).lineLimit(1)
                    Image(systemName: "chevron.right").font(MyChatSystemFont.appFont(size: 16))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }.foregroundStyle(MyChatTheme.secondaryText).frame(minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("查看思考过程").accessibilityIdentifier("document.thinking")
            if expanded {
                Text(reasoningSummary ?? summary ?? "Preparing the response…")
                    .font(MyChatTypography.metadata).lineSpacing(5).foregroundStyle(MyChatTheme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                    .background(MyChatTheme.raised, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityIdentifier("document.thinking.content")
            }
        }
    }
}

struct GeneratedDocumentCard: View {
    let document: ChatDocument
    var complete = true
    @State private var modalID = UUID()
    @State private var opened = false
    var body: some View {
        Button {
            NativeDocumentModalActivity.set(modalID, active: true)
            opened = true
        } label: {
            VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 20) {
                DocumentGlyph().stroke(Color(red: 0.13, green: 0.35, blue: 0.56), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                    .frame(width: 22, height: 28)
                    .frame(width: 56, height: 78)
                    .background(Color(red: 0.89, green: 0.94, blue: 0.99), in: UnevenRoundedRectangle(topLeadingRadius: 9, topTrailingRadius: 9))
                    .overlay { UnevenRoundedRectangle(topLeadingRadius: 9, topTrailingRadius: 9).stroke(Color.blue.opacity(0.12), lineWidth: 0.5) }
                    .offset(y: 13)
                VStack(alignment: .leading, spacing: 3) {
                    Text(document.title).font(MyChatSystemFont.appFont(size: 18, weight: .regular)).lineLimit(1)
                    Text(complete ? document.typeLabel : "Writing document…").font(MyChatTypography.metadata).foregroundStyle(MyChatTheme.secondaryText)
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, minHeight: 70, maxHeight: 70, alignment: .leading)
            .background(MyChatTheme.canvas)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 16).stroke(MyChatTheme.border.opacity(0.75), lineWidth: 0.65) }
            }
        }
        .buttonStyle(.plain).disabled(!complete)
        .accessibilityLabel(document.title)
        .accessibilityIdentifier("document-card-" + document.id)
        .sheet(isPresented: $opened, onDismiss: { NativeDocumentModalActivity.set(modalID, active: false) }) {
            ChatDocumentPreview(document: document).presentationDetents([.large]).presentationCornerRadius(42).presentationBackground(MyChatTheme.canvas)
        }
    }
}

struct DocumentTextContent: View {
    let document: ChatDocument
    @State private var blocks: [MessageMarkdownBlock] = []
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    if case let .heading(level, title) = block {
                        Text(title).font(headingFont(title, level: level)).fixedSize(horizontal: false, vertical: true)
                    } else { MessageMarkdownBlockView(block: block, searches: [], thinking: false, paragraphLineSpacing: 6.5).equatable() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.top, 7).padding(.bottom, 30)
        }
        .task(id: document.content) {
            blocks = await Task.detached(priority: .userInitiated) {
                ChatPresentationCache.document(key: "document:" + document.id, source: document.content, streaming: false).blocks
            }.value
        }
    }
    private func headingFont(_ title: String, level: Int) -> Font {
        let size: CGFloat = level == 1 ? 24 : 20
        return title.range(of: #"\p{Han}"#, options: .regularExpression) != nil
            ? MyChatSystemFont.hanFont(size: size, strong: true)
            : MyChatSystemFont.appFont(size: size, weight: .semibold)
    }
}

struct ChatDocumentPreview: View {
    let document: ChatDocument
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var shareURLs: [URL] = []
    @State private var sharing = false
    @State private var exportError: String?
    @State private var exporting = false
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(document.title).font(MyChatTypography.navigation.weight(.semibold)).lineLimit(1).padding(.horizontal, 70)
                HStack {
                    Button { dismiss() } label: { Image(systemName: "xmark").font(MyChatSystemFont.appFont(size: 18, weight: .regular)) }
                        .buttonStyle(MyChatIconButtonStyle()).accessibilityLabel("关闭文件预览")
                    Spacer()
                    Menu {
                        Button("Download", systemImage: "arrow.down.to.line") { exportDocument() }
                        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = document.content }
                    } label: { Image(systemName: "ellipsis").font(MyChatSystemFont.appFont(size: 20, weight: .medium)) }
                    .buttonStyle(MyChatIconButtonStyle()).accessibilityLabel("文件操作")
                }
            }.padding(.horizontal, 20).padding(.top, 8).frame(height: 74)
            if document.isMarkdown { DocumentTextContent(document: document) }
            else { ArtifactSandboxView(rawHTML: document.content, colorScheme: colorScheme) }
        }
        .foregroundStyle(MyChatTheme.text).background(MyChatTheme.canvas)
        .sheet(isPresented: $sharing) { DocumentShareSheet(urls: shareURLs) }
        .alert("无法导出", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) { Button("好", role: .cancel) {} } message: { Text(exportError ?? "") }
    }
    private func exportDocument() {
        guard !exporting else { return }; exporting = true
        Task {
            defer { exporting = false }
            do { shareURLs = [try await Task.detached(priority: .userInitiated) { try document.downloadURL() }.value]; sharing = true }
            catch { exportError = error.localizedDescription }
        }
    }
}

private struct DocumentShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: urls, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct UploadedFileCard: View {
    let file: ChatFilePreview
    @State private var preview = false
    @State private var modalID = UUID()
    @State private var thumbnail: UIImage?
    var body: some View {
        Button { NativeDocumentModalActivity.set(modalID, active: true); preview = true } label: {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    MyChatTheme.selected
                    if let thumbnail { Image(uiImage: thumbnail).resizable().scaledToFit().padding(.horizontal, 13).padding(.top, 12) }
                    else { DocumentGlyph().stroke(MyChatTheme.secondaryText, lineWidth: 1.5).frame(width: 32, height: 42) }
                }.frame(height: 99).clipped()
                VStack(alignment: .leading, spacing: 3) {
                    Text((file.name as NSString).deletingPathExtension).font(MyChatSystemFont.appFont(size: 15, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Text(file.typeLabel + " · " + file.sizeLabel).font(MyChatTypography.caption).foregroundStyle(MyChatTheme.secondaryText)
                }.padding(.horizontal, 10).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading).background(MyChatTheme.raised)
            }
            .frame(width: 140, height: 140).clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).stroke(MyChatTheme.border.opacity(0.8), lineWidth: 0.6) }
        }.buttonStyle(.plain).accessibilityLabel("预览文件 " + file.name)
        .task(id: file.id) {
            let url = file.fileURL
            thumbnail = await Task.detached(priority: .userInitiated) {
                guard let url, file.contentType == "application/pdf", let document = PDFDocument(url: url), let first = document.page(at: 0) else { return nil as UIImage? }
                return first.thumbnail(of: CGSize(width: 342, height: 420), for: .mediaBox)
            }.value
        }
        .sheet(isPresented: $preview, onDismiss: { NativeDocumentModalActivity.set(modalID, active: false) }) { UploadedFilePreview(file: file).presentationDetents([.large]).presentationCornerRadius(42).presentationBackground(MyChatTheme.canvas) }
    }
}

private struct UploadedFilePreview: View {
    let file: ChatFilePreview
    @Environment(\.dismiss) private var dismiss
    @State private var text: String?
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(file.name).font(MyChatTypography.navigation.weight(.semibold)).lineLimit(1).padding(.horizontal, 70)
                HStack {
                    Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(MyChatIconButtonStyle()).accessibilityLabel("关闭文件预览")
                    Spacer()
                    if let url = file.fileURL { ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }.buttonStyle(MyChatIconButtonStyle()) }
                }
            }.padding(.horizontal, 20).frame(height: 62)
            if let url = file.fileURL, file.contentType == "application/pdf" { PDFDocumentSurface(url: url) }
            else if let text { DocumentTextContent(document: ChatDocument(id: file.id.uuidString, title: file.name, filename: file.name, content: text, isMarkdown: true)) }
            else if file.fileURL == nil { ContentUnavailableView("File unavailable", systemImage: "doc", description: Text("The original file is no longer on this phone.")) }
            else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.background(MyChatTheme.canvas).foregroundStyle(MyChatTheme.text)
        .task {
            guard file.contentType != "application/pdf", let url = file.fileURL else { return }
            text = await Task.detached(priority: .userInitiated) { (try? String(contentsOf: url, encoding: .utf8)) ?? "无法读取文件内容" }.value
        }
    }
}
private struct PDFDocumentSurface: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView(); view.autoScales = true; view.displayDirection = .vertical; view.displayMode = .singlePageContinuous
        view.backgroundColor = UIColor(MyChatTheme.canvas); view.document = PDFDocument(url: url); return view
    }
    func updateUIView(_ view: PDFView, context: Context) {}
}

@MainActor private final class ConversationFilesController: ObservableObject {
    @Published private(set) var documents: [ChatDocument] = []
    private var subscription: AnyCancellable?
    private var task: Task<Void, Never>?
    private var pending: [ChatMessage]?
    private var cache: [UUID: (source: String, documents: [ChatDocument])] = [:]
    init(_ model: AppModel) {
        subscription = model.$messages.sink { [weak self] messages in
            self?.pending = messages
            self?.schedule()
        }
    }
    private func schedule() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            while self.pending != nil {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled, let messages = self.pending else { break }
                self.pending = nil
                let existing = self.cache
                let result = await Task.detached(priority: .userInitiated) {
                    var updated = existing
                    let ids = Set(messages.map(\.id))
                    updated = updated.filter { ids.contains($0.key) }
                    for message in messages where message.role == .assistant {
                        guard message.completedReplyIsVisible else { updated[message.id] = nil; continue }
                        guard updated[message.id]?.source != message.content else { continue }
                        let docs = ChatDocument.documents(in: message.content, namespace: message.id.uuidString)
                        updated[message.id] = (message.content, docs)
                    }
                    return (updated, messages.flatMap { updated[$0.id]?.documents ?? [] })
                }.value
                self.cache = result.0
                if self.documents != result.1 { self.documents = result.1 }
            }
            self.task = nil
            if self.pending != nil { self.schedule() }
        }
    }
}

struct ConversationFilesButton: View {
    @StateObject private var files: ConversationFilesController
    @State private var opened = false
    @State private var modalID = UUID()
    init(appModel: AppModel) { _files = StateObject(wrappedValue: ConversationFilesController(appModel)) }
    var body: some View {
        if !files.documents.isEmpty {
            Button {
                NativeDocumentModalActivity.set(modalID, active: true); opened = true
            } label: { DocumentGlyph().stroke(MyChatTheme.text, style: StrokeStyle(lineWidth: 1.55, lineJoin: .round)).frame(width: 22, height: 26) }
            .buttonStyle(MyChatIconButtonStyle()).accessibilityLabel("对话文件")
            .sheet(isPresented: $opened, onDismiss: { NativeDocumentModalActivity.set(modalID, active: false) }) {
                ConversationFilesSheet(documents: files.documents).presentationDetents([.fraction(0.55), .large]).presentationDragIndicator(.visible).presentationCornerRadius(42).presentationBackground(MyChatTheme.canvas)
            }
        }
    }
}
struct ConversationFilesSheet: View {
    let documents: [ChatDocument]
    var showsHeader = true
    @Environment(\.dismiss) private var dismiss
    @State private var urls: [URL] = []
    @State private var sharing = false
    @State private var error: String?
    @State private var exporting = false
    var body: some View {
        VStack(spacing: 0) {
            if showsHeader { ZStack {
                Text("Files").font(MyChatTypography.navigation.weight(.semibold))
                HStack { Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(MyChatIconButtonStyle()).accessibilityLabel("关闭文件列表"); Spacer() }
            }.padding(.horizontal, 18).frame(height: 64) }
            ScrollView {
                LazyVStack(spacing: 12) { ForEach(documents) { GeneratedDocumentCard(document: $0) } }.padding(.horizontal, 16).padding(.top, 14)
            }
            Button {
                guard !exporting else { return }; exporting = true
                Task {
                    defer { exporting = false }
                    do { urls = try await Task.detached(priority: .userInitiated) { try documents.map { try $0.downloadURL() } }.value; sharing = true }
                    catch { self.error = error.localizedDescription }
                }
            } label: {
                Label("Download all", systemImage: "arrow.down.to.line").font(MyChatTypography.navigation.weight(.semibold))
                    .foregroundStyle(MyChatTheme.canvas).frame(maxWidth: .infinity).frame(height: 48).background(MyChatTheme.text, in: Capsule())
            }.buttonStyle(.plain).padding(.horizontal, 16).padding(.bottom, 16)
        }.background(MyChatTheme.canvas).foregroundStyle(MyChatTheme.text)
        .sheet(isPresented: $sharing) { DocumentShareSheet(urls: urls) }
        .alert("无法导出", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好", role: .cancel) {} } message: { Text(error ?? "") }
    }
}

@MainActor enum NativeDocumentModalActivity {
    private static var active = Set<UUID>()
    static func set(_ id: UUID, active presented: Bool) {
        let previouslyVisible = !active.isEmpty
        if presented { active.insert(id) } else { active.remove(id) }
        let visible = !active.isEmpty
        if previouslyVisible != visible { NotificationCenter.default.post(name: .myChatModalVisibilityChanged, object: visible) }
    }
}

// Shared native chat instructions also cover the user's direct ChatGPT plan.
enum NativeDocumentInstructions {
    static let prompt = """
    MyChat supports named, previewable Markdown/PDF documents. For a complete article, report, proposal or requested file, deliver the document directly and keep the chat acknowledgment short. Ordinary questions remain ordinary replies. Use:
    <document>
    title: Human-readable document title
    filename: document.md
    summary: Brief public task description in the user's language

    # Document title

    Complete Markdown content.
    </document>
    Use one tag per file, without a surrounding code fence. Default to .md; .pdf is exported as a real PDF by the client. Do not claim to have created unsupported binary formats.
    """
}
