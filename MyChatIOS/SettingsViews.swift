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
}

struct SettingsHomeView: View {
    let api: APIClient
    let signOut: () -> Void
    let conversationsDeleted: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(
                        [
                            SettingsRoute.account,
                            .memory,
                            .models,
                            .systemPrompt,
                            .usage,
                        ],
                        id: \.self
                    ) { route in
                        NavigationLink(value: route) {
                            SettingsNavigationRow(route: route)
                        }
                        .buttonStyle(.plain)
                        EditorialDivider()
                            .padding(.leading, 50)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
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

private struct SettingsNavigationRow: View {
    let route: SettingsRoute

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: route.symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(AppPalette.secondaryText)
                .frame(width: 20)
            Text(route.title)
                .font(.system(size: 17))
                .foregroundStyle(AppPalette.text)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppPalette.secondaryText)
        }
        .frame(minHeight: 54)
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
            VStack(alignment: .leading, spacing: 0) {
                EditorialLabel("邮箱")
                    .padding(.top, 20)
                Text(email.isEmpty ? "加载中…" : email)
                    .font(.system(size: 17))
                    .foregroundStyle(email.isEmpty ? AppPalette.secondaryText : AppPalette.text)
                    .padding(.vertical, 14)
                EditorialDivider()

                EditorialLabel("修改密码")
                    .padding(.top, 28)
                SecureField("输入新密码", text: $password)
                    .textContentType(.newPassword)
                    .font(.system(size: 17))
                    .padding(.vertical, 14)
                EditorialDivider()

                Button {
                    updatePassword()
                } label: {
                    HStack {
                        Text(saving ? "保存中…" : "保存密码")
                        Spacer()
                        if saving { ProgressView().controlSize(.small) }
                    }
                    .font(.system(size: 16, weight: .medium))
                    .frame(minHeight: 50)
                }
                .buttonStyle(.plain)
                .disabled(password.count < 8 || saving)
                .opacity(password.count < 8 ? 0.42 : 1)

                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(AppPalette.secondaryText)
                        .padding(.top, 4)
                }

                EditorialDivider()
                    .padding(.top, 30)
                Button(role: .destructive, action: signOut) {
                    Text("退出登录")
                        .font(.system(size: 16, weight: .medium))
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
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
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("使用记忆")
                            .font(.system(size: 17))
                        Text("允许模型在后续对话中使用已保存内容")
                            .font(.system(size: 12.5))
                            .foregroundStyle(AppPalette.secondaryText)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { store.enabled },
                        set: store.setEnabled
                    ))
                    .labelsHidden()
                }
                .padding(.vertical, 16)
                EditorialDivider()

                EditorialLabel("添加记忆")
                    .padding(.top, 24)
                HStack(spacing: 12) {
                    TextField("输入希望模型记住的内容", text: $newMemory, axis: .vertical)
                        .lineLimit(1...4)
                        .font(.system(size: 16))
                        .padding(.vertical, 13)
                    Button("添加") { addMemory() }
                        .font(.system(size: 15, weight: .medium))
                        .disabled(newMemory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                EditorialDivider()

                EditorialLabel("已记住的内容")
                    .padding(.top, 28)
                    .padding(.bottom, 8)

                if store.loading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 30)
                } else if store.memories.isEmpty {
                    Text("还没有保存的记忆")
                        .font(.system(size: 15))
                        .foregroundStyle(AppPalette.secondaryText)
                        .padding(.vertical, 24)
                } else {
                    ForEach(store.memories) { memory in
                        memoryRow(memory)
                        EditorialDivider()
                    }
                }

                Button(role: .destructive) {
                    confirmation = .memories
                } label: {
                    Text("删除全部记忆")
                        .font(.system(size: 16))
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.top, 26)

                EditorialDivider()

                Button(role: .destructive) {
                    confirmation = .conversations
                } label: {
                    Text("删除全部对话")
                        .font(.system(size: 16))
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                }
                .buttonStyle(.plain)

                if let error = store.error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.top, 8)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
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
            VStack(alignment: .leading, spacing: 0) {
                EditorialLabel("已添加的模型")
                    .padding(.top, 20)
                    .padding(.bottom, 8)

                if loading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 30)
                } else if endpoints.isEmpty {
                    Text("还没有添加模型")
                        .font(.system(size: 15))
                        .foregroundStyle(AppPalette.secondaryText)
                        .padding(.vertical, 22)
                } else {
                    ForEach(endpoints) { endpoint in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(endpoint.name)
                                    .font(.system(size: 16, weight: .medium))
                                Text(endpoint.model)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(AppPalette.secondaryText)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button {
                                editor = EndpointEditorTarget(endpoint: endpoint)
                            } label: {
                                Image(systemName: "pencil")
                                    .frame(width: 36, height: 40)
                            }
                            Button(role: .destructive) {
                                delete(endpoint)
                            } label: {
                                Image(systemName: "trash")
                                    .frame(width: 36, height: 40)
                            }
                        }
                        .frame(minHeight: 60)
                        EditorialDivider()
                    }
                }

                Button {
                    editor = EndpointEditorTarget(endpoint: nil)
                } label: {
                    Label("添加 API", systemImage: "plus")
                        .font(.system(size: 16, weight: .medium))
                        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.top, 14)

                if let error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.top, 8)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 30)
        }
        .background(AppPalette.background)
        .navigationTitle("模型")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(item: $editor) { target in
            ModelEndpointEditor(api: api, endpoint: target.endpoint) { saved in
                if let index = endpoints.firstIndex(where: { $0.id == saved.id }) {
                    endpoints[index] = saved
                } else {
                    endpoints.insert(saved, at: 0)
                }
                editor = nil
            }
            .presentationBackground(AppPalette.background)
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
                VStack(alignment: .leading, spacing: 0) {
                    EditorialLabel("Base URL").padding(.top, 18)
                    TextField("https://api.example.com/v1", text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .font(.system(size: 16))
                        .padding(.vertical, 13)
                    EditorialDivider()

                    EditorialLabel("API Key").padding(.top, 22)
                    SecureField(endpoint == nil ? "输入 API Key" : "留空则保持现有密钥", text: $apiKey)
                        .textContentType(.password)
                        .font(.system(size: 16))
                        .padding(.vertical, 13)
                    EditorialDivider()

                    Button {
                        discover()
                    } label: {
                        HStack {
                            Text(loadingModels ? "正在获取…" : "一键获取模型列表")
                            Spacer()
                            if loadingModels { ProgressView().controlSize(.small) }
                        }
                        .font(.system(size: 16, weight: .medium))
                        .frame(minHeight: 52)
                    }
                    .buttonStyle(.plain)
                    .disabled(baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || loadingModels)

                    if !discovered.isEmpty {
                        EditorialLabel("模型列表").padding(.top, 20)
                        ForEach(discovered) { model in
                            Button {
                                selectedModel = model.id
                                manualModel = ""
                            } label: {
                                HStack(spacing: 10) {
                                    Circle()
                                        .fill(selectedModel == model.id ? AppPalette.text : .clear)
                                        .frame(width: 6, height: 6)
                                        .frame(width: 14)
                                    Text(model.displayName)
                                        .font(.system(size: 15.5))
                                    Spacer()
                                }
                                .frame(minHeight: 44)
                            }
                            .buttonStyle(.plain)
                        }
                        EditorialDivider()
                    }

                    EditorialLabel("手动添加模型").padding(.top, 22)
                    TextField("模型 ID", text: $manualModel)
                        .textInputAutocapitalization(.never)
                        .font(.system(size: 16))
                        .padding(.vertical, 13)
                        .onChange(of: manualModel) { _, value in
                            if !value.isEmpty { selectedModel = "" }
                        }
                    EditorialDivider()

                    EditorialLabel("显示名称").padding(.top, 22)
                    TextField("可选", text: $displayName)
                        .font(.system(size: 16))
                        .padding(.vertical, 13)
                    EditorialDivider()

                    if let error {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding(.top, 12)
                    }

                    Button {
                        save()
                    } label: {
                        HStack {
                            Text(saving ? "保存中…" : "保存")
                            Spacer()
                            if saving { ProgressView().controlSize(.small) }
                        }
                        .font(.system(size: 16, weight: .semibold))
                        .frame(minHeight: 54)
                    }
                    .buttonStyle(.plain)
                    .disabled(effectiveModel.isEmpty || baseURL.isEmpty || saving)
                    .opacity(effectiveModel.isEmpty || baseURL.isEmpty ? 0.42 : 1)
                    .padding(.top, 16)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
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
        VStack(spacing: 0) {
            TextEditor(text: $prompt)
                .font(.system(size: 16))
                .lineSpacing(5)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 15)
                .padding(.top, 12)
                .disabled(loading)
            EditorialDivider()
                .padding(.horizontal, 20)
            Button {
                save()
            } label: {
                HStack {
                    Text(saving ? "保存中…" : "保存")
                    Spacer()
                    if saving { ProgressView().controlSize(.small) }
                }
                .font(.system(size: 16, weight: .semibold))
                .frame(minHeight: 54)
                .padding(.horizontal, 20)
            }
            .buttonStyle(.plain)
            .disabled(loading || saving)
        }
        .background(AppPalette.background)
        .navigationTitle("系统提示词")
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            "保存失败",
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
            VStack(alignment: .leading, spacing: 0) {
                UsageMetric(
                    title: "5 小时用量",
                    value: quota?.tokens5h ?? 0,
                    limit: 500_000,
                    reset: quota?.window5hStart.addingTimeInterval(5 * 60 * 60)
                )
                .padding(.top, 18)
                EditorialDivider()
                    .padding(.vertical, 22)
                UsageMetric(
                    title: "一周用量",
                    value: quota?.tokens7d ?? 0,
                    limit: 10_000_000,
                    reset: quota?.window7dStart.addingTimeInterval(7 * 24 * 60 * 60)
                )

                EditorialDivider()
                    .padding(.vertical, 26)
                EditorialLabel("兑换码")
                HStack(spacing: 12) {
                    TextField("输入兑换码", text: $code)
                        .textInputAutocapitalization(.characters)
                        .font(.system(size: 16))
                        .padding(.vertical, 13)
                    Button(redeeming ? "兑换中…" : "兑换") {
                        redeem()
                    }
                    .font(.system(size: 15, weight: .medium))
                    .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || redeeming)
                }
                EditorialDivider()

                if loading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                }
                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(AppPalette.secondaryText)
                        .padding(.top, 12)
                }
            }
            .padding(.horizontal, 20)
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

private struct EditorialLabel: View {
    let value: String

    init(_ value: String) {
        self.value = value
    }

    var body: some View {
        Text(value)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(AppPalette.secondaryText)
            .textCase(.uppercase)
            .tracking(0.35)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct EditorialDivider: View {
    var body: some View {
        Rectangle()
            .fill(AppPalette.border)
            .frame(height: 0.5)
    }
}
