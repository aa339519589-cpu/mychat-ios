import SwiftUI

@main
struct MyChatIOSApp: App {
    @StateObject private var appModel = Self.makeModel()
    @Environment(\.scenePhase) private var scenePhase

    @MainActor private static func makeModel() -> AppModel {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-test-mode") {
            return NativeRuntimeFixture.makeModel()
        }
        #endif
        return AppModel()
    }

    #if DEBUG
    private static var runsLiveAPIProbe: Bool {
        ProcessInfo.processInfo.environment["MYCHAT_LIVE_NETWORK_PROBE"] != nil
            || ProcessInfo.processInfo.arguments.contains("--live-api-probe")
    }
    private static var runtimeTestColorScheme: ColorScheme? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--ui-test-mode"),
              let index = arguments.firstIndex(of: "-AppleInterfaceStyle"),
              arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1] == "Light" ? .light : .dark
    }
    #endif

    var body: some Scene {
        WindowGroup {
            MyChatApplicationSurface(appModel: appModel)
                .font(MyChatTypography.appDefault)
                #if DEBUG
                .preferredColorScheme(Self.runtimeTestColorScheme)
                #endif
                .onChange(of: scenePhase) { _, phase in
                    #if DEBUG
                    guard !Self.runsLiveAPIProbe else { return }
                    #endif
                    if phase == .active { Task {
                        await BackendReadinessPrewarmer.shared.start()
                        await appModel.resumeAuthentication()
                        if let owner = appModel.authSession?.user.id { _ = await HealthConnector.modelContext(ownerID: owner, refresh: true) }
                    } }
                }
                .task {
                    #if DEBUG
                    // API probes own authentication; host startup must not rotate
                    // the same stored refresh token concurrently with the test.
                    if Self.runsLiveAPIProbe {
                        if ProcessInfo.processInfo.environment["MYCHAT_LIVE_NETWORK_PROBE"] == "standalone"
                            || ProcessInfo.processInfo.arguments.contains("--live-api-probe") {
                            let probe = Task { await NativeLiveChatProbe.run(appModel: appModel) }
                            let limit = Task {
                                try? await Task.sleep(for: .seconds(150))
                                if !Task.isCancelled { probe.cancel() }
                            }
                            await probe.value
                            limit.cancel()
                        }
                        return
                    }
                    #endif
                    await BackendReadinessPrewarmer.shared.start()
                    await appModel.restoreAuthenticationIfNeeded()
                    if let owner = appModel.authSession?.user.id { Task { _ = await HealthConnector.modelContext(ownerID: owner) } }
                    await appModel.loadModelsIfNeeded()
                    await openFixtureConversationIfNeeded()
                }
        }
    }

    // Device-installation verification fixture: opens the seeded conversation
    // on launch so transcript/composer geometry can be inspected without
    // touching the phone. No-op outside DEBUG and without the launch argument.
    @MainActor private func openFixtureConversationIfNeeded() async {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-test-seed-draft") {
            appModel.draft = String(repeating: "你好明确测试多行草稿排版内容 ", count: 6) + "ninpopogonpo qqssh tail"
        }
        guard ProcessInfo.processInfo.arguments.contains("--ui-test-open-conversation") else { return }
        for _ in 0..<50 {
            if let conversation = appModel.conversations.first {
                appModel.openConversation(conversation)
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
#else
        return
#endif
    }
}
