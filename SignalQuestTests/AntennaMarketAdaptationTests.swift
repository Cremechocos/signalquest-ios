import SwiftUI
import XCTest
@testable import SignalQuest

/// La fiche antenne sert cinq registres qui ne remplissent pas les mêmes champs
/// et ne donnent pas le même sens aux mêmes clés. Ces tests figent l'adaptation
/// par marché à partir de réponses RÉELLES relevées en production (août 2026).
final class AntennaMarketAdaptationTests: XCTestCase {

    private func core(_ json: String) throws -> AntennaCoreDetails {
        try JSONDecoder.signalQuest.decode(AntennaCoreDetails.self, from: Data(json.utf8))
    }

    private func minimal(
        market: String,
        status: String? = nil,
        supportType: String? = nil,
        commune: String? = nil,
        extraTop: String = "",
        extraSiteInfo: String = ""
    ) -> String {
        let statusJSON = status.map { "\"status\": \"\($0)\"," } ?? ""
        let supportJSON = supportType.map { "\"supportType\": \"\($0)\"," } ?? ""
        let communeJSON = commune.map { "\"commune\": \"\($0)\"," } ?? ""
        return """
        {
          "id": "x", "supId": "x", "anfrCode": "ID-1", "market": "\(market)",
          "lat": 0, "lng": 0, \(communeJSON) \(statusJSON) \(extraTop)
          "operators": [], "technologies": [], "azimuts": [],
          "frequencyBands": [], "radioCarriers": [],
          "cellIdentifiers": { "enb": [], "gnb": [], "pci": [], "cellId": [] },
          "technical": {},
          "siteInfo": { \(supportJSON) \(extraSiteInfo) "_": null }
        }
        """
    }

    // MARK: Statut

    /// Suisse : l'OFCOM recopie la CLASSE D'INSTALLATION dans `status`
    /// (« Outdoor > 6 Werp »). Ce n'est pas un statut — l'afficher en badge
    /// orange laissait croire à un site à l'arrêt.
    func testSwissInstallationClassIsNotShownAsAStatus() throws {
        let core = try core(minimal(market: "CH", status: "Outdoor > 6 Werp", supportType: "Outdoor > 6 Werp"))
        XCTAssertNil(core.displayStatus)
    }

    /// Belgique : le BIPT publie « Octroye », sans accent. C'est bien un statut,
    /// mais de licence — on l'affiche correctement écrit et en attente.
    func testBelgianLicenceStatusIsSpelledAndFlaggedPending() throws {
        let core = try core(minimal(market: "BE", status: "Octroye"))
        XCTAssertEqual(core.displayStatus, "Licence octroyée")
        XCTAssertTrue(core.isPendingStatus)
        XCTAssertFalse(core.isInService)
    }

    func testFrenchStatusesAreKeptAsIs() throws {
        let inService = try core(minimal(market: "FR", status: "En service", supportType: "Immeuble"))
        XCTAssertEqual(inService.displayStatus, "En service")
        XCTAssertTrue(inService.isInService)
        XCTAssertFalse(inService.isPendingStatus)

        let project = try core(minimal(market: "FR", status: "Projet approuvé", supportType: "Pylône"))
        XCTAssertEqual(project.displayStatus, "Projet approuvé")
        XCTAssertTrue(project.isPendingStatus)
    }

    /// Canada : `status` est absent. Pas de badge, et surtout pas d'orange.
    func testCanadaHasNoStatusBadge() throws {
        let core = try core(minimal(market: "CA", supportType: "P"))
        XCTAssertNil(core.displayStatus)
        XCTAssertFalse(core.isPendingStatus)
    }

    /// Accueil, « Antennes suivies » : un projet sans panne n'est pas « En service » (12/11,
    /// Clermont-l'Hérault), et sans statut ni pannes lues on n'affiche rien.
    func testFollowedSiteBadgeShowsTheRealState() throws {
        let project = try core(minimal(market: "FR", status: "Projet approuvé", supportType: "Pylône"))
        let live = try core(minimal(market: "FR", status: "En service", supportType: "Pylône"))
        XCTAssertEqual(FollowedSiteState.resolve(hasOutage: false, core: project), .published("Projet approuvé", pending: true))
        XCTAssertEqual(FollowedSiteState.resolve(hasOutage: false, core: live), .inService)
        XCTAssertEqual(FollowedSiteState.resolve(hasOutage: true, core: project), .outage)
        XCTAssertEqual(FollowedSiteState.resolve(hasOutage: true, core: nil), .outage)
        XCTAssertNil(FollowedSiteState.resolve(hasOutage: nil, core: live))
        XCTAssertNil(FollowedSiteState.resolve(hasOutage: false, core: nil))
        XCTAssertNil(FollowedSiteState.resolve(hasOutage: false, core: try core(minimal(market: "CA", supportType: "P"))))
    }

    // MARK: Libellés

    /// « Code ANFR » devant un identifiant ISED, BIPT ou OFCOM serait faux.
    func testRegistryLabelFollowsTheMarketRegulator() throws {
        XCTAssertEqual(try core(minimal(market: "FR")).registryLabel, "Code ANFR")
        XCTAssertEqual(try core(minimal(market: "DROM")).registryLabel, "Code ANFR")
        XCTAssertEqual(try core(minimal(market: "CA")).registryLabel, "Identifiant ISED")
        XCTAssertEqual(try core(minimal(market: "BE")).registryLabel, "Identifiant BIPT")
        XCTAssertEqual(try core(minimal(market: "CH")).registryLabel, "Identifiant OFCOM")
        XCTAssertEqual(try core(minimal(market: "PT")).registryLabel, "Identifiant du registre")
    }

    /// Canada : la rangée porte la ville et la province (« Lieu »), pas une commune.
    func testCanadaLocalityIsLabelledPlace() throws {
        XCTAssertEqual(try core(minimal(market: "CA", commune: "QC")).localityLabel, "Lieu")
        XCTAssertEqual(try core(minimal(market: "FR", commune: "Paris 4e")).localityLabel, "Commune")
    }

    /// ISED r1 (f) : `commune` = `municipality` (la ville), province servie à part ; un serveur
    /// d'avant f met encore le code de province dans `commune`.
    func testCanadaPlaceJoinsCityAndProvince() throws {
        let both = try core(minimal(market: "CA", commune: "Montréal",
                                    extraTop: #""municipality": "Montréal", "provinceCode": "QC", "address": "1 rue X","#))
        XCTAssertEqual(both.isedPlace, "Montréal, Québec")
        XCTAssertEqual(both.localityValue, "Montréal, Québec")
        XCTAssertEqual(both.fullAddress, "1 rue X, Montréal, Québec")

        // Ville seule : le serveur f ne sert pas encore la province sur R2.
        let cityOnly = try core(minimal(market: "CA", commune: "Montréal", extraTop: #""municipality": "Montréal","#))
        XCTAssertEqual(cityOnly.isedPlace, "Montréal")

        // Hors de toute ville : province seule, comme le Web.
        let provinceOnly = try core(minimal(market: "CA", extraTop: #""municipality": null, "provinceCode": "ON","#))
        XCTAssertEqual(provinceOnly.isedPlace, "Ontario")

        // Serveur d'avant f : `commune` porte le code de province, jamais pris pour une ville.
        let legacy = try core(minimal(market: "CA", commune: "QC"))
        XCTAssertNil(legacy.isedCity)
        XCTAssertEqual(legacy.isedPlace, "Québec")

        // La France garde code postal + commune.
        let france = try core(minimal(market: "FR", commune: "Paris 4e"))
        XCTAssertNil(france.isedPlace)
        XCTAssertEqual(france.localityValue, "Paris 4e")
    }

    // MARK: Données structurelles

    /// BE/CH ne publient ni hauteur, ni secteurs, ni azimuts : la fiche doit
    /// pouvoir l'expliquer au lieu de ressembler à un chargement raté.
    func testMissingStructuralDataIsDetected() throws {
        XCTAssertFalse(try core(minimal(market: "BE")).hasStructuralData)
        XCTAssertTrue(try core(minimal(market: "FR", extraSiteInfo: "\"supportHeight\": \"29,5\",")).hasStructuralData)
        XCTAssertTrue(try core(minimal(market: "CA", extraSiteInfo: "\"sectorCount\": 2,")).hasStructuralData)
    }

    /// La hauteur arrive en chaîne du registre (« 29,5 » en France, « 4 » au
    /// Canada) : sans conversion, la fiche l'affichait sans unité.
    func testSupportHeightParsesRegistryStrings() throws {
        let fr = try core(minimal(market: "FR", extraSiteInfo: "\"supportHeight\": \"29,5\","))
        XCTAssertEqual(fr.siteInfo.supportHeightMeters ?? 0, 29.5, accuracy: 0.001)
        let ca = try core(minimal(market: "CA", extraSiteInfo: "\"supportHeight\": \"4\","))
        XCTAssertEqual(ca.siteInfo.supportHeightMeters ?? 0, 4, accuracy: 0.001)
    }

    // MARK: Sites relevés par un membre

    /// `/map/antenna/{id}` sert AUSSI les sites pointés à la main : la fiche est
    /// la même, seule la provenance change. JSON réel du site bosnien.
    func testCustomSiteDetailIsDecodedWithItsProvenance() throws {
        let core = try core("""
        {
          "id": "cmrvefks50b0f01qzafukx84k", "supId": "cmrvefks50b0f01qzafukx84k",
          "anfrCode": "cs-site-250", "siteKey": "cs-site-250",
          "displayName": "Pylône BH Telecom", "source": "user",
          "isCustomSite": true, "validationStatus": "validated",
          "status": null, "description": null,
          "lat": 43.823190524392345, "lng": 18.211460717057633,
          "address": "4 Kopišanj II, 71240 Hadžići", "commune": null,
          "market": "BA", "marketCode": "BA",
          "operators": ["BH_MOBILE_BA", "BH MOBILE"], "technologies": ["4G"],
          "azimuts": [], "frequencyBands": ["4G B3 (1820 MHz)"], "radioCarriers": [],
          "cellIdentifiers": { "enb": ["250"], "gnb": [], "pci": [], "cellId": [] },
          "technical": {}, "siteInfo": {}
        }
        """)
        XCTAssertTrue(core.isCustomSite)
        XCTAssertEqual(core.displayName, "Pylône BH Telecom")
        XCTAssertEqual(core.source, "user")
        XCTAssertEqual(core.validationStatus, "validated")
        XCTAssertEqual(core.address, "4 Kopišanj II, 71240 Hadžići")
        XCTAssertEqual(core.cellIdentifiers.enb, ["250"])
        // Le slug interne n'est l'identifiant d'aucun régulateur.
        XCTAssertEqual(core.registryLabel, "Référence du site")
        XCTAssertNil(core.displayStatus)
        XCTAssertFalse(core.hasStructuralData)
    }

    /// Antenne mutualisée (métro, tunnel, gare) : nouvelle valeur de
    /// `sharingKind` et liste additive des opérateurs, contrat du 30/09.
    func testSharedAntennaListsItsOperatorsAndOlderBackendsStayReadable() throws {
        let shared = try core(minimal(market: "FR").replacingOccurrences(
            of: "\"operators\": [],",
            with: "\"operators\": [\"SFR\"], \"sharingKind\": \"mutualise\", \"mutualiseOperators\": [\"SFR\", \"BOUYGUES\"],"
        ))
        XCTAssertEqual(shared.sharingKind, "mutualise")
        XCTAssertEqual(shared.mutualiseOperators, ["SFR", "BOUYGUES"])
        XCTAssertEqual(shared.operators, ["SFR"], "L'opérateur de la station seul")

        let outside = try core(minimal(market: "FR").replacingOccurrences(
            of: "\"operators\": [],", with: "\"operators\": [], \"mutualiseOperators\": null,"
        ))
        XCTAssertEqual(outside.mutualiseOperators, [])
        XCTAssertEqual(try core(minimal(market: "FR")).mutualiseOperators, [], "Backend antérieur")
    }

    /// Une fiche officielle ne doit jamais être prise pour une contribution.
    func testOfficialSiteIsNotFlaggedAsCustom() throws {
        let core = try core(minimal(market: "FR", status: "En service", supportType: "Immeuble"))
        XCTAssertFalse(core.isCustomSite)
        XCTAssertNil(core.displayName)
        XCTAssertEqual(core.registryLabel, "Code ANFR")
    }

    // MARK: Alignement sur la fiche Web (choix d'Alexandre du 20/11)

    private var french: Bool { Bundle.main.preferredLocalizations.first == "fr" }

    /// Le n° ARCEP de l'opérateur ouvert : `operatorSiteId`, sinon le premier de `operatorSiteIds`,
    /// jamais le code ANFR (il passait pour le numéro de l'opérateur sur le Web).
    func testOperatorSiteNumberIsTheArcepNumberNeverTheAnfrCode() throws {
        let single = try core(minimal(market: "FR", extraTop: "\"operatorSiteId\": \"3810003843\", \"operatorSiteIds\": [\"3810003843\"],"))
        XCTAssertEqual(single.operatorSiteNumber, "3810003843")
        let list = try core(minimal(market: "FR", extraTop: "\"operatorSiteIds\": [\"\", \"00000123\", \"00000456\"],"))
        XCTAssertEqual(list.operatorSiteNumber, "00000123")
        XCTAssertNil(try core(minimal(market: "FR", extraTop: "\"operatorSiteId\": \" \", \"operatorSiteIds\": null,")).operatorSiteNumber)
        XCTAssertNil(try core(minimal(market: "FR")).operatorSiteNumber, "Jamais le code ANFR ID-1 en repli")
        XCTAssertEqual(AntennaDetailSheet.operatorNumberText("3810003843"), french ? "n° 3810003843" : "no. 3810003843")
        XCTAssertEqual(AntennaDetailSheet.operatorNumberText(nil),
                       french ? "n° non publié par l’ARCEP" : "no. not published by ARCEP")
        // Rangée Radio de l'onglet Essentiel (choix du 21/11) : le n° ARCEP de chaque opérateur,
        // rien tant que sa fiche n'est pas lue, la forme courte une fois lue sans numéro.
        XCTAssertEqual(AntennaDetailSheet.operatorNumberShortText(.some("170023")), french ? "n° 170023" : "no. 170023")
        XCTAssertEqual(AntennaDetailSheet.operatorNumberShortText(.some(nil)),
                       french ? "n° non publié" : "number not published")
        XCTAssertNil(AntennaDetailSheet.operatorNumberShortText(nil))
    }

    private func change(_ id: String, _ technology: String, _ generation: String, _ type: String,
                        _ effective: String?) -> ANFRSiteHistoryChange {
        ANFRSiteHistoryChange(id: id, operatorRaw: "ORANGE", technology: technology, generation: generation,
                              modTypeRaw: type, statut: "En service", effectiveDate: effective)
    }

    private func entry(_ date: String, _ changes: [ANFRSiteHistoryChange]) -> ANFRSiteHistoryEntry {
        ANFRSiteHistoryEntry(archiveDate: date, isCurrentSnapshot: false, city: "", address: nil, operators: ["ORANGE"],
                             modTypes: [], changeCount: changes.count, changes: changes)
    }

    /// « Dernier changement ANFR » : le plus récent du support à sa date réelle, sinon à celle du
    /// relevé ; à égalité, le premier servi, comme le tri stable du Web (exemple de la planche).
    func testLatestAnfrChangeIsTheMostRecentOfTheSupport() {
        let history = ANFRSiteHistory(supId: "1", currentSnapshotDate: "2026-11-12", entries: [
            // Rattrapage publié le 12/11, en service depuis juin : pas le plus récent.
            entry("2026-11-12", [change("a", "LTE 800", "4G", "activated", "2026-06-01")]),
            entry("2026-11-05", [change("b", "GSM 900", "2G", "deleted", nil),
                                 change("c", "5G NR 3500", "5G", "activated", "2026-11-05")]),
            entry("2026-10-15", [change("d", "LTE 2100", "4G", "added", "2026-10-15")]),
        ])
        XCTAssertEqual(AntennaDetailSheet.latestAnfrChange(history),
                       french ? "5 novembre 2026\u{00A0}· 2G 900 retirée" : "November 5, 2026\u{00A0}· 2G 900 removed")
        let activated = ANFRSiteHistory(supId: "1", currentSnapshotDate: nil, entries: [
            entry("2026-11-05", [change("c", "5G NR 3500", "5G", "activated", "2026-11-01")]),
        ])
        XCTAssertEqual(AntennaDetailSheet.latestAnfrChange(activated),
                       french ? "1 novembre 2026\u{00A0}· 5G 3,5\u{00A0}GHz en service"
                              : "November 1, 2026\u{00A0}· 5G 3.5\u{00A0}GHz on air")
        let modified = ANFRSiteHistory(supId: "1", currentSnapshotDate: nil, entries: [
            entry("2026-11-05", [change("e", "LTE 700", "4G", "modified", nil), change("f", "UMTS 900", "3G", "new", nil)]),
        ])
        XCTAssertEqual(AntennaDetailSheet.latestAnfrChange(modified),
                       french ? "5 novembre 2026\u{00A0}· 4G 700 repassée en projet" : "November 5, 2026\u{00A0}· 4G 700 back to planned")
        XCTAssertNil(AntennaDetailSheet.latestAnfrChange(nil))
        XCTAssertNil(AntennaDetailSheet.latestAnfrChange(ANFRSiteHistory(supId: "1", currentSnapshotDate: nil,
                                                                          entries: [entry("2026-11-05", [])])))
    }

    /// « Ce que la communauté sait » : eNB validés, sinon gNB, sinon « Pas encore identifié » ; photos ;
    /// date de la dernière mesure. Chaque fait ouvre son onglet. Au Canada, les eNB/gNB viennent du registre.
    func testCommunityFactsFollowTheWebBlock() {
        let full = AntennaDetailSheet.communityFacts(enb: ["812345", "812346"], gnb: ["1203344"], identifiesNodes: true,
                                                     photos: 2, lastMeasurement: "2026-11-03T08:12:00.000Z")
        XCTAssertEqual(full.map(\.text), french
                       ? ["eNB 812345 · 812346 validés", "2 photos", "Mesuré le 3 nov. 2026"]
                       : ["eNB 812345 · 812346 validated", "2 photos", "Measured on Nov 3, 2026"])
        XCTAssertEqual(full.map(\.tab), [.identifiers, .photos, .measures])
        XCTAssertEqual(full.map(\.validated), [true, false, false])

        let gnbOnly = AntennaDetailSheet.communityFacts(enb: [], gnb: ["1203344"], identifiesNodes: true,
                                                        photos: 1, lastMeasurement: nil)
        XCTAssertEqual(gnbOnly.map(\.text), french ? ["gNB 1203344 validé", "1 photo"] : ["gNB 1203344 validated", "1 photo"])

        let nothing = AntennaDetailSheet.communityFacts(enb: [], gnb: [], identifiesNodes: true, photos: 0, lastMeasurement: nil)
        XCTAssertEqual(nothing.map(\.text), french ? ["Pas encore identifié", "Aucune photo"] : ["Not identified yet", "No photos"])
        XCTAssertEqual(nothing.map(\.validated), [false, false])

        let canada = AntennaDetailSheet.communityFacts(enb: ["4501"], gnb: [], identifiesNodes: false, photos: 0,
                                                       lastMeasurement: "pas une date")
        XCTAssertEqual(canada.map(\.tab), [.photos])
    }

    /// Captures des deux blocs de l'Essentiel, pour relecture (variable SQ_ESSENTIAL_SHOTS).
    @MainActor
    func testCaptureEssentialWebBlocksForReview() async throws {
        guard let output = ProcessInfo.processInfo.environment["SQ_ESSENTIAL_SHOTS"] else {
            throw XCTSkip("SQ_ESSENTIAL_SHOTS absent")
        }
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        let latest = AntennaDetailSheet.latestAnfrChange(ANFRSiteHistory(supId: "1", currentSnapshotDate: nil, entries: [
            entry("2026-11-05", [change("c", "5G NR 3500", "5G", "activated", "2026-11-05")]),
        ])) ?? ""
        let cases: [(String, [AntennaCommunityFact])] = [
            ("identifie", AntennaDetailSheet.communityFacts(enb: ["812345", "812346"], gnb: [], identifiesNodes: true,
                                                            photos: 2, lastMeasurement: "2026-11-03T08:12:00.000Z")),
            ("vide", AntennaDetailSheet.communityFacts(enb: [], gnb: [], identifiesNodes: true, photos: 0, lastMeasurement: nil)),
        ]
        let variants: [(String, ColorScheme, DynamicTypeSize)] = [
            ("clair", .light, .large), ("sombre", .dark, .large), ("ax", .light, .accessibility2),
        ]
        // Dans une vraie fenêtre, comme la fiche : ImageRenderer tronquait un titre en AX.
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.makeKeyAndVisible()
        for (name, facts) in cases {
            for (variant, scheme, size) in variants {
                let view = ScrollView {
                    VStack(alignment: .leading, spacing: SQSpace.md) {
                        AntennaLatestChangeCard(text: latest)
                        AntennaCommunityCard(facts: facts) { _ in }
                    }
                    .padding(16)
                }
                .background(SQColor.bg)
                .environment(\.colorScheme, scheme)
                .environment(\.dynamicTypeSize, size)
                let host = UIHostingController(rootView: view)
                host.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
                window.rootViewController = host
                try await Task.sleep(nanoseconds: 1_000_000_000)
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: output).appendingPathComponent("\(name)-\(variant).png"))
            }
        }
    }
}


/// Sites pointés à la main : seule couche d'antennes disponible dans les pays
/// sans open data. Le JSON ci-dessous est la réponse RÉELLE de la tuile
/// bosnienne (z12/2255/1492, août 2026).
/// SEC-31 : une validation ou une identification écrite depuis une session
/// désigne le site canadien par sa `siteKey`, jamais par son `sup_id` ISED.
final class ServingAntennaSiteIdTests: XCTestCase {
    private func antenna(_ json: String) throws -> ServingAntenna? {
        ServingAntenna(wrapper: try JSONDecoder().decode(ServingAntennaWrapper.self, from: Data(json.utf8)))
    }

    func testCanadianSiteIsWrittenUnderItsSiteKey() throws {
        let siteKey = "3f2a9c1e4b5d6f708192a3b4c5d6e7f801234567"
        let site = try XCTUnwrap(antenna("""
        { "ok": true, "result": { "identified": true, "antenna": {
          "latitude": 45.5, "longitude": -73.6, "sup_id": "M1229", "siteKey": "\(siteKey)" } } }
        """))
        XCTAssertEqual(site.siteId, siteKey)
    }

    func testFrenchSiteKeepsItsSupportNumber() throws {
        let site = try XCTUnwrap(antenna("""
        { "ok": true, "result": { "identified": true, "antenna": {
          "latitude": 44.06, "longitude": 5.9, "sup_id": "1002637", "siteKey": "0042700042" } } }
        """))
        XCTAssertEqual(site.siteId, "1002637")
    }

    func testCommunityKeysFollowTheServerRule() {
        XCTAssertTrue(ServingAntenna.isCommunitySiteKey(String(repeating: "a", count: 40)))
        XCTAssertTrue(ServingAntenna.isCommunitySiteKey("7C9E6679-7425-40DE-944B-E07FC1F90AE7"))
        XCTAssertFalse(ServingAntenna.isCommunitySiteKey("M1229"))
        XCTAssertFalse(ServingAntenna.isCommunitySiteKey("1002637"))
        XCTAssertFalse(ServingAntenna.isCommunitySiteKey(String(repeating: "g", count: 40)))
    }

    func testMapAntennaIsWrittenUnderItsHexKeyInCanadaOnly() {
        func site(id: String, siteId: String?) -> AntennaSite {
            AntennaSite(
                id: id, siteId: siteId, anfrCode: nil, latitude: 45.5, longitude: -73.6,
                operators: ["BELL"], technologies: ["4G"], bands: [], azimuths: [],
                sharingType: nil, crozonLeader: nil, address: nil, height: nil, owner: nil
            )
        }
        let hex = "3f2a9c1e4b5d6f708192a3b4c5d6e7f801234567"
        XCTAssertEqual(site(id: hex, siteId: "M1229").writeSiteId, hex, "Marqueur ISED : son id, pas son sup_id")
        XCTAssertEqual(site(id: "anfr-123", siteId: "37199").writeSiteId, "37199")
        XCTAssertEqual(site(id: "cmpo873aw0jnx2fll7pthh8ii", siteId: nil).writeSiteId, "cmpo873aw0jnx2fll7pthh8ii")
    }

    /// Deux sites canadiens de titulaires différents peuvent partager un `sup_id` : la liste de la
    /// carte les garde tous les deux (la déduplication suit la clé d'écriture), et un même site
    /// français rendu par plusieurs opérateurs ne compte qu'une fois.
    func testListKeepsTwoCanadianSitesSharingASupId() async throws {
        let first = "3f2a9c1e4b5d6f708192a3b4c5d6e7f801234567"
        let second = "9a8b7c6d5e4f30211203f4e5d6c7b8a998877665"
        func list(market: String, operatorName: String, body: String) async throws -> [AntennaSite] {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            let api = APIClient(config: .test, credentials: CredentialStore(tokenStore: InMemoryTokenStore()),
                                session: URLSession(configuration: config))
            MockURLProtocol.requestHandler = { request in
                (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                 Data(body.utf8))
            }
            defer { MockURLProtocol.requestHandler = nil }
            return try await AntennasService(api: api).list(
                bbox: BoundingBox(north: 46, south: 45, east: -73, west: -74),
                market: market, operatorName: operatorName, technologies: []
            )
        }
        let canadian = try await list(market: "CA", operatorName: "BELL", body: """
        { "antennas": [
          { "id": "\(first)", "sup_id": "M1229", "latitude": 45.5, "longitude": -73.6 },
          { "id": "\(second)", "sup_id": "M1229", "latitude": 45.6, "longitude": -73.7 } ] }
        """)
        XCTAssertEqual(canadian.map(\.writeSiteId), [first, second])
        let french = try await list(market: "FR", operatorName: "ALL", body: """
        { "antennas": [ { "id": "anfr-1", "sup_id": "37199", "latitude": 44.06, "longitude": 5.9 } ] }
        """)
        XCTAssertEqual(french.map(\.writeSiteId), ["37199"], "Même site rendu pour SFR, Bouygues et ALL : une seule fois")
    }

    func testSearchResultIsWrittenUnderItsSiteKeyToo() throws {
        let hex = "3f2a9c1e4b5d6f708192a3b4c5d6e7f801234567"
        let canadian = try JSONDecoder().decode(AntennaSite.self, from: Data("""
        { "sup_id": "M1229", "site_key": "\(hex)", "latitude": 45.5, "longitude": -73.6 }
        """.utf8))
        XCTAssertEqual(canadian.writeSiteId, hex, "Même clé que depuis la carte")
        let french = try JSONDecoder().decode(AntennaSite.self, from: Data("""
        { "sup_id": "1002637", "latitude": 44.06, "longitude": 5.9 }
        """.utf8))
        XCTAssertEqual(french.writeSiteId, "1002637")
    }

    /// LM110-01 (11/11) : la recherche rend l'enregistrement ISED brut, titulaire dans
    /// `marketOperator` et sans `operators`. Sans repli, la fiche demandait le site à Bell.
    func testSearchResultTakesItsOperatorFromMarketOperator() throws {
        let canadian = try JSONDecoder().decode(AntennaSite.self, from: Data("""
        { "sup_id": "LM110-01", "marketOperator": "VIDEOTRON_FREEDOM", "latitude": 45.49, "longitude": -73.56 }
        """.utf8))
        XCTAssertEqual(canadian.operators, ["VIDEOTRON_FREEDOM"])
        let listed = try JSONDecoder().decode(AntennaSite.self, from: Data("""
        { "sup_id": "37199", "operators": ["SFR", "BOUYGUES"], "marketOperator": "SFR" }
        """.utf8))
        XCTAssertEqual(listed.operators, ["SFR", "BOUYGUES"], "La liste servie prime")
        let unknown = try JSONDecoder().decode(AntennaSite.self, from: Data("""
        { "sup_id": "X1", "marketOperator": "UNKNOWN" }
        """.utf8))
        XCTAssertEqual(unknown.operators, [])
    }

    func testOfficialSourceOutageTellsToRetryShortly() {
        XCTAssertEqual(
            APIError.userFacingMessage(status: 503, code: "OFFICIAL_ANTENNA_SOURCE_UNAVAILABLE", serverMessage: ""),
            String(localized: "La source officielle des antennes ne répond pas. Réessaie dans quelques secondes.")
        )
    }
}

final class CustomSiteDecodeTests: XCTestCase {

    private func decode(_ json: String) throws -> AndroidCustomSiteTileResponse {
        try JSONDecoder.signalQuest.decode(AndroidCustomSiteTileResponse.self, from: Data(json.utf8))
    }

    func testBosnianCustomSiteDecodesWithItsRadioIdentifiers() throws {
        let response = try decode("""
        {
          "tile": { "z": 12, "x": 2255, "y": 1492 },
          "markers": [{
            "id": "cmrvefks50b0f01qzafukx84k",
            "lat": 43.823190524392345, "lng": 18.211460717057633,
            "name": "Pylône BH Telecom", "type": "PYLONE", "description": null,
            "createdByUserId": "cmoyedypl001428pfhwzv8jsx",
            "createdByDisplayName": "zlnvcc",
            "createdAt": "2026-07-22T01:23:46.037Z",
            "photoCount": 0, "primaryPhotoUrl": null,
            "validationStatus": "validated",
            "radio": {
              "enb": "250", "gnb": null, "cellId": "184", "pci": 242, "tac": "4074",
              "earfcn": 1351, "nrarfcn": null, "band": 3, "mcc": 218, "mnc": 90,
              "operator": "BH Mobile", "technology": "LTE"
            }
          }]
        }
        """)
        let marker = try XCTUnwrap(response.markers.first)
        XCTAssertEqual(marker.name, "Pylône BH Telecom")
        XCTAssertEqual(marker.typeLabel, "Pylône")
        XCTAssertTrue(marker.isValidated)
        XCTAssertEqual(marker.createdByDisplayName, "zlnvcc")
        XCTAssertEqual(marker.radio?.enb, "250")
        XCTAssertEqual(marker.radio?.pci, 242)
        XCTAssertEqual(marker.radio?.band, 3)
        // Le PLMN se recompose des deux moitiés : 218-90 = BH Telecom.
        XCTAssertEqual(marker.radio?.plmn, "218-90")
        XCTAssertFalse(marker.radio?.isEmpty ?? true)
    }

    /// Un site sans identifiants relevés doit rester affichable : la fiche masque
    /// simplement la section radio.
    func testCustomSiteWithoutRadioStaysUsable() throws {
        let response = try decode("""
        {
          "tile": { "z": 12, "x": 1, "y": 1 },
          "markers": [{ "id": "a", "lat": 1.5, "lng": 2.5, "name": null, "type": "CHATEAU_EAU",
                        "photoCount": 2, "validationStatus": "pending", "radio": {} }]
        }
        """)
        let marker = try XCTUnwrap(response.markers.first)
        XCTAssertEqual(marker.typeLabel, "Château d'eau")
        XCTAssertFalse(marker.isValidated)
        XCTAssertEqual(marker.photoCount, 2)
        XCTAssertTrue(marker.radio?.isEmpty ?? false)
    }

    /// Un type inconnu du backend ne doit pas disparaître de la fiche : on le
    /// rend lisible plutôt que de le masquer ou d'afficher la constante brute.
    func testUnknownSupportTypeIsHumanised() throws {
        let response = try decode("""
        { "tile": { "z": 1, "x": 0, "y": 0 },
          "markers": [{ "id": "b", "lat": 1, "lng": 1, "type": "ANTENNE_MURALE" }] }
        """)
        XCTAssertEqual(response.markers.first?.typeLabel, "Antenne Murale")
    }
}

/// Audit perf, C7 : changer d'opérateur sur un support partagé montre la fiche
/// déjà lue pour ses bandes ; une relecture explicite suit une écriture et
/// oublie ces fiches.
@MainActor
final class AntennaDetailOperatorSwitchTests: XCTestCase {
    func testOperatorSwitchReusesReadDetailsUntilAnExplicitReload() async throws {
        let service = CountingDetailsService()
        let model = AntennaDetailViewModel(service: service)
        await model.show(id: "799050", market: "FR", operatorName: "ORANGE", anfrCode: nil)
        XCTAssertEqual(model.details?.core?.operators, ["ORANGE"])
        XCTAssertEqual(service.calls, ["ORANGE"])

        model.remember(try CountingDetailsService.details(operatorName: "SFR"), operatorName: "SFR")
        await model.show(id: "799050", market: "FR", operatorName: "SFR", anfrCode: nil)
        XCTAssertEqual(model.details?.core?.operators, ["SFR"])
        await model.show(id: "799050", market: "FR", operatorName: "ORANGE", anfrCode: nil)
        XCTAssertEqual(model.details?.core?.operators, ["ORANGE"])
        XCTAssertEqual(service.calls, ["ORANGE"], "Les deux fiches étaient déjà lues")

        await model.load(id: "799050", market: "FR", operatorName: "ORANGE", anfrCode: nil)
        await model.show(id: "799050", market: "FR", operatorName: "SFR", anfrCode: nil)
        XCTAssertEqual(model.details?.core?.operators, ["SFR"])
        XCTAssertEqual(service.calls, ["ORANGE", "ORANGE", "SFR"], "Après une relecture, plus rien n'est repris")
    }
}

private final class CountingDetailsService: AntennasServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var requested: [String] = []
    var calls: [String] { lock.withLock { requested } }

    nonisolated static func details(operatorName: String) throws -> AntennaDetails {
        try JSONDecoder.signalQuest.decode(AntennaDetails.self, from: Data("""
        {"antenna":{"id":"799050","supId":"799050","lat":45.0,"lng":5.0,"operators":["\(operatorName)"],"technologies":["4G"],"azimuts":[]}}
        """.utf8))
    }

    func list(bbox: BoundingBox) async throws -> [AntennaSite] { [] }
    func list(bbox: BoundingBox, market: String, operatorName: String, technologies: Set<String>) async throws -> [AntennaSite] { [] }
    func list(bbox: BoundingBox, market: String, operatorName: String, technologies: Set<String>, bands: Set<Int>, sharing: Set<String>) async throws -> [AntennaSite] { [] }
    func list(bbox: BoundingBox, market: String, operatorName: String, technologies: Set<String>, bands: Set<Int>, bandMatch: BandMatchMode, sharing: Set<String>) async throws -> [AntennaSite] { [] }
    func details(id: String) async throws -> AntennaDetails { throw APIError.cancelled }
    func details(id: String, market: String, operatorName: String) async throws -> AntennaDetails {
        try await details(id: id, market: market, operatorName: operatorName, anfrCode: nil)
    }
    func details(id: String, market: String, operatorName: String, anfrCode: String?) async throws -> AntennaDetails {
        lock.withLock { requested.append(operatorName) }
        return try Self.details(operatorName: operatorName)
    }
    func search(query: String) async throws -> [AntennaSite] { [] }
    func quickSearch(query: String, market: String, department: String?) async throws -> [AntennaSite] { [] }
    func listCommunitySites(bbox: BoundingBox, market: String, operatorName: String?) async throws -> [AntennaSite] { [] }
}
