import Foundation
import UniformTypeIdentifiers

/// Boîte de dépôt entre l'extension « Partager vers SignalQuest » et l'app.
///
/// L'extension n'envoie rien : elle copie le contenu partagé dans le conteneur de
/// l'App Group (`ShareInbox/<uuid>/manifest.json` plus les fichiers), puis l'app
/// le propose à l'utilisateur à sa prochaine ouverture — c'est elle qui, pour
/// chaque envoi, passe par les chemins existants (chiffrement compris).
///
/// Compilé tel quel dans l'app et dans l'extension : aucune dépendance aux
/// modèles de l'app. Un dépôt vit au plus 24 h, et part à la déconnexion.
struct ShareInbox: Sendable {
    // MARK: Limites

    /// Images d'un partage.
    static let maxImages = 10
    /// Vidéo ou fichier : la limite d'une pièce jointe de messagerie
    /// (`MessageAttachmentOutboxStore.maximumSourceBytes`, 10 Mio).
    static let maxFileBytes = 10 * 1_024 * 1_024
    /// Une image est ré-encodée avant l'envoi (message ou fil) : on accepte plus
    /// lourd qu'une pièce jointe, sans laisser entrer une image démesurée.
    static let maxImageBytes = 20 * 1_024 * 1_024
    /// Texte d'un partage (texte et lien compris, avant leur assemblage).
    static let maxTextCharacters = 4_000
    /// Durée de vie d'un dépôt non traité.
    static let lifetime: TimeInterval = 24 * 3_600

    private static let manifestName = "manifest.json"
    private static let manifestMaxBytes = 256 * 1_024
    private static let stagingPrefix = ".tmp-"
    /// Un dépôt en cours d'écriture n'est jamais balayé avant ce délai.
    private static let stagingLifetime: TimeInterval = 3_600
    /// Tolérance d'horloge pour une date de dépôt « dans le futur ».
    private static let clockSkew: TimeInterval = 300

    // MARK: Modèle

    enum Kind: String, Codable, Sendable {
        case image, video, file

        /// Rangement d'un type de contenu (UTI) dans l'un des trois genres.
        static func classify(typeIdentifier: String) -> Kind {
            guard let type = UTType(typeIdentifier) else { return .file }
            if type.conforms(to: .image) { return .image }
            if type.conforms(to: .movie) { return .video }
            return .file
        }
    }

    struct Item: Codable, Equatable, Sendable {
        let kind: Kind
        /// Nom du fichier dans le dépôt, aussi montré à l'utilisateur.
        let fileName: String
        let uti: String
        let byteCount: Int
    }

    struct Manifest: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let createdAt: Date
        let text: String?
        let url: String?
        let items: [Item]

        init(id: String, createdAt: Date, text: String?, url: String?, items: [Item]) {
            self.id = id
            self.createdAt = createdAt
            self.text = text
            self.url = url
            self.items = items
        }

        private enum CodingKeys: String, CodingKey { case id, createdAt, text, url, items }

        /// Tolérant : une clé absente vaut « rien », une clé inconnue est ignorée
        /// et un élément d'un genre inconnu est écarté sans perdre les autres.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            createdAt = try container.decode(Date.self, forKey: .createdAt)
            text = try container.decodeIfPresent(String.self, forKey: .text)
            url = try container.decodeIfPresent(String.self, forKey: .url)
            let lossy = try container.decodeIfPresent([LossyItem].self, forKey: .items) ?? []
            items = lossy.compactMap(\.item)
        }

        private struct LossyItem: Decodable {
            let item: Item?
            init(from decoder: Decoder) throws {
                item = try? Item(from: decoder)
            }
        }

        /// Il reste quelque chose à partager.
        var hasContent: Bool {
            (text?.isEmpty == false) || (url?.isEmpty == false) || !items.isEmpty
        }

        var imageCount: Int { items.filter { $0.kind == .image }.count }
        /// La vidéo ou le fichier, s'il y en a un.
        var attachment: Item? { items.first { $0.kind != .image } }
        var totalBytes: Int { items.reduce(0) { $0 + $1.byteCount } }

        /// Texte et lien tels qu'ils arrivent dans un champ de saisie.
        var composedText: String {
            [text, url].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        }
    }

    /// Un dépôt lisible : son manifeste et son dossier.
    struct Entry: Equatable, Sendable, Identifiable {
        let manifest: Manifest
        let directory: URL
        var id: String { manifest.id }

        func fileURL(for item: Item) -> URL {
            directory.appendingPathComponent(item.fileName, isDirectory: false)
        }

        /// Contenu d'un fichier du dépôt, dans la limite de son genre.
        func data(for item: Item) throws -> Data {
            let limit = item.kind == .image ? ShareInbox.maxImageBytes : ShareInbox.maxFileBytes
            let url = fileURL(for: item)
            let size = try ShareInbox.byteCount(of: url)
            guard size > 0, size <= limit else { throw Failure.fileTooLarge(item.fileName) }
            return try Data(contentsOf: url, options: .mappedIfSafe)
        }
    }

    /// Un fichier à déposer : déjà copié par l'appelant dans un emplacement qui
    /// lui est propre (la copie du système ne dure que le temps du rappel).
    struct Source: Sendable {
        let kind: Kind
        let fileName: String
        let uti: String
        let fileURL: URL

        init(kind: Kind, fileName: String, uti: String, fileURL: URL) {
            self.kind = kind
            self.fileName = fileName
            self.uti = uti
            self.fileURL = fileURL
        }
    }

    enum Failure: Error, Equatable {
        /// Rien à déposer.
        case empty
        case textTooLong
        case tooManyImages
        /// Plus d'une vidéo ou d'un fichier, ou images mêlées à l'un d'eux.
        case unsupportedCombination
        case unsupportedURL
        case fileTooLarge(String)
        case unreadable(String)
        case storageUnavailable
        case writeFailed
    }

    // MARK: Emplacement

    let root: URL

    init(root: URL) {
        self.root = root
    }

    /// Le dépôt de l'App Group de cette cible. Même lecture de `SQ_APP_GROUP` que
    /// `E2EEV2NotificationContextStore.configured` : la clé est alimentée par le
    /// xcconfig dans l'Info.plist de l'app ET de l'extension, jamais figée ici
    /// (une Beta ne doit pas lire le groupe de production).
    static func appGroup(bundle: Bundle = .main) -> ShareInbox? {
        guard let group = bundle.object(forInfoDictionaryKey: "SQ_APP_GROUP") as? String,
              !group.isEmpty, !group.contains("$("),
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            return nil
        }
        return ShareInbox(root: container.appendingPathComponent("ShareInbox", isDirectory: true))
    }

    // MARK: Écriture

    /// Dépose un partage. Le dossier n'apparaît qu'une fois complet (écriture
    /// dans un dossier de travail puis renommage) : l'app ne lit jamais un dépôt
    /// à moitié écrit.
    @discardableResult
    func write(
        text: String?,
        url: URL?,
        sources: [Source],
        now: Date = Date()
    ) throws -> Manifest {
        let cleanText = Self.normalized(text)
        if let cleanText, cleanText.count > Self.maxTextCharacters { throw Failure.textTooLong }
        var cleanURL: String?
        if let url {
            guard Self.isWebURL(url) else { throw Failure.unsupportedURL }
            cleanURL = url.absoluteString
        }
        try Self.validate(kinds: sources.map(\.kind))
        guard cleanText != nil || cleanURL != nil || !sources.isEmpty else { throw Failure.empty }

        let fileManager = FileManager.default
        let id = UUID().uuidString
        let staging = root.appendingPathComponent(
            "\(Self.stagingPrefix)\(Int(now.timeIntervalSince1970))-\(id)", isDirectory: true
        )
        do {
            try prepareRoot()
            try fileManager.createDirectory(
                at: staging, withIntermediateDirectories: false,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
            var used: Set<String> = [Self.manifestName.lowercased()]
            var items: [Item] = []
            for source in sources {
                let size: Int
                do { size = try Self.byteCount(of: source.fileURL) } catch { throw Failure.unreadable(source.fileName) }
                let limit = source.kind == .image ? Self.maxImageBytes : Self.maxFileBytes
                guard size > 0 else { throw Failure.unreadable(source.fileName) }
                guard size <= limit else { throw Failure.fileTooLarge(source.fileName) }
                let name = Self.uniqueName(Self.sanitizedFileName(source.fileName), used: &used)
                let destination = staging.appendingPathComponent(name, isDirectory: false)
                try fileManager.copyItem(at: source.fileURL, to: destination)
                try fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: destination.path)
                items.append(Item(kind: source.kind, fileName: name, uti: source.uti, byteCount: size))
            }
            let manifest = Manifest(id: id, createdAt: now, text: cleanText, url: cleanURL, items: items)
            try Self.encoder.encode(manifest).write(
                to: staging.appendingPathComponent(Self.manifestName, isDirectory: false),
                options: [.atomic, .completeFileProtection]
            )
            try fileManager.moveItem(at: staging, to: directory(for: id))
            return manifest
        } catch let failure as Failure {
            try? fileManager.removeItem(at: staging)
            throw failure
        } catch {
            try? fileManager.removeItem(at: staging)
            throw Failure.writeFailed
        }
    }

    // MARK: Lecture

    /// Le dépôt le plus récent qui n'a pas expiré, ou `nil`.
    func pending(now: Date = Date()) -> Entry? {
        entries().filter { !Self.isExpired($0.manifest, now: now) }
            .max { $0.manifest.createdAt < $1.manifest.createdAt }
    }

    /// Traité (remis à la saisie) ou ignoré.
    func remove(id: String) {
        guard UUID(uuidString: id) != nil else { return }
        try? FileManager.default.removeItem(at: directory(for: id))
    }

    /// À la déconnexion : ce qui attendait appartenait au compte qui s'en va.
    func purgeAll() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Dépôts de plus de 24 h, dépôts illisibles et dossiers de travail oubliés.
    /// Un manifeste qu'on ne peut pas LIRE (appareil verrouillé : protection
    /// des fichiers) est laissé en place ; seul un contenu lu mais incompréhensible
    /// est supprimé.
    func purgeExpired(now: Date = Date()) {
        let fileManager = FileManager.default
        guard let children = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: []
        ) else { return }
        for child in children {
            let name = child.lastPathComponent
            if name.hasPrefix(Self.stagingPrefix) {
                if Self.isStaleStaging(name, now: now) { try? fileManager.removeItem(at: child) }
                continue
            }
            guard UUID(uuidString: name) != nil else { continue }
            switch Self.readManifest(in: child) {
            case .unreadable:
                continue
            case .invalid:
                try? fileManager.removeItem(at: child)
            case .manifest(let manifest):
                if manifest.id != name || Self.isExpired(manifest, now: now) {
                    try? fileManager.removeItem(at: child)
                }
            }
        }
    }

    // MARK: Interne

    private func directory(for id: String) -> URL {
        root.appendingPathComponent(id, isDirectory: true)
    }

    private func prepareRoot() throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: root.path) {
            try fileManager.createDirectory(
                at: root, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
        }
        // Un dépôt n'a rien à faire dans une sauvegarde.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableRoot = root
        try? mutableRoot.setResourceValues(values)
    }

    private func entries() -> [Entry] {
        let fileManager = FileManager.default
        guard let children = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        return children.compactMap { child in
            guard UUID(uuidString: child.lastPathComponent) != nil,
                  case .manifest(let manifest) = Self.readManifest(in: child),
                  manifest.id == child.lastPathComponent else { return nil }
            // Un fichier disparu retire seulement cet élément.
            let present = manifest.items.filter { item in
                guard Self.isPlainName(item.fileName),
                      let size = try? Self.byteCount(of: child.appendingPathComponent(item.fileName)) else { return false }
                return size == item.byteCount
            }
            let readable = Manifest(
                id: manifest.id, createdAt: manifest.createdAt,
                text: manifest.text, url: manifest.url, items: present
            )
            return readable.hasContent ? Entry(manifest: readable, directory: child) : nil
        }
    }

    private enum ManifestRead {
        case manifest(Manifest)
        /// Lu, mais pas un manifeste.
        case invalid
        /// Pas lisible maintenant (appareil verrouillé, fichier absent).
        case unreadable
    }

    private static func readManifest(in directory: URL) -> ManifestRead {
        let url = directory.appendingPathComponent(manifestName, isDirectory: false)
        // Un dépôt n'apparaît qu'avec son manifeste : sans lui, c'est un débris.
        guard FileManager.default.fileExists(atPath: url.path) else { return .invalid }
        guard let size = try? byteCount(of: url) else { return .unreadable }
        guard size <= manifestMaxBytes else { return .invalid }
        guard let data = try? Data(contentsOf: url) else { return .unreadable }
        guard let manifest = try? decoder.decode(Manifest.self, from: data) else { return .invalid }
        return .manifest(manifest)
    }

    private static func isExpired(_ manifest: Manifest, now: Date) -> Bool {
        let age = now.timeIntervalSince(manifest.createdAt)
        return age >= lifetime || age < -clockSkew
    }

    private static func isStaleStaging(_ name: String, now: Date) -> Bool {
        // `.tmp-<secondes>-<uuid>` : l'heure est dans le nom, sans lire de date de fichier.
        let parts = name.dropFirst(stagingPrefix.count).split(separator: "-", maxSplits: 1)
        guard let first = parts.first, let seconds = TimeInterval(first) else { return true }
        return now.timeIntervalSince1970 - seconds >= stagingLifetime
    }

    /// Images seules (10 au plus), ou une vidéo, ou un fichier.
    static func validate(kinds: [Kind]) throws {
        let images = kinds.filter { $0 == .image }.count
        let others = kinds.count - images
        guard images <= maxImages else { throw Failure.tooManyImages }
        guard others <= 1, others == 0 || images == 0 else { throw Failure.unsupportedCombination }
    }

    static func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else { return false }
        return true
    }

    private static func normalized(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Taille lue en se plaçant à la fin du fichier : pas d'attribut de fichier à lire.
    static func byteCount(of url: URL) throws -> Int {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return Int(try handle.seekToEnd())
    }

    private static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && name.lowercased() != manifestName
    }

    /// Nom sans chemin, sans caractère de contrôle ni point initial, borné.
    static func sanitizedFileName(_ raw: String) -> String {
        let base = (raw as NSString).lastPathComponent
        var cleaned = String(base.unicodeScalars.map { scalar -> Character in
            if scalar.value < 0x20 || scalar.value == 0x7F || scalar == ":" || scalar == "/" || scalar == "\\" {
                return "_"
            }
            return Character(scalar)
        })
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty { cleaned = "file" }
        guard cleaned.count > 120 else { return cleaned }
        let ext = (cleaned as NSString).pathExtension
        let stem = String((cleaned as NSString).deletingPathExtension.prefix(100))
        return ext.isEmpty ? stem : "\(stem).\(String(ext.prefix(12)))"
    }

    private static func uniqueName(_ name: String, used: inout Set<String>) -> String {
        var candidate = name
        var counter = 2
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        while used.contains(candidate.lowercased()) {
            candidate = ext.isEmpty ? "\(stem) (\(counter))" : "\(stem) (\(counter)).\(ext)"
            counter += 1
        }
        used.insert(candidate.lowercased())
        return candidate
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
