import CryptoKit
import Foundation
import os
import UIKit

/// Motifs de signalement — alignés 1:1 sur l'enum backend
/// (`/api/social/reports` : `spam|harassment|privacy|illegal|misleading|other`).
/// Toute valeur hors de cet ensemble est rejetée en 400 côté serveur.
enum ReportReason: String, CaseIterable, Identifiable {
    case spam, harassment, privacy, illegal, misleading, other

    var id: String { rawValue }
    var label: String {
        switch self {
        case .spam: return "Spam"
        case .harassment: return String(localized: "Harcèlement")
        case .privacy: return String(localized: "Atteinte à la vie privée")
        case .illegal: return String(localized: "Contenu illégal")
        case .misleading: return String(localized: "Désinformation")
        case .other: return String(localized: "Autre")
        }
    }

    /// Motifs proposés pour un message, alignés sur le web.
    static let messageReasons: [ReportReason] = [.spam, .harassment, .illegal, .other]
}

/// Cible d'un signalement.
///
/// Ce type était auparavant une simple `String`, ce qui a laissé passer un bug
/// silencieux : le signalement de photo envoyait `targetType: "photo"` à
/// `/api/social/reports`, dont le schéma zod n'accepte que
/// `post|comment|profile` — donc **400 systématique** sur un contenu généré par
/// les utilisateurs. Le compilateur garantit désormais qu'aucune cible ne peut
/// être routée vers un endpoint qui ne la comprend pas.
enum ReportTarget: Equatable, Sendable {
    case post(String)
    case comment(String)
    case profile(String)
    case story(String)
    case photo(String)
    case photoComment(String)

    var id: String {
        switch self {
        case .post(let id), .comment(let id), .profile(let id), .story(let id),
             .photo(let id), .photoComment(let id):
            return id
        }
    }
}

/// Corps de `/api/social/reports` (posts, commentaires, profils, stories).
struct ReportRequest: Codable {
    let targetType: String
    let targetId: String
    let reason: String
    /// Le backend lit le texte libre dans `details` (et non `comment`).
    let details: String?
}

/// Corps des routes de modération photo (`contentReportSchema` côté backend :
/// `{ reason, description }` — ni `targetType` ni `targetId`, portés par l'URL).
struct ContentReportRequest: Codable {
    let reason: String
    let description: String?
}

protocol ReportsServicing: Sendable {
    func report(_ target: ReportTarget, reason: ReportReason, comment: String?) async throws
}

final class ReportsService: ReportsServicing {
    private let api: APIClient
    init(api: APIClient) { self.api = api }

    func report(_ target: ReportTarget, reason: ReportReason, comment: String?) async throws {
        if AppEnvironment.usesDemoData {
            try? await Task.sleep(nanoseconds: 300_000_000)
            return
        }
        let trimmed = comment?.trimmingCharacters(in: .whitespacesAndNewlines)
        let details = (trimmed?.isEmpty == false) ? trimmed : nil

        // Les photos ont leurs propres routes de modération, avec un corps
        // différent : la cible est portée par l'URL, pas par le payload.
        switch target {
        case .photo(let id):
            let _: SuccessResponse = try await api.requestJSON(
                "/api/photos/\(id)/report",
                body: ContentReportRequest(reason: reason.rawValue, description: details)
            )
        case .photoComment(let id):
            let _: SuccessResponse = try await api.requestJSON(
                "/api/photos/comments/\(id)/report",
                body: ContentReportRequest(reason: reason.rawValue, description: details)
            )
        case .post, .comment, .profile, .story:
            let _: SuccessResponse = try await api.requestJSON(
                "/api/social/reports",
                body: ReportRequest(
                    targetType: Self.socialTargetType(target),
                    targetId: target.id,
                    reason: reason.rawValue,
                    details: details
                )
            )
        }
    }

    /// Valeurs acceptées par le schéma zod de `/api/social/reports`.
    private static func socialTargetType(_ target: ReportTarget) -> String {
        switch target {
        case .post: return "post"
        case .comment: return "comment"
        case .profile: return "profile"
        // Accepté par le serveur depuis le 29/09 (SOC-12).
        case .story: return "story"
        // Inatteignable : les cas photo sont routés vers leurs endpoints dédiés
        // avant d'arriver ici. Le `switch` reste exhaustif pour qu'un nouveau
        // cas force une décision explicite.
        case .photo, .photoComment: return "post"
        }
    }

    /// Contestation d'une décision de modération sur une photo. Apple attend ce
    /// recours sur un flux de contenu utilisateur modéré.
    func appealPhoto(id: String, reason: ReportReason, comment: String?) async throws {
        if AppEnvironment.usesDemoData {
            try? await Task.sleep(nanoseconds: 300_000_000)
            return
        }
        let trimmed = comment?.trimmingCharacters(in: .whitespacesAndNewlines)
        let _: SuccessResponse = try await api.requestJSON(
            "/api/photos/\(id)/appeal",
            body: ContentReportRequest(
                reason: reason.rawValue,
                description: (trimmed?.isEmpty == false) ? trimmed : nil
            )
        )
    }
}

// MARK: - Bugs et idées

/// Catégories de `/api/bugs`, alignées sur `BUG_CATEGORIES` du serveur (web et
/// Android envoient les mêmes). Une idée est un signalement de catégorie
/// `feature`.
enum BugCategory: String, CaseIterable, Identifiable, Sendable {
    case crash, ui, performance, network, data, feature, other

    var id: String { rawValue }
    var label: String {
        switch self {
        case .crash: return String(localized: "Plantage")
        case .ui: return String(localized: "Affichage")
        case .performance: return String(localized: "Lenteur")
        case .network: return String(localized: "Réseau")
        case .data: return String(localized: "Données")
        case .feature: return String(localized: "Idée")
        case .other: return String(localized: "Autre")
        }
    }

    /// Ce qui ne va pas, dans l'ordre du formulaire.
    static let bugKinds: [BugCategory] = [.crash, .ui, .performance, .network, .data, .other]
}

/// Gêne ressentie (`severity`) ; `medium` par défaut, comme sur le serveur.
enum BugSeverity: String, CaseIterable, Identifiable, Sendable {
    case low, medium, high, critical

    var id: String { rawValue }
    var label: String {
        switch self {
        case .low: return String(localized: "bug.severity.low", defaultValue: "Faible")
        case .medium: return String(localized: "bug.severity.medium", defaultValue: "Moyenne")
        case .high: return String(localized: "Forte")
        case .critical: return String(localized: "Bloquante")
        }
    }
    var pillLabel: String {
        switch self {
        case .low: return String(localized: "Gêne faible")
        case .medium: return String(localized: "Gêne moyenne")
        case .high: return String(localized: "Gêne forte")
        case .critical: return String(localized: "Gêne bloquante")
        }
    }
}

enum BugStatus: String, Sendable {
    case open
    case inProgress = "in_progress"
    case resolved
    case closed
    case wontFix = "wont_fix"

    var label: String {
        switch self {
        case .open: return String(localized: "Ouvert")
        case .inProgress: return String(localized: "En cours")
        case .resolved: return String(localized: "Résolu")
        case .closed: return String(localized: "Fermé")
        case .wontFix: return String(localized: "Non retenu")
        }
    }

    /// Le serveur refuse une réponse de l'auteur sur un signalement fermé ou
    /// non retenu ; une réponse sur un signalement résolu le rouvre.
    var acceptsReplies: Bool { self != .closed && self != .wontFix }
    var isFinished: Bool { self == .resolved || self == .closed || self == .wontFix }
}

/// Un signalement de `/api/bugs`. Décodage tolérant : un champ absent ou d'un
/// type inattendu ne fait pas disparaître le signalement de la liste.
struct BugReport: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let description: String
    let category: BugCategory
    let severity: BugSeverity
    let status: BugStatus
    let deviceModel: String?
    let osVersion: String?
    let appVersion: String?
    let steps: String?
    let expectedResult: String?
    let images: [String]
    let adminResponse: String?
    let fixVersion: String?
    let createdAt: Date?
    let updatedAt: Date?
    let resolvedAt: Date?

    var isIdea: Bool { category == .feature }

    enum CodingKeys: String, CodingKey {
        case id, title, description, category, severity, status, deviceModel, osVersion, appVersion
        case steps, expectedResult, images, adminResponse, fixVersion, createdAt, updatedAt, resolvedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        description = (try? c.decodeIfPresent(String.self, forKey: .description)) ?? ""
        category = (try? c.decodeIfPresent(String.self, forKey: .category)).flatMap(BugCategory.init(rawValue:)) ?? .other
        severity = (try? c.decodeIfPresent(String.self, forKey: .severity)).flatMap(BugSeverity.init(rawValue:)) ?? .medium
        status = (try? c.decodeIfPresent(String.self, forKey: .status)).flatMap(BugStatus.init(rawValue:)) ?? .open
        deviceModel = try? c.decodeIfPresent(String.self, forKey: .deviceModel)
        osVersion = try? c.decodeIfPresent(String.self, forKey: .osVersion)
        appVersion = try? c.decodeIfPresent(String.self, forKey: .appVersion)
        steps = try? c.decodeIfPresent(String.self, forKey: .steps)
        expectedResult = try? c.decodeIfPresent(String.self, forKey: .expectedResult)
        images = (try? c.decodeIfPresent([String].self, forKey: .images)) ?? []
        adminResponse = try? c.decodeIfPresent(String.self, forKey: .adminResponse)
        fixVersion = try? c.decodeIfPresent(String.self, forKey: .fixVersion)
        createdAt = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
        updatedAt = try? c.decodeIfPresent(Date.self, forKey: .updatedAt)
        resolvedAt = try? c.decodeIfPresent(Date.self, forKey: .resolvedAt)
    }

    init(id: String, title: String, description: String, category: BugCategory, severity: BugSeverity = .medium,
         status: BugStatus = .open, deviceModel: String? = nil, osVersion: String? = nil, appVersion: String? = nil,
         steps: String? = nil, expectedResult: String? = nil, images: [String] = [], adminResponse: String? = nil,
         fixVersion: String? = nil, createdAt: Date? = nil, updatedAt: Date? = nil, resolvedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.description = description
        self.category = category
        self.severity = severity
        self.status = status
        self.deviceModel = deviceModel
        self.osVersion = osVersion
        self.appVersion = appVersion
        self.steps = steps
        self.expectedResult = expectedResult
        self.images = images
        self.adminResponse = adminResponse
        self.fixVersion = fixVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.resolvedAt = resolvedAt
    }
}

/// Un message de la conversation d'un signalement (`/api/bugs/{id}/comments`).
/// Les notes internes de l'équipe ne sont jamais servies à l'auteur.
struct BugComment: Decodable, Identifiable, Equatable, Sendable {
    struct Author: Decodable, Equatable, Sendable {
        let id: String?
        let name: String?
        let role: String?
    }

    let id: String
    let content: String
    let images: [String]
    let isAdmin: Bool
    let createdAt: Date?
    let user: Author?

    enum CodingKeys: String, CodingKey { case id, content, images, isAdmin, createdAt, user }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        content = (try? c.decodeIfPresent(String.self, forKey: .content)) ?? ""
        images = (try? c.decodeIfPresent([String].self, forKey: .images)) ?? []
        user = try? c.decodeIfPresent(Author.self, forKey: .user)
        // Le serveur seul sait si l'auteur parlait au nom de l'équipe : un admin
        // qui écrit sur son propre signalement depuis l'app reste l'auteur.
        isAdmin = (try? c.decodeIfPresent(Bool.self, forKey: .isAdmin)) ?? false
        createdAt = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
    }

    init(id: String, content: String, images: [String] = [], isAdmin: Bool = false, createdAt: Date? = nil,
         user: Author? = nil) {
        self.id = id
        self.content = content
        self.images = images
        self.isAdmin = isAdmin
        self.createdAt = createdAt
        self.user = user
    }
}

/// Corps de `POST /api/bugs`. Le serveur ne lit l'appareil, le système et la
/// version que dans le corps ; les champs sont déjà bornés à ses limites.
struct BugReportSubmission: Codable, Equatable, Sendable {
    let title: String
    let description: String
    let category: String
    let severity: String
    let deviceModel: String
    let deviceBrand: String
    let osVersion: String
    let appVersion: String
    let screenSize: String?
    let steps: String?
    let expectedResult: String?
    let images: [String]?
    let context: BugReportContext
}

/// `context` libre de `/api/bugs` : connexion et build toujours, dernier
/// speedtest et position approximative seulement si l'auteur les coche.
struct BugReportContext: Codable, Equatable, Sendable {
    struct Speedtest: Codable, Equatable, Sendable {
        let downloadMbps: Double
        let uploadMbps: Double?
        let pingMs: Double?
        let connectionType: String
        let network: String
        let measuredAt: String
    }

    /// Arrondie à 0,01° (environ 1 km) avant de quitter l'iPhone.
    struct Location: Codable, Equatable, Sendable {
        let latitude: Double
        let longitude: Double
        let approx: Bool

        init(latitude: Double, longitude: Double) {
            self.latitude = (latitude * 100).rounded() / 100
            self.longitude = (longitude * 100).rounded() / 100
            approx = true
        }
    }

    let platform: String
    let networkType: String
    let build: String
    let speedtest: Speedtest?
    let location: Location?
}

extension BugReportSubmission {
    static let titleLimit = 200
    static let descriptionLimit = 5000
    static let stepsLimit = 2000
    static let expectedLimit = 1000
    /// Captures par signalement : 5, comme le web et Android (le serveur en accepte 6).
    static let maxImages = 5

    init(category: BugCategory, title: String, description: String, severity: BugSeverity,
         steps: String?, expectedResult: String?, images: [String], device: BugReportDevice,
         speedtest: BugReportContext.Speedtest?, location: BugReportContext.Location?) {
        func clipped(_ value: String?, _ limit: Int) -> String? {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
            return String(trimmed.prefix(limit))
        }
        self.init(
            title: clipped(title, Self.titleLimit) ?? "",
            description: clipped(description, Self.descriptionLimit) ?? "",
            category: category.rawValue,
            severity: severity.rawValue,
            deviceModel: String(device.model.prefix(100)),
            deviceBrand: "Apple",
            osVersion: String(device.osVersion.prefix(50)),
            appVersion: String(device.appVersion.prefix(20)),
            screenSize: device.screenSize.map { String($0.prefix(20)) },
            steps: clipped(steps, Self.stepsLimit),
            expectedResult: clipped(expectedResult, Self.expectedLimit),
            images: images.isEmpty ? nil : Array(images.prefix(Self.maxImages)),
            context: BugReportContext(platform: "ios", networkType: device.network, build: device.build,
                                      speedtest: speedtest, location: location)
        )
    }
}

/// Ce qui est joint d'office à un signalement, montré tel quel dans le formulaire.
struct BugReportDevice: Equatable, Sendable {
    let model: String
    let osVersion: String
    /// « 1.0 (170) ».
    let appVersion: String
    let build: String
    let network: String
    let screenSize: String?

    @MainActor
    static func current(network: String) -> BugReportDevice {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        let bounds = UIScreen.main.bounds
        return BugReportDevice(
            model: AppleDeviceDescriptor.currentModelName,
            osVersion: AppleDeviceDescriptor.currentOSVersionLabel,
            appVersion: "\(version) (\(build))",
            build: build,
            network: network,
            screenSize: "\(Int(bounds.width))x\(Int(bounds.height))"
        )
    }
}

/// Signalements de bugs et idées (`/api/bugs`), partagés avec le web et Android :
/// un signalement envoyé de l'iPhone se suit aussi sur le site, et inversement.
protocol BugReportsServicing: Sendable {
    func myReports() async throws -> [BugReport]
    func report(id: String) async throws -> BugReport
    @discardableResult
    func submit(_ submission: BugReportSubmission, submissionID: UUID) async throws -> BugReport
    func comments(bugId: String) async throws -> [BugComment]
    @discardableResult
    func addComment(bugId: String, content: String, images: [String]) async throws -> BugComment
    func delete(bugId: String) async throws
    /// Hors connexion : le signalement attend sur l'iPhone, chiffré, et part
    /// au retour du réseau avec la même clé.
    func stage(_ submission: BugReportSubmission, submissionID: UUID) async throws
    func pendingCount() async -> Int
    func retryPending() async
}

final class BugReportsService: BugReportsServicing {
    private let api: APIClient
    private let outbox: BugReportOutboxStore
    private let currentUserId: @Sendable () -> String?
    private let demo = BugReportsDemoStore()
    private let logger = Logger(subsystem: "fr.signalquest.ios", category: "BugReportOutbox")

    init(api: APIClient, outbox: BugReportOutboxStore = BugReportOutboxStore(),
         currentUserId: @escaping @Sendable () -> String? = { LocalAccountScope.currentUserId }) {
        self.api = api
        self.outbox = outbox
        self.currentUserId = currentUserId
    }

    func myReports() async throws -> [BugReport] {
        if AppEnvironment.usesDemoData { return await demo.reports() }
        return try await api.request(
            APIEndpoint(path: "/api/bugs", query: [URLQueryItem(name: "myBugs", value: "true")]),
            as: BugReportsEnvelope.self
        ).reports
    }

    func report(id: String) async throws -> BugReport {
        if AppEnvironment.usesDemoData {
            guard let report = await demo.reports().first(where: { $0.id == id }) else { throw APIError.http(status: 404, code: nil, message: "", requestId: nil, retryAfter: nil) }
            return report
        }
        return try await api.request(APIEndpoint(path: "/api/bugs/\(id)"), as: BugReportEnvelope.self).report
    }

    @discardableResult
    func submit(_ submission: BugReportSubmission, submissionID: UUID) async throws -> BugReport {
        if AppEnvironment.usesDemoData {
            try? await Task.sleep(nanoseconds: 400_000_000)
            return await demo.add(submission)
        }
        // Clé créée à l'ouverture du formulaire : un double appui ou un rejeu
        // après une réponse perdue reste un seul signalement.
        let envelope: BugReportEnvelope = try await api.requestJSON(
            "/api/bugs",
            body: submission,
            idempotencyKey: "bug-report-\(submissionID.uuidString)"
        )
        return envelope.report
    }

    func comments(bugId: String) async throws -> [BugComment] {
        if AppEnvironment.usesDemoData { return await demo.comments(bugId) }
        return try await api.request(
            APIEndpoint(path: "/api/bugs/\(bugId)/comments"),
            as: BugCommentsEnvelope.self
        ).comments
    }

    @discardableResult
    func addComment(bugId: String, content: String, images: [String]) async throws -> BugComment {
        struct Body: Encodable {
            let content: String
            let images: [String]?
        }
        if AppEnvironment.usesDemoData {
            try? await Task.sleep(nanoseconds: 300_000_000)
            return await demo.addComment(bugId, content: content, images: images)
        }
        return try await api.requestJSON(
            "/api/bugs/\(bugId)/comments",
            body: Body(content: content, images: images.isEmpty ? nil : images)
        )
    }

    func delete(bugId: String) async throws {
        if AppEnvironment.usesDemoData {
            await demo.delete(bugId)
            return
        }
        try await api.request(APIEndpoint(path: "/api/bugs/\(bugId)", method: .delete))
    }

    func stage(_ submission: BugReportSubmission, submissionID: UUID) async throws {
        guard let userId = currentUserId(), !userId.isEmpty else { throw APIError.missingAuthToken }
        try await outbox.stage(userId: userId, submission: submission, submissionID: submissionID)
    }

    func pendingCount() async -> Int {
        guard let userId = currentUserId(), !userId.isEmpty else { return 0 }
        return (try? await outbox.pending(userId: userId).count) ?? 0
    }

    func retryPending() async {
        guard !AppEnvironment.usesDemoData, let userId = currentUserId(), !userId.isEmpty,
              let pending = try? await outbox.pending(userId: userId) else { return }
        for record in pending {
            guard await outbox.claim(record.submissionID) else { continue }
            do {
                try await submit(record.submission, submissionID: record.submissionID)
            } catch {
                await outbox.release(record.submissionID)
                if error.isCancellation { return }
                logger.warning("Bug report replay failed; encrypted record retained")
                // Une panne commune rendrait les suivants inutiles ; un refus
                // du serveur garde le signalement, comme les sites ajoutés.
                if CustomSiteOutboxRetryPolicy.isRetryable(error) { return }
                continue
            }
            do {
                try await outbox.remove(userId: userId, submissionID: record.submissionID)
            } catch {
                logger.error("Unable to clear acknowledged bug report outbox record")
            }
            await outbox.release(record.submissionID)
        }
    }
}

/// Signalements écrits hors connexion : un fichier par compte, scellé en
/// AES-GCM avec une clé du trousseau, sur le modèle de `CustomSiteOutboxStore`.
/// Les captures y sont gardées telles qu'elles partiront.
actor BugReportOutboxStore {
    struct Record: Codable, Equatable, Sendable {
        let submissionID: UUID
        let ownerScopeId: String
        let submission: BugReportSubmission
        let createdAtMs: Int64
    }

    private struct File: Codable {
        var version = 1
        var records: [Record] = []
    }

    private static let folderName = "BugReportOutboxV1"
    static let keyService = "fr.signalquest.ios.bug-report-outbox"
    /// Au-delà, le plus ancien laisse sa place : la file n'est pas une archive.
    static let maxRecords = 10

    private let rootURL: URL
    private let fileManager: FileManager
    private let keyStore: TokenStore
    private var inFlight: Set<UUID> = []

    init(rootURL: URL? = nil, fileManager: FileManager = .default,
         keyStore: TokenStore = KeychainStore(service: BugReportOutboxStore.keyService)) {
        self.fileManager = fileManager
        self.keyStore = keyStore
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            self.rootURL = support
                .appendingPathComponent("SignalQuest", isDirectory: true)
                .appendingPathComponent(Self.folderName, isDirectory: true)
        }
    }

    /// Un second appui sur « Envoyer » garde un seul signalement.
    func stage(userId: String, submission: BugReportSubmission, submissionID: UUID) throws {
        let owner = CustomSiteOutboxOwner.scope(for: userId)
        var file = try read(owner)
        guard !file.records.contains(where: { $0.submissionID == submissionID }) else { return }
        file.records.append(Record(submissionID: submissionID, ownerScopeId: owner, submission: submission,
                                   createdAtMs: Int64(Date().timeIntervalSince1970 * 1_000)))
        file.records = Array(file.records.suffix(Self.maxRecords))
        try write(file, owner)
    }

    func pending(userId: String) throws -> [Record] {
        try read(CustomSiteOutboxOwner.scope(for: userId)).records.sorted { $0.createdAtMs < $1.createdAtMs }
    }

    func remove(userId: String, submissionID: UUID) throws {
        let owner = CustomSiteOutboxOwner.scope(for: userId)
        var file = try read(owner)
        file.records.removeAll { $0.submissionID == submissionID }
        try write(file, owner)
    }

    /// Un renvoi déjà en cours (réseau revenu puis premier plan) n'est pas doublé.
    func claim(_ id: UUID) -> Bool { inFlight.insert(id).inserted }
    func release(_ id: UUID) { inFlight.remove(id) }

    private func read(_ owner: String) throws -> File {
        let url = fileURL(owner)
        guard fileManager.fileExists(atPath: url.path) else { return File() }
        let box = try AES.GCM.SealedBox(combined: try Data(contentsOf: url, options: [.mappedIfSafe]))
        let file = try JSONDecoder.signalQuest.decode(File.self, from: try AES.GCM.open(box, using: try key(owner)))
        guard file.version == 1, file.records.allSatisfy({ $0.ownerScopeId == owner }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return file
    }

    private func write(_ file: File, _ owner: String) throws {
        let url = fileURL(owner)
        if file.records.isEmpty {
            if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
            return
        }
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let box = try AES.GCM.seal(try JSONEncoder.signalQuest.encode(file), using: try key(owner))
        guard let combined = box.combined else { throw CocoaError(.fileWriteUnknown) }
        try combined.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func key(_ owner: String) throws -> SymmetricKey {
        let name = "key:\(owner)"
        if let encoded = try keyStore.string(for: name), let bytes = Data(base64Encoded: encoded), bytes.count == 32 {
            return SymmetricKey(data: bytes)
        }
        let key = SymmetricKey(size: .bits256)
        try keyStore.set(key.withUnsafeBytes { Data($0) }.base64EncodedString(), for: name, accessibility: .afterFirstUnlock)
        return key
    }

    private func fileURL(_ owner: String) -> URL {
        rootURL
            .appendingPathComponent(String(owner.dropFirst("user:".count)), isDirectory: true)
            .appendingPathComponent("pending.json.enc", isDirectory: false)
    }
}

/// Réponses de l'équipe pas encore lues, pour le badge du Profil. Par compte,
/// sur cet appareil : seulement des identifiants et des dates.
enum BugReportsSeenStore {
    private static let prefix = "SignalQuest.BugReportsSeen.v1"

    private static func key(_ ownerScopeId: String) -> String {
        "\(prefix).\(LocalAccountScope.storageNamespace(for: ownerScopeId))"
    }

    /// L'équipe a répondu ou changé le statut.
    static func hasTeamActivity(_ report: BugReport) -> Bool {
        report.status != .open || !(report.adminResponse?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    /// Nombre de signalements dont l'activité de l'équipe n'a pas été vue. La
    /// première lecture d'un compte sert de point de départ : ce qui existait
    /// déjà ne s'allume pas d'un coup.
    static func unseenCount(
        in reports: [BugReport],
        ownerScopeId: String = LocalAccountScope.currentOwnerScopeId,
        defaults: UserDefaults = .standard
    ) -> Int {
        guard ownerScopeId.hasPrefix("user:") else { return 0 }
        guard let seen = defaults.dictionary(forKey: key(ownerScopeId)) as? [String: Double] else {
            save(Dictionary(reports.map { ($0.id, stamp($0)) }, uniquingKeysWith: max),
                 ownerScopeId: ownerScopeId, defaults: defaults)
            return 0
        }
        return reports.filter { report in
            guard hasTeamActivity(report) else { return false }
            guard let last = seen[report.id] else { return true }
            return stamp(report) > last
        }.count
    }

    static func markSeen(
        _ report: BugReport,
        ownerScopeId: String = LocalAccountScope.currentOwnerScopeId,
        defaults: UserDefaults = .standard
    ) {
        guard ownerScopeId.hasPrefix("user:") else { return }
        var seen = defaults.dictionary(forKey: key(ownerScopeId)) as? [String: Double] ?? [:]
        seen[report.id] = max(seen[report.id] ?? 0, stamp(report))
        save(seen, ownerScopeId: ownerScopeId, defaults: defaults)
    }

    private static func stamp(_ report: BugReport) -> Double {
        (report.updatedAt ?? report.createdAt ?? .distantPast).timeIntervalSince1970
    }

    private static func save(_ seen: [String: Double], ownerScopeId: String, defaults: UserDefaults) {
        defaults.set(seen, forKey: key(ownerScopeId))
    }
}

// MARK: Admin (`/api/admin/bugs`)

/// Les segments de la liste d'admin, dans l'ordre du site : le tri d'abord.
enum AdminBugSegment: String, CaseIterable, Identifiable, Sendable {
    case triage
    case inProgress = "in_progress"
    case resolved, ideas, all

    var id: String { rawValue }
    var label: String {
        switch self {
        case .triage: return String(localized: "À trier")
        case .inProgress: return String(localized: "En cours")
        case .resolved: return String(localized: "Résolus")
        case .ideas: return String(localized: "Idées")
        case .all: return String(localized: "Tous")
        }
    }
}

/// D'où vient le signalement (`source`).
enum AdminBugSource: String, CaseIterable, Identifiable, Sendable {
    case all, ios, android, web, assistant

    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return String(localized: "Toutes les sources")
        case .ios: return "iOS"
        case .android: return "Android"
        case .web: return String(localized: "admin.source.web", defaultValue: "Site")
        case .assistant: return String(localized: "Assistant")
        }
    }
}

struct AdminBugFilters: Equatable, Sendable {
    var segment: AdminBugSegment = .triage
    var source: AdminBugSource = .all
    var onlyMine = false
    var onlyCritical = false
    var query = ""

    /// Les filtres hors segment : ce que le bouton de filtres signale comme actif.
    var activeCount: Int { (source == .all ? 0 : 1) + (onlyMine ? 1 : 0) + (onlyCritical ? 1 : 0) }

    /// `segment` est toujours envoyé : sans aucun des paramètres récents, le serveur
    /// garderait l'ancienne réponse, avec chaque conversation entière.
    func queryItems(page: Int) -> [URLQueryItem] {
        var items = [URLQueryItem(name: "segment", value: segment.rawValue),
                     URLQueryItem(name: "page", value: String(page)),
                     URLQueryItem(name: "limit", value: "30")]
        if source != .all { items.append(URLQueryItem(name: "source", value: source.rawValue)) }
        if onlyMine { items.append(URLQueryItem(name: "assignee", value: "me")) }
        if onlyCritical { items.append(URLQueryItem(name: "critical", value: "1")) }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty { items.append(URLQueryItem(name: "q", value: q)) }
        return items
    }
}

/// Signaleur, assigné ou candidat à l'assignation.
struct AdminBugPerson: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String?
    let email: String?
    let handle: String?
    let isMe: Bool

    enum CodingKeys: String, CodingKey { case id, name, email, handle, isMe }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? ""
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        email = try? c.decodeIfPresent(String.self, forKey: .email)
        handle = try? c.decodeIfPresent(String.self, forKey: .handle)
        isMe = (try? c.decodeIfPresent(Bool.self, forKey: .isMe)) ?? false
    }

    init(id: String, name: String?, email: String? = nil, handle: String? = nil, isMe: Bool = false) {
        self.id = id
        self.name = name
        self.email = email
        self.handle = handle
        self.isMe = isMe
    }

    var displayName: String {
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        if let handle, !handle.isEmpty { return "@\(handle)" }
        return email ?? String(localized: "Compte sans nom")
    }
}

/// Un signalement vu par l'équipe : celui de l'auteur, plus le tri.
struct AdminBug: Decodable, Identifiable, Equatable, Sendable {
    let report: BugReport
    let source: String?
    let reporter: AdminBugPerson?
    let assignee: AdminBugPerson?
    let commentCount: Int
    let similarCount: Int
    let fixReleaseVersion: String?
    let stackTrace: String?
    let build: String?
    let legacyAdminNotes: String?

    var id: String { report.id }

    private enum CodingKeys: String, CodingKey {
        case source, user, assignee, commentCount, similarCount, fixRelease, stackTrace, build, legacyAdminNotes
    }
    private struct FixRelease: Decodable { let version: String? }

    init(from decoder: Decoder) throws {
        report = try BugReport(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try? c.decodeIfPresent(String.self, forKey: .source)
        reporter = try? c.decodeIfPresent(AdminBugPerson.self, forKey: .user)
        assignee = try? c.decodeIfPresent(AdminBugPerson.self, forKey: .assignee)
        commentCount = (try? c.decodeIfPresent(Int.self, forKey: .commentCount)) ?? 0
        similarCount = (try? c.decodeIfPresent(Int.self, forKey: .similarCount)) ?? 0
        fixReleaseVersion = (try? c.decodeIfPresent(FixRelease.self, forKey: .fixRelease))?.version
        stackTrace = try? c.decodeIfPresent(String.self, forKey: .stackTrace)
        build = try? c.decodeIfPresent(String.self, forKey: .build)
        legacyAdminNotes = try? c.decodeIfPresent(String.self, forKey: .legacyAdminNotes)
    }

    var sourceLabel: String? { source.flatMap(AdminBugSource.init(rawValue:))?.label ?? source }
}

/// Un message de la discussion vu par l'équipe : la réponse publique au signaleur,
/// ou la note interne, que le signaleur ne voit jamais.
struct AdminBugComment: Decodable, Identifiable, Equatable, Sendable {
    let comment: BugComment
    let isInternal: Bool
    let authorName: String?

    var id: String { comment.id }

    private enum CodingKeys: String, CodingKey { case `internal`, author, authorName }
    private struct Author: Decodable { let name: String? }

    init(from decoder: Decoder) throws {
        comment = try BugComment(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isInternal = (try? c.decodeIfPresent(Bool.self, forKey: .internal)) ?? false
        authorName = (try? c.decodeIfPresent(Author.self, forKey: .author))?.name
            ?? (try? c.decodeIfPresent(String.self, forKey: .authorName))
    }
}

struct AdminBugDetail: Decodable, Equatable, Sendable {
    let bug: AdminBug
    let comments: [AdminBugComment]
    let assignees: [AdminBugPerson]

    private enum CodingKeys: String, CodingKey { case bug, assignees }
    private enum BugKeys: String, CodingKey { case comments }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bug = try c.decode(AdminBug.self, forKey: .bug)
        let bugContainer = try c.nestedContainer(keyedBy: BugKeys.self, forKey: .bug)
        comments = ((try? bugContainer.decodeIfPresent([BugFailable<AdminBugComment>].self, forKey: .comments)) ?? [])
            .compactMap(\.value)
            .sorted { ($0.comment.createdAt ?? .distantPast) < ($1.comment.createdAt ?? .distantPast) }
        assignees = ((try? c.decodeIfPresent([BugFailable<AdminBugPerson>].self, forKey: .assignees)) ?? [])
            .compactMap(\.value)
            .filter { !$0.id.isEmpty }
    }
}

struct AdminBugsPage: Decodable, Equatable, Sendable {
    let bugs: [AdminBug]
    let totalCount: Int
    let currentPage: Int
    let totalPages: Int
    /// Par segment, avec la source et « à moi » appliqués, comme sur le site.
    let counts: [String: Int]

    private enum CodingKeys: String, CodingKey { case bugs, pagination, counts }
    private struct Pagination: Decodable {
        let totalCount: Int?
        let totalPages: Int?
        let currentPage: Int?
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bugs = ((try? c.decodeIfPresent([BugFailable<AdminBug>].self, forKey: .bugs)) ?? []).compactMap(\.value)
        let pagination = try? c.decodeIfPresent(Pagination.self, forKey: .pagination)
        totalCount = pagination?.totalCount ?? bugs.count
        currentPage = pagination?.currentPage ?? 1
        totalPages = pagination?.totalPages ?? 1
        counts = (try? c.decodeIfPresent([String: Int].self, forKey: .counts)) ?? [:]
    }

    func count(_ segment: AdminBugSegment) -> Int? { counts[segment.rawValue] }
    var hasMore: Bool { currentPage < totalPages }
}

/// Corps de `PATCH /api/admin/bugs/{id}` : seuls les champs posés partent.
struct AdminBugPatch: Encodable, Equatable, Sendable {
    enum Assignment: Equatable, Sendable { case me, nobody }

    var status: BugStatus?
    var severity: BugSeverity?
    var fixVersion: String?
    var adminResponse: String?
    var assignment: Assignment?

    private enum CodingKeys: String, CodingKey { case status, severity, fixVersion, adminResponse, assigneeId }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(status?.rawValue, forKey: .status)
        try c.encodeIfPresent(severity?.rawValue, forKey: .severity)
        try c.encodeIfPresent(fixVersion, forKey: .fixVersion)
        try c.encodeIfPresent(adminResponse, forKey: .adminResponse)
        switch assignment {
        case .me: try c.encode("me", forKey: .assigneeId)
        case .nobody: try c.encodeNil(forKey: .assigneeId)
        case nil: break
        }
    }
}

protocol AdminBugsServicing: Sendable {
    func list(_ filters: AdminBugFilters, page: Int) async throws -> AdminBugsPage
    func detail(id: String) async throws -> AdminBugDetail
    func update(id: String, _ patch: AdminBugPatch) async throws
    /// `isInternal` : note de l'équipe, jamais montrée ni notifiée au signaleur.
    func comment(id: String, content: String, isInternal: Bool) async throws
}

/// Réservé aux administrateurs : le serveur répond 403 à tout autre compte.
final class AdminBugsService: AdminBugsServicing {
    private let api: APIClient

    init(api: APIClient) { self.api = api }

    private struct DataEnvelope<T: Decodable>: Decodable { let data: T }

    private static func path(_ id: String) -> String { "/api/admin/bugs/\(id)" }

    func list(_ filters: AdminBugFilters, page: Int) async throws -> AdminBugsPage {
        try await api.request(APIEndpoint(path: "/api/admin/bugs", query: filters.queryItems(page: page)),
                              as: DataEnvelope<AdminBugsPage>.self).data
    }

    func detail(id: String) async throws -> AdminBugDetail {
        try await api.request(APIEndpoint(path: Self.path(id)), as: DataEnvelope<AdminBugDetail>.self).data
    }

    func update(id: String, _ patch: AdminBugPatch) async throws {
        try await api.requestJSON(Self.path(id), method: .patch, body: patch)
    }

    func comment(id: String, content: String, isInternal: Bool) async throws {
        struct Body: Encodable {
            let content: String
            let `internal`: Bool
        }
        try await api.requestJSON(Self.path(id), body: Body(content: content, internal: isInternal))
    }
}

// MARK: Enveloppes tolérantes

/// `GET /api/bugs?myBugs=true` renvoie un tableau nu ; `{ bugs: [...] }` est
/// aussi accepté. Un élément malformé est ignoré, pas toute la liste.
private struct BugReportsEnvelope: Decodable {
    let reports: [BugReport]

    init(from decoder: Decoder) throws {
        if let array = try? decoder.singleValueContainer().decode([BugFailable<BugReport>].self) {
            reports = array.compactMap(\.value)
            return
        }
        let c = try decoder.container(keyedBy: BugDynamicKey.self)
        for key in ["bugs", "items", "data"] {
            if let dyn = BugDynamicKey(stringValue: key),
               let array = try? c.decode([BugFailable<BugReport>].self, forKey: dyn) {
                reports = array.compactMap(\.value)
                return
            }
        }
        reports = []
    }
}

/// Un signalement, nu (contrat actuel) ou sous `bug`.
private struct BugReportEnvelope: Decodable {
    let report: BugReport

    init(from decoder: Decoder) throws {
        if let direct = try? decoder.singleValueContainer().decode(BugReport.self) {
            report = direct
            return
        }
        let c = try decoder.container(keyedBy: BugDynamicKey.self)
        for key in ["bug", "data"] {
            if let dyn = BugDynamicKey(stringValue: key), let value = try? c.decode(BugReport.self, forKey: dyn) {
                report = value
                return
            }
        }
        throw APIError.decoding("bug-report-response")
    }
}

private struct BugCommentsEnvelope: Decodable {
    let comments: [BugComment]

    init(from decoder: Decoder) throws {
        if let array = try? decoder.singleValueContainer().decode([BugFailable<BugComment>].self) {
            comments = array.compactMap(\.value)
            return
        }
        let c = try decoder.container(keyedBy: BugDynamicKey.self)
        for key in ["comments", "items", "data"] {
            if let dyn = BugDynamicKey(stringValue: key),
               let array = try? c.decode([BugFailable<BugComment>].self, forKey: dyn) {
                comments = array.compactMap(\.value)
                return
            }
        }
        comments = []
    }
}

private struct BugFailable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? decoder.singleValueContainer().decode(T.self)
    }
}

private struct BugDynamicKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

// MARK: Données de démonstration

/// Signalements fictifs du mode démo (captures, tests UI) : rien ne part au serveur.
private actor BugReportsDemoStore {
    private var stored: [BugReport]
    private var threads: [String: [BugComment]]

    init() {
        let now = Date()
        func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }
        stored = [
            BugReport(id: "demo-bug-1", title: String(localized: "La carte reste blanche après le retour de veille"),
                      description: String(localized: "Après 5 min de veille, la carte reste blanche jusqu'à ce que je change d'onglet."),
                      category: .ui, severity: .medium, status: .inProgress, deviceModel: "iPhone", osVersion: "iOS 26.1",
                      appVersion: "1.0 (170)",
                      adminResponse: String(localized: "Merci ! On reproduit le problème sur iOS 26.1, un correctif est prévu dans la prochaine version."),
                      createdAt: ago(30), updatedAt: ago(2)),
            BugReport(id: "demo-bug-2", title: String(localized: "Pouvoir comparer deux speedtests côte à côte"),
                      description: String(localized: "Pour voir si le changement de forfait a vraiment amélioré le débit au même endroit."),
                      category: .feature, status: .open, appVersion: "1.0 (170)", createdAt: ago(96)),
            BugReport(id: "demo-bug-3", title: String(localized: "Le Drive Test s'arrêtait au changement d'antenne"),
                      description: String(localized: "La session s'arrête dès que l'iPhone change de cellule."),
                      category: .crash, severity: .high, status: .resolved, deviceModel: "iPhone", osVersion: "iOS 26.0",
                      appVersion: "1.0 (166)",
                      adminResponse: String(localized: "Corrigé : la session reprend toute seule après le changement de cellule. Merci pour les étapes, elles ont tout débloqué."),
                      fixVersion: "1.0 (168)", createdAt: ago(380), updatedAt: ago(264), resolvedAt: ago(264))
        ]
        threads = [
            "demo-bug-1": [
                BugComment(id: "demo-c1", content: String(localized: "Ça arrive aussi en données mobiles ?"), isAdmin: true,
                           createdAt: ago(14), user: .init(id: nil, name: nil, role: "admin")),
                BugComment(id: "demo-c2", content: String(localized: "Oui, en 5G aussi."), createdAt: ago(13.7))
            ],
            "demo-bug-3": [
                BugComment(id: "demo-c3", content: String(localized: "Tu peux confirmer avec la 168 ?"), isAdmin: true,
                           createdAt: ago(250), user: .init(id: nil, name: nil, role: "admin"))
            ]
        ]
    }

    func reports() -> [BugReport] { stored }
    func comments(_ id: String) -> [BugComment] { threads[id] ?? [] }

    func add(_ submission: BugReportSubmission) -> BugReport {
        let report = BugReport(
            id: "demo-bug-\(UUID().uuidString.prefix(8))", title: submission.title, description: submission.description,
            category: BugCategory(rawValue: submission.category) ?? .other,
            severity: BugSeverity(rawValue: submission.severity) ?? .medium, deviceModel: submission.deviceModel,
            osVersion: submission.osVersion, appVersion: submission.appVersion, steps: submission.steps,
            expectedResult: submission.expectedResult, images: submission.images ?? [], createdAt: Date(), updatedAt: Date()
        )
        stored.insert(report, at: 0)
        return report
    }

    func addComment(_ id: String, content: String, images: [String]) -> BugComment {
        let comment = BugComment(id: "demo-c-\(UUID().uuidString.prefix(8))", content: content, images: images, createdAt: Date())
        threads[id, default: []].append(comment)
        return comment
    }

    func delete(_ id: String) {
        stored.removeAll { $0.id == id }
        threads[id] = nil
    }
}
