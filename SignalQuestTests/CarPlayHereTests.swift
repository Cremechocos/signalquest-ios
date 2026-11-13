import CarPlay
import CoreLocation
import XCTest
@testable import SignalQuest

/// Verrouille l'onglet « Ici » — celui qui répond à « pourquoi ça capte mal ».
/// Ses pièges sont éditoriaux : ne rien afficher de trompeur quand la donnée
/// manque ou n'est pas encore arrivée, ne jamais laisser un verdict sans son
/// opérateur ni son nombre de mesures, et faire de chaque rangée une porte.
@MainActor
final class CarPlayHereTests: XCTestCase {

    private typealias Builder = NearestAntennaTemplateBuilder

    private func quality(level: CoverageQualityBand = .poor,
                         samples: Int = 42,
                         operatorKey: String = "ORANGE",
                         operatorLabel: String = "Orange") -> NearbyNetworkQuality {
        NearbyNetworkQuality(
            level: level, signalBand: level, speedBand: level,
            medianRsrpDbm: -108, medianDownloadMbps: 12,
            operatorLabel: operatorLabel, operatorKey: operatorKey, operatorSource: .ipAsn,
            sampleCount: samples, radiusMeters: 1000
        )
    }

    private func cellularPath(_ technology: CellularRadioTechnology? = .fourG) -> NetworkPathStatus {
        NetworkPathStatus(
            connection: .cellular, cellularTechnology: technology, operatorName: "BOUYGUES",
            operatorMcc: 208, operatorMnc: 20, isExpensive: true, isConstrained: false
        )
    }

    private func site(operators: [String] = ["ORANGE"],
                      technologies: [String] = ["4G", "5G"]) throws -> AntennaSite {
        let json = """
        {"id":"1","siteId":"75-1234","lat":48.86,"lng":2.36,
         "operators":\(operators),"technologies":\(technologies),"azimuts":[0,120,240]}
        """
        return try JSONDecoder.signalQuest.decode(AntennaSite.self, from: Data(json.utf8))
    }

    private func row(_ row: Builder.Row, in items: [CPListItem]) -> CPListItem? {
        items.first { ($0.userInfo as? Builder.Row) == row }
    }

    private func rows(_ items: [CPListItem]) -> [Builder.Row?] {
        items.map { $0.userInfo as? Builder.Row }
    }

    private func bundle(_ language: String) throws -> Bundle {
        let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"))
        return try XCTUnwrap(Bundle(path: path))
    }

    // MARK: - Ordre et chargement

    /// Le verdict passe avant tout le reste : c'est la question que l'utilisateur
    /// se pose en ouvrant cet écran. La comparaison ferme la marche.
    func testRowsAreOrderedVerdictAntennaConnectionCompare() throws {
        let items = Builder.items(
            for: .init(path: cellularPath(), quality: quality(), nearestSite: try site(),
                       nearestDistanceMeters: 340),
            actions: .init(showQuality: { _ in }, showAntenna: { _ in }, compareOperators: {})
        )
        XCTAssertEqual(rows(items), [.verdict, .antenna, .connection, .compare])
    }

    /// Pendant le chargement, on DIT qu'on cherche : « Pas assez de mesures »
    /// ou « Aucune antenne » seraient des faits faux tant que la réponse n'est
    /// pas arrivée.
    func testLoadingSaysWhatIsHappeningInsteadOfClaimingEmptiness() throws {
        let items = Builder.items(for: .init(phase: .loading, path: cellularPath()),
                                  actions: .init(showQuality: { _ in }, showAntenna: { _ in }))
        let verdict = try XCTUnwrap(row(.verdict, in: items))
        let antenna = try XCTUnwrap(row(.antenna, in: items))
        XCTAssertEqual(verdict.text, String(localized: "Analyse du réseau ici…"))
        XCTAssertEqual(antenna.text, String(localized: "Recherche des antennes autour…"))
        XCTAssertNil(verdict.handler, "rien à ouvrir tant que le verdict n'est pas là")
        XCTAssertNil(antenna.handler)
        XCTAssertNotNil(row(.connection, in: items), "la connexion se lit sans attendre le réseau")
    }

    // MARK: - Verdict

    func testVerdictStatesTheLevel() throws {
        let verdict = try XCTUnwrap(row(.verdict, in: Builder.items(
            for: .init(path: cellularPath(), quality: quality(level: .good))
        )))
        XCTAssertEqual(verdict.text, Builder.verdictTitle(.good))
        XCTAssertTrue(try XCTUnwrap(verdict.text).contains(CoverageQualityBand.good.title.lowercased()))
    }

    /// « Mauvais sur 3 mesures » et « mauvais sur 400 » ne se valent pas, et un
    /// verdict sans opérateur laisserait croire qu'il vaut pour tout le monde.
    func testVerdictNamesItsOperatorInFullAndItsSampleCount() throws {
        let q = quality(operatorKey: "BOUYGUES", operatorLabel: "Bouygues")
        let verdict = try XCTUnwrap(row(.verdict, in: Builder.items(
            for: .init(path: cellularPath(), quality: q)
        )))
        let detail = try XCTUnwrap(verdict.detailText)
        XCTAssertTrue(detail.contains("Bouygues Telecom"), detail)
        XCTAssertTrue(detail.contains(Builder.samplesPhrase(q)), detail)
    }

    /// Le pluriel doit suivre le nombre, dans les deux langues.
    func testSamplesPhraseIsPluralized() throws {
        let key = "%lld mesures à moins de %@"
        let french = try bundle("fr").localizedString(forKey: key, value: nil, table: nil)
        let english = try bundle("en").localizedString(forKey: key, value: nil, table: nil)
        XCTAssertEqual(String.localizedStringWithFormat(french, 1, "1 km"), "1 mesure à moins de 1 km")
        XCTAssertEqual(String.localizedStringWithFormat(french, 42, "1 km"), "42 mesures à moins de 1 km")
        XCTAssertEqual(String.localizedStringWithFormat(english, 1, "1 km"), "1 measurement within 1 km")
        XCTAssertEqual(String.localizedStringWithFormat(english, 42, "1 km"), "42 measurements within 1 km")
    }

    /// Sans mesures, on le DIT. Un écran muet laisserait croire à un bug, ou
    /// pire, à une absence de réseau. « Pas de mesure » (`.unknown`) n'est pas
    /// un verdict non plus.
    func testMissingQualityIsStatedExplicitly() throws {
        for missing in [nil, quality(level: .unknown)] {
            let verdict = try XCTUnwrap(row(.verdict, in: Builder.items(
                for: .init(path: cellularPath(), quality: missing),
                actions: .init(showQuality: { _ in })
            )))
            XCTAssertEqual(verdict.text, String(localized: "Pas assez de mesures"))
            XCTAssertFalse(verdict.detailText?.isEmpty ?? true)
            XCTAssertNil(verdict.handler, "pas de détail à ouvrir sans verdict")
        }
    }

    /// Le détail du verdict reste sous les plafonds CarPlay et sans bouton.
    func testQualityDetailStaysWithinCarPlayLimits() {
        let template = Builder.qualityDetail(quality())
        XCTAssertLessThanOrEqual(template.items.count, CarPlayDetailTemplateBuilder.maxItems)
        XCTAssertTrue(template.actions.isEmpty)
        XCTAssertTrue(template.items.contains { $0.title == String(localized: "Signal médian") })
        XCTAssertTrue(template.items.contains { $0.title == String(localized: "Mesures") })
    }

    // MARK: - Antenne

    /// Distance ET direction : la distance seule ne dit pas où regarder. La
    /// direction ouvre le détail plutôt que de finir le titre, qui se coupait
    /// en taille Minimum juste avant elle (CarPlay Simulator, 13/11).
    func testAntennaRowGivesDistanceAndDirection() throws {
        let antenna = try XCTUnwrap(row(.antenna, in: Builder.items(
            for: .init(path: cellularPath(), quality: quality(), nearestSite: try site(),
                       nearestDistanceMeters: 340, bearingDegrees: 135)
        )))
        let text = try XCTUnwrap(antenna.text)
        XCTAssertEqual(text, String(localized: "Antenne à \(SQUnits.distance(meters: 340))"))
        let detail = try XCTUnwrap(antenna.detailText)
        let direction = CarPlayDetailTemplateBuilder.compassLabel(135)
        XCTAssertTrue(detail.hasPrefix(direction.prefix(1).uppercased() + direction.dropFirst()), detail)
        XCTAssertTrue(detail.contains("Orange"), detail)
    }

    /// Être dans l'axe d'un secteur explique une bonne réception malgré la
    /// distance — c'est l'information qui rend la rangée utile plutôt que
    /// descriptive. Inconnu, on n'en dit rien.
    func testSectorAlignmentIsReported() throws {
        let s = try site()
        let aligned = Builder.antennaDetail(s, isInSector: true)
        let off = Builder.antennaDetail(s, isInSector: false)
        let unknown = Builder.antennaDetail(s, isInSector: nil)
        XCTAssertTrue(aligned.contains(String(localized: "Dans l'axe")))
        XCTAssertTrue(off.contains(String(localized: "Hors de l'axe")))
        XCTAssertFalse(unknown.contains(String(localized: "Dans l'axe")))
        XCTAssertFalse(unknown.contains(String(localized: "Hors de l'axe")))
    }

    /// La ligne coupe sa fin : l'axe passe avant la génération, et une seule
    /// génération suffit (la fiche donne les autres).
    func testAntennaDetailPutsTheAxisBeforeTheNewestGeneration() throws {
        let detail = Builder.antennaDetail(
            try site(operators: ["SFR", "BOUYGUES"], technologies: ["2G", "3G", "4G", "5G"]),
            isInSector: false
        )
        XCTAssertEqual(detail, "SFR / Bouygues Telecom · \(String(localized: "Hors de l'axe")) · 5G")
        XCTAssertNil(Builder.newestGeneration(["inconnue"]))
    }

    /// Noms complets, sans doublon ; la clé brute en secours plutôt qu'un faux nom.
    func testOperatorNamesAreFullAndDeduplicated() {
        XCTAssertEqual(Builder.operatorNames(["SFR", "BOUYGUES", "SFR"]), "SFR / Bouygues Telecom")
        XCTAssertEqual(Builder.operatorNames(["FREE"]), "Free Mobile")
        XCTAssertEqual(Builder.operatorNames(["PROXIMUS"]), "PROXIMUS")
    }

    /// Le serveur mélange « LTE », « 4G », « 5G NR » : le conducteur lit des
    /// générations, la plus récente d'abord.
    func testGenerationsAreNormalizedNewestFirst() {
        XCTAssertEqual(Builder.generations(["LTE", "5G NR", "4G", "GSM"]), "5G, 4G, 2G")
        XCTAssertEqual(Builder.generations([]), "")
    }

    /// Pas de rangée vide : une phrase — et un échec n'est pas une zone vide.
    func testMissingAntennaIsStatedExplicitly() throws {
        let none = try XCTUnwrap(row(.antenna, in: Builder.items(
            for: .init(path: cellularPath(), quality: quality())
        )))
        XCTAssertEqual(none.text, String(localized: "Aucune antenne connue à proximité."))

        var failedInput = Builder.Input(path: cellularPath(), quality: quality())
        failedInput.antennasUnavailable = true
        let failed = try XCTUnwrap(row(.antenna, in: Builder.items(for: failedInput)))
        XCTAssertEqual(failed.text, String(localized: "Antennes indisponibles"))
        XCTAssertNotEqual(failed.text, none.text)
    }

    // MARK: - Connexion, position

    func testMissingLocationKeepsConnectionWithoutLocalClaims() throws {
        let path = cellularPath()
        let normal = Builder.items(for: .init(path: path, quality: quality()),
                                   actions: .init(compareOperators: {}))
        let unavailable = Builder.items(for: .init(phase: .withoutLocation, path: path),
                                        actions: .init(compareOperators: {}))

        XCTAssertEqual(rows(unavailable), [.location, .connection])
        XCTAssertEqual(row(.connection, in: unavailable)?.text, row(.connection, in: normal)?.text)
        XCTAssertNil(row(.verdict, in: unavailable))
        XCTAssertNil(row(.antenna, in: unavailable))
        XCTAssertNil(row(.compare, in: unavailable), "comparer dépend de l'endroit")
    }

    /// La connexion nomme la génération et l'opérateur en entier ; en Wi-Fi,
    /// pas d'opérateur mobile qui laisserait croire au réseau cellulaire.
    func testConnectionRowNamesTechnologyAndFullOperator() throws {
        let cellular = Builder.connectionItem(for: cellularPath(.fiveGNSA))
        XCTAssertTrue(try XCTUnwrap(cellular.text).contains("5G NSA"))
        XCTAssertEqual(cellular.detailText, "Bouygues Telecom")

        let wifi = Builder.connectionItem(for: NetworkPathStatus(
            connection: .wifi, cellularTechnology: nil, operatorName: "BOUYGUES",
            operatorMcc: nil, operatorMnc: nil, isExpensive: false, isConstrained: false
        ))
        XCTAssertNil(wifi.detailText)
    }

    /// La rangée décrit le réseau en cours, pas l'écran d'authentification : en
    /// anglais elle dit « Connection », pas « Sign in ».
    func testConnectionRowIsNotTheSignInLabelInEnglish() throws {
        XCTAssertEqual(
            try bundle("en").localizedString(forKey: "Connexion : %@", value: nil, table: nil),
            "Connection: %@"
        )
    }

    // MARK: - Actions et images

    /// Chaque rangée qui résume quelque chose l'ouvre : à la molette, c'est le
    /// seul moyen d'aller plus loin.
    func testRowsOpenWhatTheySummarize() throws {
        var openedQuality: NearbyNetworkQuality?
        var openedSite: AntennaSite?
        var compared = false
        let s = try site()
        let items = Builder.items(
            for: .init(path: cellularPath(), quality: quality(), nearestSite: s, nearestDistanceMeters: 340),
            actions: .init(showQuality: { openedQuality = $0 },
                           showAntenna: { openedSite = $0 },
                           compareOperators: { compared = true })
        )
        for kind in [Builder.Row.verdict, .antenna, .compare] {
            let item = try XCTUnwrap(row(kind, in: items))
            XCTAssertEqual(item.accessoryType, .disclosureIndicator, "\(kind)")
            item.handler?(item, {})
        }
        XCTAssertEqual(openedQuality, quality())
        XCTAssertEqual(openedSite?.id, s.id)
        XCTAssertTrue(compared)
        XCTAssertNil(row(.connection, in: items)?.handler, "rien à ouvrir sous la connexion")
    }

    /// Sans action fournie, aucune rangée ne promet d'ouvrir quoi que ce soit.
    func testNothingIsActionableWithoutActions() throws {
        let items = Builder.items(
            for: .init(path: cellularPath(), quality: quality(), nearestSite: try site())
        )
        XCTAssertTrue(items.allSatisfy { $0.handler == nil })
        XCTAssertNil(row(.compare, in: items))
    }

    /// Chaque rangée porte sa pastille : c'est elle qui se lit avant le texte.
    func testEveryRowHasAnImage() throws {
        let inputs: [Builder.Input] = [
            .init(phase: .loading, path: cellularPath()),
            .init(path: cellularPath(), quality: quality(), nearestSite: try site(operators: ["SFR", "BOUYGUES"])),
            .init(path: cellularPath(nil), quality: nil),
            .init(phase: .withoutLocation, path: cellularPath()),
        ]
        for input in inputs {
            for item in Builder.items(for: input, actions: .init(compareOperators: {})) {
                XCTAssertNotNil(item.image, "\(String(describing: item.userInfo))")
            }
        }
    }

    /// L'encre suit le fond : noir sur le jaune « Moyen », blanc sur le violet 5G.
    func testBadgeInkStaysReadableOnItsFill() {
        func red(_ color: UIColor) -> CGFloat {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            XCTAssertTrue(color.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
            return red
        }
        XCTAssertEqual(red(CarPlayImageFactory.inkColor(on: CoverageQualityBand.fair.uiColor)), 0, accuracy: 0.01)
        XCTAssertEqual(red(CarPlayImageFactory.inkColor(on: SQQualityScale.Generation.fiveG.uiColor)), 1, accuracy: 0.01)
    }

    /// Le titre de l'onglet reste « Ici ».
    func testTemplateIsTitledHere() {
        let template = Builder.make(input: .init(phase: .loading, path: cellularPath()), actions: .init())
        XCTAssertEqual(template.title, String(localized: "Ici"))
        XCTAssertEqual(template.sections.count, 1)
    }
}
