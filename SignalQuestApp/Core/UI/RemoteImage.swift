import SwiftUI
import CryptoKit
import ImageIO
import UIKit

enum ImagePipelineError: Error {
    case decodeFailed
    case privateSessionChanged
    case httpStatus(Int)
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

/// Cache disque des images privées (photos de conversation), un dossier par compte.
/// Les octets ne sont jamais partagés entre comptes : le dossier porte l'empreinte du
/// propriétaire, il est protégé tant que l'appareil est verrouillé, hors sauvegarde, plafonné,
/// et supprimé à la déconnexion ou au changement de compte.
enum PrivateImageDiskCache {
    /// Au-delà, les fichiers les plus anciennement écrits partent (ils se retéléchargent).
    static let maxBytesPerAccount = 150 * 1024 * 1024

    private static func root() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("sq-private-images", isDirectory: true)
    }

    private static func directory(ownerNamespace: String) -> URL? {
        root()?.appendingPathComponent(ownerNamespace, isDirectory: true)
    }

    /// Nom stable : l'adresse sans ses paramètres (une adresse signée en change d'une réponse à l'autre).
    static func fileName(for url: URL) -> String {
        let source = (url.host ?? "") + url.path
        return SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func data(for url: URL, ownerNamespace: String) -> Data? {
        guard let file = directory(ownerNamespace: ownerNamespace)?.appendingPathComponent(fileName(for: url)),
              let data = try? Data(contentsOf: file), !data.isEmpty else { return nil }
        return data
    }

    static func store(_ data: Data, for url: URL, ownerNamespace: String, limit: Int = maxBytesPerAccount) {
        guard !data.isEmpty, data.count <= limit, let directory = directory(ownerNamespace: ownerNamespace) else { return }
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var folder = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        let file = directory.appendingPathComponent(fileName(for: url))
        guard (try? data.write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])) != nil else { return }
        trim(directory: directory, keeping: file, limit: limit)
    }

    /// Éviction par ancienneté jusqu'à repasser sous le plafond.
    static func trim(directory: URL, keeping: URL?, limit: Int) {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let urls = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        var entries: [(url: URL, size: Int, date: Date)] = urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > limit else { return }
        entries.sort { $0.date < $1.date }
        for entry in entries where total > limit && entry.url != keeping {
            if (try? fileManager.removeItem(at: entry.url)) != nil { total -= entry.size }
        }
    }

    /// Déconnexion ou changement de compte : tout le dossier du compte disparaît.
    static func purge(ownerScopeId: String) {
        let namespace = LocalAccountScope.storageNamespace(for: ownerScopeId)
        if let directory = directory(ownerNamespace: namespace) {
            try? FileManager.default.removeItem(at: directory)
        }
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
                let (data, response) = try await publicSession.data(for: request)
                try Self.requireSuccessfulHTTP(response)
                return data
            case .privateAccount(let account):
                // Cette session n'a aucun URLCache ni cookie jar partagé. La
                // requête explicite également le bypass afin qu'une évolution de
                // configuration ne puisse pas réactiver un cache HTTP privé global.
                // Le cache disque est celui du compte, jamais partagé (P01).
                if !reload, account.isCurrent,
                   let stored = PrivateImageDiskCache.data(for: url, ownerNamespace: account.ownerNamespace) {
                    return stored
                }
                let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
                let (data, response) = try await privateSession.data(for: request)
                try Self.requireSuccessfulHTTP(response)
                if account.isCurrent {
                    PrivateImageDiskCache.store(data, for: url, ownerNamespace: account.ownerNamespace)
                }
                return data
            }
        }
        configureMemoryCache()
    }

    private static func requireSuccessfulHTTP(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ImagePipelineError.httpStatus(http.statusCode)
        }
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
    var pipeline: ImagePipeline = .shared
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
                    .accessibilityIdentifier("remoteImage.loaded")
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
            if let cached = pipeline.cachedImage(
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
                let loaded = try await pipeline.image(
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
                        .accessibilityIdentifier("remoteImage.failure")
                }
                if maxDimension >= 180 {
                    Text("Photo indisponible")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .accessibilityIdentifier("remoteImage.failure")
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
                    .accessibilityIdentifier("remoteImage.retry")
                }
            }
            .foregroundStyle(SQColor.label)
        }
    }

    /// Recharge quand l'URL OU l'échelle change.
    private var requestIdentity: String {
        "\(cacheScope.cacheIdentity)|\(url?.absoluteString ?? "nil")|\(Int(maxDimension * displayScale))"
    }

    private var taskKey: String {
        "\(requestIdentity)|\(retryCount)"
    }
}
