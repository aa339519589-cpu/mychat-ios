import SwiftUI
import UIKit
import WebKit

/// Feed the browser complete tokens while the source is growing. Appending a
/// synthetic closing SVG tag to a half-written attribute produces a different
/// DOM and can erase shapes which were already visible in the previous frame.
enum StreamingArtifactSource {
    static func renderableHTML(_ source: String, streaming: Bool) -> String {
        guard streaming else { return source }
        var tagStart: String.Index?
        var quote: Character?
        var comment = false
        var index = source.startIndex
        while index < source.endIndex {
            let character = source[index]
            if comment {
                if source[index...].hasPrefix("-->") {
                    index = source.index(index, offsetBy: 3)
                    comment = false
                    tagStart = nil
                    continue
                }
            } else if tagStart != nil {
                if let activeQuote = quote {
                    if character == activeQuote { quote = nil }
                } else if character == "\"" || character == "'" {
                    quote = character
                } else if character == ">" {
                    tagStart = nil
                }
            } else if character == "<" {
                tagStart = index
                comment = source[index...].hasPrefix("<!--")
            }
            index = source.index(after: index)
        }
        var result = tagStart.map { String(source[..<$0]) } ?? source
        // A stylesheet is atomic: publishing a half-written CSS rule changes
        // layout across the whole drawing. Existing CSS stays until it closes.
        if let opening = result.range(of: "<style", options: [.caseInsensitive, .backwards]),
           result.range(of: "</style>", options: .caseInsensitive, range: opening.lowerBound..<result.endIndex) == nil {
            result = String(result[..<opening.lowerBound])
        }
        return result
    }
}

struct ArtifactSandboxView: UIViewRepresentable {
    let rawHTML: String
    let colorScheme: ColorScheme
    var isStreaming = false
    var inline = false
    var reduceMotion = UIAccessibility.isReduceMotionEnabled

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        makeWebView(coordinator: context.coordinator)
    }

    func makeWebView(coordinator: Coordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.scrollView.isScrollEnabled = !isStreaming
        view.allowsLinkPreview = false
        view.isInspectable = false
        coordinator.update(self, in: view)
        // Load only the trusted shell. Model-produced content never becomes a
        // document navigation, and page JavaScript remains disabled.
        view.loadHTMLString(Self.shell, baseURL: nil)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        view.scrollView.isScrollEnabled = !isStreaming
        context.coordinator.update(self, in: view)
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading()
        view.navigationDelegate = nil
    }

    private static let shell = #"""
    <!doctype html><html><head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; connect-src 'none'; frame-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'; img-src data: blob:; media-src data: blob:; style-src 'unsafe-inline'">
    <style id="artifact-head-styles"></style>
    <style>
    :root { color-scheme: light dark; }
    * { box-sizing: border-box; max-width: 100%; }
    html,body { margin:0; padding:0; background:transparent; color:var(--foreground); }
    body { padding:20px; font:-apple-system-body; line-height:1.55; overflow-wrap:anywhere; }
    img,video,canvas { height:auto; }
    svg { display:block; width:100%; height:auto; }
    pre,code { font-family:ui-monospace,SFMono-Regular,Menlo,monospace; }
    pre { overflow-x:auto; padding:14px; border:1px solid var(--border); border-radius:14px; }
    table { width:100%; border-collapse:collapse; }
    th,td { padding:8px; border:1px solid var(--border); text-align:left; }
    a { color:inherit; text-decoration:underline; }
    </style></head><body><main id="artifact"></main></body></html>
    """#

    final class Coordinator: NSObject, WKNavigationDelegate {
        private var pending: ArtifactSandboxView?
        private var signature: String?
        private var ready = false
        private var applying = false

        func update(_ parent: ArtifactSandboxView, in view: WKWebView) {
            pending = parent
            applyLatest(in: view)
        }

        func webView(_ view: WKWebView, didFinish navigation: WKNavigation?) {
            ready = true
            applyLatest(in: view)
        }

        private func applyLatest(in view: WKWebView) {
            guard ready, !applying, let parent = pending else { return }
            let source = StreamingArtifactSource.renderableHTML(parent.rawHTML, streaming: parent.isStreaming)
            let nextSignature = "\(parent.colorScheme)-\(parent.isStreaming)-\(parent.inline)-\(parent.reduceMotion)-\(source)"
            guard signature != nextSignature else { return }
            applying = true
            let encoded = Data(source.utf8).base64EncodedString()
            let foreground = parent.colorScheme == .dark ? "#f1f0ea" : "#20201e"
            let border = parent.colorScheme == .dark ? "#3c3c38" : "#deded8"
            let script = #"""
            (() => {
              const bytes = Uint8Array.from(atob('\#(encoded)'), c => c.charCodeAt(0));
              const source = new TextDecoder().decode(bytes);
              const parsed = new DOMParser().parseFromString(source, 'text/html');
              // Defense in depth: page JS is disabled and the CSP denies network
              // access. Strip active content before reconciling the trusted DOM.
              parsed.querySelectorAll('script,iframe,frame,frameset,object,embed,form,input,button,textarea,select,meta,link,base').forEach(n => n.remove());
              parsed.querySelectorAll('*').forEach(n => {
                for (const a of [...n.attributes]) {
                  if (/^on/i.test(a.name) || a.name === 'srcdoc' ||
                      (/^(href|xlink:href|src|action|formaction)$/i.test(a.name) && /^\s*(javascript|vbscript):/i.test(a.value))) n.removeAttribute(a.name);
                }
              });
              const streaming = \#(parent.isStreaming ? "true" : "false");
              const animateAdditions = streaming && \#(parent.reduceMotion ? "false" : "true");
              function insert(fresh, target, old) {
                const node = document.importNode(fresh, true);
                if (old) target.replaceChild(node, old); else target.appendChild(node);
                // Only newly drawn elements fade in; the canvas and existing
                // SVG nodes never reload, crossfade, or restart their animation.
                if (animateAdditions && node.nodeType === Node.ELEMENT_NODE && node.animate)
                  node.animate([{opacity: 0}, {opacity: 1}], {duration: 120, easing: 'ease-out'});
              }
              function reconcile(target, incoming) {
                const desired = [...incoming.childNodes];
                for (let i = 0; i < desired.length; i++) {
                  const fresh = desired[i];
                  let old = target.childNodes[i];
                  if (!old) { insert(fresh, target); continue; }
                  if (old.nodeType !== fresh.nodeType || old.nodeName !== fresh.nodeName) {
                    insert(fresh, target, old); continue;
                  }
                  if (old.nodeType === Node.TEXT_NODE || old.nodeType === Node.COMMENT_NODE) {
                    if (old.nodeValue !== fresh.nodeValue) old.nodeValue = fresh.nodeValue;
                  } else if (old.nodeType === Node.ELEMENT_NODE) {
                    if (!streaming) for (const a of [...old.attributes]) if (!fresh.hasAttribute(a.name)) old.removeAttribute(a.name);
                    for (const a of [...fresh.attributes]) if (old.getAttribute(a.name) !== a.value) old.setAttribute(a.name, a.value);
                    reconcile(old, fresh);
                  }
                }
                // An unfinished streamed tag can temporarily disappear from the
                // parser's DOM. Keep already drawn nodes until the final frame.
                if (!streaming) while (target.childNodes.length > desired.length) target.lastChild.remove();
              }
              const root = document.getElementById('artifact');
              if (!root) return false;
              document.documentElement.style.setProperty('--foreground', '\#(foreground)');
              document.documentElement.style.setProperty('--border', '\#(border)');
              document.documentElement.style.colorScheme = '\#(parent.colorScheme == .dark ? "dark" : "light")';
              document.body.style.padding = '\#(parent.inline ? "0" : "20px")';
              const style = document.getElementById('artifact-head-styles');
              const css = [...parsed.head.querySelectorAll('style')].map(n => n.textContent).join('\n');
              if ((!streaming || css.length > 0) && style.textContent !== css) style.textContent = css;
              reconcile(root, parsed.body);
              return true;
            })()
            """#
            // This is app-owned code in an isolated world, not model JS.
            view.evaluateJavaScript(script, in: nil, in: .defaultClient) { [weak self, weak view] result in
                guard let self, let view else { return }
                self.applying = false
                switch result {
                case .success: self.signature = nextSignature
                case .failure: return
                }
                self.applyLatest(in: view)
            }
        }

        func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            if action.navigationType == .linkActivated, url.scheme == "https" || url.scheme == "http" {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(url.scheme == "about" ? .allow : .cancel)
        }
    }
}
