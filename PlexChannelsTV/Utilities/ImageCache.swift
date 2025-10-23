//
//  ImageCache.swift
//  PlexChannelsTV
//
//  Created by Codex on 11/02/25.
//

import SwiftUI
import UIKit
import OSLog

enum CachedImagePhase {
    case empty
    case success(Image)
    case failure
}

final class PlexImageCache {
    static let shared = PlexImageCache()

    private let cache = NSCache<NSURL, UIImage>()

    private init() {
        cache.countLimit = 150
        cache.totalCostLimit = 128 * 1024 * 1024
    }

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func insert(_ image: UIImage, for url: URL) {
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale)
        cache.setObject(image, forKey: url as NSURL, cost: cost)
    }
}

@MainActor
final class ImageLoader: ObservableObject {
    @Published private(set) var phase: CachedImagePhase = .empty

    private var task: Task<Void, Never>?
    private static var loggedMissingLogos: Set<String> = []

    func load(url: URL?, scale: CGFloat = 1.0) {
        task?.cancel()

        guard let url else {
            phase = .empty
            return
        }

        // Check cache first
        if let cached = PlexImageCache.shared.image(for: url) {
            phase = .success(Image(uiImage: cached))
            return
        }

        // Load from network
        phase = .empty
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard !Task.isCancelled else { return }

                // Check HTTP status
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                    if httpResponse.statusCode == 404, let logoDescriptor = Self.logoDescriptor(from: url) {
                        if !Self.loggedMissingLogos.contains(logoDescriptor) {
                            Self.loggedMissingLogos.insert(logoDescriptor)
                            AppLoggers.net.info("event=image.logo.missing url=\(logoDescriptor, privacy: .public)")
                        }
                    } else {
                        AppLoggers.net.error("event=image.load.failed status=\(httpResponse.statusCode) url=\(url.redactedForLogging(), privacy: .public)")
                    }
                    self.phase = .failure
                    return
                }

                // Decode image
                if let uiImage = UIImage(data: data, scale: scale) {
                    PlexImageCache.shared.insert(uiImage, for: url)
                    self.phase = .success(Image(uiImage: uiImage))
                } else {
                    AppLoggers.net.error("event=image.load.failed reason=invalidImageData bytes=\(data.count) url=\(url.redactedForLogging(), privacy: .public)")
                    self.phase = .failure
                }
            } catch {
                guard !Task.isCancelled else { return }
                AppLoggers.net.error("event=image.load.failed error=\(String(describing: error), privacy: .public) url=\(url.redactedForLogging(), privacy: .public)")
                self.phase = .failure
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    private static func logoDescriptor(from url: URL) -> String? {
        if url.absoluteString.contains("clearLogo") {
            return url.redactedForLogging()
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let encodedTarget = components.queryItems?.first(where: { $0.name == "url" })?.value else {
            return nil
        }

        if let decoded = encodedTarget.removingPercentEncoding,
           let nestedURL = URL(string: decoded) {
            return nestedURL.redactedForLogging()
        }

        return url.redactedForLogging()
    }
}

struct CachedAsyncImage<Content: View>: View {
    private let url: URL?
    private let scale: CGFloat
    private let content: (CachedImagePhase) -> Content

    @StateObject private var loader = ImageLoader()

    init(
        url: URL?,
        scale: CGFloat = 1.0,
        @ViewBuilder content: @escaping (CachedImagePhase) -> Content
    ) {
        self.url = url
        self.scale = scale
        self.content = content
    }

    var body: some View {
        content(loader.phase)
            .task(id: url) {
                loader.load(url: url, scale: scale)
            }
            .onDisappear {
                loader.cancel()
            }
    }
}
