import SwiftUI

struct DefaultConnectorsView: View {
    @EnvironmentObject private var appModel: AppModel
    @StateObject private var health: HealthConnector
    @State private var busy: Kind?
    @State private var error: String?
    private let ownerID: String
    private enum Kind { case health }

    init(ownerID: String) {
        self.ownerID = ownerID
        _health = StateObject(wrappedValue: HealthConnector(ownerID: ownerID))
    }

    var body: some View {
        VStack(spacing: 0) {
            row(.health, title: "苹果", icon: "ConnectorHealth")
        }
        .background(MyChatTheme.raised, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .disabled(ownerID.isEmpty || appModel.isPrivateChat)
        .alert("无法连接", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private func row(_ kind: Kind, title: String, icon: String) -> some View {
        HStack(spacing: 0) {
            Button { connect(kind) } label: {
            HStack(spacing: 13) {
                Image(icon).resizable().interpolation(.high).scaledToFit()
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityHidden(true)
                Text(title).font(MyChatTypography.navigation)
                Spacer(minLength: 0)
                if busy == kind && !health.authorizationWasRequested { ProgressView() }
                else if !health.authorizationWasRequested {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(MyChatTheme.secondaryText)
                }
            }
            .padding(.leading, 16).padding(.trailing, 12).frame(minHeight: 72)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy != nil)
            if health.authorizationWasRequested {
                Toggle(title, isOn: Binding(get: {
                    health.isEnabled
                }, set: { enabled in
                        health.setEnabled(enabled)
                        if enabled { Task { _ = await HealthConnector.modelContext(ownerID: ownerID, refresh: true) } }
                }))
                .labelsHidden().tint(MyChatTheme.toggleOnTint)
                .padding(.trailing, 16)
                .accessibilityIdentifier("connectors.default.health.enabled")
            }
        }
        .accessibilityIdentifier("connectors.default.health")
        .contextMenu {
            if health.authorizationWasRequested {
                Button("断开连接", role: .destructive) { health.disconnect() }
            }
        }
    }

    private func connect(_ kind: Kind) {
        guard busy == nil, !appModel.isPrivateChat else { return }
        busy = kind
        Task {
            defer { busy = nil }
            do {
                    if !health.authorizationWasRequested || health.needsExpandedAuthorization { try await health.authorize() }
                    else {
                        health.setEnabled(!health.isEnabled)
                        if health.isEnabled { Task { _ = await HealthConnector.modelContext(ownerID: ownerID, refresh: true) } }
                    }
            } catch { self.error = error.localizedDescription }
        }
    }
}
