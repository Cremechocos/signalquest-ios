import Foundation
import os

/// Un point de couverture contribué par iOS (F1). PAS de signal radio (iOS ne
/// l'expose pas) : seulement génération (`technology`) + connectivité + position,
/// et débit/latence aux points testés.
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
    var downloadMbps: Double? = nil
    var uploadMbps: Double? = nil
    var pingMs: Double? = nil

    init(
        localId: UUID = UUID(),
        latitude: Double,
        longitude: Double,
        timestamp: Int,
        technology: String,
        downloadMbps: Double? = nil,
        uploadMbps: Double? = nil,
        pingMs: Double? = nil
    ) {
        self.localId = localId
        self.latitude = latitude
        self.longitude = longitude
        self.timestamp = timestamp
        self.technology = technology
        self.downloadMbps = downloadMbps
        self.uploadMbps = uploadMbps
        self.pingMs = pingMs
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
    var operatorKey: String? = nil
    var marketCode: String? = nil
    var showOnMap: Bool
    var points: [CoveragePointUpload]

    var idempotencyKey: String {
        "coverage-ios-\(sessionId.uuidString.lowercased())"
    }
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

private struct CoverageSessionQueueFile: Codable, Sendable {
    var version = 1
    var sessions: [PendingCoverageSession] = []
}

/// File durable située dans Application Support (et non Caches, qui peut être
/// purgé par iOS). Chaque mutation est encodée puis remplacée atomiquement.
/// Le verrou rend les écritures synchrones sûres depuis les callbacks GPS et
/// garantit qu'un point est sur disque avant que l'UI poursuive son traitement.
final class CoverageSessionQueue: @unchecked Sendable {
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
    func sessions(offset: Int, limit: Int) async throws -> SessionsListResponse
    func sessionDetail(id: String) async throws -> CoverageSessionDetail
    /// Écrit/remplace le brouillon atomique avant toute tentative réseau.
    func persistCoverageDraft(_ session: CoverageSessionUpload) throws
    /// Rend la session rejouable. Doit être appelé synchronement avant de lancer
    /// la tâche réseau afin qu'un kill entre stop() et l'upload ne perde rien.
    func finalizeCoverageDraft(_ session: CoverageSessionUpload) throws
    func discardCoverageDraft(sessionId: UUID) throws
    /// Téléverse une session finalisée, en la conservant si la requête échoue.
    func createCoverageSession(_ session: CoverageSessionUpload) async throws
    /// Reprend les brouillons interrompus et rejoue la file. Ne remonte pas l'erreur
    /// à l'appelant de cycle de vie : les éléments restent sur disque.
    func retryPendingCoverageSessions() async
}

final class SessionsService: SessionsServicing, @unchecked Sendable {
    private let api: APIClient
    private let queue: CoverageSessionQueue
    /// Coalesce les drains concurrents (lancement, retour écran, fin de session).
    private let flushState = OSAllocatedUnfairLock<Task<Void, Error>?>(initialState: nil)

    init(api: APIClient, queueFileURL: URL? = nil) {
        self.api = api
        self.queue = CoverageSessionQueue(fileURL: queueFileURL)
    }

    func persistCoverageDraft(_ session: CoverageSessionUpload) throws {
        try queue.upsert(session, state: .recording)
    }

    func finalizeCoverageDraft(_ session: CoverageSessionUpload) throws {
        try queue.upsert(session, state: .queued)
    }

    func discardCoverageDraft(sessionId: UUID) throws {
        try queue.discard(sessionId: sessionId)
    }

    func createCoverageSession(_ session: CoverageSessionUpload) async throws {
        // Idempotent côté client : la même valeur remplace le brouillon, elle ne
        // crée jamais une seconde entrée locale.
        try finalizeCoverageDraft(session)
        do {
            try await flushPendingCoverageSessions()
        } catch {
            // Une autre entrée de la file peut avoir échoué après que celle demandée
            // a réussi. Dans ce cas, l'appel courant est bien un succès.
            if (try? queue.contains(sessionId: session.sessionId)) == false { return }
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

    func sessions(offset: Int = 0, limit: Int = 30) async throws -> SessionsListResponse {
        try await api.request(
            APIEndpoint(
                path: "/api/coverage/sessions",
                query: [
                    URLQueryItem(name: "offset", value: String(offset)),
                    URLQueryItem(name: "limit", value: String(limit))
                ]
            ),
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
        let _: SuccessResponse = try await api.requestJSON(
            "/api/coverage/session/import-ios",
            body: session,
            idempotencyKey: session.idempotencyKey
        )
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
            do {
                try await submit(session)
                try queue.discard(sessionId: session.sessionId)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }
}
