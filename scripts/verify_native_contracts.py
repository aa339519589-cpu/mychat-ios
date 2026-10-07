#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def text(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")

def require(path: str, needle: str, label: str) -> None:
    if needle not in text(path):
        raise SystemExit(f"FAIL {label}: {needle!r} missing from {path}")

def forbid(path: str, needle: str, label: str) -> None:
    if needle in text(path):
        raise SystemExit(f"FAIL {label}: stale {needle!r} remains in {path}")

def main() -> None:
    theme = "MyChatIOS/DesignSystem/Theme.swift"
    shell = "MyChatIOS/Features/MainShellView.swift"
    sidebar = "MyChatIOS/Features/SidebarView.swift"
    composer = "MyChatIOS/Features/ComposerView.swift"
    conversation = "MyChatIOS/Features/ChatConversationView.swift"
    model = "MyChatIOS/App/AppModel.swift"

    require(theme, "brandSidebar = MyChatSystemFont.nativeFont(size: 24", "sidebar brand scale")
    require(theme, "sidebarPrimary = MyChatSystemFont.font(size: 18", "sidebar navigation type")
    require(theme, "sidebarConversation = MyChatSystemFont.font(size: 18", "sidebar history type")
    require(theme, "responseBody = MyChatSystemFont.serif(size: responseBodySize", "response body scale")
    require(theme, "static let responseBodySize: CGFloat = 17", "response body type size")
    require(theme, "userMessage = MyChatSystemFont.userMessageFont(size: 17", "user-message Han weight matches response")
    require(theme, "static func userMessageFont(size: CGFloat, weight: UIFont.Weight)", "user-message Chinese-only font cascade")
    require(theme, ".cascadeList: [han]", "preserve user-message Latin font while matching Han weight")
    require(theme, "PingFangSC-Regular", "native Han font cascade")
    require(theme, "responseBodyLineSpacing: CGFloat = 7.2", "response leading")
    require(theme, "controlSurface", "adaptive composer controls")
    require(theme, "MyChatFloatingSurface", "shared thin-border floating controls")

    forbid(shell, ".simultaneousGesture(drawerGesture", "non-exclusive drawer gesture")
    forbid(shell, ".highPriorityGesture(drawerGesture", "scroll-blocking SwiftUI gesture")
    require(shell, "UIViewPropertyAnimator", "native drawer animation")
    require(shell, "DirectionalDrawerPanGestureRecognizer", "directional drawer recognizer")
    require(shell, "surface.transform = CGAffineTransform", "compositor drawer transform")
    require(shell, "cancelsTouchesInView = true", "tap cancellation")
    forbid(shell, "scrollView.panGestureRecognizer.require(toFail: pan)", "no window-wide scroll delay")
    forbid(shell, "drawerDragOffset", "no per-pan SwiftUI state")
    require(shell, "myChatDrawerVisibilityChanged", "drawer visibility notification")
    require(shell, ".background(MyChatTheme.canvas.ignoresSafeArea())", "full-screen canvas background")
    require(shell, "canvasHost.safeAreaRegions = .container", "single content safe-area owner")

    require(shell, "view.keyboardLayoutGuide.topAnchor", "system keyboard layout ownership")
    forbid(shell, "canvasHost.view.layer.cornerRadius", "no second inset rounded container")
    require(model, "@Published private(set) var newChatRevision = 0", "new-chat action owns a visible refresh token")
    require(shell, "newChatRevision = appModel.newChatRevision", "transcript surface observes the app model refresh token")
    require(shell, "controller.lastNavigationKey != navigationKey", "new-chat refresh follows the canvas navigation key")
    require(shell, "controller.canvasHost.rootView = canvas", "navigation key refreshes the hosted transcript")
    require(shell, "beginNewChat: { beginNewChat() }", "header new-chat button invokes the explicit reset action")
    require(shell, 'accessibilityIdentifier("header.new-chat")', "header new-chat button has a stable interaction identifier")
    require(shell, 'HStack(spacing: 0) {\n                Button(action: beginNewChat)', "header new-chat is a real button in the control cluster")
    require(shell, 'NewChatHeaderGlyph()\n                        .frame(width: 50, height: 44)\n                        .contentShape(Rectangle())', "header new-chat button has a bounded hit target")
    require(shell, '.accessibilityIdentifier("header.new-chat")\n\n                ConversationActionMenu(', "header new-chat button has its own hit target beside the menu")
    require(shell, 'Capsule().stroke(MyChatTheme.headerControlForeground.opacity(0.14), lineWidth: 0.7)\n                    }\n                    .allowsHitTesting(false)', "header surface is isolated from control hit testing")
    forbid(shell, '.overlay(alignment: .leading) {\n                Button(action: beginNewChat)', "no overlay-based header hit target")
    require(shell, 'private func beginNewChat(in project: ProjectRecord? = nil) {\n        HapticFeedback.impact()', "new-chat action has immediate tap feedback")
    require(shell, "resetTransaction.disablesAnimations = true", "new-chat model reset commits without animation")
    require(shell, "NotificationCenter.default.post(name: .myChatDismissComposer, object: nil)", "new-chat action dismisses the keyboard")
    require(shell, "resetTransaction.disablesAnimations = true", "new-chat model reset is synchronous")
    require(shell, 'NewChatHeaderGlyph()\n                    .frame(width: 50, height: 44)\n                    .contentShape(Rectangle())', "project header new-chat action has a full-size touch target")
    require(shell, "ConversationActionMenu(\n                    appModel: appModel,\n                    conversation: conversation,\n                    openPrivateChat: openPrivateChat", "private chat remains available outside the new-chat action")
    forbid(shell, "if showsPrivateChat {", "new-chat button remains available on an empty chat canvas")

    require(sidebar, "guard !interactionLocked else { return }", "sidebar action guard")
    require(sidebar, ".allowsHitTesting(!interactionLocked)", "sidebar interaction gating")
    require(sidebar, "MyChatTheme.sidebarDestinationHeight", "measured destination rows")
    require(sidebar, "MyChatTypography.sidebarConversation", "history typography")
    require(sidebar, "destination != .chats && appModel.selectedDestination == destination", "Chats is never highlighted")
    require(sidebar, "if filteredConversations.count > 8 {", "All chats hidden for short history")
    require(sidebar, "spacing: filteredConversations.count > 8 ? 14 : 0", "All chats separated from account control")
    forbid(sidebar, ".shadow(color: .black.opacity(0.10), radius: 12", "new chat relief")

    require(composer, "@State private var isSidebarPresented", "sidebar focus state")
    require(composer, "myChatDrawerVisibilityChanged", "keyboard dismissal on drawer")
    require(composer, "guard !isSidebarPresented", "focus reopen prevention")
    require(composer, "MyChatTheme.controlSurface", "adaptive inner controls")
    require(composer, "SystemComposerSurface", "system-controlled composer material")
    require(composer, "accessibilityReduceTransparency", "opaque accessibility appearance")
    require(composer, "glassEffect(.regular", "system Liquid Glass appearance")
    require(composer, "appModel.sendDraft()", "synchronous send/focus transaction")
    require(composer, "else if appModel.canSendCurrentDraft", "attachment-only send action")
    require(composer, "attachment.kind == .image", "compact composer image attachment preview")
    require(model, "|| !pendingAttachments.isEmpty", "attachments enable send without text")
    require(model, "sourceImages: sourceImages.isEmpty ? nil : sourceImages", "images remain on their user message")
    require(model, "@Published private(set) var historyRetrievalEnabled = true", "past-chat retrieval defaults on independently of saved memory")
    require(model, "func setHistoryRetrievalEnabled(_ enabled: Bool)", "past-chat retrieval has a persistent setting action")
    require(model, "historyRetrieval: !isPrivateChat && historyRetrievalEnabled", "past-chat retrieval is sent separately from saved memory")
    require(model, "cache.historyRetrievalEnabled = historyRetrievalEnabled", "past-chat retrieval preference is cached per account")
    require(model, "var historyRetrievalEnabled: Bool? = nil", "past-chat retrieval cache remains backward-compatible")
    require(sidebar, "搜索并引用过往对话", "memory settings expose a separate past-chat search control")
    require(shell, "title: \"搜索历史对话\"", "chat tools expose the past-chat search control")
    require("MyChatIOS/Infrastructure/ChatAPIClient.swift", "images = message.sourceImages?.isEmpty == false ? message.sourceImages : nil", "image-only user message is sent to the chat API")
    require("MyChatIOS/Domain/ChatModels.swift", "var connectorIDs: [String]? = nil", "chat tool selection supports explicit connector IDs")
    require("MyChatIOS/Domain/ChatModels.swift", "enum ChatConnectorAccessMode: String, Codable, CaseIterable, Sendable", "chat connector access modes match Claude's per-conversation modes")
    require("MyChatIOS/Domain/ChatModels.swift", 'case alwaysAvailable = "always_available"', "connector access mode uses the backend wire value")
    require("MyChatIOS/Infrastructure/ChatAPIClient.swift", "connectorIds = command.tools.connectorIDs?.map { $0.lowercased() }.sorted()", "selected connectors are sent to the server")
    require("MyChatIOS/Infrastructure/ChatAPIClient.swift", "connectorAccessMode = command.tools.connectorAccessMode", "connector access mode is sent on every chat turn")
    require(model, "func setConnectorAccessModeInCurrentChat", "connector access mode is changeable per chat")
    require(model, "connectorAccessModesByConversation", "connector access mode survives local chat restoration")
    require(model, "func connectorIsAvailableInCurrentChat", "connectors have a per-conversation selection")
    require(model, "var connectorSelections: [String: [String]]? = nil", "connector selections survive app restarts")
    require(shell, "Text(\"本次对话的连接器\")", "chat tools expose per-conversation connectors")
    require(shell, "Picker(\n                    \"工具调用方式\"", "chat tools expose Auto, Always, and On demand modes")
    require(shell, "appModel.setConnectorAvailableInCurrentChat(connector, available: $0)", "connector controls update the active conversation")
    require(conversation, "latestSearchIsConnector", "on-demand connector discovery appears in the transcript")
    require(conversation, "ConnectorToolSearchResultCard(result: result)", "connector tool search has an inline result presentation")

    require(conversation, "VStack(alignment: .leading, spacing: 24)", "exact layout for short transcripts")
    require(conversation, "updates.snapshot.messages.count > 64", "long transcripts switch to bounded rendering")
    require(conversation, "LazyVStack(alignment: .leading, spacing: 24)", "long transcripts are virtualized")
    require(conversation, ".containerRelativeFrame(.horizontal)\n        .frame(maxWidth: .infinity, maxHeight: .infinity", "transcript viewport is anchored to the native canvas width")
    require(conversation, "scrollView.isDecelerating", "native inertia protection")
    require(conversation, "setGenerationActive(updates.snapshot.isGenerating)", "generation scroll-follow lock")
    require(conversation, "guard followingLatest, !nativeInteractionActive, !followScheduled else { return }", "automatic follow yields to user scrolling")
    require(conversation, "followingLatest = false\n            stopSmoothFollow()", "streaming follow stops during user interaction")
    forbid(conversation, "scrollProxy.scrollTo", "no forced per-token scroll")
    require(conversation, ".padding(.horizontal, 16)", "compact text inset")
    require(conversation, "VStack(alignment: .leading, spacing: 10)", "compact paragraph rhythm")
    require(conversation, ".fill(MyChatTheme.userBubble)", "flat user bubble surface")
    require(conversation, "UserMessageRow(message: message)", "user messages use one dedicated row for all payload types")
    require(conversation, "private struct UserMessageRow: View", "dedicated user message layout component")
    require(conversation, "UserMessageCard(message: message)\n                .frame(maxWidth: 360, alignment: .trailing)", "user content width cap preserves natural bubble sizing")
    require(conversation, ".frame(maxWidth: .infinity, alignment: .trailing)\n    }\n}\n\nprivate struct UserMessageCard", "user row fills the transcript and anchors payloads to the trailing edge")
    require(conversation, "latestSearchIsHistory", "past-chat retrieval has a distinct activity label")
    require(conversation, "HistorySearchResultCard", "past-chat retrieval renders source cards")
    require(conversation, "openHistoryConversation", "past-chat citations open their source conversation")
    forbid(conversation, ".containerRelativeFrame(.horizontal) { width, _ in max(0, (width - 32) * 0.88) }", "no nested relative-frame sizing for user bubbles")
    forbid(conversation, ".containerRelativeFrame(.horizontal) { width, _ in max(0, width - 32) }", "no nested relative-frame sizing for user rows")
    require(conversation, "ThinkingOrbitalBalls(reduceMotion: reduceMotion)", "thinking state uses the three-ball orbital animation")
    forbid(conversation, 'Text("Thinking…")', "thinking animation has no visible status label")
    require(conversation, "LazyVGrid(columns: imageColumns, alignment: .trailing", "compact square user image attachments align right")
    require(conversation, "min(max(message.sourceImages?.count ?? 1, 1), 2)", "single image occupies a trailing single-column row")
    require(conversation, "showsMessageBubble ? 13 : 0", "image-only messages have no large bubble")
    require(conversation, ".fullScreenCover(item: $selectedImage)", "tap image to open full-screen preview")
    require(conversation, "CopyableMessageCodeBlock(language: language, text: text)", "copy UI only on explicit code blocks")
    require(conversation, "UIPasteboard.general.string = text", "copy exact fenced block contents")
    require(conversation, "fontSize: 16,", "display math size")
    require(conversation, '@MainActor private static let processPool', "math renderer reuse")

    require(model, "ConversationCacheStore", "persistent conversation cache")
    require(model, "startConversationPrefetch", "history prefetch")
    require(model, "privateConversationIDs", "private cleanup tracking")
    require(model, "finishGenerationUI(command)", "immediate terminal state")
    require("MyChatIOS/Infrastructure/JobEventStream.swift", "SSEByteParser", "SSE blank-line framing")

    deploy = ROOT / "scripts/deploy-device.sh"
    if not deploy.exists():
        raise SystemExit("FAIL deploy script missing")

    print("Static native interaction and typography contracts verified; runtime layout needs screenshots.")

if __name__ == "__main__":
    main()
