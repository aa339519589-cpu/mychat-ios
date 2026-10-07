import SwiftUI

struct AuthenticationView: View {
    @StateObject private var viewModel: AuthenticationViewModel
    @FocusState private var focusedField: AuthenticationField?

    init(
        client: any SupabaseAuthenticating = SupabaseAuthClient(),
        onAuthenticated: @escaping (AuthSession) -> Void
    ) {
        _viewModel = StateObject(
            wrappedValue: AuthenticationViewModel(
                client: client,
                onAuthenticated: onAuthenticated
            )
        )
    }

    var body: some View {
        ZStack {
            MyChatTheme.canvas.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 54)
                    Text("欢迎来到 MyChat")
                .font(MyChatSystemFont.appFont(for: .largeTitle, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .padding(.top, 22)
                    Text("在一个地方，使用你需要的每一个模型。")
                        .font(MyChatSystemFont.appFont(for: .body, weight: .regular))
                        .foregroundStyle(MyChatTheme.secondaryText)
                        .multilineTextAlignment(.center)
                        .padding(.top, 10)
                        .padding(.horizontal, 28)

                    authCard
                        .padding(.top, 34)
                    Spacer(minLength: 28)
                }
                .frame(maxWidth: 540)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .foregroundStyle(MyChatTheme.text)
        .task {
            await viewModel.restoreSession()
        }
    }

    private var authCard: some View {
        VStack(spacing: 18) {
            modePicker

            VStack(spacing: 12) {
                fieldContainer {
                    TextField("邮箱", text: $viewModel.email)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .submitLabel(.next)
                        .focused($focusedField, equals: .email)
                        .onSubmit { focusedField = .password }
                }

                fieldContainer {
                    SecureField("密码（至少 6 位）", text: $viewModel.password)
                        .textContentType(viewModel.mode == .signIn ? .password : .newPassword)
                        .submitLabel(.go)
                        .focused($focusedField, equals: .password)
                        .onSubmit { submit() }
                }
            }

            if let message = viewModel.message {
                Label(PresentationText.plain(message.text), systemImage: message.isError ? "exclamationmark.circle" : "envelope")
                    .font(MyChatSystemFont.appFont(for: .footnote, weight: .regular))
                    .foregroundStyle(message.isError ? Color.red : MyChatTheme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(action: submit) {
                Group {
                    if viewModel.isWorking {
                        ProgressView()
                            .tint(MyChatTheme.canvas)
                    } else {
                        Text(viewModel.mode.actionTitle)
                    }
                }
                .font(MyChatSystemFont.appFont(for: .headline, weight: .semibold))
                .foregroundStyle(MyChatTheme.canvas)
                .frame(maxWidth: .infinity, minHeight: 54)
                .background(
                    MyChatTheme.text,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canSubmit)
            .opacity(viewModel.canSubmit ? 1 : 0.45)

            HStack(spacing: 14) {
                Rectangle()
                    .fill(MyChatTheme.border)
                    .frame(height: 0.7)
                Text("或者")
                    .font(MyChatSystemFont.appFont(for: .caption1, weight: .regular))
                    .foregroundStyle(MyChatTheme.secondaryText)
                    .fixedSize()
                Rectangle()
                    .fill(MyChatTheme.border)
                    .frame(height: 0.7)
            }

            Button {
                focusedField = nil
                Task { await viewModel.continueAsGuest() }
            } label: {
                Text("以游客身份继续")
                    .font(MyChatSystemFont.appFont(for: .body, weight: .medium))
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(
                        MyChatTheme.selected,
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isWorking)
        }
        .padding(18)
        .background(
            MyChatTheme.raised,
            in: RoundedRectangle(cornerRadius: 28, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(MyChatTheme.border.opacity(0.8), lineWidth: 0.7)
        }
        .shadow(color: .black.opacity(0.08), radius: 22, y: 10)
    }

    private var modePicker: some View {
        HStack(spacing: 4) {
            ForEach(EmailAuthMode.allCases) { mode in
                Button {
                    viewModel.selectMode(mode)
                } label: {
                    Text(mode.title)
                        .font(MyChatSystemFont.appFont(for: .body, weight: .medium))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(
                            viewModel.mode == mode ? MyChatTheme.raised : Color.clear,
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                        .overlay {
                            if viewModel.mode == mode {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(MyChatTheme.border.opacity(0.7), lineWidth: 0.7)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(viewModel.mode == mode ? .isSelected : [])
            }
        }
        .padding(4)
        .background(MyChatTheme.selected, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("认证方式")
    }

    private func fieldContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .font(MyChatSystemFont.appFont(for: .body, weight: .regular))
            .padding(.horizontal, 16)
            .frame(minHeight: 54)
            .background(
                MyChatTheme.canvas,
                in: RoundedRectangle(cornerRadius: 17, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .stroke(MyChatTheme.border.opacity(0.82), lineWidth: 0.7)
            }
    }

    private func submit() {
        focusedField = nil
        Task { await viewModel.submit() }
    }
}

private enum AuthenticationField {
    case email
    case password
}

enum EmailAuthMode: String, CaseIterable, Identifiable {
    case signIn
    case signUp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .signIn: return "登录"
        case .signUp: return "注册"
        }
    }

    var actionTitle: String {
        switch self {
        case .signIn: return "登录 MyChat"
        case .signUp: return "创建账户"
        }
    }
}

struct AuthenticationMessage: Equatable {
    let text: String
    let isError: Bool
}

@MainActor
final class AuthenticationViewModel: ObservableObject {
    @Published var mode: EmailAuthMode = .signIn
    @Published var email = ""
    @Published var password = ""
    @Published private(set) var isWorking = false
    @Published private(set) var message: AuthenticationMessage?

    private let client: any SupabaseAuthenticating
    private let onAuthenticated: (AuthSession) -> Void
    private var didAttemptRestore = false

    init(
        client: any SupabaseAuthenticating,
        onAuthenticated: @escaping (AuthSession) -> Void
    ) {
        self.client = client
        self.onAuthenticated = onAuthenticated
    }

    var canSubmit: Bool {
        !isWorking
            && email.trimmingCharacters(in: .whitespacesAndNewlines).contains("@")
            && password.count >= 6
    }

    func selectMode(_ mode: EmailAuthMode) {
        self.mode = mode
        message = nil
    }

    func restoreSession() async {
        guard !didAttemptRestore else { return }
        didAttemptRestore = true
        isWorking = true
        defer { isWorking = false }
        do {
            if let session = try await client.restoreSession() {
                onAuthenticated(session)
            }
        } catch {
            message = AuthenticationMessage(text: displayMessage(for: error), isError: true)
        }
    }

    func submit() async {
        guard canSubmit else { return }
        isWorking = true
        message = nil
        defer { isWorking = false }

        do {
            let result: AuthenticationResult
            switch mode {
            case .signIn:
                result = try await client.signIn(email: email, password: password)
            case .signUp:
                result = try await client.signUp(email: email, password: password)
            }
            handle(result)
        } catch {
            message = AuthenticationMessage(text: displayMessage(for: error), isError: true)
        }
    }

    func continueAsGuest() async {
        guard !isWorking else { return }
        isWorking = true
        message = nil
        defer { isWorking = false }

        do {
            let session = try await client.signInAnonymously()
            onAuthenticated(session)
        } catch {
            message = AuthenticationMessage(text: displayMessage(for: error), isError: true)
        }
    }

    private func handle(_ result: AuthenticationResult) {
        switch result {
        case let .authenticated(session):
            password = ""
            onAuthenticated(session)
        case .emailConfirmationRequired:
            password = ""
            message = AuthenticationMessage(
                text: "确认邮件已发送，请完成验证后再登录。",
                isError: false
            )
        }
    }

    private func displayMessage(for error: Error) -> String {
        AuthenticationError.connectionMessage(for: error)
    }
}
