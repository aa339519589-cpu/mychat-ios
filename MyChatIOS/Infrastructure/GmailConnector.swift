import AuthenticationServices
import Combine
import CryptoKit
import Foundation
import Security
import UIKit

/// Native, read-only Google OAuth. Tokens never pass through the MyChat server.
/// The iOS OAuth client must be registered for com.mychat.ios before enabling it.
@MainActor final class GmailConnector: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published private(set) var isConnected = false
    @Published private(set) var isEnabled = false
    private var webSession: ASWebAuthenticationSession?
    private var credentials: Credentials?
    private let ownerID: String
    private let clientID: String
    private static let redirect = "com.mychat.ios:/oauth2redirect"
    private static let scope = "https://www.googleapis.com/auth/gmail.readonly"
    private let session = URLSession(configuration: .ephemeral)
    var isConfigured: Bool { clientID.hasSuffix(".apps.googleusercontent.com") && !clientID.contains("$(") }

    init(ownerID: String, clientID: String = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String ?? "") {
        self.ownerID = ownerID
        self.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        super.init()
        if let data = try? keychainRead(), let saved = try? JSONDecoder().decode(Credentials.self, from: data), saved.clientID == self.clientID {
            credentials = saved
            isConnected = true
            isEnabled = ConnectorEnabledPreference.value(kind: "gmail", ownerID: ownerID)
        }
    }

    func connect() async throws {
        guard isConfigured else { throw ConnectorAccessError.message("Gmail 暂未开放：需要先为 MyChat 配置 Google OAuth iOS 客户端。") }
        guard webSession == nil else { throw ConnectorAccessError.message("已有 Google 授权正在进行。") }
        let state = try randomValue(), verifier = try randomValue()
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = ["client_id": clientID, "redirect_uri": Self.redirect,
            "response_type": "code", "scope": Self.scope, "state": state,
            "code_challenge": GmailOAuth.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))),
            "code_challenge_method": "S256", "access_type": "offline", "prompt": "consent"]
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        let callback = try await authenticate(components.url!)
        let code = try GmailOAuth.authorizationCode(callback: callback, state: state)
        let token = try await exchange(["client_id": clientID, "redirect_uri": Self.redirect,
            "code": code, "code_verifier": verifier, "grant_type": "authorization_code"])
        guard token.scope?.split(separator: " ").contains(Substring(Self.scope)) == true else {
            throw ConnectorAccessError.message("未授予 Gmail 只读权限，请重新连接并选择允许读取邮件。")
        }
        try save(token, previousRefreshToken: nil)
        setEnabled(true)
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled && isConnected
        ConnectorEnabledPreference.set(isEnabled, kind: "gmail", ownerID: ownerID)
    }

    func disconnect() async throws {
        if let value = credentials {
            var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = GmailOAuth.form(["token": value.refreshToken ?? value.accessToken])
            let (_, response) = try await session.data(for: request)
            guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 || status == 400 else {
                throw ConnectorAccessError.message("Google 暂时无法撤销授权，请稍后重试。")
            }
        }
        let status = SecItemDelete(keychainQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ConnectorAccessError.message("无法删除本机 Gmail 授权。") }
        credentials = nil
        isConnected = false
        setEnabled(false)
    }

    func recentMessages() async throws -> [GmailMessageSummary] {
        let token = try await accessToken()
        let list: GmailMessageList = try await get("messages?maxResults=10&labelIds=INBOX", token: token)
        var results: [GmailMessageSummary] = []
        for item in list.messages ?? [] {
            let message: GmailMessage = try await get("messages/\(item.id)?format=metadata&metadataHeaders=Subject&metadataHeaders=From&metadataHeaders=Date", token: token)
            results.append(GmailMessageSummary(id: message.id,
                subject: message.header("Subject") ?? "（无主题）",
                sender: message.header("From") ?? "未知发件人", date: message.header("Date") ?? ""))
        }
        return results
    }

    func messageText(id: String) async throws -> String {
        guard id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { throw ConnectorAccessError.message("邮件 ID 无效。") }
        let message: GmailMessage = try await get("messages/\(id)?format=full", token: try await accessToken())
        let body = message.payload?.plainText ?? message.snippet ?? "（没有可读取的纯文本正文）"
        return ["来自 Gmail 的邮件（只读副本）", "主题：\(message.header("Subject") ?? "（无主题）")",
            "发件人：\(message.header("From") ?? "未知")", "日期：\(message.header("Date") ?? "未知")", "", String(body.prefix(40_000))]
            .joined(separator: "\n")
    }

    private func accessToken() async throws -> String {
        guard isEnabled else { throw ConnectorAccessError.message("Gmail 已关闭。") }
        guard let saved = credentials else { throw ConnectorAccessError.message("请先连接 Gmail。") }
        if saved.expiresAt.timeIntervalSinceNow > 60 { return saved.accessToken }
        guard let refresh = saved.refreshToken else { throw ConnectorAccessError.message("Google 授权已过期，请重新连接 Gmail。") }
        let token = try await exchange(["client_id": clientID, "refresh_token": refresh, "grant_type": "refresh_token"])
        try save(token, previousRefreshToken: refresh)
        return token.access_token
    }

    private func get<T: Decodable>(_ path: String, token: String) async throws -> T {
        guard isEnabled else { throw ConnectorAccessError.message("Gmail 已关闭。") }
        var request = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/" + path)!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 25
        let (data, response) = try await session.data(for: request)
        guard isEnabled else { throw ConnectorAccessError.message("Gmail 已关闭。") }
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw ConnectorAccessError.message("无法读取 Gmail，请确认网络及 Google 邮件授权。")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func exchange(_ fields: [String: String]) async throws -> Token {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = GmailOAuth.form(fields)
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ConnectorAccessError.message("Google 授权未完成或已过期，请重新连接。")
        }
        return try JSONDecoder().decode(Token.self, from: data)
    }

    private func save(_ token: Token, previousRefreshToken: String?) throws {
        let saved = Credentials(clientID: clientID, accessToken: token.access_token,
            refreshToken: token.refresh_token ?? previousRefreshToken, expiresAt: Date().addingTimeInterval(token.expires_in))
        let data = try JSONEncoder().encode(saved)
        let updated = SecItemUpdate(keychainQuery as CFDictionary, [kSecValueData: data] as CFDictionary)
        if updated == errSecItemNotFound {
            var query = keychainQuery
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw ConnectorAccessError.message("无法安全保存 Gmail 授权。") }
        } else if updated != errSecSuccess { throw ConnectorAccessError.message("无法更新 Gmail 授权。") }
        credentials = saved
        isConnected = true
        isEnabled = ConnectorEnabledPreference.value(kind: "gmail", ownerID: ownerID)
    }

    private var keychainQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.mychat.ios.gmail",
         kSecAttrAccount as String: ownerID]
    }
    private func keychainRead() throws -> Data? {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ConnectorAccessError.message("无法读取 Gmail 授权。") }
        return item as? Data
    }
    private func randomValue() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw ConnectorAccessError.message("无法创建安全授权请求。") }
        return GmailOAuth.base64URL(Data(bytes))
    }
    private func authenticate(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let auth = ASWebAuthenticationSession(url: url, callbackURLScheme: "com.mychat.ios") { [weak self] callback, error in
                Task { @MainActor in
                    self?.webSession = nil
                    if let callback { continuation.resume(returning: callback) }
                    else { continuation.resume(throwing: ConnectorAccessError.message(
                        (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin ? "Google 授权已取消。" : "无法打开 Google 授权。")) }
                }
            }
            auth.presentationContextProvider = self
            webSession = auth
            if !auth.start() {
                webSession = nil
                continuation.resume(throwing: ConnectorAccessError.message("无法启动 Google 授权。"))
            }
        }
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
    private struct Credentials: Codable { let clientID: String; let accessToken: String; let refreshToken: String?; let expiresAt: Date }
    private struct Token: Decodable { let access_token: String; let refresh_token: String?; let expires_in: Double; let scope: String? }
}

enum GmailOAuth {
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func form(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return Data(fields.sorted { $0.key < $1.key }.map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&").utf8)
    }
    static func authorizationCode(callback: URL, state: String) throws -> String {
        let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false)
        let items = parts?.queryItems ?? []
        func single(_ key: String) -> String? { let values = items.filter { $0.name == key }; return values.count == 1 ? values[0].value : nil }
        guard callback.scheme == "com.mychat.ios", callback.host == nil, callback.path == "/oauth2redirect",
              single("state") == state, !items.contains(where: { $0.name == "error" }),
              let code = single("code"), !code.isEmpty else { throw ConnectorAccessError.message("Google 授权回调无效或已取消，请重新连接。") }
        return code
    }
}

struct GmailMessageSummary: Identifiable { let id: String; let subject: String; let sender: String; let date: String }
private struct GmailMessageList: Decodable { let messages: [MessageID]?; struct MessageID: Decodable { let id: String } }
private struct GmailMessage: Decodable {
    let id: String; let snippet: String?; let payload: GmailPayload?
    func header(_ name: String) -> String? { payload?.headers?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value }
}
struct GmailPayload: Decodable {
    let mimeType: String?; let headers: [Header]?; let body: Body?; let parts: [GmailPayload]?
    struct Header: Decodable { let name: String; let value: String }
    struct Body: Decodable { let data: String? }
    var plainText: String? {
        if mimeType == "text/plain", var value = body?.data {
            value = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            value += String(repeating: "=", count: (4 - value.count % 4) % 4)
            if let data = Data(base64Encoded: value), let text = String(data: data, encoding: .utf8) { return text }
        }
        let text = (parts ?? []).compactMap(\.plainText).joined(separator: "\n")
        return text.isEmpty ? nil : text
    }
}
