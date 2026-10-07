import SwiftUI

struct ChatGPTPlanSettingsSection: View {
    @ObservedObject var provider: ChatGPTPlanProvider
    let onModelsUpdated: @MainActor () async -> Void
    @State private var operationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 9) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(MyChatSystemFont.appFont(size: 19, weight: .medium))
                    .foregroundStyle(MyChatTheme.accent)
                Text("ChatGPT 订阅")
                    .font(MyChatSystemFont.appFont(for: .headline, weight: .semibold))
                    .foregroundStyle(MyChatTheme.text)
                Spacer()
                if provider.isConnected && provider.canUsePlan {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(MyChatTheme.accent)
                        .accessibilityLabel("ChatGPT 套餐已连接")
                }
            }

            if let account = provider.account {
                VStack(alignment: .leading, spacing: 4) {
                    Text(account.displayName ?? "ChatGPT 账户")
                        .font(MyChatSystemFont.appFont(for: .body, weight: .medium))
                        .foregroundStyle(MyChatTheme.text)
                    if let email = account.email {
                        Text(email)
                            .font(MyChatSystemFont.appFont(for: .caption1, weight: .regular))
                            .foregroundStyle(MyChatTheme.secondaryText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(13)
                .background(MyChatTheme.controlSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            stateMessage

            if provider.isAuthorizing {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("等待 ChatGPT 授权…")
                        .font(MyChatSystemFont.appFont(for: .footnote, weight: .regular))
                        .foregroundStyle(MyChatTheme.secondaryText)
                    Spacer()
                    Button("取消") { provider.cancelSignIn() }
                        .font(MyChatSystemFont.appFont(for: .footnote, weight: .medium))
                        .foregroundStyle(MyChatTheme.accent)
                }
                .frame(minHeight: 44)
            } else {
                Button(action: beginAuthorization) {
                    HStack(spacing: 9) {
                        Image(systemName: provider.account == nil ? "person.crop.circle.badge.plus" : "arrow.clockwise")
                            .font(MyChatSystemFont.appFont(size: 16, weight: .semibold))
                        Text(primaryActionTitle)
                            .font(MyChatSystemFont.appFont(for: .body, weight: .semibold))
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(MyChatSystemFont.appFont(for: .caption1, weight: .semibold))
                    }
                    .foregroundStyle(MyChatTheme.text)
                    .padding(.horizontal, 15)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(MyChatTheme.controlSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(MyChatTheme.border.opacity(0.7), lineWidth: 0.7)
                    }
                }
                .buttonStyle(.plain)
            }

            if let operationError {
                Text(operationError)
                    .font(MyChatSystemFont.appFont(for: .footnote, weight: .regular))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MyChatTheme.raised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private var stateMessage: some View {
        switch provider.state {
        case .connected:
            EmptyView()
        case .planPermissionMissing:
            Label("已登录，但没有 ChatGPT 套餐调用权限。重新授权后才会显示套餐模型。", systemImage: "exclamationmark.circle.fill")
                .font(MyChatSystemFont.appFont(for: .footnote, weight: .regular))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .reauthorizationRequired:
            Label("授权已过期或被撤销。请重新授权；当前不会发送套餐请求。", systemImage: "exclamationmark.triangle.fill")
                .font(MyChatSystemFont.appFont(for: .footnote, weight: .regular))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case let .unavailable(message):
            Text(message)
                .font(MyChatSystemFont.appFont(for: .footnote, weight: .regular))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        case .authorizing, .disconnected:
            EmptyView()
        }
    }

    private var primaryActionTitle: String {
        switch provider.state {
        case .planPermissionMissing: return "重新授权套餐使用权限"
        case .reauthorizationRequired: return "重新连接 ChatGPT"
        case .connected: return "管理 ChatGPT 授权"
        default: return "连接 ChatGPT 账户"
        }
    }

    private func beginAuthorization() {
        let needsConsent = provider.state == .planPermissionMissing
        operationError = nil
        Task {
            do {
                try await provider.signIn(reauthorizePlanAccess: needsConsent)
                await onModelsUpdated()
                if provider.state == .planPermissionMissing {
                    operationError = "ChatGPT 账户身份已确认，但套餐权限仍未授予。请检查授权页选择的权限。"
                }
            } catch {
                if (error as? ChatGPTPlanError) != .cancelled {
                    operationError = error.localizedDescription
                }
            }
        }
    }
}
