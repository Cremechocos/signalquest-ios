import Foundation
import os

/// Journal radio du compte : lecture incrémentale, balayage du catalogue, et
/// résolution d'une hypothèse de site à la demande.
///
/// iOS est en LECTURE SEULE sur ce journal : il ne pousse jamais (`push` reste
/// l'affaire d'Android, qui capte). Il lit, il agrège en sites, il demande au
/// serveur lesquels sont déjà identifiés — et il n'attribue rien de lui-même.
protocol RadioLogsServicing: Sendable {
    /// Instantané local, sans réseau (affichage immédiat à l'ouverture).
    func cachedSnapshot() -> RadioLogSnapshot
    /// Rattrape le journal depuis la position du curseur local. Émet un instantané
    /// à chaque page pour que la liste se remplisse au fil de l'eau.
    func syncStream() -> AsyncStream<RadioLogSyncProgress>
    /// Statuts d'identification encore FRAIS, sans réseau.
    func cachedSiteStates() -> [String: RadioLogSiteState]
    /// Persiste une identification faite par l'utilisateur, pour qu'elle survive au retour sur
    /// l'écran — le balayage n'en sait rien tant qu'il n'a pas retourné ce site.
    func markIdentified(siteKey: String, siteId: String)
    /// Balaie le catalogue par fenêtres, en émettant chaque fenêtre résolue.
    func scanStream(sites: [RadioLogSite]) -> AsyncStream<[String: RadioLogSiteState]>
    /// Hypothèse de site pour UN site non identifié — charge complète, position
    /// comprise. Coûteuse : réservée à l'écran où l'on regarde un site à la fois.
    func hypothesis(for site: RadioLogSite) async -> RadioLogSiteHypothesis?
    /// Purge serveur du journal. Jamais gatée côté serveur : révoquer son
    /// consentement doit toujours aboutir.
    func purge() async throws
    /// Efface le cache local (journal + statuts).
    func clearLocalCache()
}

/// Avancement d'un rattrapage.
struct RadioLogSyncProgress: Sendable {
    let snapshot: RadioLogSnapshot
    /// Lignes reçues depuis le début du rattrapage (recouvrements compris).
    let received: Int
    let hasMore: Bool
    let readOnly: Bool
    /// Renseigné sur le DERNIER événement quand le rattrapage s'est interrompu.
    /// Un flux qui se termine sans rien dire laisserait l'écran afficher un
    /// journal tronqué comme s'il était complet.
    let failure: RadioLogSyncFailure?

    init(
        snapshot: RadioLogSnapshot,
        received: Int,
        hasMore: Bool,
        readOnly: Bool,
        failure: RadioLogSyncFailure? = nil
    ) {
        self.snapshot = snapshot
        self.received = received
        self.hasMore = hasMore
        self.readOnly = readOnly
        self.failure = failure
    }
}

/// Cause d'interruption d'un rattrapage, à présenter différemment à l'écran.
enum RadioLogSyncFailure: Sendable, Equatable {
    /// Refus de DROIT (403) : la sauvegarde cloud est réservée au Premium. Ce
    /// n'est pas un incident, et l'afficher comme tel serait mensonger.
    case premiumRequired(String)
    case network(String)
}

final class RadioLogsService: RadioLogsServicing, @unchecked Sendable {
    private let api: APIClient
    private let store: RadioLogStoring
    private let statusStore: RadioLogSiteStatusStoring
    private let logger = Logger(subsystem: "fr.signalquest.ios", category: "RadioLogs")

    /// Taille de page du `pull`. Le serveur plafonne à 1 000 ; on prend le maximum
    /// parce que le rattrapage initial porte sur des dizaines de milliers de lignes.
    private let pullLimit = 1000
    /// Sites par fenêtre du balayage. La route plafonne à 200 : 150 laisse la marge
    /// qu'Android s'est donnée après avoir pris des 413 en pleine passe.
    private let scanWindow = 150
    /// Fenêtres de balayage en vol. Trois : chacune coûte cher au serveur, qui y
    /// rejoue la résolution item par item.
    private let scanWindowsInFlight = 3
    /// Fraîcheur du cache de statut — DISSYMÉTRIQUE, parce que les deux verdicts
    /// ne vieillissent pas pareil.
    ///
    /// Un site IDENTIFIÉ ne redevient pas inconnu : sa validation reste en base.
    /// Le revérifier n'apprend rien, et sur un catalogue de 5 700 sites c'est une
    /// quarantaine de requêtes pour confirmer ce qu'on savait. Sept jours.
    ///
    /// Un site NON identifié, lui, peut devenir identifié à tout moment —
    /// quelqu'un d'autre le fait, ou soi-même depuis un autre appareil. Vingt-
    /// quatre heures, pour que l'information arrive sans marteler le serveur.
    ///
    /// Avant : trente minutes pour les deux, donc un balayage COMPLET à chaque
    /// ouverture passé ce délai. C'est ce que l'utilisateur ressentait.
    private let identifiedTtlMs = 7 * 24 * 60 * 60 * 1000
    private let unidentifiedTtlMs = 24 * 60 * 60 * 1000

    /// Recul appliqué au curseur STOCKÉ avant de reprendre un rattrapage. Il
    /// s'ajoute à celui du serveur : un rattrapage repris des jours plus tard ne
    /// doit pas manquer une ligne committée hors ordre juste après le dernier
    /// passage. Le surcoût est nul, l'application étant idempotente.
    private let resumeRewind: TimeInterval = 60

    init(
        api: APIClient,
        store: RadioLogStoring = RadioLogStore(),
        statusStore: RadioLogSiteStatusStoring = RadioLogSiteStatusStore()
    ) {
        self.api = api
        self.store = store
        self.statusStore = statusStore
    }

    private func nowMs() -> Int { Int(Date().timeIntervalSince1970 * 1000) }

    // MARK: - Lecture incrémentale

    func cachedSnapshot() -> RadioLogSnapshot { store.load() }

    func syncStream() -> AsyncStream<RadioLogSyncProgress> {
        AsyncStream { continuation in
            let task = Task { [weak self] in
                guard let self else { continuation.finish(); return }
                await self.runSync(emitting: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Rattrapage complet.
    ///
    /// Les pages sont appliquées EN MÉMOIRE et diffusées au fil de l'eau — la
    /// liste se remplit pendant le rattrapage — mais le disque n'est écrit
    /// qu'une fois, à la fin. Le journal du compte de test pèse ~2 Mo : écrire à
    /// chaque page, c'est seize décodages et seize encodages de 2 Mo pour un
    /// seul rattrapage, payés pendant que l'utilisateur regarde l'écran.
    private func runSync(emitting continuation: AsyncStream<RadioLogSyncProgress>.Continuation) async {
        let initial = store.load()
        var cursor = initial.cursor.map {
            // Recul de reprise : on repart un peu avant la dernière position connue.
            RadioLogCursor(sinceAt: $0.sinceAt.addingTimeInterval(-resumeRewind), sinceId: $0.sinceId)
        }
        var entries = initial.entries
        var incoming: [RadioLogEntry] = []
        var lastCursor = initial.cursor
        var seenKeys = Set<String>()
        var received = 0
        var readOnly = false
        var completed = false
        var failure: RadioLogSyncFailure?

        while !Task.isCancelled {
            let page: RadioLogPullPage
            do {
                page = try await pull(cursor: cursor)
            } catch {
                if error.isCancellation { break }
                logger.error("pull échoué: \(error.localizedDescription, privacy: .public)")
                if case let RadioLogSyncError.premiumRequired(message) = error {
                    failure = .premiumRequired(message)
                } else {
                    failure = .network(error.localizedDescription)
                }
                break
            }

            readOnly = page.readOnly
            received += page.items.count
            incoming.append(contentsOf: page.items)
            entries = RadioLogStore.applying(incoming: page.items, to: entries)
            if let next = page.nextCursor { lastCursor = next }

            // Progression réelle : combien de lignes de cette page n'avaient pas
            // déjà été vues DANS CE RATTRAPAGE. Le serveur utilise un keyset strict ;
            // l'absence totale de nouveauté signale donc un curseur bloqué.
            let freshCount = page.items.reduce(into: 0) { count, entry in
                if seenKeys.insert(entry.dedupeKey).inserted { count += 1 }
            }

            continuation.yield(
                RadioLogSyncProgress(
                    snapshot: RadioLogSnapshot(entries: entries, cursor: lastCursor, lastSyncedAtMs: initial.lastSyncedAtMs),
                    received: received,
                    hasMore: page.hasMore,
                    readOnly: readOnly
                )
            )

            guard page.hasMore else {
                completed = true
                break
            }

            guard let next = page.nextCursor else {
                logger.error("pagination sans curseur suivant — rattrapage interrompu")
                failure = .network(String(localized: "Le serveur a renvoyé une pagination incomplète : synchronisation interrompue."))
                break
            }

            if freshCount == 0 || next == cursor {
                logger.error("curseur bloqué — rattrapage interrompu")
                failure = .network(String(localized: "Le serveur renvoie toujours les mêmes relevés : synchronisation incomplète."))
                break
            }
            cursor = next
        }

        // Écriture UNIQUE. Y compris après un échec en cours de route : les pages
        // déjà reçues sont bonnes, les jeter obligerait à tout retélécharger au
        // prochain essai.
        guard !incoming.isEmpty || failure != nil || completed else { return }
        let snapshot = store.merge(
            incoming: incoming,
            cursor: lastCursor,
            nowMs: nowMs(),
            markSynced: completed
        )
        continuation.yield(
            RadioLogSyncProgress(
                snapshot: snapshot,
                received: received,
                hasMore: false,
                readOnly: readOnly,
                failure: failure
            )
        )
    }

    /// Une page du journal.
    ///
    /// La pagination est strictement keysetée par `(updatedAt, id)`. Le curseur
    /// est donc transmis tel quel : aucune compensation temporelle locale ne
    /// doit pouvoir créer un trou entre deux pages.
    private func pull(cursor: RadioLogCursor?) async throws -> RadioLogPullPage {
        var query = [URLQueryItem(name: "limit", value: String(pullLimit))]
        if let cursor {
            query.append(URLQueryItem(name: "sinceAt", value: cursor.sinceAtParameter))
            query.append(URLQueryItem(name: "sinceId", value: cursor.sinceId))
        }
        do {
            return try await api.request(
                APIEndpoint(path: "/api/android/radio-logs/pull", query: query),
                as: RadioLogPullPage.self
            )
        } catch let APIError.http(status, code, message, _, _) where status == 403 {
            // Refus de DROIT, pas incident réseau : la page doit le dire autrement.
            throw RadioLogSyncError.premiumRequired(
                APIError.userFacingMessage(status: status, code: code, serverMessage: message)
            )
        }
    }

    func purge() async throws {
        try await api.request(APIEndpoint(path: "/api/android/radio-logs/all", method: .delete))
        clearLocalCache()
    }

    func clearLocalCache() {
        store.clear()
        statusStore.clear()
    }

    // MARK: - Balayage du catalogue

    func cachedSiteStates() -> [String: RadioLogSiteState] {
        statusStore.fresh(
            identifiedTtlMs: identifiedTtlMs,
            unidentifiedTtlMs: unidentifiedTtlMs,
            nowMs: nowMs()
        )
    }

    /// Inscrit une identification que L'UTILISATEUR vient de faire.
    ///
    /// Sans cela, le statut ne vivait qu'en mémoire : le magasin n'était alimenté que par le
    /// balayage, donc la liste réaffichait « Non identifié » dès qu'elle relisait le cache —
    /// au retour sur l'écran, au rafraîchissement, au redémarrage. L'utilisateur voyait son
    /// travail disparaître alors que le serveur l'avait bien accepté.
    ///
    /// On n'attend pas la confirmation d'un balayage : l'écriture serveur a déjà réussi (on
    /// tient son `siteId`), et le prochain scan ne ferait que reconfirmer ce qu'on sait.
    func markIdentified(siteKey: String, siteId: String) {
        statusStore.merge([siteKey: .identified(siteId: siteId)], nowMs: nowMs())
    }

    /// Balaie les sites par fenêtres concurrentes bornées.
    ///
    /// CHARGE MINIMALE, volontairement : opérateur, PLMN, eNB/gNB, techno, bande.
    /// Ni PCI, ni cellId, ni position. Android l'a mesuré sur 150 sites réels — le
    /// PCI et le cellId ne changent rien (10 trouvés dans les trois cas), la
    /// position fait passer à 141 mais en `resolutionMode: proximity`, c'est-à-dire
    /// des hypothèses de voisinage, pour 3,7× le temps. La question posée ici est
    /// « ce site est-il déjà identifié ? » : une hypothèse n'y répond pas.
    func scanStream(sites: [RadioLogSite]) -> AsyncStream<[String: RadioLogSiteState]> {
        AsyncStream { continuation in
            let task = Task { [weak self] in
                guard let self else { continuation.finish(); return }
                let windows = sites.chunked(into: self.scanWindow)
                await withTaskGroup(of: [String: RadioLogSiteState].self) { group in
                    var iterator = windows.makeIterator()
                    var inFlight = 0
                    for _ in 0..<self.scanWindowsInFlight {
                        guard let window = iterator.next() else { break }
                        group.addTask { await self.scanWindow(window) }
                        inFlight += 1
                    }
                    while inFlight > 0, let resolved = await group.next() {
                        inFlight -= 1
                        if Task.isCancelled { break }
                        if !resolved.isEmpty {
                            self.statusStore.merge(resolved, nowMs: self.nowMs())
                            continuation.yield(resolved)
                        }
                        if let window = iterator.next() {
                            group.addTask { await self.scanWindow(window) }
                            inFlight += 1
                        }
                    }
                    group.cancelAll()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func scanWindow(_ window: [RadioLogSite]) async -> [String: RadioLogSiteState] {
        let items = window.map { site in
            QuickIdentifyBatchItem(
                id: site.id,
                operator: site.operatorName,
                market: RadioLogOperatorResolver.marketCode(forOperator: site.operatorName, mcc: site.mcc),
                mcc: site.mcc,
                mnc: site.mnc,
                enb: site.kind == .enb ? site.node : nil,
                gnb: site.kind == .gnb ? site.node : nil,
                pci: nil, cellId: nil, ci: nil, lat: nil, lng: nil,
                band: site.band,
                earfcn: site.earfcn,
                tech: site.techLabel
            )
        }
        do {
            let response: QuickIdentifyBatchResponse = try await api.requestJSON(
                "/api/android/map/identify/quick/batch",
                method: .post,
                body: QuickIdentifyBatchRequest(items: items)
            )
            let byId = Dictionary(
                response.results.compactMap { result -> (String, QuickIdentifyBatchResult)? in
                    guard let id = result.id else { return nil }
                    return (id, result)
                },
                uniquingKeysWith: { first, _ in first }
            )
            // Un statut pour CHAQUE site demandé, non trouvés compris. Ne rien
            // rendre pour un site le laisserait « jamais vérifié » et le ferait
            // revenir à la passe suivante, indéfiniment.
            return window.reduce(into: [:]) { states, site in
                states[site.id] = Self.state(from: byId[site.id]?.result, site: site)
            }
        } catch {
            // Fenêtre en échec : on n'écrit RIEN plutôt qu'un « non identifié »
            // qui serait un mensonge. Ces sites repasseront au balayage suivant.
            if !error.isCancellation {
                logger.error("fenêtre de balayage échouée: \(error.localizedDescription, privacy: .public)")
            }
            return [:]
        }
    }

    /// Un seul critère : le nœud eNB/gNB est-il connu du serveur ?
    ///
    /// La réponse est dans `matchedRadio`, et NULLE PART AILLEURS. Quand le
    /// serveur y liste le type de nœud qu'on a envoyé, c'est qu'il l'a retrouvé
    /// dans ses validations : le nœud est connu, point.
    ///
    /// ⚠️ NE PAS se fier à `requiresUserConfirmation` ni à `resolutionMode` pour
    /// trancher cette question — ils répondent à une AUTRE : « sait-on à quel
    /// site rattacher ce nœud ? ». Mesuré sur un journal réel, 35 sites sur 150
    /// reviennent en `resolutionMode: "shared_operator"`,
    /// `requiresUserConfirmation: true`, `source: "fr_validations"` — ET avec
    /// leur eNB dans `matchedRadio`. Ce sont des sites MUTUALISÉS : le nœud est
    /// parfaitement connu, c'est l'opérateur propriétaire qui demande
    /// confirmation. Les rejeter affichait « Non identifié » sur 23 % du
    /// catalogue à tort.
    ///
    /// Ces deux champs restent utiles pour le cas où le serveur ne détaille
    /// AUCUNE correspondance : là, `found: true` peut venir d'un simple repli
    /// géographique, et l'accepter ferait dire « Identifié » à « il y a une
    /// antenne dans le coin ».
    static func state(from resolution: QuickIdentifyResolution?, site: RadioLogSite) -> RadioLogSiteState {
        guard let resolution, resolution.found == true else { return .unidentified }
        guard let siteId = resolution.canonicalSiteId ?? resolution.siteId, !siteId.isEmpty else {
            return .unidentified
        }

        let matched = resolution.matchedTypes
        if matched.contains(site.kind == .enb ? "enb" : "gnb") {
            return .identified(siteId: siteId)
        }
        // D'autres identifiants correspondent (PCI, cellId) mais pas le nœud :
        // l'unité de la page est le SITE, une cellule ne l'identifie pas.
        if !matched.isEmpty { return .unidentified }

        // Aucune correspondance détaillée. On accepte — parité Android, et le
        // balayage n'envoie aucune position — SAUF si le serveur annonce
        // lui-même une résolution géographique ou à confirmer.
        if resolution.requiresUserConfirmation == true { return .unidentified }
        if let mode = resolution.resolutionMode?.lowercased(), mode.contains("proximity") {
            return .unidentified
        }
        return .identified(siteId: siteId)
    }

    // MARK: - Hypothèse (charge complète, un site à la fois)

    func hypothesis(for site: RadioLogSite) async -> RadioLogSiteHypothesis? {
        guard let latitude = site.latitude, let longitude = site.longitude else { return nil }
        var query: [URLQueryItem] = [
            URLQueryItem(name: "operator", value: site.operatorName ?? "ALL"),
            URLQueryItem(name: "market", value: RadioLogOperatorResolver.marketCode(forOperator: site.operatorName, mcc: site.mcc) ?? "FR"),
            URLQueryItem(name: "lat", value: String(latitude)),
            URLQueryItem(name: "lng", value: String(longitude)),
            URLQueryItem(name: "tech", value: site.techLabel)
        ]
        if let mcc = site.mcc { query.append(URLQueryItem(name: "mcc", value: mcc)) }
        if let mnc = site.mnc { query.append(URLQueryItem(name: "mnc", value: mnc)) }
        switch site.kind {
        case .enb: query.append(URLQueryItem(name: "enb", value: site.node))
        case .gnb: query.append(URLQueryItem(name: "gnb", value: site.node))
        }
        if let band = site.band { query.append(URLQueryItem(name: "band", value: String(band))) }
        if let earfcn = site.earfcn { query.append(URLQueryItem(name: "earfcn", value: String(earfcn))) }
        // Le PCI de la première cellule aide le serveur à dériver le secteur.
        if let pci = site.cells.compactMap(\.pci).first {
            query.append(URLQueryItem(name: "pci", value: String(pci)))
        }

        guard let resolution = try? await api.request(
            APIEndpoint(path: "/api/android/map/identify/quick", query: query),
            as: QuickIdentifyResolution.self
        ) else { return nil }

        guard let payload = resolution.hypothesis,
              let siteId = payload.canonicalSiteId ?? payload.siteId ?? resolution.canonicalSiteId ?? resolution.siteId,
              !siteId.isEmpty
        else { return nil }

        return RadioLogSiteHypothesis(
            siteId: siteId,
            latitude: payload.latitude,
            longitude: payload.longitude,
            confidenceScore: payload.confidenceScore,
            distanceMeters: (payload.distanceMeters ?? resolution.distanceMeters).map { Int($0.rounded()) },
            sector: payload.sector,
            resolutionMode: resolution.resolutionMode ?? resolution.source
        )
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
