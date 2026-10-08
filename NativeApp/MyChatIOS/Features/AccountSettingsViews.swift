import SwiftUI
import AuthenticationServices
import PhotosUI
import UIKit
import AVFoundation

struct SystemPromptSettingsView: View {
    @ObservedObject private var appModel: AppModel
    @AppStorage("mychat.profile.fullName") private var fullName = ""
    @AppStorage("mychat.profile.nickname") private var nickname = ""
    @AppStorage("mychat.profile.avatarJPEG") private var avatarJPEG = Data()
    @State private var prompt = ""
    @State private var loading = true
    @State private var saving = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var photoLibraryPresented = false
    @State private var cameraPresented = false
    @State private var photoError: String?
    @State private var errorMessage: String?
    @State private var savedMessage: String?

    init(appModel: AppModel) {
        _appModel = ObservedObject(wrappedValue: appModel)
        _prompt = State(initialValue: appModel.cachedSystemPrompt ?? "")
        _loading = State(initialValue: appModel.cachedSystemPrompt == nil)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(spacing: 10) {
                    Button { photoLibraryPresented = true } label: {
                        profileAvatar
                            .frame(width: 88, height: 88)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("编辑头像")

                    Menu {
                        Button("从照片图库选择", systemImage: "photo") { photoLibraryPresented = true }
                        Button("拍照", systemImage: "camera") {
                            guard UIImagePickerController.isSourceTypeAvailable(.camera) else { photoError = "这台设备没有可用相机"; return }
                            guard AVCaptureDevice.authorizationStatus(for: .video) != .denied,
                                  AVCaptureDevice.authorizationStatus(for: .video) != .restricted else { photoError = "请在系统设置中允许 MyChat 使用相机"; return }
                            cameraPresented = true
                        }
                    } label: {
                        Text("编辑头像").font(MyChatTypography.caption).foregroundStyle(MyChatTheme.text)
                            .padding(.horizontal, 12).frame(height: 28)
                            .background(MyChatTheme.raised, in: Capsule())
                            .overlay { Capsule().stroke(MyChatTheme.border, lineWidth: 0.7) }
                    }.accessibilityLabel("编辑头像")
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 10) {
                    VStack(spacing: 0) {
                        profileField("姓名", text: $fullName)
                        Divider().padding(.leading, 18)
                        profileField("昵称", text: $nickname)
                    }
                    .settingsCardStyle(cornerRadius: 22)
                    Text("已保存在此设备上。")
                        .font(MyChatTypography.metadata)
                        .foregroundStyle(MyChatTheme.secondaryText)
                        .padding(.horizontal, 18)
                }

                if loading {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .frame(height: 180)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("自定义指令")
                            .font(MyChatTypography.metadata)
                            .foregroundStyle(MyChatTheme.secondaryText)
                            .padding(.horizontal, 10)

                        TextField("你希望 MyChat 如何回复", text: $prompt, axis: .vertical)
                            .font(MyChatTypography.navigation).lineLimit(1...5)
                            .padding(.horizontal, 18).padding(.vertical, 14)
                            .settingsCardStyle(cornerRadius: 22)
                            .accessibilityIdentifier("profile.instructions")

                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("你的指令会应用于所有对话。")
                                .lineLimit(1).minimumScaleFactor(0.8)
                            Spacer(minLength: 4)
                            Text("\(prompt.count) / 20 000").monospacedDigit().fixedSize()
                                .foregroundStyle(prompt.count > 20_000 ? Color.red : MyChatTheme.secondaryText)
                        }
                        .font(MyChatSystemFont.appFont(size: 12)).foregroundStyle(MyChatTheme.secondaryText)
                        .padding(.horizontal, 10)

                    }

                    HStack {
                        Spacer()
                        if let savedMessage {
                            Label(savedMessage, systemImage: "checkmark.circle.fill")
                                .font(MyChatSystemFont.appFont(for: .caption1, weight: .semibold))
                                .foregroundStyle(MyChatTheme.accent)
                        }
                    }
                }

                SettingsErrorText(message: errorMessage)
            }
            .padding(18)
        }
        .navigationTitle("个人资料")
        .navigationBarTitleDisplayMode(.inline)
        .foregroundStyle(MyChatTheme.text)
        .tint(MyChatTheme.accent)
        .background(MyChatTheme.canvas)
        .photosPicker(isPresented: $photoLibraryPresented, selection: $selectedPhoto, matching: .images)
        .fullScreenCover(isPresented: $cameraPresented) {
            CameraImagePicker { data in
                cameraPresented = false
                if let data { saveProfilePhoto(data) }
            }.ignoresSafeArea()
        }
        .alert("无法编辑照片", isPresented: Binding(get: { photoError != nil }, set: { if !$0 { photoError = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(photoError ?? "") }
        .task { await load() }
        .onChange(of: appModel.cachedSystemPrompt) { _, value in
            guard let value, !saving else { return }
            prompt = value
        }
        .onChange(of: selectedPhoto) { _, photo in
            guard let photo else { return }
            Task {
                do {
                    guard let data = try await photo.loadTransferable(type: Data.self) else { throw AttachmentPreparationError.invalidImage }
                    saveProfilePhoto(data)
                } catch { photoError = error.localizedDescription }
                selectedPhoto = nil
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: save) {
                    Group {
                        if saving {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "checkmark")
                                .font(MyChatSystemFont.appFont(size: 16, weight: .semibold))
                                .foregroundStyle(MyChatTheme.text)
                        }
                    }
                }
                .disabled(loading || saving || prompt.count > 20_000)
                .opacity(loading || prompt.count > 20_000 ? 0.4 : 1)
                .accessibilityLabel("保存自定义指令")
            }
        }
    }

    private func saveProfilePhoto(_ data: Data) {
        Task {
            let compressed = await Task.detached(priority: .userInitiated) { () -> Data? in
                guard let image = UIImage(data: data) else { return nil }
                let scale = min(1, 640 / max(max(image.size.width, image.size.height), 1))
                let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                let renderer = UIGraphicsImageRenderer(size: size)
                return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }.jpegData(compressionQuality: 0.8)
            }.value
            if let compressed { avatarJPEG = compressed }
            else { photoError = AttachmentPreparationError.invalidImage.localizedDescription }
        }
    }

    private func load() async {
        if let cached = appModel.cachedSystemPrompt {
            prompt = cached
            errorMessage = nil
            loading = false
            return
        }
        loading = true
        do {
            prompt = try await appModel.fetchSystemPrompt()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }

    private func save() {
        saving = true
        savedMessage = nil
        Task {
            do {
                prompt = try await appModel.saveSystemPrompt(prompt)
                errorMessage = nil
                savedMessage = "已保存"
            } catch {
                errorMessage = error.localizedDescription
            }
            saving = false
        }
    }

    @ViewBuilder
    private var profileAvatar: some View {
        if let image = UIImage(data: avatarJPEG) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .clipShape(Circle())
        } else {
            ZStack {
                Circle().fill(MyChatTheme.selected)
                Text(profileInitial)
                    .font(MyChatSystemFont.appFont(size: 29, design: .rounded, weight: .semibold))
                    .foregroundStyle(MyChatTheme.text)
            }
        }
    }

    private var profileInitial: String {
        let source = nickname.isEmpty
            ? (fullName.isEmpty ? appModel.authSession?.user.email ?? "M" : fullName)
            : nickname
        return String(source.first ?? "M").uppercased()
    }

    private func profileField(_ title: String, text: Binding<String>) -> some View {
        HStack(spacing: 14) {
            Text(title)
                .font(MyChatTypography.navigation)
                .foregroundStyle(MyChatTheme.secondaryText)
                .frame(width: 98, alignment: .leading)
            TextField(title, text: text)
                .font(MyChatTypography.navigation)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 50)
    }
}

struct UsageSettingsView: View {
    @ObservedObject private var appModel: AppModel
    @State private var snapshot: AccountQuotaSnapshot?
    @State private var invitationCode = ""
    @State private var loading = true
    @State private var redeeming = false
    @State private var resultMessage: String?
    @State private var errorMessage: String?

    init(appModel: AppModel) {
        _appModel = ObservedObject(wrappedValue: appModel)
        _snapshot = State(initialValue: appModel.cachedQuotaSnapshot)
        _loading = State(initialValue: appModel.cachedQuotaSnapshot == nil)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("使用额度")
                    .font(MyChatTypography.pageTitleEditorial)

                if loading {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .frame(height: 180)
                } else if let snapshot {
                    UsageMeter(
                        title: "5 小时窗口",
                        used: snapshot.tokens5h,
                        limit: AccountQuotaSnapshot.fiveHourLimit
                    )
                    UsageMeter(
                        title: "7 天窗口",
                        used: snapshot.tokens7d,
                        limit: AccountQuotaSnapshot.sevenDayLimit
                    )

                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("可用余额")
                                .font(MyChatSystemFont.appFont(for: .subheadline, weight: .regular))
                                .foregroundStyle(MyChatTheme.secondaryText)
                            Text(snapshot.balance.formatted())
                                .font(MyChatSystemFont.appFont(size: 30, design: .rounded, weight: .semibold))
                        }
                        Spacer()
                        Image(systemName: "sparkles")
                            .font(MyChatSystemFont.appFont(size: 24, weight: .medium))
                            .foregroundStyle(MyChatTheme.accent)
                    }
                    .padding(18)
                    .settingsCardStyle(cornerRadius: 20)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("兑换邀请码")
                        .font(MyChatSystemFont.appFont(for: .headline, weight: .semibold))
                    TextField("输入邀请码", text: $invitationCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 14)
                        .frame(minHeight: 50)
                        .background(
                            MyChatTheme.canvas,
                            in: RoundedRectangle(cornerRadius: 15, style: .continuous)
                        )
                    Button { redeem() } label: {
                        Group {
                            if redeeming { ProgressView() } else { Text("兑换") }
                        }
                        .font(MyChatSystemFont.appFont(for: .headline, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(
                            MyChatTheme.accent,
                            in: RoundedRectangle(cornerRadius: 15, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(redeeming || invitationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(18)
                .settingsCardStyle(cornerRadius: 20)

                if let resultMessage {
                    Label(resultMessage, systemImage: "checkmark.circle.fill")
                        .font(MyChatSystemFont.appFont(for: .subheadline, weight: .semibold))
                        .foregroundStyle(MyChatTheme.accent)
                }
                SettingsErrorText(message: errorMessage)
            }
            .padding(22)
        }
        .navigationTitle("用量")
        .navigationBarTitleDisplayMode(.inline)
        .foregroundStyle(MyChatTheme.text)
        .tint(MyChatTheme.accent)
        .background(MyChatTheme.canvas)
        .task { await reload() }
        .refreshable { await reload(forceRefresh: true) }
        .onChange(of: appModel.cachedQuotaSnapshot) { _, value in
            guard let value else { return }
            snapshot = value
            loading = false
        }
    }

    private func reload(forceRefresh: Bool = false) async {
        if !forceRefresh, let cached = appModel.cachedQuotaSnapshot {
            snapshot = cached
            errorMessage = nil
            loading = false
            return
        }
        loading = snapshot == nil
        do {
            snapshot = try await appModel.fetchQuota(forceRefresh: forceRefresh)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }

    private func redeem() {
        redeeming = true
        resultMessage = nil
        Task {
            do {
                let result = try await appModel.redeemInvitationCode(invitationCode)
                invitationCode = ""
                resultMessage = "已增加 \(result.tokensAdded.formatted())，当前余额 \(result.newBalance.formatted())"
                snapshot = try await appModel.fetchQuota(forceRefresh: true)
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
            redeeming = false
        }
    }
}

private struct UsageMeter: View {
    let title: String
    let used: Int64
    let limit: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(MyChatSystemFont.appFont(for: .headline, weight: .semibold))
                Spacer()
                Text("\(used.formatted()) / \(limit.formatted())")
                    .font(MyChatSystemFont.appFont(for: .caption1, weight: .regular).monospacedDigit())
                    .foregroundStyle(MyChatTheme.secondaryText)
            }
            ProgressView(value: min(Double(used) / Double(max(limit, 1)), 1))
                .tint(MyChatTheme.accent)
        }
        .padding(18)
        .settingsCardStyle(cornerRadius: 20)
    }
}

struct ChangePasswordSettingsView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var password = ""
    @State private var confirmation = ""
    @State private var saving = false
    @State private var success = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("修改密码")
                    .font(MyChatTypography.pageTitleEditorial)
                Text("至少 6 位")
                    .font(MyChatSystemFont.appFont(for: .subheadline, weight: .regular))
                    .foregroundStyle(MyChatTheme.secondaryText)

                SecureField("新密码", text: $password)
                    .textContentType(.newPassword)
                    .padding(.horizontal, 15)
                    .frame(minHeight: 52)
                    .settingsCardStyle(cornerRadius: 16)
                SecureField("再次输入", text: $confirmation)
                    .textContentType(.newPassword)
                    .padding(.horizontal, 15)
                    .frame(minHeight: 52)
                    .settingsCardStyle(cornerRadius: 16)

                Button { save() } label: {
                    Group {
                        if saving { ProgressView() } else { Text("更新密码") }
                    }
                    .font(MyChatSystemFont.appFont(for: .headline, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(
                        MyChatTheme.accent,
                        in: RoundedRectangle(cornerRadius: 17, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .disabled(saving || password.count < 6 || password != confirmation)

                if success {
                    Label("密码已更新", systemImage: "checkmark.circle.fill")
                        .font(MyChatSystemFont.appFont(for: .subheadline, weight: .semibold))
                        .foregroundStyle(MyChatTheme.accent)
                }
                SettingsErrorText(message: errorMessage)
            }
            .padding(22)
        }
        .navigationTitle("密码")
        .navigationBarTitleDisplayMode(.inline)
        .foregroundStyle(MyChatTheme.text)
        .tint(MyChatTheme.accent)
        .background(MyChatTheme.canvas)
    }

    private func save() {
        success = false
        guard password == confirmation else {
            errorMessage = "两次输入的密码不一致"
            return
        }
        saving = true
        Task {
            do {
                try await appModel.changePassword(password)
                password = ""
                confirmation = ""
                errorMessage = nil
                success = true
            } catch {
                errorMessage = error.localizedDescription
            }
            saving = false
        }
    }
}

struct DataControlsSettingsView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var deletingConversations = false
    @State private var deletingMemories = false
    @State private var confirmConversations = false
    @State private var confirmMemories = false
    @State private var resultMessage: String?
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("数据控制")
                    .font(MyChatTypography.pageTitleEditorial)

                DestructiveSettingsButton(
                    title: "删除对话",
                    loading: deletingConversations
                ) { confirmConversations = true }

                DestructiveSettingsButton(
                    title: "删除全部记忆",
                    loading: deletingMemories
                ) { confirmMemories = true }

                if let resultMessage {
                    Label(resultMessage, systemImage: "checkmark.circle.fill")
                        .font(MyChatSystemFont.appFont(for: .subheadline, weight: .semibold))
                        .foregroundStyle(MyChatTheme.accent)
                }
                SettingsErrorText(message: errorMessage)
            }
            .padding(22)
        }
        .navigationTitle("数据")
        .navigationBarTitleDisplayMode(.inline)
        .foregroundStyle(MyChatTheme.text)
        .tint(MyChatTheme.accent)
        .background(MyChatTheme.canvas)
        .confirmationDialog("确定删除对话？", isPresented: $confirmConversations, titleVisibility: .visible) {
            Button("删除对话", role: .destructive) { deleteConversations() }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("确定删除全部记忆？", isPresented: $confirmMemories, titleVisibility: .visible) {
            Button("删除全部记忆", role: .destructive) { deleteMemories() }
            Button("取消", role: .cancel) {}
        }
    }

    private func deleteConversations() {
        deletingConversations = true
        resultMessage = nil
        Task {
            do {
                let count = try await appModel.deleteAllConversations()
                resultMessage = "已删除 \(count) 个对话"
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
            deletingConversations = false
        }
    }

    private func deleteMemories() {
        deletingMemories = true
        resultMessage = nil
        Task {
            do {
                try await appModel.deleteAllMemories()
                resultMessage = "已清空全部记忆"
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
            deletingMemories = false
        }
    }
}

private struct DestructiveSettingsButton: View {
    let title: String
    let loading: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: "trash")
                    .font(MyChatSystemFont.appFont(size: 18, weight: .semibold))
                    .frame(width: 38, height: 38)
                    .background(matteDanger.opacity(0.13), in: Circle())
                Text(title)
                    .font(MyChatSystemFont.appFont(for: .headline, weight: .semibold))
                Spacer()
                if loading { ProgressView() }
            }
            .foregroundStyle(matteDanger)
            .padding(16)
            .settingsCardStyle(cornerRadius: 19)
        }
        .buttonStyle(.plain)
        .disabled(loading)
    }

    private var matteDanger: Color {
        Color(red: 0.91, green: 0.55, blue: 0.59)
    }
}

struct CustomModelsSettingsView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var editorPresented = false
    @State private var endpointToDelete: CustomModelEndpoint?
    @State private var endpointError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ChatGPTPlanSettingsSection(
                    provider: appModel.chatGPTPlanProvider,
                    onModelsUpdated: { await appModel.reloadModels() }
                )
                VStack(alignment: .leading, spacing: 12) {
                    Text("自定义 API")
                        .font(MyChatSystemFont.appFont(for: .headline, weight: .semibold))
                    Button {
                        HapticFeedback.impact()
                        editorPresented = true
                    } label: {
                        Label("添加 API 与 URL", systemImage: "plus.circle")
                            .font(MyChatSystemFont.appFont(for: .body, weight: .medium))
                            .foregroundStyle(MyChatTheme.accent)
                            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                            .padding(.horizontal, 16)
                            .background(MyChatTheme.controlSurface, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                    .tint(MyChatTheme.accent)
                    ForEach(appModel.customModelEndpoints) { endpoint in
                        HStack(spacing: 12) {
                            Button {
                                if let model = appModel.models.first(where: { $0.endpointID == endpoint.id }) {
                                    appModel.selectModel(model)
                                }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(endpoint.name).font(MyChatSystemFont.appFont(for: .body, weight: .medium))
                                        Text(endpoint.baseURL).font(MyChatSystemFont.appFont(for: .caption1, weight: .regular)).foregroundStyle(MyChatTheme.secondaryText)
                                            .lineLimit(1)
                                        if endpoint.needsReconnect {
                                            Text("凭据已失效，请移除后重新连接").font(MyChatSystemFont.appFont(for: .caption1, weight: .regular)).foregroundStyle(.red)
                                        }
                                    }
                                    Spacer()
                                    if appModel.selectedModel?.endpointID == endpoint.id {
                                        Image(systemName: "checkmark").foregroundStyle(MyChatTheme.accent)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(endpoint.needsReconnect)
                            Button { endpointToDelete = endpoint } label: {
                                Image(systemName: "trash").frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("移除 \(endpoint.name)")
                        }
                        .padding(14)
                        .background(MyChatTheme.raised, in: RoundedRectangle(cornerRadius: 16))
                    }
                    SettingsErrorText(message: endpointError)
                }
                Text("可用模型")
                    .font(MyChatSystemFont.appFont(for: .headline, weight: .semibold))

                if builtInModels.isEmpty {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .frame(height: 84)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(builtInModels) { model in
                            Button {
                                appModel.selectModel(model)
                            } label: {
                                HStack(spacing: 12) {
                                    ProviderBadge(provider: model.provider, modelID: model.id, size: 38)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(model.name)
                                            .font(MyChatSystemFont.appFont(size: 16, weight: .medium))
                                            .foregroundStyle(MyChatTheme.text)
                                            .lineLimit(1)
                                        Text(model.provider)
                                            .font(MyChatSystemFont.appFont(for: .caption1, weight: .regular))
                                            .foregroundStyle(MyChatTheme.secondaryText)
                                    }
                                    Spacer()
                                    ModelPricePair(model: model)
                                    if appModel.selectedModelID == model.id {
                                        Image(systemName: "checkmark")
                                            .font(MyChatSystemFont.appFont(size: 13, weight: .bold))
                                            .foregroundStyle(MyChatTheme.accent)
                                    } else if !model.isSelectable {
                                        Image(systemName: "lock")
                                            .font(MyChatSystemFont.appFont(for: .caption1, weight: .regular))
                                            .foregroundStyle(MyChatTheme.secondaryText)
                                    }
                                }
                                .padding(.horizontal, 14)
                                .frame(minHeight: 58)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(!model.isSelectable)

                            if model.id != builtInModels.last?.id {
                                Divider().padding(.leading, 64)
                            }
                        }
                    }
                    .background(
                        MyChatTheme.raised,
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                    )
                }
            }
            .padding(22)
        }
        .navigationTitle("模型与 API")
        .navigationBarTitleDisplayMode(.inline)
        .foregroundStyle(MyChatTheme.text)
        .tint(MyChatTheme.accent)
        .background(MyChatTheme.canvas)
        .task { await appModel.loadModelsIfNeeded() }
        .refreshable { await appModel.reloadModels() }
        .sheet(isPresented: $editorPresented) {
            CustomModelEndpointEditor { endpoint in
                if let model = appModel.models.first(where: { $0.endpointID == endpoint.id }) {
                    appModel.selectModel(model)
                }
            }
            .environmentObject(appModel)
        }
        .confirmationDialog("移除这个自定义 API？", isPresented: Binding(
            get: { endpointToDelete != nil }, set: { if !$0 { endpointToDelete = nil } }
        ), titleVisibility: .visible) {
            Button("移除", role: .destructive) {
                guard let endpoint = endpointToDelete else { return }
                endpointToDelete = nil
                Task {
                    do { try await appModel.deleteCustomModelEndpoint(endpoint); endpointError = nil }
                    catch { endpointError = error.localizedDescription }
                }
            }
            Button("取消", role: .cancel) { endpointToDelete = nil }
        }
    }

    private var builtInModels: [ModelCatalogItem] {
        appModel.models.filter { $0.endpointID == nil }
    }

}

struct MCPConnectorsSettingsView: View {
    @EnvironmentObject private var appModel: AppModel
    @StateObject private var authenticator = MCPWebAuthenticator()
    @State private var editorPresented = false
    @State private var directoryPresented = false
    @State private var connectorToDelete: MCPConnectorRecord?
    @State private var busyConnectorIDs: Set<String> = []
    @State private var operationError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 17) {
                DefaultConnectorsView(ownerID: appModel.authSession?.user.id ?? "")
                    .id(appModel.authSession?.user.id)
                if case .loading = appModel.connectorsPhase, appModel.connectors.isEmpty {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .frame(height: 130)
                } else if case .failed = appModel.connectorsPhase, appModel.connectors.isEmpty {
                    VStack(spacing: 10) {
                        Text("无法加载连接器")
                            .font(MyChatTypography.cardBody)
                        Button("重试") { Task { await appModel.reloadConnectors() } }
                            .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, minHeight: 130)
                } else if appModel.connectors.isEmpty {
                    EmptyView()
                } else {
                    ForEach(appModel.connectors) { connector in
                        connectorCard(connector)
                    }
                }

                if let notice = appModel.connectorNotice {
                    Text(notice).font(MyChatTypography.caption).foregroundStyle(MyChatTheme.secondaryText)
                }
                SettingsErrorText(message: operationError ?? appModel.connectorsError)
            }
            .padding(20)
        }
        .scrollIndicators(.hidden)
        .navigationTitle("连接器")
        .navigationBarTitleDisplayMode(.inline)
        .foregroundStyle(MyChatTheme.text)
        .tint(MyChatTheme.accent)
        .background(MyChatTheme.canvas)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("浏览连接器", systemImage: "square.grid.2x2") { directoryPresented = true }
                    Button("添加自定义连接器", systemImage: "plus") { editorPresented = true }
                } label: { Image(systemName: "plus") }.accessibilityLabel("添加连接器")
            }
        }
        .task { await appModel.reloadConnectors() }
        .refreshable { await appModel.reloadConnectors() }
        .navigationDestination(isPresented: $editorPresented) {
            MCPConnectorEditor(entry: nil, onConnected: { editorPresented = false })
                .environmentObject(appModel)
        }
        .navigationDestination(isPresented: $directoryPresented) {
            MCPConnectorDirectoryView(
                opensEditorOnSelection: true,
                onSelect: { _ in },
                onConnected: { directoryPresented = false }
            )
            .environmentObject(appModel)
        }
        .confirmationDialog("断开此连接器？", isPresented: Binding(
            get: { connectorToDelete != nil },
            set: { if !$0 { connectorToDelete = nil } }
        ), titleVisibility: .visible) {
            Button("断开连接", role: .destructive) {
                guard let connector = connectorToDelete else { return }
                connectorToDelete = nil
                perform(connector, operation: { try await appModel.deleteConnector(connector) })
            }
            Button("取消", role: .cancel) { connectorToDelete = nil }
        } message: {
            if let connectorToDelete {
                Text("将移除 \(connectorToDelete.name)，删除保存的凭据，并尝试向服务方撤销授权。")
            }
        }
    }

    private func connectorCard(_ connector: MCPConnectorRecord) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(connector.name)
                        .font(MyChatTypography.cardTitle)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Toggle("已启用", isOn: Binding(
                    get: { connector.enabled },
                    set: { enabled in
                        perform(connector) {
                            try await appModel.setConnectorEnabled(connector, enabled: enabled)
                        }
                    }
                ))
                .labelsHidden()
                .accessibilityLabel("启用 \(connector.name)")
                .disabled(busyConnectorIDs.contains(connector.id))
            }

            HStack(spacing: 8) {
                Label("\(connector.toolCount)", systemImage: "wrench.and.screwdriver")
                if connector.authType == "oauth" {
                    Label(connector.authorizationStatus == "connected" ? "已连接" : "需授权", systemImage: "person.badge.key")
                } else if connector.hasAccessToken {
                    Label("令牌已保存", systemImage: "lock.fill")
                } else {
                    Label("无需认证", systemImage: "globe")
                }
            }
            .font(MyChatTypography.caption)
            .foregroundStyle(MyChatTheme.secondaryText)

            HStack(spacing: 10) {
                if connector.authType == "oauth" {
                    Button("重新授权") {
                        perform(connector) {
                            guard let owner = appModel.authSession?.user.id else { throw AccountSettingsError.invalidAccessToken }
                            let started = try await appModel.startConnectorAuthorization(connectorID: connector.id,
                                name: connector.name, serverURL: connector.serverURL)
                            let callback = try await authenticator.authenticate(started.authorizationUrl)
                            try await appModel.finishConnectorAuthorization(started, callback: callback, ownerID: owner)
                        }
                    }
                    .font(MyChatTypography.caption)
                    .disabled(busyConnectorIDs.contains(connector.id))
                }
                Button {
                    perform(connector) {
                        try await appModel.refreshConnector(connector)
                    }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                        .font(MyChatTypography.caption)
                        .frame(minHeight: 40)
                }
                .buttonStyle(.plain)
                .disabled(busyConnectorIDs.contains(connector.id))

                Spacer(minLength: 0)

                Button(role: .destructive) {
                    connectorToDelete = connector
                } label: {
                    Label("断开", systemImage: "trash")
                        .font(MyChatTypography.caption)
                        .frame(minHeight: 40)
                }
                .buttonStyle(.plain)
                .disabled(busyConnectorIDs.contains(connector.id))
            }
            .tint(MyChatTheme.accent)
        }
        .padding(15)
        .background(MyChatTheme.raised, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .stroke(MyChatTheme.border.opacity(0.55), lineWidth: 0.7)
                .allowsHitTesting(false)
        }
    }

    private func perform(
        _ connector: MCPConnectorRecord,
        operation: @escaping () async throws -> Void
    ) {
        guard !busyConnectorIDs.contains(connector.id) else { return }
        busyConnectorIDs.insert(connector.id)
        operationError = nil
        Task {
            defer { busyConnectorIDs.remove(connector.id) }
            do { try await operation() }
            catch { operationError = error.localizedDescription }
        }
    }
}

private struct MCPConnectorEditor: View {
    @EnvironmentObject private var appModel: AppModel
    @StateObject private var authenticator = MCPWebAuthenticator()
    @State private var directoryPresented = false
    private let onConnected: () -> Void
    @State private var authMode = "oauth"
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var pendingAuthorization: MCPOAuthStartResponse?
    @State private var name = ""
    @State private var serverURL = ""
    @State private var accessToken = ""
    @State private var saving = false
    @State private var errorMessage: String?

    init(entry: MCPDirectoryEntry? = nil, onConnected: @escaping () -> Void) {
        self.onConnected = onConnected
        _name = State(initialValue: entry?.name ?? "")
        _serverURL = State(initialValue: entry?.serverUrl ?? "")
        _authMode = State(initialValue: entry?.authType ?? "oauth")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Button { directoryPresented = true } label: {
                    Label("常用服务", systemImage: "square.grid.2x2")
                        .font(MyChatTypography.button).frame(minHeight: 44)
                }
                .accessibilityIdentifier("connector.directory")

                TextField("名称", text: $name)
                    .textContentType(.name)
                    .settingsField()
                    .accessibilityIdentifier("connector.name")

                TextField("MCP 服务地址", text: $serverURL)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .settingsField()
                    .accessibilityIdentifier("connector.server-url")
                    .disabled(pendingAuthorization != nil)

                Picker("认证", selection: $authMode) {
                    Text("OAuth").tag("oauth")
                    Text("令牌").tag("bearer")
                    Text("无").tag("none")
                }.pickerStyle(.segmented).disabled(pendingAuthorization != nil)
                if authMode == "bearer" {
                    SecureField("访问令牌", text: $accessToken)
                        .textContentType(.password).textInputAutocapitalization(.never)
                        .autocorrectionDisabled().settingsField()
                        .accessibilityIdentifier("connector.access-token")
                } else if authMode == "oauth" {
                    DisclosureGroup("OAuth 客户端") {
                        TextField("客户端 ID", text: $clientID)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().settingsField()
                        SecureField("客户端密钥", text: $clientSecret)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().settingsField()
                        Text("回调地址")
                            .font(MyChatTypography.caption)
                        Text("https://mychat-nm6x.onrender.com/api/connectors/oauth/callback")
                            .font(MyChatTypography.caption).textSelection(.enabled)
                    }
                }

                SettingsErrorText(message: errorMessage)
            }
            .padding(20)
        }
        .foregroundStyle(MyChatTheme.text)
        .background(MyChatTheme.canvas)
        .navigationTitle("连接服务")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(action: save) {
                    if saving { ProgressView().controlSize(.small) }
                    else { Text("连接") }
                }
                .disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("connector.connect")
            }
        }
        .navigationDestination(isPresented: $directoryPresented) {
            MCPConnectorDirectoryView(
                opensEditorOnSelection: false,
                onSelect: { entry in
                    name = entry.name
                    serverURL = entry.serverUrl
                    authMode = entry.authType
                    pendingAuthorization = nil
                    directoryPresented = false
                },
                onConnected: onConnected
            )
            .environmentObject(appModel)
        }
    }

    private func save() {
        guard !saving else { return }
        saving = true
        errorMessage = nil
        Task {
            do {
                if authMode == "oauth" {
                    guard let owner = appModel.authSession?.user.id else { throw AccountSettingsError.invalidAccessToken }
                    let started = try await appModel.startConnectorAuthorization(
                        connectorID: pendingAuthorization?.connectorId, name: name, serverURL: serverURL,
                        clientID: clientID.isEmpty ? nil : clientID, clientSecret: clientSecret.isEmpty ? nil : clientSecret)
                    pendingAuthorization = started
                    let callback = try await authenticator.authenticate(started.authorizationUrl)
                    try await appModel.finishConnectorAuthorization(started, callback: callback, ownerID: owner)
                } else {
                    _ = try await appModel.createConnector(name: name, serverURL: serverURL,
                        accessTokenValue: authMode == "bearer" ? accessToken : nil)
                }
                onConnected()
            } catch {
                errorMessage = error.localizedDescription
                saving = false
            }
        }
    }
}

@MainActor private final class MCPWebAuthenticator: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func authenticate(_ url: URL) async throws -> URL {
        guard session == nil else { throw AccountSettingsError.invalidInput("已有授权正在进行") }
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "mychat") { [weak self] callback, error in
                Task { @MainActor in
                    self?.session = nil
                    if let callback { continuation.resume(returning: callback) }
                    else {
                        let cancelled = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                        continuation.resume(throwing: AccountSettingsError.invalidInput(cancelled ? "授权已取消，可以重试" : "无法完成登录授权，请重试"))
                    }
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                self.session = nil
                continuation.resume(throwing: AccountSettingsError.invalidInput("无法打开授权页面，请重试"))
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}

private struct MCPConnectorDirectoryView: View {
    @EnvironmentObject private var appModel: AppModel
    let opensEditorOnSelection: Bool
    let onSelect: (MCPDirectoryEntry) -> Void
    let onConnected: () -> Void
    @State private var selectedEntry: MCPDirectoryEntry?
    @State private var editorPresented = false
    @State private var query = ""
    @State private var entries: [MCPDirectoryEntry] = []
    @State private var nextCursor: String?
    @State private var loading = false
    @State private var error: String?
    @State private var requestID = UUID()

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(entries) { entry in
                    Button {
                        if opensEditorOnSelection {
                            selectedEntry = entry
                            editorPresented = true
                        } else {
                            onSelect(entry)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 10) {
                                Image(systemName: "square.grid.2x2").font(MyChatSystemFont.appFont(size: 16))
                                    .frame(width: 28, height: 28).background(MyChatTheme.selected, in: RoundedRectangle(cornerRadius: 7))
                                Text(entry.name).font(MyChatTypography.cardTitle)
                                Spacer(minLength: 6)
                                Text("连接").font(MyChatSystemFont.appFont(size: 13, weight: .medium))
                                    .foregroundStyle(MyChatTheme.canvas).padding(.horizontal, 14).frame(height: 28)
                                    .background(MyChatTheme.text, in: Capsule())
                            }
                            Text(entry.description).font(MyChatTypography.caption).foregroundStyle(MyChatTheme.secondaryText)
                                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(MyChatTheme.raised, in: RoundedRectangle(cornerRadius: 18))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("connector.catalog.\(entry.id)")
                }
                if loading { ProgressView().padding() }
                if let error { Text(error).foregroundStyle(.red); Button("重试") { Task { await load(reset: true) } } }
                if entries.isEmpty && !loading && error == nil { Text("未找到可直接连接的服务").foregroundStyle(MyChatTheme.secondaryText).padding(.vertical, 50) }
                if nextCursor != nil { Button("加载更多") { Task { await load(reset: false) } }.disabled(loading) }
            }.padding(.horizontal, 16).padding(.top, 12)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                TextField("搜索连接器", text: $query)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("connector.directory.search")
            }.font(MyChatTypography.navigation).foregroundStyle(MyChatTheme.secondaryText)
                .padding(.horizontal, 14).frame(height: 44)
                .modifier(MyChatFloatingSurface(shape: Capsule(), isInteractive: true))
                .padding(.horizontal, 16).padding(.vertical, 8)
        }
        .background(MyChatTheme.canvas).foregroundStyle(MyChatTheme.text)
        .navigationTitle("连接器").navigationBarTitleDisplayMode(.inline)
        .task(id: query) {
            do { try await Task.sleep(for: .milliseconds(300)); await load(reset: true) }
            catch { }
        }
        .tint(MyChatTheme.accent)
        .navigationDestination(isPresented: $editorPresented) {
            if let selectedEntry {
                MCPConnectorEditor(entry: selectedEntry, onConnected: onConnected)
                    .environmentObject(appModel)
            }
        }
    }

    @MainActor private func load(reset: Bool) async {
        let id = UUID(); requestID = id
        if reset { entries = []; nextCursor = nil }
        loading = true; error = nil
        defer { if requestID == id { loading = false } }
        do {
            let result = try await appModel.fetchConnectorDirectory(search: query, cursor: reset ? nil : nextCursor)
            guard requestID == id, !Task.isCancelled else { return }
            let existing = Set(entries.map(\.id))
            entries.append(contentsOf: result.entries.filter { !existing.contains($0.id) })
            nextCursor = result.nextCursor
        } catch {
            guard requestID == id, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}

private struct ModelPricePair: View {
    let model: ModelCatalogItem

    var body: some View {
        HStack(spacing: 7) {
            Label(price(model.promptPrice), systemImage: "arrow.down")
            Label(price(model.completionPrice), systemImage: "arrow.up")
        }
        .font(MyChatSystemFont.appFont(size: 11, weight: .medium))
        .foregroundStyle(MyChatTheme.secondaryText)
        .labelStyle(.titleAndIcon)
        .fixedSize()
        .accessibilityLabel("输入价格 \(price(model.promptPrice))，输出价格 \(price(model.completionPrice))")
    }

    private func price(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...4)))
    }
}

private struct CustomModelEndpointEditor: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss
    let onCreated: (CustomModelEndpoint) -> Void

    @State private var baseURL = ""
    @State private var apiKey = ""
    @State private var authType: CustomEndpointAuthType = .auto
    @State private var discovered: CustomModelDiscovery?
    @State private var selectedModelID = ""
    @State private var displayName = ""
    @State private var outputKind: CustomEndpointOutputKind = .chat
    @State private var discovering = false
    @State private var saving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TextField("https://api.example.com/v1", text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .settingsField()
                    SecureField("API Key（无鉴权可留空）", text: $apiKey)
                        .textContentType(.password)
                        .settingsField()
                    Picker("鉴权", selection: $authType) {
                        ForEach(CustomEndpointAuthType.allCases, id: \.self) { type in
                            Text(type.title).tag(type)
                        }
                    }
                    .pickerStyle(.menu)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 50)
                    .background(
                        MyChatTheme.raised,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )

                    Button { discover() } label: {
                        Group {
                            if discovering { ProgressView() } else { Text("读取模型") }
                        }
                        .font(MyChatSystemFont.appFont(for: .headline, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(
                            MyChatTheme.selected,
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(saving || discovering || baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if let discovered, !discovered.models.isEmpty {
                        Picker("读取到的模型", selection: $selectedModelID) {
                            ForEach(discovered.models) { model in
                                Text(model.displayName).tag(model.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 50)
                        .background(MyChatTheme.raised, in: RoundedRectangle(cornerRadius: 16))
                    }
                    TextField("模型 ID（也可手动填写）", text: $selectedModelID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .settingsField()
                    TextField("显示名称（可选）", text: $displayName).settingsField()
                    Picker("用途", selection: $outputKind) {
                        ForEach(CustomEndpointOutputKind.allCases, id: \.self) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    Button { save() } label: {
                        Group {
                            if saving { ProgressView() } else { Text("保存并选择模型") }
                        }
                        .font(MyChatSystemFont.appFont(for: .headline, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(MyChatTheme.controlSurface, in: RoundedRectangle(cornerRadius: 17))
                    }
                    .buttonStyle(.plain)
                    .disabled(saving || discovering || selectedModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    SettingsErrorText(message: errorMessage)
                }
                .padding(22)
            }
            .navigationTitle("连接模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .buttonStyle(MyChatIconButtonStyle())
                        .accessibilityLabel("关闭")
                }
            }
            .foregroundStyle(MyChatTheme.text)
            .background(MyChatTheme.canvas)
        }
    }

    private func discover() {
        discovering = true
        discovered = nil
        errorMessage = nil
        Task {
            do {
                let result = try await appModel.discoverCustomModels(
                    baseURL: baseURL,
                    apiKey: apiKey,
                    authType: authType
                )
                discovered = result
                baseURL = result.baseURL
                authType = result.authType
                selectedModelID = result.models.first(where: \.chatCompatible)?.id
                    ?? result.models.first?.id
                    ?? ""
            } catch {
                errorMessage = error.localizedDescription
            }
            discovering = false
        }
    }

    private func save() {
        saving = true
        errorMessage = nil
        Task {
            do {
                let endpoint = try await appModel.createCustomModelEndpoint(
                    CustomEndpointDraft(
                        baseURL: baseURL,
                        apiKey: apiKey,
                        model: selectedModelID,
                        displayName: displayName,
                        outputKind: outputKind,
                        authType: authType
                    )
                )
                onCreated(endpoint)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            saving = false
        }
    }
}

private struct SettingsErrorText: View {
    let message: String?

    var body: some View {
        if let message, !message.isEmpty {
            Label(PresentationText.plain(message), systemImage: "exclamationmark.triangle.fill")
                .font(MyChatSystemFont.appFont(for: .subheadline, weight: .regular))
                .foregroundStyle(Color.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private extension View {
    func settingsCardStyle(cornerRadius: CGFloat = 20) -> some View {
        self
            .background(
                MyChatTheme.raised,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
    }

    func settingsField() -> some View {
        self
            .padding(.horizontal, 14)
            .frame(minHeight: 50)
            .settingsCardStyle(cornerRadius: 16)
    }
}
