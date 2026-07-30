import SwiftUI

private enum SettingsRoute: Hashable {
    case account
    case memory
    case models
    case systemPrompt
    case usage

    var title: String {
        switch self {
        case .account: return "账户"
        case .memory: return "记忆"
        case .models: return "模型"
        case .systemPrompt: return "系统提示词"
        case .usage: return "使用额度"
        }
    }

    var symbol: String {
        switch self {
        case .account: return "person"
        case .memory: return "brain"
        case .models: return "slider.horizontal.3"
        case .systemPrompt: return "text.alignleft"
        case .usage: return "chart.line.uptrend.xyaxis"
        }
    }

    var detail: String {
        switch self {
        case .account: return "登录信息与安全"
        case .memory: return "管理模型记住的内容"
        case .models: return "连接与管理 API"
        case .systemPrompt: return "设定长期回复偏好"
        case .usage: return "查看额度与兑换"
        }
    }
}

struct SettingsHomeView: View {
    let api: APIClient
    let signOut: () -> Void
    let conversationsDeleted: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var path: [SettingsRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text("管理你的账户、AI 偏好与使用情况。")
                        .font(.system(size: 15))
                        .foregroundStyle(AppPalette.secondaryText)

                    SettingsRouteGroup(
                        title: "个人",
                        routes: [.account, .memory]
                    )
                    SettingsRouteGroup(
                        title: "AI",
                        routes: [.models, .systemPrompt]
                    )
                    SettingsRouteGroup(
                        title: "用量",
                        routes: [.usage]
                    )
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 36)
            }
            .background(AppPalette.background)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: SettingsRoute.self) { route in
                destination(for: route)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .foregroundStyle(AppPalette.text)
                }
            }
        }
    }

    @ViewBuilder
    private func destination(for route: SettingsRoute) -> some View {
        switch route {
        case .account:
            AccountSettingsView(api: api) {
                dismiss()
                signOut()
            }
        case .memory:
            MemorySettingsView(api: api, conversationsDeleted: conversationsDeleted)
        case .models:
            ModelSettingsView(api: api)
        case .systemPrompt:
            SystemPromptSettingsView(api: api)
        case .usage:
            UsageSettingsView(api: api)
        }
    }
}

private struct SettingsRouteGroup: View {
    let title: String
    let routes: [SettingsRoute]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppPalette.secondaryText)
                .padding(.leading, 3)

            VStack(spacing: 3) {
                ForEach(routes, id: \.self) { route in
                    NavigationLink(value: route) {
                        SettingsNavigationRow(route: route)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(7)
            .background(AppPalette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }
}

private struct SettingsNavigationRow: View {
    let route: SettingsRoute

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: route.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppPalette.text)
                .frame(width: 34, height: 34)
                .background(AppPalette.mutedSurface)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(route.title)
                    .font(.system(size: 16.5, weight: .medium))
                    .foregroundStyle(AppPalette.text)
                Text(route.detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(AppPalette.secondaryText)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppPalette.secondaryText)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 62)
        .contentShape(Rectangle())
    }
}

private struct AccountSettingsView: View {
    let api: APIClient
    let signOut: () -> Void
    @State private var email = ""
    @State private var password = ""
    @State private var saving = false
    @State private var message: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsSectionHeading(
                        title: "登录账户",
                        caption: "当前用于同步对话与偏好的邮箱"
                    )
                    HStack(spacing: 13) {
                        Image(systemName: "person.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 38, height: 38)
                            .background(AppPalette.mutedSurface)
                            .clipShape(Circle())
                        Text(email.isEmpty ? "加载中…" : email)
                            .font(.system(size: 16))
                            .foregroundStyle(
                                email.isEmpty
                                    ? AppPalette.secondaryText
                                    : AppPalette.text
                            )
                            .lineLimit(2)
                    }
                    .padding(15)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppPalette.surface)
                    .clipShape(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                    )
                }

                VStack(alignment: .leading, spacing: 12) {
                    SettingsSectionHeading(
                        title: "修改密码",
                        caption: "至少 8 个字符，保存后立即生效"
                    )
                    SecureField("输入新密码", text: $password)
                        .textContentType(.newPassword)
                        .settingsInput()

                    Button {
                        updatePassword()
                    } label: {
                        HStack {
                            Text(saving ? "保存中…" : "保存密码")
                            Spacer()
                            if saving { ProgressView().tint(AppPalette.background) }
                        }
                    }
                    .buttonStyle(SettingsPrimaryButtonStyle())
                    .disabled(password.count < 8 || saving)
                    .opacity(password.count < 8 ? 0.42 : 1)
                }

                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(AppPalette.secondaryText)
                }

                VStack(alignment: .leading, spacing: 9) {
                    SettingsSectionHeading(
                        title: "会话",
                        caption: "退出后，本机将不再保留当前登录状态"
                    )
                    Button(role: .destructive, action: signOut) {
                        Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                            .font(.system(size: 16, weight: .medium))
                            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 2)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 36)
        }
        .background(AppPalette.background)
        .navigationTitle("账户")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do { email = try await api.account().email ?? "" }
            catch { message = error.localizedDescription }
        }
    }

    private func updatePassword() {
        guard password.count >= 8, !saving else { return }
        Task {
            saving = true
            defer { saving = false }
            do {
                try await api.updatePassword(password)
                password = ""
                message = "密码已更新"
                lightHaptic()
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

@MainActor
private final class MemorySettingsStore: ObservableObject {
    @Published var enabled = true
    @Published var memories: [MemoryRecord] = []
    @Published var loading = true
    @Published var busy = false
    @Published var error: String?
    let api: APIClient

    init(api: APIClient) {
        self.api = api
    }

    func load() async {
        loading = true
        defer { loading = false }
        do {
            async let memoryRows = api.memories()
            async let profile = api.profile()
            memories = try await memoryRows
            let fetchedProfile = try await profile
            enabled = fetchedProfile?.memoryEnabled ?? true
        } catch {
            self.error = error.localizedDescription
        }
    }

    func setEnabled(_ value: Bool) {
        let previous = enabled
        enabled = value
        Task {
            do { try await api.setMemoryEnabled(value) }
            catch {
                enabled = previous
                self.error = error.localizedDescription
            }
        }
    }
}

private struct MemorySettingsView: View {
    let conversationsDeleted: () -> Void
    @StateObject private var store: MemorySettingsStore
    @State private var newMemory = ""
    @State private var editingID: UUID?
    @State private var editingText = ""
    @State private var confirmation: Confirmation?

    private enum Confirmation: String, Identifiable {
        case memories
        case conversations
        var id: String { rawValue }
    }

    init(api: APIClient, conversationsDeleted: @escaping () -> Void) {
        self.conversationsDeleted = conversationsDeleted
        _store = StateObject(wrappedValue: MemorySettingsStore(api: api))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("使用记忆")
                            .font(.system(size: 17, weight: .medium))
                        Text("允许模型在后续对话中使用已保存内容")
                            .font(.system(size: 13))
                            .foregroundStyle(AppPalette.secondaryText)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { store.enabled },
                        set: store.setEnabled
                    ))
                    .labelsHidden()
                }
                .padding(16)
                .background(AppPalette.surface)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                VStack(alignment: .leading, spacing: 12) {
                    SettingsSectionHeading(
                        title: "添加记忆",
                        caption: "例如偏好的语言、称呼或长期目标"
                    )
                    HStack(alignment: .bottom, spacing: 10) {
                        TextField(
                            "输入希望模型记住的内容",
                            text: $newMemory,
                            axis: .vertical
                        )
                        .lineLimit(1...4)
                        .settingsInput()

                        Button("添加") { addMemory() }
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(minWidth: 58, minHeight: 50)
                            .background(AppPalette.accent)
                            .clipShape(
                                RoundedRectangle(cornerRadius: 15, style: .continuous)
                            )
                            .disabled(
                                newMemory
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                    .isEmpty
                            )
                            .opacity(
                                newMemory
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                    .isEmpty ? 0.42 : 1
                            )
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    SettingsSectionHeading(
                        title: "已记住的内容",
                        caption: "你可以随时编辑或删除"
                    )

                    if store.loading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 30)
                    } else if store.memories.isEmpty {
                        Text("还没有保存的记忆")
                            .font(.system(size: 15))
                            .foregroundStyle(AppPalette.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(17)
                            .background(AppPalette.surface)
                            .clipShape(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                            )
                    } else {
                        VStack(spacing: 10) {
                            ForEach(store.memories) { memory in
                                memoryRow(memory)
                                    .padding(.horizontal, 14)
                                    .background(AppPalette.surface)
                                    .clipShape(
                                        RoundedRectangle(
                                            cornerRadius: 18,
                                            style: .continuous
                                        )
                                    )
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 7) {
                    SettingsSectionHeading(
                        title: "数据管理",
                        caption: "这些操作不可撤销"
                    )
                    Button(role: .destructive) {
                        confirmation = .memories
                    } label: {
                        Label("删除全部记忆", systemImage: "brain.head.profile.fill")
                            .font(.system(size: 15.5, weight: .medium))
                            .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
                    }
                    .buttonStyle(.plain)

                    Button(role: .destructive) {
                        confirmation = .conversations
                    } label: {
                        Label("删除全部对话", systemImage: "trash")
                            .font(.system(size: 15.5, weight: .medium))
                            .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }

                if let error = store.error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 36)
        }
        .background(AppPalette.background)
        .navigationTitle("记忆")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.load() }
        .confirmationDialog(
            confirmation == .memories ? "删除全部记忆？" : "删除全部对话？",
            isPresented: Binding(
                get: { confirmation != nil },
                set: { if !$0 { confirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("确认删除", role: .destructive) {
                let target = confirmation
                confirmation = nil
                deleteAll(target)
            }
            Button("取消", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func memoryRow(_ memory: MemoryRecord) -> some View {
        if editingID == memory.id {
            HStack(alignment: .top, spacing: 10) {
                TextField("记忆内容", text: $editingText, axis: .vertical)
                    .lineLimit(2...8)
                    .font(.system(size: 15))
                    .padding(.vertical, 12)
                Button("保存") { saveMemory(memory) }
                    .font(.system(size: 14, weight: .medium))
                    .padding(.top, 13)
            }
        } else {
            HStack(alignment: .top, spacing: 12) {
                Text(memory.content)
                    .font(.system(size: 15))
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 13)
                Menu {
                    Button {
                        editingID = memory.id
                        editingText = memory.content
                    } label: {
                        Label("编辑", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        deleteMemory(memory)
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 36, height: 42)
                }
                .foregroundStyle(AppPalette.secondaryText)
            }
        }
    }

    private func addMemory() {
        let value = newMemory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        Task {
            do {
                store.memories.append(try await store.api.addMemory(value))
                newMemory = ""
                lightHaptic()
            } catch { store.error = error.localizedDescription }
        }
    }

    private func saveMemory(_ memory: MemoryRecord) {
        let value = editingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        Task {
            do {
                try await store.api.updateMemory(id: memory.id, content: value)
                if let index = store.memories.firstIndex(where: { $0.id == memory.id }) {
                    store.memories[index].content = value
                }
                editingID = nil
                lightHaptic()
            } catch { store.error = error.localizedDescription }
        }
    }

    private func deleteMemory(_ memory: MemoryRecord) {
        Task {
            do {
                try await store.api.deleteMemory(id: memory.id)
                store.memories.removeAll { $0.id == memory.id }
            } catch { store.error = error.localizedDescription }
        }
    }

    private func deleteAll(_ target: Confirmation?) {
        Task {
            do {
                if target == .memories {
                    try await store.api.deleteAllMemories()
                    store.memories = []
                } else if target == .conversations {
                    try await store.api.deleteAllConversations()
                    conversationsDeleted()
                }
                lightHaptic()
            } catch { store.error = error.localizedDescription }
        }
    }
}

private struct ModelSettingsView: View {
    let api: APIClient
    @State private var endpoints: [ModelEndpointSummary] = []
    @State private var loading = true
    @State private var editor: EndpointEditorTarget?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SettingsSectionHeading(
                    title: "自定义模型",
                    caption: "添加兼容 OpenAI 接口的 API，聊天时即可切换使用"
                )

                if loading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 30)
                } else if endpoints.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 20, weight: .medium))
                        Text("还没有添加模型")
                            .font(.system(size: 16, weight: .medium))
                        Text("平台模型仍可正常使用。")
                            .font(.system(size: 13))
                            .foregroundStyle(AppPalette.secondaryText)
                    }
                    .padding(17)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppPalette.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                } else {
                    VStack(spacing: 10) {
                        ForEach(endpoints) { endpoint in
                            HStack(spacing: 12) {
                                Image(systemName: "cpu")
                                    .font(.system(size: 15, weight: .semibold))
                                    .frame(width: 36, height: 36)
                                    .background(AppPalette.mutedSurface)
                                    .clipShape(Circle())
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(endpoint.name)
                                        .font(.system(size: 16, weight: .medium))
                                    Text(endpoint.model)
                                        .font(.system(size: 12.5))
                                        .foregroundStyle(AppPalette.secondaryText)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Menu {
                                    Button {
                                        editor = EndpointEditorTarget(endpoint: endpoint)
                                    } label: {
                                        Label("编辑", systemImage: "pencil")
                                    }
                                    Button(role: .destructive) {
                                        delete(endpoint)
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                } label: {
                                    Image(systemName: "ellipsis")
                                        .frame(width: 38, height: 42)
                                }
                                .foregroundStyle(AppPalette.secondaryText)
                            }
                            .padding(14)
                            .background(AppPalette.surface)
                            .clipShape(
                                RoundedRectangle(cornerRadius: 19, style: .continuous)
                            )
                        }
                    }
                }

                Button {
                    editor = EndpointEditorTarget(endpoint: nil)
                } label: {
                    Label("添加 API", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .buttonStyle(SettingsPrimaryButtonStyle())

                if let error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 36)
        }
        .background(AppPalette.background)
        .navigationTitle("模型")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .fullScreenCover(item: $editor) { target in
            ModelEndpointEditor(api: api, endpoint: target.endpoint) { saved in
                if let index = endpoints.firstIndex(where: { $0.id == saved.id }) {
                    endpoints[index] = saved
                } else {
                    endpoints.insert(saved, at: 0)
                }
                editor = nil
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do { endpoints = try await api.modelEndpoints() }
        catch { self.error = error.localizedDescription }
    }

    private func delete(_ endpoint: ModelEndpointSummary) {
        Task {
            do {
                try await api.deleteModelEndpoint(id: endpoint.id)
                endpoints.removeAll { $0.id == endpoint.id }
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct EndpointEditorTarget: Identifiable {
    let id = UUID()
    let endpoint: ModelEndpointSummary?
}

private struct ModelEndpointEditor: View {
    let api: APIClient
    let endpoint: ModelEndpointSummary?
    let saved: (ModelEndpointSummary) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var baseURL: String
    @State private var apiKey = ""
    @State private var displayName: String
    @State private var selectedModel: String
    @State private var manualModel = ""
    @State private var discovered: [DiscoveredModel] = []
    @State private var loadingModels = false
    @State private var saving = false
    @State private var error: String?

    init(
        api: APIClient,
        endpoint: ModelEndpointSummary?,
        saved: @escaping (ModelEndpointSummary) -> Void
    ) {
        self.api = api
        self.endpoint = endpoint
        self.saved = saved
        _baseURL = State(initialValue: endpoint?.baseURL ?? "")
        _displayName = State(initialValue: endpoint?.name ?? "")
        _selectedModel = State(initialValue: endpoint?.model ?? "")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    VStack(alignment: .leading, spacing: 11) {
                        SettingsSectionHeading(
                            title: "连接地址",
                            caption: "填写兼容 OpenAI API 的 Base URL"
                        )
                        TextField("https://api.example.com/v1", text: $baseURL)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .settingsInput()
                    }

                    VStack(alignment: .leading, spacing: 11) {
                        SettingsSectionHeading(
                            title: "API Key",
                            caption: endpoint == nil
                                ? "密钥只用于请求你配置的服务"
                                : "留空会继续使用现有密钥"
                        )
                        SecureField(
                            endpoint == nil ? "输入 API Key" : "留空则保持现有密钥",
                            text: $apiKey
                        )
                        .textContentType(.password)
                        .settingsInput()
                    }

                    Button {
                        discover()
                    } label: {
                        HStack {
                            Text(loadingModels ? "正在获取…" : "一键获取模型列表")
                            Spacer()
                            if loadingModels { ProgressView().controlSize(.small) }
                        }
                    }
                    .buttonStyle(SettingsSoftButtonStyle())
                    .disabled(
                        baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || loadingModels
                    )

                    if !discovered.isEmpty {
                        VStack(alignment: .leading, spacing: 11) {
                            SettingsSectionHeading(
                                title: "可用模型",
                                caption: "选择一个用于聊天的模型"
                            )
                            VStack(spacing: 2) {
                                ForEach(discovered) { model in
                                    Button {
                                        selectedModel = model.id
                                        manualModel = ""
                                    } label: {
                                        HStack(spacing: 11) {
                                            Text(model.displayName)
                                                .font(.system(size: 15.5))
                                            Spacer()
                                            if selectedModel == model.id {
                                                Image(systemName: "checkmark")
                                                    .font(.system(size: 13, weight: .bold))
                                            }
                                        }
                                        .padding(.horizontal, 14)
                                        .frame(minHeight: 48)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(5)
                            .background(AppPalette.surface)
                            .clipShape(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                            )
                        }
                    }

                    VStack(alignment: .leading, spacing: 11) {
                        SettingsSectionHeading(
                            title: "手动填写模型",
                            caption: "列表中没有时，直接输入模型 ID"
                        )
                        TextField("模型 ID", text: $manualModel)
                            .textInputAutocapitalization(.never)
                            .settingsInput()
                            .onChange(of: manualModel) { _, value in
                                if !value.isEmpty { selectedModel = "" }
                            }
                    }

                    VStack(alignment: .leading, spacing: 11) {
                        SettingsSectionHeading(
                            title: "显示名称",
                            caption: "可选，会出现在聊天顶部的模型菜单"
                        )
                        TextField("可选", text: $displayName)
                            .settingsInput()
                    }

                    if let error {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    Button {
                        save()
                    } label: {
                        HStack {
                            Text(saving ? "保存中…" : "保存")
                            Spacer()
                            if saving { ProgressView().tint(AppPalette.background) }
                        }
                    }
                    .buttonStyle(SettingsPrimaryButtonStyle())
                    .disabled(effectiveModel.isEmpty || baseURL.isEmpty || saving)
                    .opacity(effectiveModel.isEmpty || baseURL.isEmpty ? 0.42 : 1)
                }
                .padding(.horizontal, 20)
                .padding(.top, 22)
                .padding(.bottom, 36)
            }
            .background(AppPalette.background)
            .navigationTitle(endpoint == nil ? "添加 API" : "编辑模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                        .foregroundStyle(AppPalette.text)
                }
            }
        }
    }

    private var effectiveModel: String {
        let manual = manualModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return manual.isEmpty ? selectedModel : manual
    }

    private func discover() {
        guard !loadingModels else { return }
        Task {
            loadingModels = true
            error = nil
            defer { loadingModels = false }
            do {
                discovered = try await api.discoverModels(
                    baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                    apiKey: apiKey,
                    endpointID: endpoint?.id
                ).filter(\.chatCompatible)
                if selectedModel.isEmpty { selectedModel = discovered.first?.id ?? "" }
            } catch { self.error = error.localizedDescription }
        }
    }

    private func save() {
        guard !effectiveModel.isEmpty, !saving else { return }
        Task {
            saving = true
            error = nil
            defer { saving = false }
            do {
                let value: ModelEndpointSummary
                if let endpoint {
                    value = try await api.updateModelEndpoint(
                        id: endpoint.id,
                        baseURL: apiKey.isEmpty ? nil : baseURL,
                        apiKey: apiKey.isEmpty ? nil : apiKey,
                        model: effectiveModel,
                        displayName: displayName
                    )
                } else {
                    value = try await api.createModelEndpoint(
                        baseURL: baseURL,
                        apiKey: apiKey,
                        model: effectiveModel,
                        displayName: displayName
                    )
                }
                lightHaptic()
                saved(value)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct SystemPromptSettingsView: View {
    let api: APIClient
    @State private var prompt = ""
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsSectionHeading(
                    title: "长期回复偏好",
                    caption: "这里的内容会作为每次新对话的系统指引"
                )

                ZStack {
                    TextEditor(text: $prompt)
                        .font(.system(size: 16))
                        .lineSpacing(5)
                        .scrollContentBackground(.hidden)
                        .padding(12)
                        .disabled(loading)

                    if loading {
                        ProgressView()
                    }
                }
                .frame(minHeight: 350)
                .background(AppPalette.surface)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                Button {
                    save()
                } label: {
                    HStack {
                        Text(saving ? "保存中…" : "保存")
                        Spacer()
                        if saving { ProgressView().tint(AppPalette.background) }
                    }
                }
                .buttonStyle(SettingsPrimaryButtonStyle())
                .disabled(loading || saving)
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 36)
        }
        .background(AppPalette.background)
        .navigationTitle("系统提示词")
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            "暂时无法完成操作",
            isPresented: Binding(
                get: { error != nil },
                set: { if !$0 { error = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
        .task {
            do { prompt = try await api.systemPrompt() }
            catch { self.error = error.localizedDescription }
            loading = false
        }
    }

    private func save() {
        Task {
            saving = true
            defer { saving = false }
            do {
                try await api.saveSystemPrompt(prompt)
                lightHaptic()
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct UsageSettingsView: View {
    let api: APIClient
    @State private var quota: QuotaSnapshot?
    @State private var code = ""
    @State private var loading = true
    @State private var redeeming = false
    @State private var message: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsSectionHeading(
                        title: "当前用量",
                        caption: "额度会在对应时间窗口自动恢复"
                    )

                    VStack(spacing: 26) {
                        UsageMetric(
                            title: "5 小时用量",
                            value: quota?.tokens5h ?? 0,
                            limit: 500_000,
                            reset: quota?.window5hStart
                                .addingTimeInterval(5 * 60 * 60)
                        )
                        UsageMetric(
                            title: "一周用量",
                            value: quota?.tokens7d ?? 0,
                            limit: 10_000_000,
                            reset: quota?.window7dStart
                                .addingTimeInterval(7 * 24 * 60 * 60)
                        )
                    }
                    .padding(17)
                    .background(AppPalette.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 12) {
                    SettingsSectionHeading(
                        title: "兑换额度",
                        caption: "输入兑换码后，额度会立即加入账户"
                    )
                    HStack(alignment: .bottom, spacing: 10) {
                        TextField("输入兑换码", text: $code)
                            .textInputAutocapitalization(.characters)
                            .settingsInput()
                        Button(redeeming ? "兑换中…" : "兑换") {
                            redeem()
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 66, minHeight: 50)
                        .background(AppPalette.accent)
                        .clipShape(
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                        )
                        .disabled(
                            code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || redeeming
                        )
                    }
                }

                if loading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }

                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(AppPalette.secondaryText)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 36)
        }
        .background(AppPalette.background)
        .navigationTitle("使用额度")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do { quota = try await api.quota() }
        catch { message = error.localizedDescription }
    }

    private func redeem() {
        let value = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !redeeming else { return }
        Task {
            redeeming = true
            defer { redeeming = false }
            do {
                let tokens = try await api.redeem(code: value)
                message = "兑换成功，增加 \(tokens.formatted()) token"
                code = ""
                quota = try await api.quota()
                lightHaptic()
            } catch { message = error.localizedDescription }
        }
    }
}

private struct UsageMetric: View {
    let title: String
    let value: Int
    let limit: Int
    let reset: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.system(size: 17, weight: .medium))
                Spacer()
                Text("\(value.formatted()) / \(limit.formatted())")
                    .font(.system(size: 12.5))
                    .foregroundStyle(AppPalette.secondaryText)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(AppPalette.mutedSurface)
                    Capsule()
                        .fill(AppPalette.thinking)
                        .frame(width: geometry.size.width * progress)
                }
            }
            .frame(height: 3)
            if let reset {
                Text(reset.formatted(date: .abbreviated, time: .shortened) + " 重置")
                    .font(.system(size: 12))
                    .foregroundStyle(AppPalette.secondaryText)
            }
        }
    }

    private var progress: CGFloat {
        guard limit > 0 else { return 0 }
        return min(max(CGFloat(value) / CGFloat(limit), 0), 1)
    }
}

private struct SettingsSectionHeading: View {
    let title: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(AppPalette.text)
            Text(caption)
                .font(.system(size: 13))
                .foregroundStyle(AppPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension View {
    func settingsInput() -> some View {
        self
            .font(.system(size: 16))
            .padding(.horizontal, 15)
            .padding(.vertical, 12)
            .frame(minHeight: 50)
            .background(AppPalette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct SettingsPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 17)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(AppPalette.accent)
            .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.42)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

private struct SettingsSoftButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(AppPalette.text)
            .padding(.horizontal, 15)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(AppPalette.mutedSurface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1) : 0.4)
    }
}

struct EditorialDivider: View {
    var body: some View {
        Rectangle()
            .fill(AppPalette.border)
            .frame(height: 0.5)
    }
}
