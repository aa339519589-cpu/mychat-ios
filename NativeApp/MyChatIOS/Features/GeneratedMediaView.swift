import AVFoundation
import AVKit
import SwiftUI
import UIKit

struct GeneratedMediaView: View {
    @EnvironmentObject private var appModel: AppModel
    let media: ChatGeneratedMedia

    var body: some View {
        switch media.type {
        case .image:
            AuthenticatedGeneratedImage(
                media: media,
                accessToken: appModel.authSession?.accessToken
            )
        case .video:
            AuthenticatedGeneratedVideo(
                media: media,
                accessToken: appModel.authSession?.accessToken
            )
        }
    }
}

private struct AuthenticatedGeneratedImage: View {
    let media: ChatGeneratedMedia
    let accessToken: String?
    @State private var phase = ImagePhase.loading

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 180)
            case let .loaded(image):
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(media.alt ?? "生成图片")
            case .failed:
                Label("图片暂时无法载入", systemImage: "photo.badge.exclamationmark")
                    .font(MyChatSystemFont.appFont(for: .subheadline, weight: .regular))
                    .foregroundStyle(MyChatTheme.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .background(MyChatTheme.raised)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .task(id: media.url) {
            phase = .loading
            do {
                let data = try await GeneratedMediaTransport.load(
                    value: media.url,
                    accessToken: accessToken,
                    expected: .image
                )
                guard let image = UIImage(data: data) else { throw GeneratedMediaLoadError.invalidData }
                phase = .loaded(image)
            } catch {
                phase = .failed
            }
        }
    }

    private enum ImagePhase {
        case loading
        case loaded(UIImage)
        case failed
    }
}

private struct AuthenticatedGeneratedVideo: View {
    let media: ChatGeneratedMedia
    let accessToken: String?
    @State private var phase = VideoPhase.loading
    @State private var temporaryURL: URL?

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 190)
            case let .loaded(player):
                VideoPlayer(player: player)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .onDisappear { player.pause() }
                    .accessibilityLabel(media.alt ?? "生成视频")
            case .failed:
                Label("视频暂时无法载入", systemImage: "video.slash")
                    .font(MyChatSystemFont.appFont(for: .subheadline, weight: .regular))
                    .foregroundStyle(MyChatTheme.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .background(MyChatTheme.raised)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .task(id: media.url) {
            phase = .loading
            if let temporaryURL {
                try? FileManager.default.removeItem(at: temporaryURL)
                self.temporaryURL = nil
            }
            do {
                let data = try await GeneratedMediaTransport.load(
                    value: media.url,
                    accessToken: accessToken,
                    expected: .video
                )
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("mp4")
                try data.write(to: url, options: .atomic)
                temporaryURL = url
                phase = .loaded(AVPlayer(url: url))
            } catch {
                phase = .failed
            }
        }
        .onDisappear {
            if let temporaryURL {
                try? FileManager.default.removeItem(at: temporaryURL)
                self.temporaryURL = nil
            }
        }
    }

    private enum VideoPhase {
        case loading
        case loaded(AVPlayer)
        case failed
    }
}

private enum GeneratedMediaLoadError: Error {
    case invalidURL
    case invalidData
    case unsupportedType
    case response(Int)
    case tooLarge
}

private enum GeneratedMediaTransport {
    private static let baseURL = URL(string: "https://mychat-nm6x.onrender.com")!

    enum Expected {
        case image
        case video
    }

    static func resolvedURL(_ value: String) -> URL? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.lowercased().hasPrefix("data:") else { return nil }
        return URL(string: value, relativeTo: baseURL)?.absoluteURL
    }

    static func isMyChatOrigin(_ url: URL) -> Bool {
        url.scheme?.lowercased() == baseURL.scheme?.lowercased()
            && url.host?.lowercased() == baseURL.host?.lowercased()
            && effectivePort(url) == effectivePort(baseURL)
    }

    static func load(
        value: String,
        accessToken: String?,
        expected: Expected
    ) async throws -> Data {
        if value.lowercased().hasPrefix("data:") {
            return try decodeDataURL(value, expected: expected)
        }
        guard let url = resolvedURL(value), url.scheme?.lowercased() == "https" else {
            throw GeneratedMediaLoadError.invalidURL
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 45
        request.cachePolicy = .returnCacheDataElseLoad
        request.setValue("mychat-ios/1.0", forHTTPHeaderField: "X-Client-Info")
        if isMyChatOrigin(url), let accessToken, !accessToken.isEmpty {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw GeneratedMediaLoadError.invalidData
        }
        guard (200..<300).contains(response.statusCode) else {
            throw GeneratedMediaLoadError.response(response.statusCode)
        }
        guard data.count <= 25 * 1024 * 1024 else { throw GeneratedMediaLoadError.tooLarge }
        let mime = response.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";", maxSplits: 1)
            .first?
            .lowercased()
        switch expected {
        case .image where mime?.hasPrefix("image/") != true:
            throw GeneratedMediaLoadError.unsupportedType
        case .video where mime?.hasPrefix("video/") != true:
            throw GeneratedMediaLoadError.unsupportedType
        default:
            return data
        }
    }

    private static func decodeDataURL(_ value: String, expected: Expected) throws -> Data {
        guard
            let comma = value.firstIndex(of: ","),
            value[..<comma].lowercased().hasSuffix(";base64")
        else { throw GeneratedMediaLoadError.invalidData }
        let header = value[..<comma].lowercased()
        switch expected {
        case .image where !header.hasPrefix("data:image/"):
            throw GeneratedMediaLoadError.unsupportedType
        case .video where !header.hasPrefix("data:video/"):
            throw GeneratedMediaLoadError.unsupportedType
        default:
            break
        }
        guard let data = Data(base64Encoded: String(value[value.index(after: comma)...])),
              data.count <= 25 * 1024 * 1024 else {
            throw GeneratedMediaLoadError.tooLarge
        }
        return data
    }

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        if url.scheme?.lowercased() == "https" { return 443 }
        if url.scheme?.lowercased() == "http" { return 80 }
        return nil
    }
}
