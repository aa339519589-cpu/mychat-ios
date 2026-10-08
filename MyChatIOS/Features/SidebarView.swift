import Combine
import SwiftUI
import UIKit

struct SidebarView: View, Equatable {
    private let appModel: AppModel
    @StateObject private var updates: SidebarUpdates
    @ScaledMetric(relativeTo: .body) private var conversationRowHeight: CGFloat = MyChatTheme.sidebarConversationHeight
    @State private var conversationActionError: String?
    let width: CGFloat
    let interactionLocked: Bool
    let openSettings: () -> Void
    let openAllChats: () -> Void
    let close: () -> Void

    init(appModel: AppModel, width: CGFloat, interactionLocked: Bool,
         openSettings: @escaping () -> Void, openAllChats: @escaping () -> Void, close: @escaping () -> Void) {
        self.appModel = appModel; self.width = width
        self.interactionLocked = interactionLocked; self.openSettings = openSettings; self.close = close
        self.openAllChats = openAllChats
        _updates = StateObject(wrappedValue: SidebarUpdates(appModel))
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.width == rhs.width && lhs.interactionLocked == rhs.interactionLocked
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarHeader
            destinationList

            conversationList

        }
        .overlay(alignment: .bottom) { sidebarFooter.zIndex(1) }
        .frame(width: width)
        .ignoresSafeArea(.container, edges: .bottom)
        // Keep the controls' enabled appearance unchanged while UIKit animates
        // the drawer. Interaction is blocked at the container level instead.
        .allowsHitTesting(!interactionLocked)
        .foregroundStyle(MyChatTheme.text)
        .background(MyChatTheme.sidebar.ignoresSafeArea())
        .alert(
            "对话操作失败",
            isPresented: Binding(
                get: { conversationActionError != nil },
                set: { if !$0 { conversationActionError = nil } }
            )
        ) {
            Button("好", role: .cancel) { conversationActionError = nil }
        } message: {
            Text(PresentationText.plain(conversationActionError ?? ""))
        }
    }

    private var sidebarHeader: some View {
        Text("MyChat")
            .font(MyChatTypography.brandSidebar)
            .lineSpacing(MyChatTypography.brandSidebarLineSpacing)
            .accessibilityAddTraits(.isHeader)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 16)
    }

    private var destinationList: some View {
        VStack(spacing: 0) {
            ForEach([AppDestination.chats, .projects, .code, .artifacts]) { destination in
                Button {
            guard !interactionLocked else { return }
            HapticFeedback.impact()
            if destination != .chats {
                        appModel.discardPrivateChat()
                    }
                    appModel.selectedDestination = destination
                    close()
                } label: {
                    HStack(spacing: 14) {
                        SidebarDestinationGlyph(destination: destination)
                            .frame(width: 20, height: 21)
                            .frame(width: 22, height: 24)

                        Text(destination.rawValue)
                            .font(MyChatTypography.sidebarPrimary)
                            .tracking(MyChatTypography.sidebarTracking)
                            .lineSpacing(MyChatTypography.utilityTitleLineSpacing)
                    }
                    .frame(maxWidth: .infinity, minHeight: MyChatTheme.sidebarDestinationHeight, alignment: .leading)
                    .padding(.horizontal, MyChatTheme.sidebarInset - 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SidebarDestinationButtonStyle(
                    isSelected: destination != .chats && appModel.selectedDestination == destination,
                    highlightsWhilePressed: destination == .chats
                ))
                .accessibilityAddTraits(
                    destination != .chats && appModel.selectedDestination == destination ? .isSelected : []
                )
            }
        }
        .padding(.horizontal, 14)
    .padding(.top, 0)
    }

    @ViewBuilder
    private var conversationList: some View {
        switch appModel.conversationPhase {
        case .idle where appModel.conversations.isEmpty,
             .loading where appModel.conversations.isEmpty:
            Color.clear.frame(maxHeight: .infinity)

        case let .failed(message) where appModel.conversations.isEmpty:
            VStack(alignment: .leading, spacing: 10) {
                Text(PresentationText.plain(message))
                    .font(MyChatTypography.navigation)
                    .lineSpacing(MyChatTypography.utilityLineSpacing)
                    .foregroundStyle(MyChatTheme.secondaryText)
                    .lineLimit(3)
                Button("重新载入") {
                    guard !interactionLocked else { return }
                    Task { await appModel.reloadConversations() }
                }
                .font(MyChatSystemFont.appFont(for: .subheadline, weight: .semibold))
                .foregroundStyle(MyChatTheme.brand)
                .frame(minHeight: 44)
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 22)
            .padding(.top, 8)
            .frame(maxHeight: .infinity, alignment: .top)

        default:
            VStack(alignment: .leading, spacing: 0) {
                if !pinnedConversations.isEmpty {
                    pinnedConversationList
                }

                Text("最近")
                    .font(MyChatTypography.sidebarSection)
                    .lineSpacing(MyChatTypography.metadataLineSpacing)
                    .foregroundStyle(MyChatTheme.sidebarSecondary)
                    .padding(.horizontal, MyChatTheme.sidebarInset)
                    .padding(.top, 16)
                    .padding(.bottom, 9)
                    .accessibilityAddTraits(.isHeader)

                if recentConversations.isEmpty {
                    Text("还没有对话")
                        .font(MyChatTypography.navigation)
                        .lineSpacing(MyChatTypography.utilityLineSpacing)
                        .foregroundStyle(MyChatTheme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 22)
                        .padding(.top, 8)
                } else {
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(recentConversations) { conversation in
                                conversationButton(conversation)
                                    .padding(.horizontal, 12)
                            }
                            if filteredConversations.count > 8 { allChatsButton }
                        }
                        .padding(.bottom, 96)
                    }
                    .scrollIndicators(.hidden)
                    .scrollDisabled(interactionLocked)
                    .frame(maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var pinnedConversationList: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                Text("已置顶")
                    .font(MyChatTypography.sidebarSection)
                    .lineSpacing(MyChatTypography.metadataLineSpacing)
                    .foregroundStyle(MyChatTheme.secondaryText)
                    .padding(.horizontal, MyChatTheme.sidebarInset)
                    .padding(.top, 12)
                    .padding(.bottom, 11)
                    .accessibilityAddTraits(.isHeader)

                ForEach(pinnedConversations) { conversation in
                    conversationButton(conversation)
                        .padding(.horizontal, 12)
                }
            }
        }
        .scrollIndicators(.hidden)
        .scrollDisabled(interactionLocked)
        .frame(height: min(CGFloat(pinnedConversations.count) * max(conversationRowHeight, 48) + 36, 176))
    }

    private func conversationButton(_ conversation: ConversationRecord) -> some View {
        Button {
    guard !interactionLocked else { return }
    HapticFeedback.impact()
    appModel.openConversation(conversation)
            close()
        } label: {
            HStack(spacing: 12) {
                ConversationBubbleGlyph()
                    .stroke(MyChatTheme.sidebarSecondary, style: StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round))
                    .frame(width: 18, height: 18)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayTitle(for: conversation))
                .font(MyChatTypography.sidebarConversation)
                        .tracking(MyChatTypography.sidebarTracking)
                .lineSpacing(2)
                        .lineLimit(1)
                    if let projectName = projectName(for: conversation) {
                        Label(projectName, systemImage: "folder")
                            .font(MyChatTypography.caption)
                            .lineSpacing(MyChatTypography.captionLineSpacing)
                            .foregroundStyle(MyChatTheme.secondaryText)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if conversation.pinned {
                    Image(systemName: "pin.fill")
                        .font(MyChatSystemFont.appFont(for: .caption1, weight: .regular))
                        .foregroundStyle(MyChatTheme.secondaryText)
                }
            }
            .padding(.leading, MyChatTheme.sidebarInset - 12)
            .frame(maxWidth: .infinity, minHeight: max(MyChatTheme.sidebarConversationHeight, conversationRowHeight) - 2, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            isActive(conversation) ? MyChatTheme.selected : Color.clear,
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
        .padding(.vertical, 1)
        .accessibilityLabel(displayTitle(for: conversation))
        .accessibilityValue(isActive(conversation) ? "当前对话" : "")
        .accessibilityAddTraits(isActive(conversation) ? .isSelected : [])
        .contextMenu {
            Button {
                Task {
                    do {
                        try await appModel.setConversationPinned(
                            conversation,
                            pinned: !conversation.pinned
                        )
                    } catch {
                        conversationActionError = error.localizedDescription
                    }
                }
            } label: {
                Label(
                    conversation.pinned ? "取消置顶" : "置顶",
                    systemImage: conversation.pinned ? "pin.slash" : "pin"
                )
            }

            Menu {
                if appModel.projects.isEmpty {
                    Text("暂无项目")
                } else {
                    ForEach(appModel.projects) { project in
                        Button {
                            Task {
                                do {
                                    try await appModel.setConversationProject(
                                        conversation,
                                        project: project
                                    )
                                } catch {
                                    conversationActionError = error.localizedDescription
                                }
                            }
                        } label: {
                            if conversation.projectID == project.id {
                                Label(project.name, systemImage: "checkmark")
                            } else {
                                Text(project.name)
                            }
                        }
                    }
                }

                if conversation.projectID != nil {
                    Divider()
                    Button {
                        Task {
                            do {
                                try await appModel.setConversationProject(
                                    conversation,
                                    project: nil
                                )
                            } catch {
                                conversationActionError = error.localizedDescription
                            }
                        }
                    } label: {
                        Label("从项目中移除", systemImage: "folder.badge.minus")
                    }
                }
            } label: {
                Label { Text("添加到项目") } icon: { Image(uiImage: MyChatProjectIcon.menuImage) }
            }

            Divider()
            Button(role: .destructive) {
                Task {
                    do {
                        try await appModel.deleteConversation(conversation)
                    } catch {
                        conversationActionError = error.localizedDescription
                    }
                }
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func projectName(for conversation: ConversationRecord) -> String? {
        guard let projectID = conversation.projectID else { return nil }
        return appModel.projects.first {
            $0.id.lowercased() == projectID.lowercased()
        }?.name
    }

    private var allChatsButton: some View {
                Button {
                    guard !interactionLocked else { return }
                    openAllChats()
                } label: {
                    HStack(spacing: 7) {
                        Text("所有对话").font(MyChatTypography.sidebarSection)
                        Image(systemName: "chevron.right").font(MyChatSystemFont.appFont(size: 12, weight: .medium))
                    }
                    .foregroundStyle(MyChatTheme.sidebarSecondary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, MyChatTheme.sidebarInset)
    }

    private var sidebarFooter: some View {
            HStack(spacing: 12) {
                Button {
                    guard !interactionLocked else { return }
                    openSettings()
                } label: {
                    Text(accountInitial)
                        .font(MyChatSystemFont.appFont(size: 17, design: .rounded, weight: .medium))
                        // The glass is decorative. Give the actual button label
                        // the whole circle so taps cannot reach a history row.
                        .frame(width: 48, height: 48)
                        .contentShape(Circle())
                }
                .buttonStyle(MyChatIconButtonStyle(size: 48))
                .accessibilityLabel("账户设置")
                .accessibilityIdentifier("sidebar.accountSettings")
                .accessibilityValue(accountTitle)

                Spacer(minLength: 0)

                NewChatButton(height: 48) {
                    guard !interactionLocked else { return }
                    HapticFeedback.impact()
                    appModel.beginNewChat()
                    close()
                }
                .accessibilityHint("开始一个新的对话")
            }
            .padding(.leading, 28)
            .padding(.trailing, 27)
            .padding(.bottom, 29)
    }

    private var filteredConversations: [ConversationRecord] {
        appModel.conversations
    }

    private var pinnedConversations: [ConversationRecord] {
        filteredConversations.filter(\.pinned)
    }

    private var recentConversations: [ConversationRecord] {
        Array(filteredConversations.lazy.filter { !$0.pinned }.prefix(10))
    }

    private func displayTitle(for conversation: ConversationRecord) -> String {
        appModel.displayConversationTitle(conversation)
    }

    private func isActive(_ conversation: ConversationRecord) -> Bool {
        guard let id = UUID(uuidString: conversation.id) else { return false }
        return appModel.selectedDestination == .chats && appModel.activeConversationID == id
    }

    private var accountTitle: String {
        appModel.authSession?.user.email ?? "MyChat"
    }

    private var accountInitial: String {
        String(accountTitle.trimmingCharacters(in: .whitespacesAndNewlines).first ?? "M")
            .uppercased()
    }
}

struct ConversationHistorySheet: View {
    private let appModel: AppModel
    private let openChat: () -> Void
    private let close: () -> Void
    @State private var rows: [HistoryRow]
    @State private var query = ""
    @State private var starredOnly = false
    @State private var nextOffset = 0
    @State private var hasMore = true
    @State private var loading = false
    @State private var error: String?
    @State private var pageTask: Task<Void, Never>?

    init(appModel: AppModel, openChat: @escaping () -> Void, close: @escaping () -> Void) {
        self.appModel = appModel
        self.openChat = openChat
        self.close = close
        var seen = Set<String>()
        _rows = State(initialValue: appModel.conversations.filter {
            !appModel.isPrivateConversation($0.id) && seen.insert($0.id.lowercased()).inserted
        }.map {
            HistoryRow(record: $0, title: appModel.displayConversationTitle($0))
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("聊天").font(.system(size: 17, weight: .semibold))
                HStack {
                    Button(action: close) {
                        ChatMenuGlyph().stroke(style: StrokeStyle(lineWidth: 1.35, lineCap: .round)).frame(width: 16, height: 16)
                    }.buttonStyle(MyChatIconButtonStyle(size: 44)).accessibilityLabel("关闭聊天列表")
                    Spacer()
                    Menu {
                        Toggle("仅显示收藏", isOn: $starredOnly)
                    } label: { Image(systemName: "slider.vertical.3").font(.system(size: 18)) }
                        .buttonStyle(MyChatIconButtonStyle(size: 44)).accessibilityLabel("筛选对话")
                }
            }.padding(.horizontal, 20).frame(height: 52).padding(.bottom, 12)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredRows) { row in
                        Button {
                            appModel.openConversation(row.record)
                            openChat()
                        } label: {
                            HStack(alignment: .top, spacing: 18) {
                                ConversationBubbleGlyph().stroke(MyChatTheme.secondaryText,
                                    style: StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round))
                                    .frame(width: 18, height: 18).padding(.top, 2)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(row.title).font(.system(size: 17)).lineLimit(1)
                                    if let date = Self.historyDate(row.record.updatedAt) {
                                        Text(Self.relativeTime(date)).font(.system(size: 14)).foregroundStyle(MyChatTheme.secondaryText)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 28)
                            .frame(minHeight: 71, alignment: .top).padding(.top, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if filteredRows.isEmpty && !loading && error == nil {
                        Text(query.isEmpty ? "还没有对话" : "没有匹配的对话")
                            .font(MyChatTypography.navigation)
                            .foregroundStyle(MyChatTheme.secondaryText)
                            .padding(14)
                    }
                    if loading {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 44)
                    } else if let error {
                        Text(PresentationText.plain(error))
                            .font(MyChatTypography.caption)
                            .foregroundStyle(MyChatTheme.secondaryText)
                            .padding(.horizontal, 14)
                        loadButton("重试")
                    } else if hasMore {
                        loadButton("加载更多")
                    }
                }
                .padding(.top, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(MyChatTheme.libraryCanvas)
            .foregroundStyle(MyChatTheme.text)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(alignment: .trailing, spacing: 16) {
                    NewChatButton {
                        appModel.beginNewChat(); openChat()
                    }
                    .accessibilityIdentifier("history.new-chat")
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").font(.system(size: 18))
                        TextField("搜索", text: $query).font(.system(size: 17)).accessibilityIdentifier("history.search")
                    }.padding(.horizontal, 16).frame(height: 48)
                        .modifier(MyChatFloatingSurface(shape: Capsule(), isInteractive: true))
                }
                .padding(.horizontal, 28).padding(.bottom, 8)
            }
            .task(id: query + "|" + String(starredOnly)) {
                if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
                }
                // A cancelled search may still be unwinding its network call.
                // Wait for it; page requests never overlap. A cancelled page
                // may then be retried without advancing or duplicating rows.
                while loading && !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                }
                guard !Task.isCancelled else { return }
                if query.isEmpty && !starredOnly {
                    if nextOffset == 0 { _ = await loadNextPage() }
                } else {
                    await loadSearchPages()
                }
            }
            .onDisappear { pageTask?.cancel() }
        }.background(MyChatTheme.libraryCanvas.ignoresSafeArea()).foregroundStyle(MyChatTheme.text)
    }

    private var filteredRows: [HistoryRow] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return rows.filter { !appModel.isPrivateConversation($0.record.id) && (!starredOnly || $0.record.starred == true)
            && (search.isEmpty || $0.title.localizedStandardContains(search)) }
    }

    private static func historyDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }
    private static func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter(); formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func loadButton(_ title: String) -> some View {
        Button(title) {
            pageTask?.cancel()
            pageTask = Task {
                if query.isEmpty { _ = await loadNextPage() }
                else { await loadSearchPages() }
            }
        }
        .font(MyChatTypography.navigation)
        .foregroundStyle(MyChatTheme.secondaryText)
        .frame(maxWidth: .infinity, minHeight: 44)
        .buttonStyle(.plain)
    }

    private func loadSearchPages() async {
        while hasMore && !Task.isCancelled {
            guard await loadNextPage() else { return }
        }
    }

    @MainActor private func loadNextPage() async -> Bool {
        guard !loading, hasMore, !Task.isCancelled else { return false }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let page = try await appModel.fetchConversationHistoryPage(offset: nextOffset)
            try Task.checkCancellation()
            var positions = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element.id, $0.offset) })
            var merged = rows
            for record in page.records {
                let row = HistoryRow(record: record, title: appModel.displayConversationTitle(record))
                if let index = positions[row.id] { merged[index] = row }
                else { positions[row.id] = merged.count; merged.append(row) }
            }
            if merged != rows { rows = merged }
            nextOffset = page.nextOffset
            hasMore = page.hasMore
            return true
        } catch is CancellationError {
            return false
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
            return false
        }
    }

    private struct HistoryRow: Identifiable, Equatable {
        let record: ConversationRecord
        let title: String
        var id: String { record.id.lowercased() }
    }
}

private struct SidebarDestinationButtonStyle: ButtonStyle {
    let isSelected: Bool
    let highlightsWhilePressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                isSelected ? MyChatTheme.selected
                    : (highlightsWhilePressed && configuration.isPressed
                       ? MyChatTheme.selected.opacity(0.62) : Color.clear),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct SidebarDestinationGlyph: View {
    let destination: AppDestination

    var body: some View {
        SidebarGlyphPath(destination: destination)
            .stroke(MyChatTheme.text, style: StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round))
            .accessibilityHidden(true)
    }
}

private struct ConversationBubbleGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 2.2, y: 13.7))
        path.addCurve(to: CGPoint(x: 1, y: 9), control1: CGPoint(x: 1.4, y: 12.3), control2: CGPoint(x: 1, y: 10.8))
        path.addCurve(to: CGPoint(x: 9, y: 1), control1: CGPoint(x: 1, y: 4.5), control2: CGPoint(x: 4.5, y: 1))
        path.addCurve(to: CGPoint(x: 17, y: 9), control1: CGPoint(x: 13.5, y: 1), control2: CGPoint(x: 17, y: 4.5))
        path.addCurve(to: CGPoint(x: 9, y: 17), control1: CGPoint(x: 17, y: 13.5), control2: CGPoint(x: 13.5, y: 17))
        path.addLine(to: CGPoint(x: 1, y: 17))
        path.addLine(to: CGPoint(x: 3.1, y: 14.9))
        path.addCurve(to: CGPoint(x: 2.2, y: 13.7), control1: CGPoint(x: 2.7, y: 14.5), control2: CGPoint(x: 2.4, y: 14.1))
        return path.applying(CGAffineTransform(scaleX: rect.width / 18, y: rect.height / 18))
    }
}

private struct SidebarGlyphPath: Shape {
    let destination: AppDestination

    func path(in rect: CGRect) -> Path {
        var p = Path()
        func move(_ x: CGFloat, _ y: CGFloat) { p.move(to: CGPoint(x: x, y: y)) }
        func line(_ x: CGFloat, _ y: CGFloat) { p.addLine(to: CGPoint(x: x, y: y)) }
        func curve(_ x: CGFloat, _ y: CGFloat, _ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) {
            p.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: a, y: b), control2: CGPoint(x: c, y: d))
        }
        switch destination {
        case .chats:
            move(4.5, 16.5); curve(2, 10.5, 2.8, 15, 2, 13)
            curve(10, 2.5, 2, 6, 5.5, 2.5); curve(18, 10.5, 14.5, 2.5, 18, 6)
            curve(10, 18.5, 18, 15, 14.5, 18.5)
            line(2, 19); line(4.5, 16.5)
            move(19, 9); curve(22.5, 15.5, 21.2, 10.2, 22.5, 12.7)
            curve(21, 20, 22.5, 17.5, 22, 19); line(23, 23); line(17, 22)
            curve(10, 20.5, 14, 22, 11.5, 21.5)
        case .projects:
            return MyChatProjectGlyph().path(in: rect)
        case .artifacts:
            p.addEllipse(in: CGRect(x: 1.5, y: 14, width: 9, height: 9))
            p.addRoundedRect(in: CGRect(x: 15, y: 12, width: 8, height: 11), cornerSize: CGSize(width: 0.5, height: 0.5))
            move(8, 17); line(8, 8)
            curve(20, 7, 8, 1, 17, 1); line(8, 15.5)
        case .code:
            move(7, 5); line(1, 11.5); line(7, 18)
            move(17, 5); line(23, 11.5); line(17, 18)
            move(14.5, 2.5); line(9.5, 21)
        }
        return p.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24))
    }
}

@MainActor private final class SidebarUpdates: @preconcurrency ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    private var subscription: AnyCancellable?
    init(_ model: AppModel) {
        let changes: [AnyPublisher<Void, Never>] = [
            model.$conversations.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            model.$projects.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            model.$conversationPhase.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            model.$selectedDestination.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            model.$activeConversationID.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            model.$authSession.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            // Only the initial question affects an unnamed sidebar title.
            // Assistant token updates do not invalidate the recent-chat list.
            model.$messages.map { $0.first(where: { $0.role == .user })?.content }
                .removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher()
        ]
        subscription = Publishers.MergeMany(changes).receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }
}

struct CapabilitiesSettingsView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var errorMessage: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                NativeSettingsSection(title: "功能") {
                    capability("内联可视化", icon: "chart.xyaxis.line", isOn: $appModel.renderEnabled)
                    divider
                    capability("网页搜索", icon: "globe", isOn: $appModel.webSearchEnabled)
                }
                NativeSettingsSection(title: "记忆") {
                    capability("从对话中生成记忆", isOn: Binding(
                        get: { appModel.memoryEnabled },
                        set: { value in Task { do { try await appModel.setMemoryEnabled(value) } catch { errorMessage = error.localizedDescription } } }
                    ))
                    divider
                    capability("包含敏感主题", isOn: Binding(
                        get: { appModel.sensitiveMemoryEnabled },
                        set: { value in Task { do { try await appModel.setSensitiveMemoryEnabled(value) } catch { errorMessage = error.localizedDescription } } }
                    ))
                    divider
                    NavigationLink { MemoryManagementView() } label: { NativeSettingsRow(title: "记忆文件", icon: "") }.buttonStyle(.plain)
                }
                NativeSettingsSection(title: "工具访问") {
                    capability("搜索历史对话", icon: "clock.arrow.circlepath", isOn: Binding(
                        get: { appModel.historyRetrievalEnabled }, set: { appModel.setHistoryRetrievalEnabled($0) }
                    ))
                    divider
                    capability("在此对话中使用记忆", isOn: Binding(
                        get: { appModel.memoryEnabled && appModel.activeConversationMemoryEnabled },
                        set: { appModel.setActiveConversationMemoryEnabled($0) }
                    )).disabled(!appModel.canChangeActiveConversationMemory)
                }
                NativeSettingsSection(title: "模型") {
                    NavigationLink { CustomModelsSettingsView() } label: { NativeSettingsRow(title: "模型与 API", icon: "") }.buttonStyle(.plain)
                }
                if let errorMessage { Text(errorMessage).font(MyChatTypography.metadata).foregroundStyle(.red) }
            }.padding(.horizontal, 20).padding(.vertical, 16)
        }.navigationTitle("功能").navigationBarTitleDisplayMode(.inline)
            .background(MyChatTheme.canvas).foregroundStyle(MyChatTheme.text)
    }
    private var divider: some View { Divider().padding(.horizontal, 18) }
    private func capability(_ title: String, icon: String? = nil, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 12) {
                if let icon { Image(systemName: icon).font(MyChatSystemFont.appFont(size: 18)).frame(width: 22) }
                Text(title).font(MyChatTypography.navigation)
            }
        }.tint(MyChatTheme.brand).padding(.horizontal, 18).frame(minHeight: 60)
    }
}

private struct MemoryManagementView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var newMemory = ""
    @State private var isSaving = false
    @State private var isResettingMemories = false
    @State private var confirmsMemoryReset = false
    @State private var errorMessage: String?
    @State private var importing = false
    private var topics: [String] { Array(Set(appModel.memories.map { memoryTopic($0) })).sorted() }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("主题").font(MyChatTypography.metadata).foregroundStyle(MyChatTheme.secondaryText).padding(.leading, 20)
                if appModel.memoryPhase == .loading && appModel.memories.isEmpty { ProgressView().frame(maxWidth: .infinity).padding(24) }
                ForEach(topics, id: \.self) { topic in
                    NavigationLink { MemoryTopicView(topic: topic) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(topic).font(.system(size: 17))
                                Text("已保存的记忆").font(.system(size: 13)).foregroundStyle(MyChatTheme.secondaryText)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(MyChatTypography.metadata).foregroundStyle(MyChatTheme.secondaryText)
                        }.padding(.horizontal, 20).frame(minHeight: 70).contentShape(Rectangle())
                    }.buttonStyle(.plain).background(MyChatTheme.raised, in: RoundedRectangle(cornerRadius: 22))
                        .accessibilityIdentifier("memory.topic." + topic)
                }
                if topics.isEmpty && appModel.memoryPhase != .loading { Text("还没有记忆文件").foregroundStyle(MyChatTheme.secondaryText).padding(20) }
                if let message = appModel.memoryError ?? errorMessage { Text(message).font(MyChatTypography.metadata).foregroundStyle(.red) }
            }.padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 20)
        }.safeAreaInset(edge: .bottom, spacing: 0) {
            MemoryPromptInput(text: $newMemory, placeholder: "告诉 MyChat 要记住什么", isSaving: isSaving, submit: addMemory)
        }.navigationTitle("记忆文件").navigationBarTitleDisplayMode(.inline)
            .foregroundStyle(MyChatTheme.text).tint(MyChatTheme.text).background(MyChatTheme.canvas)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("导入", systemImage: "square.and.arrow.down") { importing = true }
                        ShareLink(item: MemoryImportParser.export(appModel.memories)) { Label("导出", systemImage: "square.and.arrow.up") }.disabled(appModel.memories.isEmpty)
                        Button("全部删除", systemImage: "trash", role: .destructive) { confirmsMemoryReset = true }.disabled(isResettingMemories || appModel.memories.isEmpty)
                    } label: { Image(systemName: "ellipsis") }.accessibilityLabel("记忆操作")
                }
            }.sheet(isPresented: $importing) { MemoryImportSheet { try await appModel.importMemories($0) } }
            .confirmationDialog("删除全部记忆？", isPresented: $confirmsMemoryReset, titleVisibility: .visible) {
                Button("全部删除", role: .destructive) {
                    isResettingMemories = true
                    Task { defer { isResettingMemories = false }; do { try await appModel.deleteAllMemories() } catch { errorMessage = error.localizedDescription } }
                }
            }.task { if case .idle = appModel.memoryPhase { await appModel.reloadMemoryData() } }
    }
    private func addMemory() {
        guard !isSaving, !newMemory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isSaving = true
        let input = newMemory
        Task {
            defer { isSaving = false }
            do {
                try await appModel.interpretMemoryInstruction(input, topic: nil)
                if newMemory == input { newMemory = "" }
                errorMessage = nil
            }
            catch { errorMessage = error.localizedDescription }
        }
    }
}
private func memoryTopic(_ record: MemoryRecord) -> String {
    let value = record.topic?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return value.isEmpty || value.lowercased() == "general" ? "常规" : value
}
private struct MemoryTopicView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss
    let topic: String
    @State private var instruction = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var deleting = false
    @State private var editing: MemoryRecord?
    private var rows: [MemoryRecord] { appModel.memories.filter { memoryTopic($0) == topic } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(rows) { memory in
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(memoryFacts(memory.content).enumerated()), id: \.offset) { _, fact in
                            HStack(alignment: .top, spacing: 10) {
                                Text("•").font(MyChatTypography.responseBody).accessibilityHidden(true)
                                MarkdownBody(fact, typography: .response)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contextMenu { Button("编辑") { editing = memory } }
                        .accessibilityIdentifier("memory-record-" + memory.id)
                }
                if let errorMessage { Text(errorMessage).font(MyChatTypography.metadata).foregroundStyle(.red) }
            }.padding(20)
        }.safeAreaInset(edge: .bottom, spacing: 0) {
            MemoryPromptInput(text: $instruction, placeholder: "告诉 MyChat 要记住或修改什么", isSaving: isSaving, submit: apply)
        }.navigationTitle(topic).navigationBarTitleDisplayMode(.inline).background(MyChatTheme.canvas)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { deleting = true } label: { Image(systemName: "trash") }.accessibilityLabel("删除主题") } }
            .confirmationDialog("删除这个主题？", isPresented: $deleting, titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    isSaving = true
                    let snapshot = rows
                    Task { defer { isSaving = false }; do { for row in snapshot { try await appModel.deleteMemory(row) }; dismiss() } catch { errorMessage = error.localizedDescription } }
                }
            }.sheet(item: $editing) { memory in
                MemoryEditSheet(memory: memory, delete: { try await appModel.deleteMemory(memory) }) { content, topic in try await appModel.updateMemory(memory, content: content, topic: topic) }
            }
    }
    private func memoryFacts(_ content: String) -> [String] {
        let separated = content.replacingOccurrences(of: #"(?:\r?\n)+|[；;。]+|(?<=[.!?])\s+"#,
            with: "\n", options: .regularExpression)
        return separated.components(separatedBy: "\n").map {
            $0.replacingOccurrences(of: #"^\s*(?:[-*•]\s*|\d+[.)]\s+)"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }
    private func apply() {
        guard !isSaving, !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isSaving = true; let text = instruction
        Task {
            defer { isSaving = false }
            do {
                try await appModel.interpretMemoryInstruction(text, topic: topic)
                if instruction == text { instruction = "" }
                errorMessage = nil
            } catch { errorMessage = error.localizedDescription }
        }
    }
}
private struct MemoryPromptInput: View {
    @Binding var text: String
    let placeholder: String
    let isSaving: Bool
    let submit: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField(placeholder, text: $text, axis: .vertical).font(MyChatTypography.responseBody).lineLimit(1...4).accessibilityIdentifier("memory.content")
            HStack { Spacer(); Button(action: submit) {
                Group { if isSaving { ProgressView().tint(.white) } else { Image(systemName: "arrow.up") } }
                    .foregroundStyle(.white).frame(width: 36, height: 36).background(MyChatTheme.thinking, in: Circle())
            }.buttonStyle(.plain).disabled(isSaving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).opacity(text.isEmpty ? 0.5 : 1).accessibilityLabel("保存记忆") }
        }.padding(14).background(MyChatTheme.composer, in: RoundedRectangle(cornerRadius: 22)).overlay { RoundedRectangle(cornerRadius: 22).stroke(MyChatTheme.border.opacity(0.5), lineWidth: 0.5) }
            .padding(.horizontal, 16).padding(.bottom, 12)
    }
}

private struct MemoryImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let importEntries: ([MemoryImportEntry]) async throws -> MemoryImportResult
    @State private var sourceText = ""
    @State private var parsedEntries: [MemoryImportEntry] = []
    @State private var isParsing = false
    @State private var parseTask: Task<Void, Never>?
    @State private var isImporting = false
    @State private var didCopyPrompt = false
    @State private var errorMessage: String?
    @State private var importResult: MemoryImportResult?

    private let exportPrompt = "Export every memory you have stored about me. Preserve each entry as written. Group entries under Markdown topic headings and put one memory on each bullet line. Do not add an introduction or summary."

    private var exceedsInputLimit: Bool { sourceText.utf8.count > 256 * 1024 }

    var body: some View {
        NavigationStack {
            Form {
                Section("准备导出") {
                    Text("请先让 Claude 或其他 AI 导出已保存的记忆，再把结果粘贴到下方。MyChat 会保留主题，并将每条内容分别保存。")
                        .font(MyChatSystemFont.appFont(for: .subheadline, weight: .regular))
                        .foregroundStyle(MyChatTheme.secondaryText)

                    Button {
                        UIPasteboard.general.string = exportPrompt
                        didCopyPrompt = true
                    } label: {
                        Label(didCopyPrompt ? "已复制导出提示词" : "复制导出提示词", systemImage: didCopyPrompt ? "checkmark" : "doc.on.doc")
                    }
                }

                Section("粘贴记忆") {
                    TextEditor(text: $sourceText)
                        .frame(minHeight: 230)
                        .disabled(importResult != nil)
                        .accessibilityLabel("待导入的记忆文本")
                }

                Section {
                    if let importResult {
                        Text(importResult.memories.isEmpty
                            ? "这些内容都已存在，没有新增记忆。"
                            : "已导入 \(importResult.memories.count) 条记忆。")
                            .font(MyChatSystemFont.appFont(for: .footnote, weight: .semibold))
                            .foregroundStyle(MyChatTheme.text)
                        if importResult.skippedDuplicates > 0 {
                            Text("已跳过 \(importResult.skippedDuplicates) 条重复内容。")
                                .font(MyChatSystemFont.appFont(for: .footnote, weight: .regular))
                                .foregroundStyle(MyChatTheme.secondaryText)
                        }
                    } else {
                        Text(isParsing ? "正在检查导出内容…" : "已识别 \(parsedEntries.count) 条记忆；每次最多导入 500 条。")
                            .font(MyChatSystemFont.appFont(for: .footnote, weight: .regular))
                            .foregroundStyle(MyChatTheme.secondaryText)
                    }
                    if exceedsInputLimit {
                        Text("导出内容过大，请拆分成多个文件，或减少粘贴的内容。")
                            .font(MyChatSystemFont.appFont(for: .footnote, weight: .regular))
                            .foregroundStyle(.red)
                    }
                    if parsedEntries.count > 500 {
                        Text("记忆超过 500 条，请分批导入。")
                            .font(MyChatSystemFont.appFont(for: .footnote, weight: .regular))
                            .foregroundStyle(.red)
                    }
                    if let errorMessage {
                        Text(PresentationText.plain(errorMessage))
                            .font(MyChatSystemFont.appFont(for: .footnote, weight: .regular))
                            .foregroundStyle(.red)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(MyChatTheme.canvas)
            .navigationTitle("导入记忆")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(importResult == nil ? "取消" : "关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        if importResult != nil {
                            dismiss()
                        } else {
                            isImporting = true
                            Task {
                                do {
                                    importResult = try await importEntries(parsedEntries)
                                    errorMessage = nil
                                } catch {
                                    errorMessage = error.localizedDescription
                                }
                                isImporting = false
                            }
                        }
                    } label: {
                        if isImporting { ProgressView() }
                        else { Text(importResult == nil ? "导入" : "完成") }
                    }
                    .disabled(isImporting || (importResult == nil
                        && (isParsing || exceedsInputLimit || parsedEntries.isEmpty || parsedEntries.count > 500)))
                }
            }
            .tint(MyChatTheme.accent)
            .onChange(of: sourceText) { _, value in
                parseTask?.cancel()
                guard !value.isEmpty, value.utf8.count <= 256 * 1024 else {
                    parsedEntries = []
                    isParsing = false
                    return
                }
                isParsing = true
                parseTask = Task {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                    let parsed = await Task.detached(priority: .utility) {
                        MemoryImportParser.parse(value)
                    }.value
                    guard !Task.isCancelled else { return }
                    parsedEntries = parsed
                    isParsing = false
                }
            }
            .onDisappear { parseTask?.cancel() }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(30)
    }
}

private struct MemoryEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let memory: MemoryRecord
    let delete: () async throws -> Void
    let save: (String, String) async throws -> Void
    @State private var content: String
    @State private var topic: String
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var confirmingDelete = false

    init(memory: MemoryRecord, delete: @escaping () async throws -> Void, save: @escaping (String, String) async throws -> Void) {
        self.memory = memory
        self.delete = delete
        self.save = save
        _content = State(initialValue: memory.content)
        _topic = State(initialValue: memory.topic ?? "常规")
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("编辑记忆").font(.system(size: 17, weight: .semibold))
                HStack {
                    Button("取消") { dismiss() }.frame(width: 64, height: 42)
                        .modifier(MyChatFloatingSurface(shape: Capsule(), isInteractive: true))
                    Spacer()
                    Button(action: saveChanges) {
                        if isSaving { ProgressView() } else { Text("保存") }
                    }.frame(width: 64, height: 42)
                        .modifier(MyChatFloatingSurface(shape: Capsule(), isInteractive: true))
                        .disabled(isSaving || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.font(.system(size: 16)).padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 20)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("主题").font(.system(size: 15)).foregroundStyle(MyChatTheme.secondaryText).padding(.leading, 20)
                    TextField("主题", text: $topic).font(.system(size: 17)).padding(.horizontal, 20).frame(minHeight: 50)
                        .background(MyChatTheme.selected, in: RoundedRectangle(cornerRadius: 22))
                        .accessibilityIdentifier("memory.edit-topic")
                    Text("记忆内容").font(.system(size: 15)).foregroundStyle(MyChatTheme.secondaryText)
                        .padding(.leading, 20).padding(.top, 18)
                    TextField("记忆内容", text: $content, axis: .vertical).font(.system(size: 17)).lineLimit(4...12)
                        .padding(20).background(MyChatTheme.selected, in: RoundedRectangle(cornerRadius: 22))
                        .accessibilityIdentifier("memory.edit-content")
                    if let errorMessage { Text(PresentationText.plain(errorMessage)).font(.system(size: 14)).foregroundStyle(.red) }
                    Button("删除记忆", role: .destructive) { confirmingDelete = true }
                        .font(.system(size: 17)).frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                        .padding(.horizontal, 20).background(MyChatTheme.selected, in: RoundedRectangle(cornerRadius: 22))
                        .padding(.top, 24).disabled(isSaving)
                }.padding(.horizontal, 26).padding(.bottom, 28)
            }
        }.foregroundStyle(MyChatTheme.text).background(MyChatTheme.canvas)
        .presentationDetents([.medium, .large]).presentationCornerRadius(42).presentationDragIndicator(.visible)
        .confirmationDialog("删除这条记忆？", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                isSaving = true
                Task {
                    defer { isSaving = false }
                    do { try await delete(); dismiss() } catch { errorMessage = error.localizedDescription }
                }
            }
        }
    }
    private func saveChanges() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do { try await save(content, topic); dismiss() } catch { errorMessage = error.localizedDescription }
        }
    }
}
