import Foundation
import Security

struct AuthUser: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let email: String?
    let isAnonymous: Bool
}

struct AuthSession: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String
    let tokenType: String
    let expiresAt: Date
    let user: AuthUser

    func expires(within interval: TimeInterval, now: Date = Date()) -> Bool {
        expiresAt.timeIntervalSince(now) <= interval
    }
}

enum ChatAuthenticationPolicy {
    // Admission normally completes in a few seconds. Keep a small clock/network
    // margin; an already expired or nearly expired token still refreshes first.
    static let admissionSafetyMargin: TimeInterval = 8

    static func canAdmitImmediately(_ session: AuthSession, now: Date = Date()) -> Bool {
        !session.expires(within: admissionSafetyMargin, now: now)
    }
}

enum AuthenticationResult: Equatable, Sendable {
    case authenticated(AuthSession)
    case emailConfirmationRequired(AuthUser?)
}

enum AuthenticationError: LocalizedError, Equatable, Sendable {
    case invalidResponse
    case invalidCredentials
    case server(status: Int, message: String)
    case missingSession
    case noStoredSession
    case sessionExpired
    case storage(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "认证服务返回了无效响应"
        case .invalidCredentials:
            return "请输入有效的邮箱和至少 6 位密码"
        case let .server(_, message):
            return message
        case .missingSession:
            return "认证服务没有返回可用会话"
        case .noStoredSession:
            return "没有可恢复的登录会话"
        case .sessionExpired:
            return "登录会话已失效，请重新登录"
        case let .storage(message):
            return message
        }
    }
}

extension AuthenticationError {
    static func connectionMessage(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet: return "网络未连接；已保存的登录状态会保留"
            case .timedOut: return "认证连接超时，请重试；已保存的登录状态会保留"
            case .cannotFindHost, .dnsLookupFailed: return "无法解析认证服务地址，请检查当前网络或 VPN"
            case .cannotConnectToHost, .networkConnectionLost: return "认证连接中断，请检查当前网络后重试"
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
                return "无法建立安全的认证连接，请检查网络或设备时间"
            default: return "认证网络连接失败（\(urlError.code.rawValue)），请重试"
            }
        }
        return (error as? LocalizedError)?.errorDescription ?? "认证连接暂时失败，请重试"
    }
}

// Keep only error metadata for on-device diagnosis, never credentials or response bodies.
enum AuthenticationDiagnostics {
    static func record(stage: String, error: Error? = nil, status: Int? = nil) {
        var entry: [String: Any] = ["stage": stage, "time": ISO8601DateFormatter().string(from: Date())]
        if let error {
            let value = error as NSError
            entry["domain"] = value.domain
            entry["code"] = value.code
            if let url = value.userInfo[NSURLErrorFailingURLErrorKey] as? URL { entry["host"] = url.host }
        }
        if let status { entry["status"] = status }
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),
              let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return }
        try? data.write(to: directory.appendingPathComponent("mychat-auth-diagnostic.json"), options: .atomic)
        try? data.write(to: directory.appendingPathComponent("mychat-auth-\(stage)-diagnostic.json"), options: .atomic)
    }
}

protocol AuthSessionStoring: Sendable {
    func load() throws -> AuthSession?
    func save(_ session: AuthSession) throws
    func clear() throws
}

final class KeychainAuthSessionStore: AuthSessionStoring, @unchecked Sendable {
    private let service: String
    private let account: String

    init(
        service: String = "com.mychat.ios.authentication",
        account: String = "current-session"
    ) {
        self.service = service
        self.account = account
    }

    func load() throws -> AuthSession? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw keychainError(status)
        }

        do {
            return try JSONDecoder().decode(AuthSession.self, from: data)
        } catch {
            throw AuthenticationError.storage("已保存的登录会话无法读取")
        }
    }

    func save(_ session: AuthSession) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(session)
        } catch {
            throw AuthenticationError.storage("无法安全保存登录会话")
        }

        let attributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw keychainError(updateStatus)
        }

        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw keychainError(addStatus)
        }
    }

    func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func keychainError(_ status: OSStatus) -> AuthenticationError {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "状态码 \(status)"
        return .storage("Keychain 操作失败：\(detail)")
    }
}
