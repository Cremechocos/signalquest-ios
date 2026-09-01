import Foundation
import os
import SwiftData

struct CoverageCellEvidenceUpload: Codable, Equatable, Sendable {
    let cellType: String
    let isPrimary: Bool
    let technology: String?
    let enb: String?
    let gnb: String?
    /// Identifiant local dans le noeud, distinct des identites completes.
    let cellId: String?
    let eci: String?
    let nci: String?
    let pci: Int?
    let tac: String?
    let earfcn: Int?
    let nrarfcn: Int?
    let timingAdvance: Int?
    let timingAdvanceSourceTechnology: String?
    let timingAdvanceSourceCellId: String?

    /// Separe l'ancre LTE et la porteuse NR d'une preuve NSA. Le TA n'est
    /// transporte que par la cellule correspondant a sa technologie source.
    static func cells(from evidence: SpeedtestRadioEvidence) -> [CoverageCellEvidenceUpload] {
        let rat = evidence.rat?.uppercased() ?? ""
        let isNsa = evidence.is5gNsa == true || rat.contains("NSA")
        let lteTimingAdvance = ["LTE", "LTE_ANCHOR"].contains(
            evidence.timingAdvanceSourceTechnology?.uppercased() ?? ""
        )
        let nrTimingAdvance = evidence.timingAdvanceSourceTechnology?.uppercased() == "NR"

        if isNsa {
            var result: [CoverageCellEvidenceUpload] = []
            if evidence.enb != nil || evidence.eci != nil || evidence.earfcn != nil || lteTimingAdvance {
                result.append(CoverageCellEvidenceUpload(
                    cellType: "LTE", isPrimary: true, technology: "LTE",
                    enb: evidence.enb, gnb: nil, cellId: evidence.localCellId,
                    eci: evidence.eci, nci: nil, pci: evidence.pci, tac: evidence.tac,
                    earfcn: evidence.earfcn, nrarfcn: nil,
                    timingAdvance: lteTimingAdvance ? evidence.timingAdvance : nil,
                    timingAdvanceSourceTechnology: lteTimingAdvance ? evidence.timingAdvanceSourceTechnology : nil,
                    timingAdvanceSourceCellId: lteTimingAdvance ? evidence.timingAdvanceSourceCellId : nil
                ))
            }
            if evidence.gnb != nil || evidence.nci != nil || evidence.nrarfcn != nil {
                result.append(CoverageCellEvidenceUpload(
                    cellType: "NR", isPrimary: false, technology: "NR",
                    enb: nil, gnb: evidence.gnb, cellId: nil,
                    eci: nil, nci: evidence.nci, pci: nil, tac: nil,
                    earfcn: nil, nrarfcn: evidence.nrarfcn,
                    timingAdvance: nrTimingAdvance ? evidence.timingAdvance : nil,
                    timingAdvanceSourceTechnology: nrTimingAdvance ? evidence.timingAdvanceSourceTechnology : nil,
                    timingAdvanceSourceCellId: nrTimingAdvance ? evidence.timingAdvanceSourceCellId : nil
                ))
            }
            return result
        }

        let isNr = rat == "NR" || evidence.is5gSa == true || evidence.nci != nil || evidence.gnb != nil
        return [CoverageCellEvidenceUpload(
            cellType: isNr ? "NR" : "LTE",
            isPrimary: true,
            technology: isNr ? "NR" : "LTE",
            enb: isNr ? nil : evidence.enb,
            gnb: isNr ? evidence.gnb : nil,
            cellId: evidence.localCellId,
            eci: isNr ? nil : evidence.eci,
            nci: isNr ? evidence.nci : nil,
            pci: evidence.pci,
            tac: evidence.tac,
            earfcn: isNr ? nil : evidence.earfcn,
            nrarfcn: isNr ? evidence.nrarfcn : nil,
            timingAdvance: (isNr ? nrTimingAdvance : lteTimingAdvance) ? evidence.timingAdvance : nil,
            timingAdvanceSourceTechnology: (isNr ? nrTimingAdvance : lteTimingAdvance)
                ? evidence.timingAdvanceSourceTechnology : nil,
            timingAdvanceSourceCellId: (isNr ? nrTimingAdvance : lteTimingAdvance)
                ? evidence.timingAdvanceSourceCellId : nil
        )]
    }
}

/// Un point de couverture contribue par iOS. Les API publiques ne fournissent
/// normalement que la generation ; les preuves cellule restent donc optionnelles
/// et ne sont emises que lorsqu'une source explicite les fournit.
struct CoveragePointUpload: Codable, Equatable, Sendable {
    /// Identifiant purement client, stable dans la file locale. Le backend actuel
    /// ignore cette clé additive, mais elle évite toute collision entre deux points
    /// capturés au même endroit et au même instant.
    let localId: UUID
    let latitude: Double
    let longitude: Double
    /// Horodatage en millisecondes epoch (non ambigu pour le backend).
    let timestamp: Int
    /// Génération : "2G"/"3G"/"4G"/"5G NSA"/"5G SA" ou "Aucun" (zone sans réseau).
    let technology: String
    var accuracy: Double? = nil
    var downloadMbps: Double? = nil
    var uploadMbps: Double? = nil
    var pingMs: Double? = nil
    var observedPlmn: String? = nil
    var enb: String? = nil
    var gnb: String? = nil
    var cellId: String? = nil
    var eci: String? = nil
    var nci: String? = nil
    var pci: Int? = nil
    var tac: String? = nil
    var earfcn: Int? = nil
    var nrarfcn: Int? = nil
    var timingAdvance: Int? = nil
    var timingAdvanceSourceTechnology: String? = nil
    var timingAdvanceSourceCellId: String? = nil
    var radioAgeMs: Int? = nil
    var locationAgeMs: Int? = nil
    var radioObservedAt: Date? = nil
    var cells: [CoverageCellEvidenceUpload]? = nil

    init(
        localId: UUID = UUID(),
        latitude: Double,
        longitude: Double,
        timestamp: Int,
        technology: String,
        accuracy: Double? = nil,
        downloadMbps: Double? = nil,
        uploadMbps: Double? = nil,
        pingMs: Double? = nil,
        observedPlmn: String? = nil,
        enb: String? = nil,
        gnb: String? = nil,
        cellId: String? = nil,
        eci: String? = nil,
        nci: String? = nil,
        pci: Int? = nil,
        tac: String? = nil,
        earfcn: Int? = nil,
        nrarfcn: Int? = nil,
        timingAdvance: Int? = nil,
        timingAdvanceSourceTechnology: String? = nil,
        timingAdvanceSourceCellId: String? = nil,
        radioAgeMs: Int? = nil,
        locationAgeMs: Int? = nil,
        radioObservedAt: Date? = nil,
        cells: [CoverageCellEvidenceUpload]? = nil
    ) {
        self.localId = localId
        self.latitude = latitude
        self.longitude = longitude
        self.timestamp = timestamp
        self.technology = technology
        self.accuracy = accuracy
        self.downloadMbps = downloadMbps
        self.uploadMbps = uploadMbps
        self.pingMs = pingMs
        self.observedPlmn = RadioLogPlmn.split(observedPlmn).map { $0.mcc + $0.mnc }
        self.enb = enb
        self.gnb = gnb
        self.cellId = cellId
        self.eci = eci
        self.nci = nci
        self.pci = pci
        self.tac = tac
        self.earfcn = earfcn
        self.nrarfcn = nrarfcn
        self.timingAdvance = timingAdvance
        self.timingAdvanceSourceTechnology = timingAdvanceSourceTechnology
        self.timingAdvanceSourceCellId = timingAdvanceSourceCellId
        self.radioAgeMs = radioAgeMs
        self.locationAgeMs = locationAgeMs
        self.radioObservedAt = radioObservedAt
        self.cells = cells
    }
}

extension CoveragePointUpload {
    /// Réduit la précision des coordonnées avant persistance/envoi au backend, pour
    /// respecter la minimisation (RGPD art. 5.1.c). Grille commune à toute l'app —
    /// voir `CoordinateGrid` pour le choix du pas. La trace locale du Drive Test
    /// (`coverageTrail`) conserve, elle, la précision réelle.
    func minimizedCoordinates() -> CoveragePointUpload {
        CoveragePointUpload(
            localId: localId,
            latitude: CoordinateGrid.snap(latitude),
            longitude: CoordinateGrid.snap(longitude),
            timestamp: timestamp,
            technology: technology,
            accuracy: accuracy,
            downloadMbps: downloadMbps,
            uploadMbps: uploadMbps,
            pingMs: pingMs,
            observedPlmn: observedPlmn,
            enb: enb,
            gnb: gnb,
            cellId: cellId,
            eci: eci,
            nci: nci,
            pci: pci,
            tac: tac,
            earfcn: earfcn,
            nrarfcn: nrarfcn,
            timingAdvance: timingAdvance,
            timingAdvanceSourceTechnology: timingAdvanceSourceTechnology,
            timingAdvanceSourceCellId: timingAdvanceSourceCellId,
            radioAgeMs: radioAgeMs,
            locationAgeMs: locationAgeMs,
            radioObservedAt: radioObservedAt,
            cells: cells
        )
    }
}

/// Session de couverture iOS à téléverser (`POST /api/coverage/session/import-ios`).
/// `sessionId` est repris par le backend dans `sourceSessionId` et sert aussi à
/// construire l'en-tête d'idempotence stable lors de chaque rejeu.
struct CoverageSessionUpload: Codable, Equatable, Sendable {
    let sessionId: UUID
    var name: String? = nil
    let startTime: Int
    var endTime: Int
    var device: String? = nil
    var mcc: Int? = nil
    var mnc: Int? = nil
    var observedPlmn: String? = nil
    var simPlmn: String? = nil
    var isRoaming: Bool? = nil
    var networkIdentitySource: String? = nil
    var networkIdentityObservedAt: Date? = nil
    var operatorKey: String? = nil
    /// Nom brut de l'abonnement/SIM remonté par CoreTelephony. Il peut désigner
    /// un MVNO et ne doit donc jamais remplacer `operatorKey` ni le PLMN observé.
    var carrierName: String? = nil
    var mvnoKey: String? = nil
    var mvnoName: String? = nil
    var marketCode: String? = nil
    /// Version binaire ayant enregistré la session. `unknown` reste préférable à
    /// une absence ambiguë pour les anciens brouillons repris hors-ligne.
    var appVersion: String? = nil
    var showOnMap: Bool
    var points: [CoveragePointUpload]

    var idempotencyKey: String {
        "coverage-ios-\(sessionId.uuidString.lowercased())"
    }
}

struct CoverageImportResponse: Decodable, Equatable, Sendable {
    let ok: Bool
    let sessionId: String?
    let totalPoints: Int?
    let idempotent: Bool?
    let plmnResolved: Bool?
    let marketCode: String?
    let operatorKey: String?
    let mvnoKey: String?
    let mvnoName: String?
    let warning: String?
    let warningMessage: String?
}

/// État local, jamais envoyé au backend.
enum CoverageSessionQueueState: String, Codable, Sendable {
    case recording
    case queued
}

struct PendingCoverageSession: Codable, Equatable, Sendable {
    var upload: CoverageSessionUpload
    var state: CoverageSessionQueueState
    var updatedAtMs: Int
}

/// `internal` (pas `private`) : lu par la migration SwiftData (`SwiftDataCoverageSessionStore`).
struct CoverageSessionQueueFile: Codable, Sendable {
    var version = 1
    var sessions: [PendingCoverageSession] = []
}

/// File durable située dans Application Support (et non Caches, qui peut être
/// purgé par iOS). Chaque mutation est encodée puis remplacée atomiquement.
/// Le verrou rend les écritures synchrones sûres depuis les callbacks GPS et
/// garantit qu'un point est sur disque avant que l'UI poursuive son traitement.
final class CoverageSessionQueue: CoverageSessionStoring, @unchecked Sendable {
    private let fileURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private let encoder = JSONEncoder.signalQuest
    private let decoder = JSONDecoder.signalQuest

    init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            self.fileURL = applicationSupport
                .appendingPathComponent("SignalQuest", isDirectory: true)
                .appendingPathComponent("PendingCoverageSessions.json", isDirectory: false)
        }
    }

    func upsert(_ upload: CoverageSessionUpload, state requestedState: CoverageSessionQueueState) throws {
        try withLock {
            var snapshot = try readUnlocked()
            let nowMs = Self.nowMs()
            if let index = snapshot.sessions.firstIndex(where: { $0.upload.sessionId == upload.sessionId }) {
                let existing = snapshot.sessions[index]
                // Une ancienne capture asynchrone ne peut ni retirer des points ni
                // repasser une session finalisée à l'état "recording".
                guard upload.points.count >= existing.upload.points.count else { return }
                let state: CoverageSessionQueueState = existing.state == .queued ? .queued : requestedState
                snapshot.sessions[index] = PendingCoverageSession(upload: upload, state: state, updatedAtMs: nowMs)
            } else {
                snapshot.sessions.append(PendingCoverageSession(upload: upload, state: requestedState, updatedAtMs: nowMs))
            }
            try writeUnlocked(snapshot)
        }
    }

    func discard(sessionId: UUID) throws {
        try withLock {
            var snapshot = try readUnlocked()
            let originalCount = snapshot.sessions.count
            snapshot.sessions.removeAll { $0.upload.sessionId == sessionId }
            if snapshot.sessions.count != originalCount {
                try writeUnlocked(snapshot)
            }
        }
    }

    /// Au lancement suivant, une session restée "recording" provient d'une
    /// terminaison brutale. Elle devient envoyable avec le dernier point comme fin.
    /// Les brouillons de moins de deux points sont inutilisables par le backend.
    func recoverInterruptedRecordings() throws {
        try withLock {
            var snapshot = try readUnlocked()
            var didChange = false
            snapshot.sessions = snapshot.sessions.compactMap { pending in
                guard pending.state == .recording else { return pending }
                guard pending.upload.points.count >= 2, let last = pending.upload.points.last else {
                    didChange = true
                    return nil
                }
                var recovered = pending
                recovered.upload.endTime = max(recovered.upload.startTime, last.timestamp)
                recovered.state = .queued
                recovered.updatedAtMs = Self.nowMs()
                didChange = true
                return recovered
            }
            if didChange { try writeUnlocked(snapshot) }
        }
    }

    func pendingUploads() throws -> [CoverageSessionUpload] {
        try withLock {
            try readUnlocked().sessions
                .filter { $0.state == .queued }
                .sorted { $0.updatedAtMs < $1.updatedAtMs }
                .map(\.upload)
        }
    }

    func contains(sessionId: UUID) throws -> Bool {
        try withLock {
            try readUnlocked().sessions.contains { $0.upload.sessionId == sessionId }
        }
    }

    func allPending() throws -> [PendingCoverageSession] {
        try withLock { try readUnlocked().sessions }
    }

    private func readUnlocked() throws -> CoverageSessionQueueFile {
        guard fileManager.fileExists(atPath: fileURL.path) else { return CoverageSessionQueueFile() }
        return try decoder.decode(CoverageSessionQueueFile.self, from: Data(contentsOf: fileURL))
    }

    private func writeUnlocked(_ snapshot: CoverageSessionQueueFile) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if snapshot.sessions.isEmpty {
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
            return
        }
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: [.atomic])
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: fileURL.path
        )
    }

    private func withLock<T>(_ operation: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    private static func nowMs() -> Int {
        Int(Date().timeIntervalSince1970 * 1_000)
    }
}

/// Accès aux sessions/logs de mesure de l'utilisateur (synchronisées côté
/// serveur, donc visibles ici même si enregistrées sur Android).
protocol SessionsServicing: Sendable {
    /// `mapPoints` demande en plus le nuage de points allégé du compte : il
    /// remplace, pour les écrans cartographiques, l'appel au détail de chaque
    /// session (~5,5 Mo pièce, contre quatre champs utiles).
    func sessions(offset: Int, limit: Int, mapPoints: Bool) async throws -> SessionsListResponse
    func sessionDetail(id: String) async throws -> CoverageSessionDetail
    /// Écrit/remplace le brouillon atomique avant toute tentative réseau.
    func persistCoverageDraft(_ session: CoverageSessionUpload) throws
    /// Rend la session rejouable. Doit être appelé synchronement avant de lancer
    /// la tâche réseau afin qu'un kill entre stop() et l'upload ne perde rien.
    func finalizeCoverageDraft(_ session: CoverageSessionUpload) throws
    func discardCoverageDraft(sessionId: UUID) throws
    /// Téléverse une session finalisée, en la conservant si la requête échoue.
    func createCoverageSession(_ session: CoverageSessionUpload) async throws -> CoverageImportResponse?
    /// Reprend les brouillons interrompus et rejoue la file. Ne remonte pas l'erreur
    /// à l'appelant de cycle de vie : les éléments restent sur disque.
    func retryPendingCoverageSessions() async
}

/// Valeurs par défaut : une exigence de protocole ne peut pas en porter, et la
/// grande majorité des appelants ne veulent pas du nuage cartographique.
extension SessionsServicing {
    func sessions(offset: Int = 0, limit: Int = 30) async throws -> SessionsListResponse {
        try await sessions(offset: offset, limit: limit, mapPoints: false)
    }
}

final class SessionsService: SessionsServicing, @unchecked Sendable {
    private struct ImportResponseState {
        var awaitedIDs = Set<UUID>()
        var responses: [UUID: CoverageImportResponse] = [:]
    }
    private let api: APIClient
    private let queue: CoverageSessionStoring
    /// Coalesce les drains concurrents (lancement, retour écran, fin de session).
    private let flushState = OSAllocatedUnfairLock<Task<Void, Error>?>(initialState: nil)
    private let importResponseState = OSAllocatedUnfairLock<ImportResponseState>(initialState: .init())

    /// Visibilité interne pour verrouiller l'absence d'accumulation lors des
    /// retries de cycle de vie, qui n'attendent aucune réponse à afficher.
    var bufferedImportResponseCount: Int {
        importResponseState.withLock { $0.responses.count }
    }

    init(api: APIClient, queueFileURL: URL? = nil) {
        self.api = api
        // iOS 17+ : vraie base SwiftData ; iOS 16 (ou fileURL de test) : repli JSON durable.
        self.queue = CoverageSessionStoreFactory.make(fileURL: queueFileURL)
    }

    func persistCoverageDraft(_ session: CoverageSessionUpload) throws {
        LocalOfflineOwnership.claim(kind: "coverage", id: session.sessionId.uuidString)
        try queue.upsert(session, state: .recording)
    }

    func finalizeCoverageDraft(_ session: CoverageSessionUpload) throws {
        LocalOfflineOwnership.claim(kind: "coverage", id: session.sessionId.uuidString)
        try queue.upsert(session, state: .queued)
    }

    func discardCoverageDraft(sessionId: UUID) throws {
        try queue.discard(sessionId: sessionId)
        LocalOfflineOwnership.release(kind: "coverage", id: sessionId.uuidString)
    }

    func createCoverageSession(_ session: CoverageSessionUpload) async throws -> CoverageImportResponse? {
        _ = importResponseState.withLock { $0.awaitedIDs.insert(session.sessionId) }
        defer {
            importResponseState.withLock {
                $0.awaitedIDs.remove(session.sessionId)
                $0.responses.removeValue(forKey: session.sessionId)
            }
        }
        // Idempotent côté client : la même valeur remplace le brouillon, elle ne
        // crée jamais une seconde entrée locale.
        try finalizeCoverageDraft(session)
        do {
            try await flushPendingCoverageSessions()
            // F-07 : un flush déjà en vol (coalescé) a pu lire la file AVANT la
            // finalisation de cette session ; l'await se termine alors sans l'avoir
            // soumise. Si elle est toujours en file, on relance un flush DÉDIÉ pour
            // ne pas annoncer « Couverture envoyée » alors qu'elle n'est que mise en file.
            if (try? queue.contains(sessionId: session.sessionId)) == true {
                try await flushPendingCoverageSessions()
            }
            return importResponseState.withLock { $0.responses.removeValue(forKey: session.sessionId) }
        } catch {
            // Une autre entrée de la file peut avoir échoué après que celle demandée
            // a réussi. Dans ce cas, l'appel courant est bien un succès.
            if (try? queue.contains(sessionId: session.sessionId)) == false {
                return importResponseState.withLock { $0.responses.removeValue(forKey: session.sessionId) }
            }
            throw error
        }
    }

    func retryPendingCoverageSessions() async {
        do {
            try queue.recoverInterruptedRecordings()
            try await flushPendingCoverageSessions()
        } catch {
            // Intentionnel : le prochain lancement/retour sur Drive Test rejouera la
            // même session, avec le même UUID et la même Idempotency-Key.
        }
    }

    func sessions(offset: Int = 0, limit: Int = 30, mapPoints: Bool = false) async throws -> SessionsListResponse {
        var query = [
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        // Nuage de points allégé, pour les écrans qui dessinent une carte. Il
        // évite d'aller chercher le DÉTAIL de chaque session — 5,5 Mo pièce là
        // où la carte a besoin de quatre champs.
        if mapPoints { query.append(URLQueryItem(name: "mapPoints", value: "1")) }
        return try await api.request(
            APIEndpoint(path: "/api/coverage/sessions", query: query),
            as: SessionsListResponse.self
        )
    }

    func sessionDetail(id: String) async throws -> CoverageSessionDetail {
        try await api.request(
            APIEndpoint(
                path: "/api/coverage/sessions",
                query: [
                    URLQueryItem(name: "sessionId", value: id),
                    URLQueryItem(name: "withAntennas", value: "1")
                ]
            ),
            as: CoverageSessionDetail.self
        )
    }

    private func submit(_ session: CoverageSessionUpload) async throws {
        let response: CoverageImportResponse = try await api.requestJSON(
            "/api/coverage/session/import-ios",
            body: session,
            idempotencyKey: session.idempotencyKey
        )
        importResponseState.withLock {
            guard $0.awaitedIDs.contains(session.sessionId) else { return }
            $0.responses[session.sessionId] = response
        }
    }

    private func flushPendingCoverageSessions() async throws {
        let task: Task<Void, Error> = flushState.withLock { current in
            if let current { return current }
            let newTask = Task<Void, Error> { [weak self] in
                guard let self else { return }
                try await self.performFlush()
            }
            current = newTask
            return newTask
        }
        defer { flushState.withLock { $0 = nil } }
        try await task.value
    }

    private func performFlush() async throws {
        let pending = try queue.pendingUploads()
        var firstError: Error?
        for session in pending {
            guard LocalOfflineOwnership.belongsToCurrentScope(
                kind: "coverage",
                id: session.sessionId.uuidString
            ) else {
                // Entrée legacy sans propriétaire, ou autre compte : quarantaine.
                continue
            }
            do {
                try await submit(session)
                try queue.discard(sessionId: session.sessionId)
                LocalOfflineOwnership.release(kind: "coverage", id: session.sessionId.uuidString)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }
}

// MARK: - Abstraction du store de couverture (SwiftData iOS 17+ / repli JSON iOS 16)

/// File des sessions de couverture en attente d'envoi, abstraite pour offrir deux
/// implémentations derrière la MÊME API synchrone (appelée depuis les callbacks GPS,
/// où un point doit être persisté avant que l'UI poursuive) :
///
/// - **iOS 17+** : `SwiftDataCoverageSessionStore` (vraie base embarquée SwiftData) ;
/// - **iOS 16**  : repli `CoverageSessionQueue` (JSON durable en Application Support).
///
/// (Le code vit dans ce fichier — déjà référencé par le `.xcodeproj` committé — car la
/// CI Xcode Cloud ne régénère pas le projet via xcodegen.)
protocol CoverageSessionStoring: Sendable {
    func upsert(_ upload: CoverageSessionUpload, state requestedState: CoverageSessionQueueState) throws
    func discard(sessionId: UUID) throws
    func recoverInterruptedRecordings() throws
    func pendingUploads() throws -> [CoverageSessionUpload]
    func contains(sessionId: UUID) throws -> Bool
    func allPending() throws -> [PendingCoverageSession]
}

/// Fabrique le store de couverture : SwiftData si iOS 17+ ET l'initialisation réussit,
/// sinon repli JSON durable. Un `fileURL` explicite (tests) force le repli JSON pour
/// rester déterministe et indépendant de SwiftData.
enum CoverageSessionStoreFactory {
    static func make(fileURL: URL? = nil) -> CoverageSessionStoring {
        if fileURL == nil, #available(iOS 17, *) {
            if let store = SwiftDataCoverageSessionStore() {
                return store
            }
        }
        return CoverageSessionQueue(fileURL: fileURL)
    }
}

/// Entité SwiftData d'une session de couverture. La session `CoverageSessionUpload`
/// (points inclus) est stockée telle quelle en `payload` JSON : elle est toujours
/// lue/écrite d'un bloc, ce qui préserve exactement le contrat existant sans dupliquer
/// le schéma des points. `pointCount` est dénormalisé pour la garde anti-rétrécissement
/// sans décoder le payload.
@available(iOS 17, *)
@Model
final class CoverageSessionEntity {
    @Attribute(.unique) var sessionKey: String
    var stateRaw: String
    var updatedAtMs: Int
    var pointCount: Int
    var payload: Data

    init(sessionKey: String, stateRaw: String, updatedAtMs: Int, pointCount: Int, payload: Data) {
        self.sessionKey = sessionKey
        self.stateRaw = stateRaw
        self.updatedAtMs = updatedAtMs
        self.pointCount = pointCount
        self.payload = payload
    }
}

/// Store de couverture adossé à SwiftData. Réplique fidèlement la logique de
/// `CoverageSessionQueue` (garde anti-rétrécissement, reprise après crash, tri par
/// ancienneté, idempotence par `sessionId`).
///
/// Concurrence : l'API du protocole est SYNCHRONE (callbacks GPS). SwiftData n'étant pas
/// thread-safe, on sérialise chaque opération avec un `NSLock` et on crée un `ModelContext`
/// FRAIS par opération (même `ModelContainer`, donc données committées visibles ; aucun
/// contexte partagé entre threads). ⚠️ À valider en compilation/exécution Xcode
/// (indisponible dans l'environnement Linux de développement de cette session).
@available(iOS 17, *)
final class SwiftDataCoverageSessionStore: CoverageSessionStoring, @unchecked Sendable {
    private let container: ModelContainer
    private let lock = NSLock()
    private let encoder = JSONEncoder.signalQuest
    private let decoder = JSONDecoder.signalQuest

    /// `init?` : si le `ModelContainer` ne peut pas être créé, la fabrique retombe sur JSON.
    init?(storeURL: URL? = nil, legacyFileURL: URL? = nil) {
        let fileManager = FileManager.default
        let resolvedStoreURL: URL
        if let storeURL {
            resolvedStoreURL = storeURL
        } else {
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            let dir = appSupport.appendingPathComponent("SignalQuest", isDirectory: true)
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            resolvedStoreURL = dir.appendingPathComponent("CoverageSessions.store", isDirectory: false)
        }
        do {
            let configuration = ModelConfiguration(url: resolvedStoreURL)
            container = try ModelContainer(for: CoverageSessionEntity.self, configurations: configuration)
        } catch {
            return nil
        }
        migrateLegacyJSONIfNeeded(explicitURL: legacyFileURL)
    }

    func upsert(_ upload: CoverageSessionUpload, state requestedState: CoverageSessionQueueState) throws {
        try withLock {
            let context = ModelContext(container)
            let key = upload.sessionId.uuidString
            let existing = try context.fetch(Self.descriptor(forKey: key)).first
            let payload = try encoder.encode(upload)
            let now = Self.nowMs()
            if let existing {
                guard upload.points.count >= existing.pointCount else { return }
                let state: CoverageSessionQueueState = existing.stateRaw == CoverageSessionQueueState.queued.rawValue ? .queued : requestedState
                existing.stateRaw = state.rawValue
                existing.updatedAtMs = now
                existing.pointCount = upload.points.count
                existing.payload = payload
            } else {
                context.insert(CoverageSessionEntity(
                    sessionKey: key,
                    stateRaw: requestedState.rawValue,
                    updatedAtMs: now,
                    pointCount: upload.points.count,
                    payload: payload
                ))
            }
            try context.save()
        }
    }

    func discard(sessionId: UUID) throws {
        try withLock {
            let context = ModelContext(container)
            let key = sessionId.uuidString
            for entity in try context.fetch(Self.descriptor(forKey: key)) {
                context.delete(entity)
            }
            try context.save()
        }
    }

    func recoverInterruptedRecordings() throws {
        try withLock {
            let context = ModelContext(container)
            let recordingRaw = CoverageSessionQueueState.recording.rawValue
            let descriptor = FetchDescriptor<CoverageSessionEntity>(
                predicate: #Predicate { $0.stateRaw == recordingRaw }
            )
            var didChange = false
            for entity in try context.fetch(descriptor) {
                guard let upload = try? decoder.decode(CoverageSessionUpload.self, from: entity.payload) else { continue }
                guard upload.points.count >= 2, let last = upload.points.last else {
                    context.delete(entity)
                    didChange = true
                    continue
                }
                var recovered = upload
                recovered.endTime = max(recovered.startTime, last.timestamp)
                if let data = try? encoder.encode(recovered) { entity.payload = data }
                entity.stateRaw = CoverageSessionQueueState.queued.rawValue
                entity.updatedAtMs = Self.nowMs()
                didChange = true
            }
            if didChange { try context.save() }
        }
    }

    func pendingUploads() throws -> [CoverageSessionUpload] {
        try withLock {
            let context = ModelContext(container)
            let queuedRaw = CoverageSessionQueueState.queued.rawValue
            var descriptor = FetchDescriptor<CoverageSessionEntity>(
                predicate: #Predicate { $0.stateRaw == queuedRaw }
            )
            descriptor.sortBy = [SortDescriptor(\CoverageSessionEntity.updatedAtMs, order: .forward)]
            return try context.fetch(descriptor).compactMap { entity in
                try? decoder.decode(CoverageSessionUpload.self, from: entity.payload)
            }
        }
    }

    func contains(sessionId: UUID) throws -> Bool {
        try withLock {
            let context = ModelContext(container)
            let key = sessionId.uuidString
            return try context.fetchCount(Self.descriptor(forKey: key)) > 0
        }
    }

    func allPending() throws -> [PendingCoverageSession] {
        try withLock {
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<CoverageSessionEntity>()
            return try context.fetch(descriptor).compactMap { entity -> PendingCoverageSession? in
                guard let upload = try? decoder.decode(CoverageSessionUpload.self, from: entity.payload),
                      let state = CoverageSessionQueueState(rawValue: entity.stateRaw) else { return nil }
                return PendingCoverageSession(upload: upload, state: state, updatedAtMs: entity.updatedAtMs)
            }
        }
    }

    private static func descriptor(forKey key: String) -> FetchDescriptor<CoverageSessionEntity> {
        FetchDescriptor<CoverageSessionEntity>(predicate: #Predicate { $0.sessionKey == key })
    }

    private func withLock<T>(_ operation: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    /// Import unique de l'ancienne file JSON (`PendingCoverageSessions.json`) vers
    /// SwiftData, puis renommage du fichier legacy pour ne pas ré-importer. Non
    /// destructif : n'écrase pas une session déjà présente en base.
    private func migrateLegacyJSONIfNeeded(explicitURL: URL?) {
        let fileManager = FileManager.default
        let legacyURL: URL
        if let explicitURL {
            legacyURL = explicitURL
        } else {
            guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
            legacyURL = appSupport
                .appendingPathComponent("SignalQuest", isDirectory: true)
                .appendingPathComponent("PendingCoverageSessions.json", isDirectory: false)
        }
        guard fileManager.fileExists(atPath: legacyURL.path),
              let data = try? Data(contentsOf: legacyURL),
              let file = try? decoder.decode(CoverageSessionQueueFile.self, from: data),
              !file.sessions.isEmpty else { return }
        do {
            try withLock {
                let context = ModelContext(container)
                for pending in file.sessions {
                    let key = pending.upload.sessionId.uuidString
                    let already = (try? context.fetchCount(Self.descriptor(forKey: key))) ?? 0
                    guard already == 0, let payload = try? encoder.encode(pending.upload) else { continue }
                    context.insert(CoverageSessionEntity(
                        sessionKey: key,
                        stateRaw: pending.state.rawValue,
                        updatedAtMs: pending.updatedAtMs,
                        pointCount: pending.upload.points.count,
                        payload: payload
                    ))
                }
                try context.save()
            }
            let backupURL = legacyURL.appendingPathExtension("migrated")
            try? fileManager.removeItem(at: backupURL)
            try? fileManager.moveItem(at: legacyURL, to: backupURL)
        } catch {
            // Échec → on garde le JSON legacy intact (réessayé au prochain lancement).
        }
    }

    private static func nowMs() -> Int { Int(Date().timeIntervalSince1970 * 1_000) }
}
