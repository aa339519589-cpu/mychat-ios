import SwiftUI
import WebKit

struct RichRendererPreview: View {
    private let fullSample = """
    ## 原生富文本测试

    这是 **加粗正文**、`inline code` 和行内公式：\\(a^2+b^2=c^2\\)

    $$
    \\int_{-\\infty}^{\\infty} e^{-x^2}\\,dx=\\sqrt{\\pi}
    $$

    | 能力 | 状态 |
    | --- | --- |
    | Markdown | 正常 |
    | LaTeX | 正常 |
    | 流式图形 | 正常 |

    ```swift
    let greeting = "Hello, MyChat"
    ```

    <inline-artifact>
    <svg viewBox="0 0 320 120" xmlns="http://www.w3.org/2000/svg">
      <rect x="8" y="8" width="304" height="104" rx="16" fill="#F2F2F0"/>
      <path d="M35 84 L105 42 L168 75 L278 28" fill="none" stroke="#171614" stroke-width="5"/>
      <circle cx="278" cy="28" r="7" fill="#171614"/>
    </svg>
    </inline-artifact>

    <mermaid>
    graph LR
      A[发送] --> B[任务入库]
      B --> C[Worker]
      C --> D[流式回复]
    </mermaid>

    <vega>
    {
      "$schema": "https://vega.github.io/schema/vega-lite/v5.json",
      "data": {"values": [
        {"能力": "文本", "完成度": 100},
        {"能力": "数学", "完成度": 100},
        {"能力": "图表", "完成度": 100}
      ]},
      "mark": {"type": "bar", "cornerRadiusEnd": 4},
      "encoding": {
        "x": {"field": "能力", "type": "nominal", "axis": {"title": null}},
        "y": {"field": "完成度", "type": "quantitative", "axis": {"title": null}},
        "color": {"value": "#52677f"}
      },
      "height": 180
    }
    </vega>

    <function-plot>
    {
      "xAxis": {"domain": [-6.3, 6.3]},
      "yAxis": {"domain": [-1.5, 1.5]},
      "data": [{"fn": "sin(x)", "color": "#52677f"}]
    }
    </function-plot>

    <artifact>
      <h2>Artifact 预览</h2>
      <p>安全、可展开、可持续更新的原生容器。</p>
      <button style="padding:10px 14px;border-radius:10px;border:1px solid #aaa">交互按钮</button>
    </artifact>
    """

    private let chartsSample = """
    ## 图表与 Artifact 测试

    <vega>
    {
      "$schema": "https://vega.github.io/schema/vega-lite/v5.json",
      "data": {"values": [
        {"能力": "文本", "完成度": 100},
        {"能力": "数学", "完成度": 100},
        {"能力": "图表", "完成度": 100}
      ]},
      "mark": {"type": "bar", "cornerRadiusEnd": 4},
      "encoding": {
        "x": {"field": "能力", "type": "nominal", "axis": {"title": null}},
        "y": {"field": "完成度", "type": "quantitative", "axis": {"title": null}},
        "color": {"value": "#52677f"}
      },
      "height": 180
    }
    </vega>

    <function-plot>
    {
      "xAxis": {"domain": [-6.3, 6.3]},
      "yAxis": {"domain": [-1.5, 1.5]},
      "data": [{"fn": "sin(x)", "color": "#52677f"}]
    }
    </function-plot>

    <artifact>
      <h2>Artifact 预览</h2>
      <p>安全、可展开、可持续更新的原生容器。</p>
      <button style="padding:10px 14px;border-radius:10px;border:1px solid #aaa">交互按钮</button>
    </artifact>
    """

    private var sample: String {
        ProcessInfo.processInfo.arguments.contains("-RichRendererChartsPreview")
            || ProcessInfo.processInfo.arguments.contains("-RichRendererArtifactPreview")
            ? chartsSample
            : fullSample
    }

    var body: some View {
        ZStack {
            AppPalette.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("均衡")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity)
                    RichAssistantContent(text: sample)
                }
                .padding(18)
            }
        }
    }
}

@MainActor
private enum RichRendererRuntime {
    static let dataStore = WKWebsiteDataStore.nonPersistent()

    static func configure(_ configuration: WKWebViewConfiguration) {
        configuration.websiteDataStore = dataStore
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    }

    static func assetLocations() -> (renderer: URL, directory: URL)? {
        guard let directory = Bundle.main.resourceURL?
            .appending(path: "WebAssets", directoryHint: .isDirectory) else {
            return nil
        }
        return (
            directory.appending(path: "renderer.html", directoryHint: .notDirectory),
            directory
        )
    }
}

@MainActor
final class RichRendererPrewarmer: NSObject, WKNavigationDelegate {
    static let shared = RichRendererPrewarmer()
    private var webView: WKWebView?

    func prepare() {
        guard webView == nil else { return }
        let configuration = WKWebViewConfiguration()
        RichRendererRuntime.configure(configuration)
        let renderer = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        renderer.navigationDelegate = self
        renderer.isOpaque = false
        renderer.isHidden = true
        webView = renderer

        if let assets = RichRendererRuntime.assetLocations() {
            renderer.loadFileURL(assets.renderer, allowingReadAccessTo: assets.directory)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript(
            "void renderMessage('MyChat \\\\(x^2\\\\)').catch(function(){});"
        )
    }
}

struct RichAssistantContent: View {
    let text: String
    let isStreaming: Bool
    @State private var retainedStreamingRenderer = false

    init(text: String, isStreaming: Bool = false) {
        self.text = text
        self.isStreaming = isStreaming
    }

    var body: some View {
        Group {
            if isStreaming || retainedStreamingRenderer || needsRichRenderer {
                RichMessageWebView(content: text)
            } else {
                Text(text)
                    .font(.system(size: 17))
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .foregroundStyle(AppPalette.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            if isStreaming { retainedStreamingRenderer = true }
        }
        .onChange(of: isStreaming) { _, value in
            if value { retainedStreamingRenderer = true }
        }
    }

    private var needsRichRenderer: Bool {
        let markers = [
            "**", "__", "~~", "`", "$", "\\(", "\\[", "# ", "## ", "- ", "* ", "> ",
            "<vega>", "<mermaid>", "<function-plot>", "<inline-artifact>", "<artifact>",
        ]
        return markers.contains(where: text.contains)
            || text.range(of: #"(?m)^\d+\.\s"#, options: .regularExpression) != nil
            || text.contains("|")
    }
}

struct NativeThinkingIndicator: View {
    var body: some View {
        HStack(spacing: 8) {
            ThreeBodyLoader()
                .frame(width: 20, height: 20)
            Text("Thinking")
                .font(.system(size: 16))
                .foregroundStyle(AppPalette.secondaryText)
        }
        .frame(minHeight: 24)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("模型正在思考")
    }
}

private struct ThreeBodyLoader: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let spin = t / 2 * .pi * 2
                let radius = min(size.width, size.height) * 0.27
                let dotRadius = min(size.width, size.height) * 0.145

                for index in 0..<3 {
                    let baseAngle = (-CGFloat.pi / 2) + CGFloat(index) * (.pi * 2 / 3)
                    let wobblePhase = t / 0.8 * .pi * 2 - Double(index) * 0.95
                    let wobble = CGFloat((sin(wobblePhase) + 1) / 2)
                    let scale = 1 - 0.35 * wobble
                    let direction: CGFloat = index == 2 ? 1 : -1
                    let travel = direction * radius * 0.24 * wobble
                    let angle = baseAngle + CGFloat(spin)
                    let point = CGPoint(
                        x: center.x + cos(angle) * (radius + travel),
                        y: center.y + sin(angle) * (radius + travel)
                    )
                    let r = dotRadius * scale
                    context.fill(
                        Path(ellipseIn: CGRect(
                            x: point.x - r,
                            y: point.y - r,
                            width: r * 2,
                            height: r * 2
                        )),
                        with: .color(
                            AppPalette.thinking.opacity(0.8 + 0.2 * Double(1 - wobble))
                        )
                    )
                }
            }
        }
    }
}

private struct RichMessageWebView: View {
    let content: String
    @State private var contentHeight: CGFloat = 32

    var body: some View {
        GeometryReader { geometry in
            RichMessageRepresentable(content: content, contentHeight: $contentHeight)
                .frame(width: geometry.size.width, height: contentHeight)
        }
        .frame(height: contentHeight)
    }
}

private struct RichMessageRepresentable: UIViewRepresentable {
    let content: String
    @Binding var contentHeight: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(height: $contentHeight)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        RichRendererRuntime.configure(configuration)
        configuration.userContentController.add(context.coordinator, name: "height")
        configuration.userContentController.add(context.coordinator, name: "copy")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsLinkPreview = false
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.backgroundColor = .clear
        webView.isOpaque = false
        webView.isAccessibilityElement = false
        webView.backgroundColor = .clear
        webView.setContentHuggingPriority(.required, for: .vertical)
        context.coordinator.webView = webView
        context.coordinator.pendingContent = content
        context.coordinator.pendingFontSize = UIFont.preferredFont(
            forTextStyle: .body,
            compatibleWith: webView.traitCollection
        ).pointSize

        if let assets = RichRendererRuntime.assetLocations() {
            webView.loadFileURL(assets.renderer, allowingReadAccessTo: assets.directory)
        } else {
            webView.loadHTMLString("<p>富文本资源不可用</p>", baseURL: nil)
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.scheduleFontSize(
            UIFont.preferredFont(
                forTextStyle: .body,
                compatibleWith: webView.traitCollection
            ).pointSize
        )
        context.coordinator.scheduleRender(content)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.renderWorkItem?.cancel()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "height")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "copy")
        webView.stopLoading()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var height: Binding<CGFloat>
        weak var webView: WKWebView?
        var ready = false
        var pendingContent = ""
        var renderedContent = ""
        var pendingFontSize: CGFloat = 17
        var renderedFontSize: CGFloat = 0
        var renderWorkItem: DispatchWorkItem?

        init(height: Binding<CGFloat>) {
            self.height = height
        }

        func scheduleRender(_ content: String) {
            pendingContent = content
            guard ready, content != renderedContent, renderWorkItem == nil else { return }
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.renderWorkItem = nil
                self.renderPendingContent()
            }
            renderWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: item)
        }

        func scheduleFontSize(_ value: CGFloat) {
            pendingFontSize = value
            guard ready, abs(value - renderedFontSize) > 0.1, let webView else { return }
            renderedFontSize = value
            webView.evaluateJavaScript("setBodyFontSize(\(Double(value)))")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            scheduleFontSize(pendingFontSize)
            renderPendingContent()
            if ProcessInfo.processInfo.arguments.contains("-RichRendererArtifactPreview") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    webView.evaluateJavaScript(
                        "document.querySelector('.artifact-button')?.click();"
                    )
                }
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url,
                  ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else {
                decisionHandler(.allow)
                return
            }
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            switch message.name {
            case "copy":
                guard let value = message.body as? String, value.utf8.count <= 1_000_000 else {
                    return
                }
                UIPasteboard.general.string = value
            case "height":
                guard let value = message.body as? Double, value.isFinite else { return }
                let next = min(max(CGFloat(value), 24), 30_000)
                if abs(height.wrappedValue - next) > 0.5 {
                    height.wrappedValue = next
                }
            default:
                break
            }
        }

        private func renderPendingContent() {
            guard ready, pendingContent != renderedContent, let webView else { return }
            renderedContent = pendingContent
            let encoded: String
            do {
                let data = try JSONEncoder().encode(pendingContent)
                encoded = String(decoding: data, as: UTF8.self)
            } catch {
                return
            }
            let command =
                "void renderMessage(\(encoded)).catch(error => {" +
                "const target=document.getElementById('display')||document.getElementById('root');" +
                "target.textContent='内容显示失败：'+(error&&error.message?error.message:'格式无效');" +
                "reportHeight();" +
                "});"
            webView.evaluateJavaScript(command) { [weak self, weak webView] _, error in
                guard error != nil else { return }
                self?.renderedContent = ""
                webView?.evaluateJavaScript(
                    "const target=document.getElementById('display')||document.body;" +
                    "target.textContent='富文本引擎加载失败';" +
                    "webkit.messageHandlers.height.postMessage(44);"
                )
            }
        }
    }
}
