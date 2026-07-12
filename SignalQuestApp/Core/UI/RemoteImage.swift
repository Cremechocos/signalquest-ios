import SwiftUI
import ImageIO
import UIKit

enum ImagePipelineError: Error { case decodeFailed }

/// Chargeur d'images partagé : cache d'octets sur disque (URLCache dédié),
/// cache mémoire d'images DÉCODÉES (NSCache) et surtout downsampling via
/// ImageIO — on ne décode jamais à la résolution source. Remplace l'usage direct
/// d'`AsyncImage` qui décode en pleine résolution et ne garde aucune image
/// décodée entre recréations de vues (cf. audit PERF-02).
final class ImagePipeline: @unchecked Sendable {
    static let shared = ImagePipeline()

    private let session: URLSession
    private let memory = NSCache<NSString, UIImage>()

    init() {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(
            memoryCapacity: 16 * 1024 * 1024,
            diskCapacity: 128 * 1024 * 1024,
            diskPath: "sq-image-cache"
        )
        config.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: config)
        memory.countLimit = 250
        memory.totalCostLimit = 64 * 1024 * 1024
    }

    /// Image déjà décodée en cache mémoire, le cas échéant (accès synchrone). Permet
    /// aux vues recyclées fréquemment (marqueurs carte) d'afficher immédiatement sans
    /// repasser par une tâche asynchrone annulable.
    func cachedImage(for url: URL, maxPixel: CGFloat) -> UIImage? {
        memory.object(forKey: "\(url.absoluteString)|\(Int(maxPixel))" as NSString)
    }

    /// Image décodée et redimensionnée à `maxPixel` (plus grand côté, en pixels).
    func image(for url: URL, maxPixel: CGFloat) async throws -> UIImage {
        let key = "\(url.absoluteString)|\(Int(maxPixel))" as NSString
        if let cached = memory.object(forKey: key) { return cached }
        let (data, _) = try await session.data(from: url)
        guard let image = Self.downsample(data: data, maxPixel: maxPixel) else {
            throw ImagePipelineError.decodeFailed
        }
        memory.setObject(image, forKey: key, cost: Self.cost(of: image))
        return image
    }

    static func downsample(data: Data, maxPixel: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private static func cost(of image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 0 }
        return cg.bytesPerRow * cg.height
    }
}

/// Vue d'image distante réutilisable, calquée sur l'API d'`AsyncImage` mais avec
/// downsampling + cache d'images décodées. `maxDimension` est exprimé en POINTS
/// (la plus grande dimension d'affichage) ; le pixel cible tient compte de l'échelle.
struct RemoteImage<Placeholder: View>: View {
    let url: URL?
    var maxDimension: CGFloat
    var contentMode: ContentMode = .fill
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: UIImage?
    @State private var failed = false
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder()
            }
        }
        .task(id: taskKey) {
            failed = false
            image = nil
            guard let url else { return }
            let maxPixel = max(1, maxDimension * displayScale)
            do {
                image = try await ImagePipeline.shared.image(for: url, maxPixel: maxPixel)
            } catch {
                failed = true
            }
        }
    }

    /// Recharge quand l'URL OU l'échelle change.
    private var taskKey: String {
        "\(url?.absoluteString ?? "nil")|\(Int(maxDimension * displayScale))"
    }
}
