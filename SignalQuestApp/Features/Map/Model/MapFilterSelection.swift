import Foundation

/// A value snapshot: editing a copy never writes preferences or starts a load.
struct MapFilterSelection: Equatable {
    var market: String
    var operatorName: String
    var technologies: Set<String>
    var bands: Set<Int>
    var bandMatch: BandMatchMode
    var azimuthStyle: AzimuthStyle
    var sharing: Set<String>
    var speedtestDays: Int
    var coverageDays: Int
    var layers: Set<MapDisplayItem.Kind>
    var includeObserved: Bool
    var plannedStatuses: Set<PlannedActivationStatus>
    /// Couche Photos restreinte aux amis : un choix à part, jamais déduit de la
    /// couche Amis.
    var photosFriendsOnly: Bool
    /// Filtres de sites, appliqués sans requête (IOS-037).
    var siteFilters = MapSiteFilters()

    static func defaults(market: String, operatorName: String) -> Self {
        Self(market: market, operatorName: operatorName, technologies: [], bands: [],
             bandMatch: .any, azimuthStyle: .lobes, sharing: [], speedtestDays: 0,
             coverageDays: 0, layers: MapFilterStore.defaultFilters, includeObserved: true,
             plannedStatuses: Set(PlannedActivationStatus.allCases), photosFriendsOnly: false)
    }

    /// Only context-dependent values are pruned. Layer bits are preserved:
    /// photos, friends and coverage also have community-market consumers.
    func normalized(for entry: MarketRegistryEntry, dromRegion: DromRegion?) -> Self {
        var result = self
        result.market = entry.marketCode.isEmpty ? entry.code : entry.marketCode
        let operators = Self.operatorOptions(for: entry, dromRegion: dromRegion)
        let candidate = entry.operatorEntry(forKey: operatorName)?.key ?? operatorName.uppercased()
        result.operatorName = operators.first { $0.caseInsensitiveCompare(candidate) == .orderedSame }
            ?? (entry.isCommunityOnly ? "ALL" : operators.first { $0 != "ALL" } ?? "ALL")
        result.technologies.formIntersection(MapFilterCatalog.technologies(forMarket: result.market).map(\.value))
        result.bands.formIntersection(MapFilterCatalog.bands(forMarket: result.market).map(\.band))
        result.sharing.formIntersection(MapFilterCatalog.sharing(forMarket: result.market).map(\.value))
        result.siteFilters = result.siteFilters.normalized(forMarket: result.market)
        return result
    }

    static func operatorOptions(for entry: MarketRegistryEntry, dromRegion: DromRegion?) -> [String] {
        var keys = entry.selectableOperators.map(\.key)
        if entry.marketCode.uppercased() == "DROM", let dromRegion {
            keys = keys.filter { dromRegion.allows(operatorKey: $0) }
        }
        if !keys.contains(where: { $0.uppercased() == "ALL" }) { keys.append("ALL") }
        return keys
    }

    func requiresNetworkReload(comparedTo previous: Self) -> Bool {
        var request = self
        request.azimuthStyle = previous.azimuthStyle
        request.plannedStatuses = previous.plannedStatuses
        request.siteFilters = previous.siteFilters
        return request != previous
    }
}

/// Filtres de sites appliqués sur les antennes déjà chargées, sans requête (IOS-037, comme
/// Android) : photos, identification, hauteur du support, mise en service ; au Canada,
/// puissance, gain et hauteur de structure des émetteurs ISED. Une valeur inconnue sort du
/// résultat dès qu'un filtre la demande.
struct MapSiteFilters: Equatable, Sendable {
    enum Photos: String, CaseIterable, Sendable { case all, with, without }
    enum Identification: String, CaseIterable, Sendable { case all, notIdentified, identified }
    enum SupportHeight: String, CaseIterable, Sendable { case all, under20, from20To40, over40 }
    enum Bucket: String, CaseIterable, Sendable { case all, low, mid, high }

    var photos: Photos = .all
    var identification: Identification = .all
    var supportHeight: SupportHeight = .all
    /// 0 : toutes ; sinon 6 ou 12 mois de 30 jours, comme Android.
    var commissionedWithinMonths = 0
    /// Jour choisi au calendrier ; il prime sur les mois.
    var commissionedSince: Date?
    var caPower: Bucket = .all
    var caGain: Bucket = .all
    var caHeight: Bucket = .all

    /// Photos et identifiants ne sont calculés par le serveur qu'à partir des tuiles de zoom 13.
    static let contributionMinTileZoom = 13

    var activeCount: Int {
        [photos != .all, identification != .all, supportHeight != .all,
         commissionedWithinMonths != 0 || commissionedSince != nil,
         caPower != .all, caGain != .all, caHeight != .all].filter { $0 }.count
    }

    /// `contributionDataAvailable` : faux sous le zoom 13, où aucun marqueur ne porte ni photos
    /// ni identifiants ; les deux filtres sont alors suspendus plutôt que de tout masquer.
    /// `isedDataAvailable` : faux pour la liste filtrée côté serveur, qui ne sert pas les champs ISED ;
    /// les tranches du Canada sont alors suspendues.
    func matches(_ site: AntennaSite, market: String, contributionDataAvailable: Bool,
                 isedDataAvailable: Bool = true, now: Date = Date()) -> Bool {
        if contributionDataAvailable {
            switch photos {
            case .all: break
            case .with: guard site.photoCount > 0 else { return false }
            case .without: guard site.photoCount == 0 else { return false }
            }
            let identified = site.hasEnb || site.hasGnb
            switch identification {
            case .all: break
            case .identified: guard identified else { return false }
            case .notIdentified: guard !identified else { return false }
            }
        }
        if market.uppercased() == "CA" {
            guard isedDataAvailable else { return true }
            return Self.matches(site.caTxPowerW, caPower, lowMax: 10, midMax: 40)
                && Self.matches(site.caAntennaGainDbi, caGain, lowMax: 5, midMax: 20)
                && Self.matches(site.caStructureHeightMeters, caHeight, lowMax: 10, midMax: 40)
        }
        // Hauteur et mise en service viennent de l'ANFR : France et DROM seulement.
        guard Self.isANFRMarket(market) else { return true }
        if supportHeight != .all {
            guard let height = site.height, height > 0 else { return false }
            switch supportHeight {
            case .all: break
            case .under20: guard height < 20 else { return false }
            case .from20To40: guard (20...40).contains(height) else { return false }
            case .over40: guard height > 40 else { return false }
            }
        }
        if let floor = commissionedFloor(now: now) {
            guard let date = site.commissionedAt, date >= floor else { return false }
        }
        return true
    }

    static func isANFRMarket(_ market: String) -> Bool { ["FR", "DROM"].contains(market.uppercased()) }

    /// Un filtre qui ne vaut pas pour ce pays repart à zéro : resté actif mais caché, il viderait la carte.
    func normalized(forMarket market: String) -> Self {
        var result = self
        if !Self.isANFRMarket(market) {
            result.supportHeight = .all
            result.commissionedWithinMonths = 0
            result.commissionedSince = nil
        }
        if market.uppercased() != "CA" {
            result.caPower = .all
            result.caGain = .all
            result.caHeight = .all
        }
        return result
    }

    func commissionedFloor(now: Date = Date()) -> Date? {
        if let commissionedSince { return commissionedSince }
        guard commissionedWithinMonths > 0 else { return nil }
        return now.addingTimeInterval(-Double(commissionedWithinMonths) * 30 * 24 * 3600)
    }

    /// Bornes hautes comprises dans la tranche basse, comme les seuils ISED d'Android.
    static func matches(_ value: Double?, _ bucket: Bucket, lowMax: Double, midMax: Double) -> Bool {
        guard bucket != .all else { return true }
        guard let value else { return false }
        switch bucket {
        case .all: return true
        case .low: return value <= lowMax
        case .mid: return value > lowMax && value <= midMax
        case .high: return value > midMax
        }
    }
}
