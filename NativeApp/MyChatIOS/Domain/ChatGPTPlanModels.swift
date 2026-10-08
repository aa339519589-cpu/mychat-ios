import Foundation

struct ChatGPTPlanModel: Identifiable, Hashable, Sendable {
    let slug: String
    let displayName: String
    let supportsVision: Bool
    let supportsTools: Bool
    let reasoningEfforts: [String]
    let contextLength: Int?

    var id: String { slug }
}

struct ChatGPTPlanAccount: Equatable, Sendable {
    let email: String?
    let displayName: String?
    let subject: String
    let clientID: String
    let hasPlanPermission: Bool
}

enum ChatGPTPlanConnectionState: Equatable, Sendable {
    case disconnected
    case authorizing
    case connected
    case planPermissionMissing
    case reauthorizationRequired
    case unavailable(String)
}

enum ChatGPTPlanError: Error, LocalizedError, Equatable, Sendable {
    case cancelled
    case timeout
    case callback(String)
    case identityValidation
    case registrationMissing
    case accountChanged
    case notConnected
    case planPermissionMissing
    case reauthorizationRequired
    case unsupportedFeature(String)
    case server(status: Int, code: String?, message: String, requestID: String?)
    case streamProtocol(message: String, requestID: String?)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "ChatGPT 登录已取消。没有发送任何套餐请求。"
        case .timeout:
            return "ChatGPT 登录等待超时，请重新开始授权。"
        case let .callback(message):
            return "ChatGPT 授权回调无效：\(message)"
        case .identityValidation:
            return "无法验证 ChatGPT 账户身份，凭据没有保存。"
        case .registrationMissing:
            return "OpenAI 没有返回正式 client_id，注册未完成。请重新登录。"
        case .accountChanged:
            return "授权账户与当前已连接账户不同。为保护原账户凭据，登录未切换。"
        case .notConnected:
            return "请先在设置中连接 ChatGPT 账户。"
        case .planPermissionMissing:
            return "账户已登录，但未授予 ChatGPT 套餐调用权限。请重新授权套餐权限后再使用。"
        case .reauthorizationRequired:
            return "ChatGPT 授权已失效，请重新登录。MyChat 不会切换到其他 API 计费通道。"
        case let .unsupportedFeature(feature):
            return "当前 ChatGPT 套餐通道暂不支持\(feature)，此请求未发送。"
        case let .server(status, code, message, requestID):
            let suffix = requestID.map { "（请求 ID：\($0)）" } ?? ""
            switch code {
            case "subscription_sharing_usage_limit_exceeded":
                return "ChatGPT 套餐通道的当前应用额度已达到限制。请查看 ChatGPT 用量设置；MyChat 不会转用 API Key。\(suffix)"
            case "subscription_sharing_user_not_eligible":
                return "此 ChatGPT 账户、工作区或策略当前不符合套餐共享资格。请检查所选账户；MyChat 不会反复授权或切换计费方式。\(suffix)"
            case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable":
                return "暂时无法读取 ChatGPT 套餐用量，请稍后重试。凭据已保留。\(suffix)"
            case "subscription_sharing_unsupported_capability":
                return "ChatGPT 套餐路由不支持此模型能力或请求参数：\(message)\(suffix)"
            case "subscription_sharing_route_not_supported":
                return "ChatGPT 套餐路由拒绝了当前接口请求，请检查 MyChat 的请求实现。\(suffix)"
            case "subscription_sharing_invalid_user", "invalid_grant", "invalid_refresh_token",
                 "token_expired", "refresh_token_expired", "refresh_token_invalidated",
                 "refresh_token_reused":
                return "ChatGPT 授权已过期或被撤销，请重新登录。MyChat 不会转用 API Key。\(suffix)"
            case "chatpass_v2_scope_not_authorized", "chatpass_v2_invalid_authorization_context":
                return "ChatGPT 套餐权限上下文无效。请重新连接账户并检查授权范围。\(suffix)"
            default:
                return "ChatGPT 服务请求失败（HTTP \(status)）：\(message)\(suffix)"
            }
        case let .streamProtocol(message, requestID):
            let suffix = requestID.map { "（请求 ID：\($0)）" } ?? ""
            return "ChatGPT Responses 流异常：\(message)\(suffix)"
        case .invalidResponse:
            return "ChatGPT 服务返回了无效响应。"
        }
    }
}
