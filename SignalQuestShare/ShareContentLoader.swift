import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Ce que l'extension ne peut pas déposer, dit en mots d'utilisateur.
enum ShareFailure: Error, Equatable {
    case nothingToShare
    case unsupported
    case unreadable
    case tooManyImages
    case imageTooLarge
    case videoTooLarge
    case fileTooLarge
    case textTooLong
    case notAWebLink
    case combination
    case storageUnavailable
    case writeFailed

    init(_ failure: ShareInbox.Failure, kind: ShareInbox.Kind? = nil) {
        switch failure {
        case .empty: self = .nothingToShare
        case .textTooLong: self = .textTooLong
        case .tooManyImages: self = .tooManyImages
        case .unsupportedCombination: self = .combination
        case .unsupportedURL: self = .notAWebLink
        case .fileTooLarge:
            switch kind {
            case .image: self = .imageTooLarge
            case .video: self = .videoTooLarge
            default: self = .fileTooLarge
            }
        case .unreadable: self = .unreadable
        case .storageUnavailable: self = .storageUnavailable
        case .writeFailed: self = .writeFailed
        }
    }

    var message: String {
        switch self {
        case .nothingToShare: return String(localized: "Il n’y a rien à partager ici.")
        case .unsupported: return String(localized: "SignalQuest ne prend pas en charge ce type de contenu.")
        case .unreadable: return String(localized: "Ce contenu est illisible. Réessaie depuis l’app d’origine.")
        case .tooManyImages: return String(localized: "Tu peux partager 10 images au plus à la fois.")
        case .imageTooLarge: return String(localized: "Une image est trop lourde : 20 Mo au plus.")
        case .videoTooLarge: return String(localized: "Cette vidéo dépasse 10 Mo. Choisis-en une plus courte.")
        case .fileTooLarge: return String(localized: "Ce fichier dépasse 10 Mo. Choisis-en un plus léger.")
        case .textTooLong: return String(localized: "Ce texte est trop long : 4 000 caractères au plus.")
        case .notAWebLink: return String(localized: "Ce lien n’est pas un lien web.")
        case .combination: return String(localized: "Partage une vidéo ou un fichier seul, sans images.")
        case .storageUnavailable: return String(localized: "SignalQuest n’est pas prêt à recevoir ce partage. Ouvre l’app puis réessaie.")
        case .writeFailed: return String(localized: "Impossible de préparer ce partage. Réessaie.")
        }
    }
}

/// Le contenu lu dans les éléments reçus de l'app d'origine, avant dépôt.
/// Les fichiers sont déjà copiés dans `stagingDirectory` (propre à l'extension) :
/// la copie du système disparaît à la fin du rappel qui la fournit.
struct ShareDraft {
    let text: String?
    let url: URL?
    let sources: [ShareInbox.Source]
    let stagingDirectory: URL
    let thumbnails: [UIImage]

    var imageCount: Int { sources.filter { $0.kind == .image }.count }
    var attachment: ShareInbox.Source? { sources.first { $0.kind != .image } }
}

/// Lecture des `NSItemProvider` d'une feuille de partage. Tout reste sur le
/// thread principal ; seules les copies de fichiers se font dans les rappels du
/// système, sur ses propres files.
@MainActor
enum ShareContentLoader {
    static func load(from items: [NSExtensionItem]) async throws -> ShareDraft {
        let providers = items.flatMap { $0.attachments ?? [] }
        guard !providers.isEmpty else { throw ShareFailure.nothingToShare }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            return try await read(providers, staging: staging)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    private static func read(_ providers: [NSItemProvider], staging: URL) async throws -> ShareDraft {
        var texts: [String] = []
        var webURL: URL?
        var sources: [ShareInbox.Source] = []
        var recognized = false

        for provider in providers {
            switch category(of: provider) {
            case .movie(let identifier):
                recognized = true
                sources.append(try await copyFile(of: provider, identifier: identifier, kind: .video, into: staging))
            case .image(let identifier):
                recognized = true
                // Dix images au plus : refusé avant de copier la onzième.
                if sources.filter({ $0.kind == .image }).count >= ShareInbox.maxImages { throw ShareFailure.tooManyImages }
                sources.append(try await copyFile(of: provider, identifier: identifier, kind: .image, into: staging))
            case .webURL:
                recognized = true
                let value = try await loadURL(from: provider)
                if ShareInbox.isWebURL(value), webURL == nil {
                    webURL = value
                } else {
                    texts.append(value.absoluteString)
                }
            case .fileURL:
                recognized = true
                sources.append(try await copyFileURL(of: provider, into: staging))
            case .file(let identifier):
                recognized = true
                sources.append(try await copyFile(of: provider, identifier: identifier, kind: .file, into: staging))
            case .text:
                recognized = true
                if let value = try await loadText(from: provider) { texts.append(value) }
            case .other:
                continue
            }
        }
        guard recognized else { throw ShareFailure.unsupported }

        // Une page partagée arrive parfois en lien ET en texte identique.
        let text = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != webURL?.absoluteString }
            .joined(separator: "\n")
        if text.count > ShareInbox.maxTextCharacters { throw ShareFailure.textTooLong }

        do {
            try ShareInbox.validate(kinds: sources.map(\.kind))
        } catch let failure as ShareInbox.Failure {
            throw ShareFailure(failure)
        }
        guard !text.isEmpty || webURL != nil || !sources.isEmpty else { throw ShareFailure.nothingToShare }

        let thumbnails = sources.filter { $0.kind == .image }.compactMap { Self.thumbnail(at: $0.fileURL) }
        return ShareDraft(
            text: text.isEmpty ? nil : text, url: webURL, sources: sources,
            stagingDirectory: staging, thumbnails: thumbnails
        )
    }

    // MARK: Classement

    private enum Category {
        case movie(String), image(String), webURL, fileURL, file(String), text, other
    }

    private static func category(of provider: NSItemProvider) -> Category {
        let identifiers = provider.registeredTypeIdentifiers
        func first(conformingTo type: UTType) -> String? {
            identifiers.first { UTType($0)?.conforms(to: type) == true }
        }
        if let id = first(conformingTo: .movie) { return .movie(id) }
        if let id = first(conformingTo: .image) { return .image(id) }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            // Un document avec sa vraie représentation de fichier passe par elle.
            if let id = identifiers.first(where: { id in
                guard let type = UTType(id) else { return false }
                return type.conforms(to: .data) && !type.conforms(to: .url) && !type.conforms(to: .text)
            }) { return .file(id) }
            return .fileURL
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) { return .webURL }
        if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) { return .text }
        if let id = identifiers.first(where: { id in
            guard let type = UTType(id) else { return false }
            return type.conforms(to: .data) && !type.conforms(to: .propertyList) && !type.conforms(to: .json)
        }) { return .file(id) }
        return .other
    }

    // MARK: Chargement

    private static func loadURL(from provider: NSItemProvider) async throws -> URL {
        let item = try await loadItem(from: provider, identifier: UTType.url.identifier)
        if let url = item as? URL { return url }
        if let string = item as? String, let url = URL(string: string) { return url }
        if let data = item as? Data, let string = String(data: data, encoding: .utf8), let url = URL(string: string) { return url }
        throw ShareFailure.unreadable
    }

    private static func loadText(from provider: NSItemProvider) async throws -> String? {
        let item = try await loadItem(from: provider, identifier: UTType.text.identifier)
        if let string = item as? String { return string }
        if let attributed = item as? NSAttributedString { return attributed.string }
        if let data = item as? Data { return String(data: data, encoding: .utf8) }
        if let url = item as? URL { return url.absoluteString }
        return nil
    }

    /// Le contenu rendu par `loadItem` n'est lu qu'ici, sur le thread principal.
    private struct LoadedItem: @unchecked Sendable {
        let value: NSSecureCoding
    }

    private static func loadItem(from provider: NSItemProvider, identifier: String) async throws -> NSSecureCoding {
        let loaded: LoadedItem = try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, error in
                if let item {
                    continuation.resume(returning: LoadedItem(value: item))
                } else {
                    continuation.resume(throwing: error ?? ShareFailure.unreadable)
                }
            }
        }
        return loaded.value
    }

    /// Copie le fichier fourni par le système dans le dossier de travail de
    /// l'extension, dans le rappel même (c'est la seule durée où il existe).
    private static func copyFile(
        of provider: NSItemProvider,
        identifier: String,
        kind: ShareInbox.Kind,
        into staging: URL
    ) async throws -> ShareInbox.Source {
        let limit = kind == .image ? ShareInbox.maxImageBytes : ShareInbox.maxFileBytes
        let folder = staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let copied: URL = try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, error in
                guard let url else {
                    continuation.resume(throwing: error ?? ShareFailure.unreadable)
                    return
                }
                do {
                    continuation.resume(returning: try stage(url, into: folder, limit: limit, kind: kind))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        return ShareInbox.Source(kind: kind, fileName: copied.lastPathComponent, uti: identifier, fileURL: copied)
    }

    /// Document dont seule l'adresse de fichier est fournie (accès à durée limitée).
    private static func copyFileURL(of provider: NSItemProvider, into staging: URL) async throws -> ShareInbox.Source {
        let url = try await loadURL(from: provider)
        guard url.isFileURL else { throw ShareFailure.unsupported }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let identifier = UTType(filenameExtension: url.pathExtension)?.identifier ?? UTType.data.identifier
        let kind = ShareInbox.Kind.classify(typeIdentifier: identifier)
        let limit = kind == .image ? ShareInbox.maxImageBytes : ShareInbox.maxFileBytes
        let folder = staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let copied = try stage(url, into: folder, limit: limit, kind: kind)
        return ShareInbox.Source(kind: kind, fileName: copied.lastPathComponent, uti: identifier, fileURL: copied)
    }

    nonisolated private static func stage(_ source: URL, into folder: URL, limit: Int, kind: ShareInbox.Kind) throws -> URL {
        let size: Int
        do { size = try ShareInbox.byteCount(of: source) } catch { throw ShareFailure.unreadable }
        guard size > 0 else { throw ShareFailure.unreadable }
        guard size <= limit else { throw ShareFailure(.fileTooLarge(source.lastPathComponent), kind: kind) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(ShareInbox.sanitizedFileName(source.lastPathComponent), isDirectory: false)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    // MARK: Vignette

    /// Vignette décodée depuis le fichier à la taille voulue : jamais l'image entière en mémoire.
    private static func thumbnail(at url: URL) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 240,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
