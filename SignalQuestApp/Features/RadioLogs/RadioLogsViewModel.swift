import Foundation
import SwiftUI

@MainActor
final class RadioLogsViewModel: ObservableObject {

    // MARK: Réglages de la page

    /// Ce que la liste affiche. Le critère est UNIQUE : l'eNB/gNB est-il connu
    /// du serveur ? Pas de troisième catégorie — une hypothèse de voisinage n'est
    /// pas une identification, et n'a sa place que là où l'on regarde un site.
    enum Filter: String, CaseIterable, Identifiable {
        case all, identified, unidentified
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return String(localized: "Tous")
            case .identified: return String(localized: "Identifiés")
            case .unidentified: return String(localized: "Non identifiés")
            }
        }
    }

    /// Le tri devient un réglage de premier plan, plus un comportement figé —
    /// et chaque option dit ce qu'elle FAIT, pas seulement son nom.
    enum SortOrder: String, CaseIterable, Identifiable {
        case relevance, recency, identifier
        var id: String { rawValue }
        var label: String {
            switch self {
            case .relevance: return String(localized: "Pertinence")
            case .recency: return String(localized: "Récence")
            case .identifier: return String(localized: "Identifiant")
            }
        }
        var hint: String {
            switch self {
            case .relevance: return String(localized: "les plus relevés d'abord")
            case .recency: return String(localized: "vus en dernier")
            case .identifier: return String(localized: "eNB croissant")
            }
        }
    }

    // MARK: État publié

    @Published private(set) var sites: [RadioLogSite] = []
    @Published private(set) var states: [String: RadioLogSiteState] = [:]
    /// Commune et adresse des sites identifiés, chargées à la demande.
    @Published private(set) var siteNames: [String: String] = [:]
    @Published private(set) var logCount = 0
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var isSyncing = false
    @Published private(set) var syncReceived = 0
    @Published private(set) var isScanning = false
    @Published private(set) var readOnly = false
    @Published var errorMessage: String?
    @Published var premiumMessage: String?
    @Published var toast: String?

    @Published var filter: Filter = .all { didSet { rebuild() } }
    @Published var sortOrder: SortOrder = .relevance { didSet { rebuild() } }
    @Published var groupByOperator = true { didSet { rebuild() } }
    /// Le balayage n'a lieu que si le réseau le permet. Le refuser en données
    /// mobiles n'est pas cosmétique : une passe complète, c'est une trentaine de
    /// requêtes qui rejouent la résolution côté serveur.
    @Published var scanOnCellular = true
    @Published var searchText = "" { didSet { rebuild() } }
    @Published var expandedSiteId: String?

    // MARK: Vues dérivées, CALCULÉES UNE FOIS
    //
    // Le tri et le regroupement portent sur plusieurs milliers de sites. En
    // propriétés calculées, ils repartaient à chaque évaluation du `body` — donc
    // à chaque fenêtre de balayage, à chaque frappe, à chaque page de
    // synchronisation, et plusieurs fois par passe (la liste ET son état vide
    // les lisent). On les recalcule sur changement d'entrée, pas sur rendu.

    @Published private(set) var sections: [Section] = []
    @Published private(set) var filteredCount = 0
    @Published private(set) var identifiedCount = 0
    @Published private(set) var unidentifiedCount = 0
    @Published private(set) var checkedCount = 0

    // MARK: Dépendances

    private let service: RadioLogsServicing
    private let antennas: AntennasServicing
    private let networkPath: NetworkPathMonitor
    private var syncTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var nameTasks: Set<String> = []

    init(service: RadioLogsServicing, antennas: AntennasServicing, networkPath: NetworkPathMonitor) {
        self.service = service
        self.antennas = antennas
        self.networkPath = networkPath
    }

    deinit {
        syncTask?.cancel()
        scanTask?.cancel()
    }

    // MARK: Dérivés

    /// Sections affichées : une par opérateur, ou une seule section anonyme.
    struct Section: Identifiable {
        let id: String
        let operatorName: String?
        let sites: [RadioLogSite]
        let logCount: Int
    }

    /// Recalcule tout ce que la vue lit. Appelé quand une ENTRÉE change (sites,
    /// statuts, filtre, tri, regroupement, recherche) — jamais pendant un rendu.
    private func rebuild() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        var identified = 0
        var unidentified = 0
        var checked = 0
        var visible: [RadioLogSite] = []
        visible.reserveCapacity(sites.count)

        // Une SEULE passe pour les compteurs du catalogue entier et le filtrage :
        // trois `filter` séparés relisaient quatre fois les mêmes milliers de sites.
        for site in sites {
            let state = states[site.id] ?? .unchecked
            if state.isIdentified { identified += 1 }
            if state.isUnidentified { unidentified += 1 }
            if state.isChecked { checked += 1 }

            switch filter {
            case .all: break
            case .identified: if !state.isIdentified { continue }
            case .unidentified: if !state.isUnidentified { continue }
            }
            if !query.isEmpty, !matches(site, query: query) { continue }
            visible.append(site)
        }

        identifiedCount = identified
        unidentifiedCount = unidentified
        checkedCount = checked

        visible.sort(by: order)
        filteredCount = visible.count
        sections = groupByOperator ? grouped(visible) : [
            Section(id: "all", operatorName: nil, sites: visible, logCount: visible.reduce(0) { $0 + $1.logCount })
        ]
    }

    private func matches(_ site: RadioLogSite, query: String) -> Bool {
        if site.node.lowercased().contains(query) { return true }
        if (site.operatorName ?? "").lowercased().contains(query) { return true }
        if site.nodeLabel.lowercased().contains(query) { return true }
        if let name = siteNames[site.id], name.lowercased().contains(query) { return true }
        return false
    }

    private func grouped(_ visible: [RadioLogSite]) -> [Section] {
        var order: [String] = []
        var buckets: [String: [RadioLogSite]] = [:]
        for site in visible {
            let key = site.operatorName ?? String(localized: "Opérateur inconnu")
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(site)
        }
        // Sections classées par volume : l'opérateur le plus relevé d'abord.
        return order
            .map { key in
                let bucket = buckets[key] ?? []
                return Section(
                    id: key,
                    operatorName: key,
                    sites: bucket,
                    logCount: bucket.reduce(0) { $0 + $1.logCount }
                )
            }
            .sorted { $0.sites.count > $1.sites.count }
    }

    /// Compteurs sur le CATALOGUE ENTIER — un décompte réel, pas la taille de la
    /// fenêtre chargée. C'est ce qu'engage la maquette, et c'est ce qui rend la
    /// page utilisable : « 3 567 non identifiés » n'a de sens que si c'est le
    /// nombre vrai.
    var totalCount: Int { sites.count }

    /// Part du catalogue dont on connaît le statut. Reste affichée APRÈS le
    /// balayage : elle dit l'état de CONNAISSANCE du catalogue, pas une tâche.
    var completion: Double {
        guard totalCount > 0 else { return 0 }
        return Double(checkedCount) / Double(totalCount)
    }

    func count(for filter: Filter) -> Int {
        switch filter {
        case .all: return totalCount
        case .identified: return identifiedCount
        case .unidentified: return unidentifiedCount
        }
    }

    func state(of site: RadioLogSite) -> RadioLogSiteState {
        states[site.id] ?? .unchecked
    }

    /// Sites non identifiés du filtre courant — la matière de la file en chaîne.
    var chainCandidates: [RadioLogSite] {
        sections.flatMap(\.sites).filter { state(of: $0).isUnidentified }
    }

    private func order(_ lhs: RadioLogSite, _ rhs: RadioLogSite) -> Bool {
        switch sortOrder {
        case .relevance:
            if lhs.logCount != rhs.logCount { return lhs.logCount > rhs.logCount }
            return lhs.lastSeenAt > rhs.lastSeenAt
        case .recency:
            if lhs.lastSeenAt != rhs.lastSeenAt { return lhs.lastSeenAt > rhs.lastSeenAt }
            return lhs.logCount > rhs.logCount
        case .identifier:
            // Numérique quand les deux nœuds sont des nombres — « 9881 » doit
            // venir après « 626 », pas avant comme le voudrait l'ordre texte.
            if let left = Int(lhs.node), let right = Int(rhs.node), left != right {
                return left < right
            }
            return lhs.node < rhs.node
        }
    }

    // MARK: Chargement

    /// Délai en deçà duquel rouvrir la page ne relance PAS de rattrapage.
    ///
    /// Le journal est alimenté par des trajets, pas par la seconde : revenir sur
    /// l'écran deux minutes après n'a aucune chance d'y trouver du neuf, et
    /// chaque passage payait pourtant un aller-retour puis une reconstruction
    /// complète de la liste. Tirer pour rafraîchir contourne toujours ce délai —
    /// c'est le geste par lequel on demande explicitement du frais.
    private let syncCooldown: TimeInterval = 10 * 60

    /// Ouverture : le cache d'abord (affichage immédiat), le réseau seulement
    /// s'il a des chances d'apporter quelque chose.
    func onAppear() async {
        loadFromCache()
        if let lastSyncedAt, Date().timeIntervalSince(lastSyncedAt) < syncCooldown {
            // Rien à retélécharger, mais le balayage peut avoir des sites dont
            // le statut a expiré depuis la dernière fois.
            await startScanIfNeeded()
            return
        }
        await sync()
    }

    private func loadFromCache() {
        let snapshot = service.cachedSnapshot()
        logCount = snapshot.entries.count
        lastSyncedAt = snapshot.lastSyncedAt
        sites = RadioLogSiteBuilder.build(from: snapshot.entries)
        states = service.cachedSiteStates()
        rebuild()
    }

    func sync() async {
        guard !isSyncing else { return }
        isSyncing = true
        syncReceived = 0
        errorMessage = nil
        premiumMessage = nil

        for await progress in service.syncStream() {
            logCount = progress.snapshot.entries.count
            lastSyncedAt = progress.snapshot.lastSyncedAt
            syncReceived = progress.received
            readOnly = progress.readOnly
            sites = RadioLogSiteBuilder.build(from: progress.snapshot.entries)
            rebuild()
            switch progress.failure {
            case let .premiumRequired(message): premiumMessage = message
            case let .network(message): errorMessage = message
            case nil: break
            }
        }

        isSyncing = false
        await startScanIfNeeded()
    }

    /// Rejoue la synchronisation ET le balayage depuis zéro (tirer pour rafraîchir).
    func refresh() async {
        stopScan()
        await sync()
    }

    // MARK: Balayage

    /// Ne balaie que ce qui n'a pas de statut frais : rouvrir la page ne doit pas
    /// relancer 4 800 résolutions déjà connues.
    func startScanIfNeeded() async {
        guard !isScanning else { return }
        guard scanIsAllowedOnCurrentNetwork else { return }
        let pending = sites.filter { states[$0.id] == nil }
        guard !pending.isEmpty else { return }
        startScan(of: pending)
    }

    /// Relance un balayage COMPLET, statuts frais compris (bouton « Tout revérifier »).
    func rescanAll() {
        guard scanIsAllowedOnCurrentNetwork else {
            toast = String(localized: "Balayage désactivé en données mobiles.")
            return
        }
        stopScan()
        startScan(of: sites)
    }

    private var scanIsAllowedOnCurrentNetwork: Bool {
        if scanOnCellular { return true }
        return networkPath.status.connection != .cellular
    }

    private func startScan(of pending: [RadioLogSite]) {
        guard !pending.isEmpty else { return }
        isScanning = true
        scanTask = Task { [weak self] in
            guard let self else { return }
            for await resolved in self.service.scanStream(sites: pending) {
                if Task.isCancelled { break }
                self.states.merge(resolved) { _, new in new }
                self.rebuild()
            }
            self.isScanning = false
        }
    }

    /// Suspension d'un geste, comme l'engage la maquette : le bandeau est un
    /// élément de contenu, pas une barre système qu'on subit.
    func stopScan() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }

    func toggleScan() {
        if isScanning {
            stopScan()
        } else {
            Task { await startScanIfNeeded() }
        }
    }

    // MARK: Fiche de site (commune / adresse)

    /// Charge commune + adresse d'un site identifié, une seule fois.
    ///
    /// À la demande, jamais en masse : c'est un `GET /antenna/{id}` par site, et
    /// la liste en compte plusieurs milliers. On le déclenche au dépliement d'une
    /// carte et dans les écrans qui montrent UN site.
    func loadSiteName(for site: RadioLogSite) {
        guard let siteId = state(of: site).siteId, !siteId.isEmpty else { return }
        guard siteNames[site.id] == nil, !nameTasks.contains(site.id) else { return }
        nameTasks.insert(site.id)
        Task { [weak self] in
            guard let self else { return }
            let market = RadioLogOperatorResolver.marketCode(forOperator: site.operatorName, mcc: site.mcc) ?? "FR"
            let details = try? await self.antennas.details(
                id: siteId,
                market: market,
                operatorName: site.operatorName ?? "ALL"
            )
            self.nameTasks.remove(site.id)
            guard let label = Self.locationLabel(from: details) else { return }
            self.siteNames[site.id] = label
        }
    }

    static func locationLabel(from details: AntennaDetails?) -> String? {
        guard let details else { return nil }
        let commune = details.core?.commune?.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = details.address?.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = [commune, address].compactMap { $0 }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        // La maquette écrit « Vézeronce-Curtin — 96 place de la Mairie ».
        return parts.joined(separator: " — ")
    }

    // MARK: Dépliement

    func toggleExpansion(_ site: RadioLogSite) {
        if expandedSiteId == site.id {
            expandedSiteId = nil
        } else {
            expandedSiteId = site.id
            loadSiteName(for: site)
        }
        Haptics.selection()
    }

    // MARK: Suites d'une identification

    /// Une identification vient d'aboutir : on marque le site sans attendre le
    /// prochain balayage. C'est un fait établi par le serveur, pas une supposition.
    func markIdentified(_ site: RadioLogSite, siteId: String) {
        states[site.id] = .identified(siteId: siteId)
        siteNames[site.id] = nil
        rebuild()
        loadSiteName(for: site)
    }

    // MARK: Purge

    func purge() async {
        do {
            try await service.purge()
            sites = []
            states = [:]
            siteNames = [:]
            logCount = 0
            lastSyncedAt = nil
            rebuild()
            toast = String(localized: "Journal radio supprimé.")
            Haptics.success()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }
}
