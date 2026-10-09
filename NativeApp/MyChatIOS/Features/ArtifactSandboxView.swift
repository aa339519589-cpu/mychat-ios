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

/// Preparation is keyed only by source and streaming state. Presentation flags
/// remain part of the coordinator's applied signature, so appearance changes
/// still reach WebKit without rescanning an unchanged SVG.
struct ArtifactSourcePreparationCache {
    private struct Input: Equatable {
        let rawHTML: String
        let isStreaming: Bool
    }

    private var input: Input?
    private var renderedHTML = ""
    private(set) var preparationCount = 0

    mutating func prepare(rawHTML: String, isStreaming: Bool) -> String {
        let next = Input(rawHTML: rawHTML, isStreaming: isStreaming)
        guard input != next else { return renderedHTML }
        renderedHTML = StreamingArtifactSource.renderableHTML(rawHTML, streaming: isStreaming)
        input = next
        preparationCount &+= 1
        return renderedHTML
    }
}

struct ArtifactSandboxView: UIViewRepresentable {
    let rawHTML: String
    let colorScheme: ColorScheme
    var isStreaming = false
    var inline = false
    var reduceMotion = UIAccessibility.isReduceMotionEnabled
    var snapshot: ((UIImage?) -> Void)? = nil
    var contentHeight: ((CGFloat) -> Void)? = nil

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
        configuration.userContentController.add(coordinator, contentWorld: .defaultClient, name: "artifactContentHeight")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.scrollView.isScrollEnabled = true
        view.scrollView.bounces = false
        view.clipsToBounds = false
        view.allowsLinkPreview = false
        view.isInspectable = false
        coordinator.update(self, in: view)
        // Load only the trusted shell. Model-produced content never becomes a
        // document navigation, and page JavaScript remains disabled.
        view.loadHTMLString(Self.shell, baseURL: nil)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        view.scrollView.isScrollEnabled = true
        context.coordinator.update(self, in: view)
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading()
        view.navigationDelegate = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName: "artifactContentHeight", contentWorld: .defaultClient)
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
    svg { display:block; width:100%; height:auto; overflow:visible; }
    pre,code { font-family:ui-monospace,SFMono-Regular,Menlo,monospace; }
    pre { overflow-x:auto; padding:14px; border:1px solid var(--border); border-radius:14px; }
    table { width:100%; border-collapse:collapse; }
    th,td { padding:8px; border:1px solid var(--border); text-align:left; }
    a { color:inherit; text-decoration:underline; }
    </style></head><body><main id="artifact"></main></body></html>
    """#

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private struct RenderSignature: Equatable {
            let colorScheme: ColorScheme
            let isStreaming: Bool
            let inline: Bool
            let reduceMotion: Bool
            let source: String
        }

        private var pending: ArtifactSandboxView?
        private var signature: RenderSignature?
        private var sourceCache = ArtifactSourcePreparationCache()
        private var ready = false
        private var applying = false
        private var snapshotScheduled = false

        var sourcePreparationCount: Int { sourceCache.preparationCount }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "artifactContentHeight", let number = message.body as? NSNumber else { return }
            let height = CGFloat(truncating: number)
            guard height.isFinite, height > 0 else { return }
            pending?.contentHeight?(height)
        }

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
            let source = sourceCache.prepare(rawHTML: parent.rawHTML, isStreaming: parent.isStreaming)
            let nextSignature = RenderSignature(colorScheme: parent.colorScheme,
                isStreaming: parent.isStreaming, inline: parent.inline,
                reduceMotion: parent.reduceMotion, source: source)
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
                  // Stable SVG IDs survive a parser inserting a sibling before
                  // them; reusing nodes by position alone resets their timeline.
                  if (fresh.nodeType === Node.ELEMENT_NODE && fresh.id) {
                    const keyed = [...target.childNodes].find(n => n.nodeType === Node.ELEMENT_NODE && n.id === fresh.id && n.nodeName === fresh.nodeName);
                    if (keyed && keyed !== old) {
                      target.insertBefore(keyed, old || null);
                      old = keyed;
                    } else if (!keyed && old && old.nodeType === Node.ELEMENT_NODE && old.id && old.id !== fresh.id) {
                      target.insertBefore(document.importNode(fresh, true), old);
                      continue;
                    }
                  }
                  if (!old) { insert(fresh, target); continue; }
                  // Unkeyed siblings (including whitespace and SVG defs) must
                  // not replace an animated keyed node needed later in the patch.
                  if (old.nodeType === Node.ELEMENT_NODE && old.id &&
                      (fresh.nodeType !== Node.ELEMENT_NODE || fresh.id !== old.id) &&
                      desired.slice(i + 1).some(n => n.nodeType === Node.ELEMENT_NODE && n.id === old.id && n.nodeName === old.nodeName)) {
                    target.insertBefore(document.importNode(fresh, true), old);
                    continue;
                  }
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
              const reduceMotion = \#(parent.reduceMotion ? "true" : "false");
              root.querySelectorAll('svg').forEach(svg => {
                svg.style.setProperty('overflow', 'visible', 'important');
                if (reduceMotion && svg.pauseAnimations) svg.pauseAnimations();
                else if (svg.unpauseAnimations) svg.unpauseAnimations();
              });
              document.getAnimations().forEach(animation => {
                if (reduceMotion) animation.pause();
                else if (animation.playState === 'paused') animation.play();
              });
              // One app-owned delegate survives every incremental DOM update.
              if (!root.dataset.interactionReady) {
                root.dataset.interactionReady = 'true';
                root.addEventListener('click', event => {
                  const node = event.target.closest('[data-label]');
                  if (!node) return;
                  let label = document.getElementById('artifact-label');
                  if (!label) {
                    label = document.createElement('div'); label.id = 'artifact-label';
                    label.setAttribute('role', 'status');
                    label.style.cssText = 'position:fixed;left:12px;right:12px;bottom:12px;padding:10px 14px;border-radius:16px;background:color-mix(in srgb, Canvas 88%, transparent);border:1px solid var(--border);backdrop-filter:blur(14px);font:14px -apple-system;pointer-events:none;z-index:10';
                    document.body.appendChild(label);
                  }
                  label.textContent = node.getAttribute('data-label');
                });
              }
              // Observe painted SVG bounds, including animation, without
              // reloading nodes or resetting their timeline. Keep peak space
              // reserved so motion never makes the transcript pulse in height.
              if (!window.__mychatMeasureArtifact) {
                let insetTop = 0, insetBottom = 0, greatestHeight = 0, lastSample = 0;
                window.__mychatMeasureArtifact = () => {
                  const base = root.getBoundingClientRect();
                  let minY = 0, maxY = Math.max(0, base.height - insetTop - insetBottom);
                  for (const node of [...root.querySelectorAll('svg *')].slice(0, 4000)) {
                    const rect = node.getBoundingClientRect();
                    if (!rect.width && !rect.height) continue;
                    minY = Math.min(minY, rect.top - base.top - insetTop);
                    maxY = Math.max(maxY, rect.bottom - base.top - insetTop);
                  }
                  const naturalHeight = base.height - insetTop - insetBottom;
                  insetTop = Math.max(insetTop, minY < 0 ? -minY + 12 : 0);
                  insetBottom = Math.max(insetBottom, maxY > naturalHeight ? maxY - naturalHeight + 12 : 0);
                  root.style.paddingTop = insetTop + 'px';
                  root.style.paddingBottom = insetBottom + 'px';
                  const height = Math.ceil(document.body.scrollHeight);
                  if (Number.isFinite(height) && height > greatestHeight + 0.5) {
                    greatestHeight = height;
                    window.webkit.messageHandlers.artifactContentHeight.postMessage(height);
                  }
                };
                const sample = time => {
                  if (time - lastSample >= 60) { lastSample = time; window.__mychatMeasureArtifact(); }
                  requestAnimationFrame(sample);
                };
                requestAnimationFrame(sample);
              }
              window.__mychatMeasureArtifact();
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
                if let snapshot = parent.snapshot, !self.snapshotScheduled {
                    self.snapshotScheduled = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak view] in
                        guard let view else { snapshot(nil); return }
                        let config = WKSnapshotConfiguration()
                        config.rect = view.bounds
                        config.snapshotWidth = 240
                        view.takeSnapshot(with: config) { image, _ in snapshot(image) }
                    }
                }
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

/// Completed HTML applications need their own JavaScript. Keep that runtime in
/// an opaque-origin sandboxed frame, with no native bridge or network access.
/// The inline streaming renderer above continues to reconcile passive SVG/HTML
/// without reloading its DOM or restarting already-running SVG animations.
struct InteractiveArtifactView: UIViewRepresentable {
    let rawHTML: String
    let colorScheme: ColorScheme

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        makeWebView(coordinator: context.coordinator)
    }

    func makeWebView(coordinator: Coordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = coordinator
        view.uiDelegate = coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.allowsLinkPreview = false
        coordinator.update(self, in: view)
        view.loadHTMLString(Self.shell, baseURL: nil)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.update(self, in: view)
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
    }

    private static let shell = #"""
    <!doctype html><html><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; media-src data: blob:; font-src data:; frame-src about:; connect-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'">
    <style>html,body{margin:0;width:100%;height:100%;background:transparent;overflow:hidden}iframe{display:block;border:0;width:100%;height:100%;background:transparent}</style>
    </head><body><iframe id="app" title="Interactive artifact" sandbox="allow-scripts" referrerpolicy="no-referrer" allow="camera 'none'; microphone 'none'; geolocation 'none'; clipboard-read 'none'; clipboard-write 'none'; payment 'none'"></iframe></body></html>
    """#

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private var pending: InteractiveArtifactView?
        private var ready = false
        private var applying = false
        private var appliedColorScheme: ColorScheme?
        private var appliedRawHTML: String?

        func update(_ parent: InteractiveArtifactView, in view: WKWebView) {
            pending = parent
            applyLatest(in: view)
        }

        func webView(_ view: WKWebView, didFinish navigation: WKNavigation?) {
            ready = true
            applyLatest(in: view)
        }

        private func applyLatest(in view: WKWebView) {
            guard ready, !applying, let parent = pending else { return }
            // Return swipes update the surrounding SwiftUI view each frame. Compare
            // these immutable inputs separately to avoid building another full-size
            // HTML string just to confirm the document hasn't changed.
            guard parent.colorScheme != appliedColorScheme || parent.rawHTML != appliedRawHTML else { return }
            let nextColorScheme = parent.colorScheme
            let nextRawHTML = parent.rawHTML
            applying = true
            let dark = nextColorScheme == .dark
            // This policy comes before the generated document. Any CSP supplied
            // by the document can only further restrict it, never loosen it.
            let document = """
            <!doctype html><html><head><meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; media-src data: blob:; font-src data:; connect-src 'none'; frame-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'">
            <style>:root{color-scheme:\(dark ? "dark" : "light")}html,body{margin:0;min-height:100%;background:transparent;color:\(dark ? "#f1f0ea" : "#20201e");font-family:-apple-system,BlinkMacSystemFont,sans-serif}*{box-sizing:border-box}img,svg,canvas{max-width:100%}</style>
            </head><body>\(nextRawHTML)</body></html>
            """
            // Arguments, not string interpolation, cross into the trusted world.
            view.callAsyncJavaScript("document.getElementById('app').srcdoc = html;",
                                     arguments: ["html": document], in: nil, in: .defaultClient) { [weak self, weak view] result in
                guard let self, let view else { return }
                self.applying = false
                if case .success = result {
                    self.appliedColorScheme = nextColorScheme
                    self.appliedRawHTML = nextRawHTML
                    self.applyLatest(in: view)
                }
            }
        }

        func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            if action.navigationType == .linkActivated, ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                UIApplication.shared.open(url)
            }
            decisionHandler(url.scheme == "about" ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            decisionHandler(.deny)
        }

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            completionHandler()
        }
    }
}
