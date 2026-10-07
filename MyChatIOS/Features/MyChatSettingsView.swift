import Combine
import SwiftUI
import UIKit

struct MyChatSettingsView: View {
    private let appModel: AppModel
    private let close: () -> Void
    @StateObject private var account: SettingsAccountUpdates
    @State private var path: [Destination] = []
    @AppStorage("mychat.profile.avatarJPEG") private var avatarData = Data()
    @State private var avatar: UIImage?
    @State private var signingOut = false
    init(appModel: AppModel, close: @escaping () -> Void) {
        self.appModel = appModel; self.close = close
        _account = StateObject(wrappedValue: SettingsAccountUpdates(appModel))
    }
    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    accountTile
                    NativeSettingsSection(title: "Account") {
                        row("Profile", icon: "person.crop.circle", destination: .profile)
                        divider
                        row("Password", icon: "lock", destination: .password)
                        divider
                        row("Privacy", icon: "lock.shield", destination: .privacy)
                    }
                    NativeSettingsSection(title: "App") {
                        row("Capabilities", icon: "slider.horizontal.3", destination: .capabilities)
                        if appModel.authSession != nil {
                            divider
                            row("Connectors", icon: "square.grid.2x2", destination: .connectors)
                        }
                    }
                    if appModel.authSession != nil {
                        Button {
                            signingOut = true
                            Task { await appModel.signOut(); signingOut = false; close() }
                        } label: {
                            HStack(spacing: 16) {
                                Image(systemName: "rectangle.portrait.and.arrow.right").frame(width: 20)
                                if signingOut { ProgressView() } else { Text("Sign out") }
                                Spacer()
                            }.font(MyChatTypography.navigation).foregroundStyle(.red)
                                .padding(.horizontal, 22).frame(height: 52).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(signingOut)
                            .background(MyChatTheme.raised, in: RoundedRectangle(cornerRadius: 22))
                    }
                }.padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 32)
            }
            .scrollIndicators(.hidden).background(MyChatTheme.canvas)
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: close) { Image(systemName: "xmark").font(MyChatSystemFont.appFont(size: 16)) }
                        .accessibilityLabel("Close settings")
                }
                ToolbarItem(placement: .principal) {
                    Text("Settings").font(MyChatSystemFont.appFont(size: 17, weight: .semibold)).accessibilityAddTraits(.isHeader)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Text("MyChat v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"))")
                        NavigationLink("Licenses", value: Destination.licenses)
                    } label: { Image(systemName: "info").font(MyChatSystemFont.appFont(size: 16)) }
                    .accessibilityLabel("About MyChat")
                }
            }
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .profile: SystemPromptSettingsView(appModel: appModel)
                case .privacy: DataControlsSettingsView()
                case .password: ChangePasswordSettingsView()
                case .capabilities: CapabilitiesSettingsView()
                case .connectors: MCPConnectorsSettingsView()
                case .licenses: ScrollView {
                    Text(licenseText).font(MyChatTypography.caption).frame(maxWidth: .infinity, alignment: .leading).padding(20)
                }.navigationTitle("Licenses").background(MyChatTheme.canvas)
                }
            }
        }
        .foregroundStyle(MyChatTheme.text).tint(MyChatTheme.text)
        .toolbarBackground(MyChatTheme.canvas, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task(id: avatarData) {
            let data = avatarData
            avatar = await Task.detached(priority: .utility) { UIImage(data: data) }.value
        }
    }
    private var accountTile: some View {
        HStack(spacing: 8) {
            Group {
                if let avatar { Image(uiImage: avatar).resizable().scaledToFill() }
                else { Text(String((appModel.authSession?.user.email ?? "M").first ?? "M").uppercased())
                    .font(MyChatSystemFont.appFont(size: 19, weight: .medium)) }
            }.frame(width: 40, height: 40)
                .background(MyChatTheme.settingsAvatar).clipShape(Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(appModel.authSession?.user.email ?? "Guest").font(MyChatTypography.navigation).lineLimit(1)
                Label("Personal", systemImage: "person").font(MyChatTypography.metadata).foregroundStyle(MyChatTheme.secondaryText)
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 20).frame(height: 72)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MyChatTheme.raised, in: RoundedRectangle(cornerRadius: 22))
    }
    private var divider: some View { Divider().padding(.leading, 58).padding(.trailing, 20) }
    private func row(_ title: String, icon: String, destination: Destination) -> some View {
        Button { path.append(destination) } label: { NativeSettingsRow(title: title, icon: icon) }.buttonStyle(.plain)
    }
    private var licenseText: String {
        guard let url = Bundle.main.url(forResource: "THREE-LICENSE", withExtension: "txt", subdirectory: "DotMotion"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "MyChat" }
        return text
    }
    private enum Destination: Hashable { case profile, password, privacy, capabilities, connectors, licenses }
}
struct NativeSettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    init(title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(MyChatSystemFont.appFont(size: 15)).foregroundStyle(MyChatTheme.secondaryText).padding(.leading, 20)
            VStack(spacing: 0) { content }.background(MyChatTheme.raised, in: RoundedRectangle(cornerRadius: 22))
        }
    }
}
struct NativeSettingsRow: View {
    let title: String
    let icon: String
    var detail: String? = nil
    var body: some View {
        HStack(spacing: 16) {
            if !icon.isEmpty { Image(systemName: icon).font(MyChatSystemFont.appFont(size: 17)).frame(width: 20).foregroundStyle(MyChatTheme.secondaryText) }
            Text(title).font(MyChatTypography.navigation)
            Spacer()
            if let detail { Text(detail).font(MyChatTypography.metadata).foregroundStyle(MyChatTheme.secondaryText) }
            Image(systemName: "chevron.right").font(MyChatSystemFont.appFont(size: 13)).foregroundStyle(MyChatTheme.secondaryText)
        }.padding(.horizontal, 22).frame(height: 52).contentShape(Rectangle())
    }
}
@MainActor private final class SettingsAccountUpdates: @preconcurrency ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    private var subscription: AnyCancellable?
    init(_ model: AppModel) {
        subscription = model.$authSession.removeDuplicates().dropFirst().sink { [weak self] _ in self?.objectWillChange.send() }
    }
}
