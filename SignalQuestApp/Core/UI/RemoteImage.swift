import SwiftUI
import ImageIO
import UIKit

enum ImagePipelineError: Error {
    case decodeFailed
    case privateSessionChanged
}

/// Frontière de confidentialité du cache d'images.
///
/// Les contenus publics peuvent partager leur cache entre toutes les sessions de
/// l'appareil. Une image privée porte au contraire la session exacte qui l'a
/// demandée : son cache mémoire est isolé par compte ET par session, et une réponse
/// arrivée après déconnexion/changement de compte est rejetée.
enum ImageCacheScope: Equatable, Sendable {
    case publicContent
    case privateAccount(LocalAccountSession)

    fileprivate var cacheIdentity: String {
        switch self {
        case .publicContent:
            return "public"
        case .privateAccount(let session):
            return "private|\(session.ownerNamespace)|\(session.sessionId)"
        }
    }

    fileprivate func requireCurrentPrivateSession() throws {
        guard case .privateAccount(let session) = self else { return }
        guard session.isCurrent else { throw ImagePipelineError.privateSessionChanged }
    }
}

/// Chargeur d'images partagé : cache d'octets sur disque (URLCache dédié),
/// cache mémoire d'images DÉCODÉES (NSCache) et surtout downsampling via
/// ImageIO — on ne décode jamais à la résolution source. Remplace l'usage direct
/// d'`AsyncImage` qui décode en pleine résolution et ne garde aucune image
/// décodée entre recréations de vues (cf. audit PERF-02).
final class ImagePipeline: @unchecked Sendable {
    static let shared = ImagePipeline()

    typealias DataLoader = @Sendable (URL, ImageCacheScope, Bool) async throws -> Data

    private let dataLoader: DataLoader
    private let memory = NSCache<NSString, UIImage>()

    init() {
        let publicSession = URLSession(configuration: Self.makePublicSessionConfiguration())
        let privateSession = URLSession(configuration: Self.makePrivateSessionConfiguration())
        dataLoader = { url, scope, reload in
            switch scope {
            case .publicContent:
                let request = URLRequest(
                    url: url,
                    cachePolicy: reload ? .reloadIgnoringLocalCacheData : .returnCacheDataElseLoad
                )
                let (data, _) = try await publicSession.data(for: request)
                return data
            case .privateAccount:
                // Cette session n'a aucun URLCache ni cookie jar partagé. La
                // requête explicite également le bypass afin qu'une évolution de
                // configuration ne puisse pas réactiver un cache HTTP privé global.
                let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
                let (data, _) = try await privateSession.data(for: request)
                return data
            }
        }
        configureMemoryCache()
    }

    /// Injection réservée aux tests : aucune requête réseau réelle n'est requise
    /// pour vérifier l'isolation A → logout → B et les réponses tardives.
    init(dataLoader: @escaping @Sendable (URL, ImageCacheScope) async throws -> Data) {
        self.dataLoader = { url, scope, _ in try await dataLoader(url, scope) }
        configureMemoryCache()
    }

    init(dataLoader: @escaping DataLoader) {
        self.dataLoader = dataLoader
        configureMemoryCache()
    }

    static func makePublicSessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(
            memoryCapacity: 16 * 1024 * 1024,
            diskCapacity: 128 * 1024 * 1024,
            diskPath: "sq-image-cache"
        )
        config.requestCachePolicy = .returnCacheDataElseLoad
        return config
    }

    static func makePrivateSessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        return config
    }

    private func configureMemoryCache() {
        memory.countLimit = 250
        memory.totalCostLimit = 64 * 1024 * 1024
    }

    /// Image déjà décodée en cache mémoire, le cas échéant (accès synchrone). Permet
    /// aux vues recyclées fréquemment (marqueurs carte) d'afficher immédiatement sans
    /// repasser par une tâche asynchrone annulable.
    func cachedImage(for url: URL, maxPixel: CGFloat, scope: ImageCacheScope = .publicContent) -> UIImage? {
        guard (try? scope.requireCurrentPrivateSession()) != nil else { return nil }
        return memory.object(forKey: memoryKey(for: url, maxPixel: maxPixel, scope: scope))
    }

    /// Image décodée et redimensionnée à `maxPixel` (plus grand côté, en pixels).
    func image(
        for url: URL,
        maxPixel: CGFloat,
        scope: ImageCacheScope = .publicContent,
        reload: Bool = false
    ) async throws -> UIImage {
        try scope.requireCurrentPrivateSession()
        let key = memoryKey(for: url, maxPixel: maxPixel, scope: scope)
        if !reload, let cached = memory.object(forKey: key) { return cached }
        let data = try await dataLoader(url, scope, reload)
        // La session peut avoir changé pendant le transport ou le décodage. Ne
        // publie jamais les octets de A dans une vue qui appartient désormais à B.
        try scope.requireCurrentPrivateSession()
        guard let image = Self.downsample(data: data, maxPixel: maxPixel) else {
            throw ImagePipelineError.decodeFailed
        }
        try scope.requireCurrentPrivateSession()
        memory.setObject(image, forKey: key, cost: Self.cost(of: image))
        return image
    }

    private func memoryKey(for url: URL, maxPixel: CGFloat, scope: ImageCacheScope) -> NSString {
        "\(scope.cacheIdentity)|\(url.absoluteString)|\(Int(maxPixel))" as NSString
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
    var cacheScope: ImageCacheScope = .publicContent
    var showsFailureUI = false
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: UIImage?
    @State private var failed = false
    @State private var retryCount = 0
    @State private var retryIdentity: String?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if failed && showsFailureUI {
                failureView
            } else {
                placeholder()
            }
        }
        .task(id: taskKey) {
            failed = false
            guard let url else { image = nil; failed = true; return }
            let maxPixel = max(1, maxDimension * displayScale)
            // Lecture SYNCHRONE du cache mémoire avant toute remise à nil.
            // Auparavant `image = nil` s'exécutait en premier et `image(for:)`
            // est `async` même sur un hit `NSCache` : chaque recyclage de cellule
            // (scroll d'une grille de photos, pan de carte) réaffichait donc au
            // moins une frame de placeholder alors que l'image décodée était
            // déjà en mémoire. L'accesseur existait et n'était appelé nulle part.
            if let cached = ImagePipeline.shared.cachedImage(
                for: url,
                maxPixel: maxPixel,
                scope: cacheScope
            ) {
                image = cached
                return
            }
            image = nil
            do {
                let forceReload = retryIdentity == requestIdentity
                let loaded = try await ImagePipeline.shared.image(
                    for: url,
                    maxPixel: maxPixel,
                    scope: cacheScope,
                    reload: forceReload
                )
                guard !Task.isCancelled else { return }
                image = loaded
                if forceReload { retryIdentity = nil }
            } catch {
                guard !Task.isCancelled else { return }
                failed = true
            }
        }
    }

    @ViewBuilder private var failureView: some View {
        ZStack {
            SQColor.fill
            VStack(spacing: 8) {
                if url == nil {
                    Image(systemName: "photo")
                        .font(.title3)
                }
                if maxDimension >= 180 {
                    Text("Photo indisponible")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                }
                if url != nil {
                    Button {
                        retryIdentity = requestIdentity
                        retryCount += 1
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: "arrow.clockwise")
                            if maxDimension >= 180 { Text("Réessayer") }
                        }
                        .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Réessayer")
                }
            }
            .foregroundStyle(SQColor.label)
        }
        .accessibilityIdentifier("remoteImage.failure")
    }

    /// Recharge quand l'URL OU l'échelle change.
    private var requestIdentity: String {
        "\(cacheScope.cacheIdentity)|\(url?.absoluteString ?? "nil")|\(Int(maxDimension * displayScale))"
    }

    private var taskKey: String {
        "\(requestIdentity)|\(retryCount)"
    }
}
