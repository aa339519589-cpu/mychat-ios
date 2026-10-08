import Foundation

protocol ModelCatalogServing: Sendable {
    func fetchCatalog(accessToken: String?) async throws -> ModelCatalogPayload
}

enum ModelCatalogError: LocalizedError {
    case invalidResponse
    case server(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "模型目录返回了无效响应"
        case let .server(_, message):
            return message
        }
    }
}

struct ModelCatalogClient: ModelCatalogServing {
    private let session: URLSession
    private let catalogURL: URL

    init(
        session: URLSession = .shared,
        catalogURL: URL = URL(string: "https://mychat-nm6x.onrender.com/api/models")!
    ) {
        self.session = session
        self.catalogURL = catalogURL
    }

    func fetchCatalog(accessToken: String? = nil) async throws -> ModelCatalogPayload {
        var request = URLRequest(url: catalogURL)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accessToken, !accessToken.isEmpty {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ModelCatalogError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ModelCatalogPayload.self, from: data).error)
                ?? "模型目录暂时不可用"
            throw ModelCatalogError.server(status: http.statusCode, message: message)
        }
        return try JSONDecoder().decode(ModelCatalogPayload.self, from: data)
    }
}
