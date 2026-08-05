import XCTest
@testable import SignalQuest

/// Mêmes cas que `apps/web/lib/sentinelle/ipv6-prefix.test.ts` et que son
/// portage Kotlin : la proposition d'adresse doit être IDENTIQUE sur le site,
/// sur Android et ici, sans quoi trois écrans donneraient trois réponses pour la
/// même box.
final class SentinelleIpv6Tests: XCTestCase {

    func testExpandDeveloppeLaCompression() {
        XCTAssertEqual(
            SentinelleIpv6.expand("2a04:800::1"),
            ["2a04", "0800", "0000", "0000", "0000", "0000", "0000", "0001"]
        )
        XCTAssertEqual(
            SentinelleIpv6.expand("::1"),
            ["0000", "0000", "0000", "0000", "0000", "0000", "0000", "0001"]
        )
        XCTAssertEqual(SentinelleIpv6.expand("2a04:0800:3622:f901:3d24:f39d:b88c:79c8")?.count, 8)
    }

    func testExpandRefuseCeQuiNEstPasUneIpv6Exploitable() {
        XCTAssertNil(SentinelleIpv6.expand("79.88.27.93"))
        // IPv4-mappée : pas de préfixe délégué.
        XCTAssertNil(SentinelleIpv6.expand("::ffff:192.168.1.1"))
        XCTAssertNil(SentinelleIpv6.expand("2a04:800::1::2"))
        XCTAssertNil(SentinelleIpv6.expand("2a04:800:3622:f901:3d24:f39d:b88c"))
        XCTAssertNil(SentinelleIpv6.expand("zzzz::1"))
        XCTAssertNil(SentinelleIpv6.expand(""))
    }

    func testExpandTolereLesCrochetsEtLIdentifiantDeZone() {
        XCTAssertEqual(SentinelleIpv6.expand("[2a04:800::1]")?.first, "2a04")
        XCTAssertEqual(SentinelleIpv6.expand("fe80::1%en0")?.first, "fe80")
    }

    func testPrefixeExtraitEtPasserelleProposee() {
        let prefix = SentinelleIpv6.prefix(of: "2a04:800:3622:f901:3d24:f39d:b88c:79c8")
        XCTAssertEqual(prefix?.label, "2a04:800:3622:f901::/64")
        XCTAssertEqual(prefix?.gateway, "2a04:800:3622:f901::1")
    }

    /// Le cas qui justifie tout le module : le téléphone change de suffixe chaque
    /// jour, mais le préfixe délégué par l'opérateur, lui, ne bouge pas.
    func testDeuxAdressesDuMemePrefixeDonnentLaMemePasserelle() {
        let first = SentinelleIpv6.prefix(of: "2a04:800:3622:f901:3d24:f39d:b88c:79c8")
        let second = SentinelleIpv6.prefix(of: "2a04:800:3622:f901:b417:266b:8e93:86")
        XCTAssertEqual(first?.gateway, second?.gateway)
        XCTAssertEqual(second?.gateway, "2a04:800:3622:f901::1")
    }

    func testLesPlagesSansPrefixeDelegueSontRefusees() {
        XCTAssertNil(SentinelleIpv6.prefix(of: "::1"))
        XCTAssertNil(SentinelleIpv6.prefix(of: "::"))
        XCTAssertNil(SentinelleIpv6.prefix(of: "fe80::1"))
        XCTAssertNil(SentinelleIpv6.prefix(of: "fd00:1234::1"))
        XCTAssertNil(SentinelleIpv6.prefix(of: "79.88.27.93"))
    }

    func testUneAdresseEui64NEstPasTenuePourTemporaire() {
        // ...ff:fe... = identifiant dérivé de l'adresse MAC, donc stable.
        XCTAssertFalse(SentinelleIpv6.looksTemporary("2a04:800:3622:f901:021a:2bff:fe3c:4d5e"))
    }

    func testUneAdresseCourteConfigureeALaMainNEstPasTenuePourTemporaire() {
        XCTAssertFalse(SentinelleIpv6.looksTemporary("2a04:800:3622:f901::1"))
        XCTAssertFalse(SentinelleIpv6.looksTemporary("2a04:800:3622:f901::dead"))
    }

    func testUnIdentifiantDInterfaceAleatoireEstTenuPourTemporaire() {
        XCTAssertTrue(SentinelleIpv6.looksTemporary("2a04:800:3622:f901:3d24:f39d:b88c:79c8"))
        XCTAssertTrue(SentinelleIpv6.looksTemporary("2a04:800:3622:f901:b417:266b:8e93:86"))
    }

    func testLaPropositionRemplaceUneAdresseTemporaireParLaPasserelle() {
        let result = SentinelleIpv6.suggestBoxAddress(observed: "2a04:800:3622:f901:3d24:f39d:b88c:79c8")
        XCTAssertEqual(result.suggested, "2a04:800:3622:f901::1")
        XCTAssertEqual(result.prefix?.label, "2a04:800:3622:f901::/64")
        XCTAssertTrue(result.warning?.contains("change régulièrement") == true)
    }

    func testUneAdresseDejaStableEstProposeeTelleQuelle() {
        let result = SentinelleIpv6.suggestBoxAddress(observed: "2a04:800:3622:f901::1")
        XCTAssertEqual(result.suggested, "2a04:800:3622:f901::1")
        XCTAssertNil(result.warning)
    }

    func testUneEntreeNonIpv6TraverseSansEtreTransformee() {
        let result = SentinelleIpv6.suggestBoxAddress(observed: "79.88.27.93")
        XCTAssertEqual(result.suggested, "79.88.27.93")
        XCTAssertNil(result.prefix)
        XCTAssertNil(result.warning)
    }
}

/// Ce que ces tests protègent : la panne que le modèle box → adresse doit rendre
/// visible. Une IPv6 morte pendant que l'IPv4 répond ne doit ni disparaître dans
/// la moyenne de la box, ni se confondre avec « pas encore de mesure ».
final class SentinelleReadingTests: XCTestCase {

    // MARK: Outils

    /// Les points sont décodés depuis du JSON plutôt que construits à la main :
    /// ils n'existent que par le réseau, et le décodage fait donc partie de ce
    /// qu'il faut vérifier.
    private func points(_ rows: [String]) throws -> [SentinelleSeriesPoint] {
        try JSONDecoder.signalQuest.decode(
            [SentinelleSeriesPoint].self,
            from: Data("[\(rows.joined(separator: ","))]".utf8)
        )
    }

    private func point(minute: Int, family: String, loss: Double?, rtt: Double? = 12) -> String {
        let at = String(format: "2026-08-01T10:%02d:00.000Z", minute)
        let lossField = loss.map { "\($0)" } ?? "null"
        let rttField = rtt.map { "\($0)" } ?? "null"
        return """
        {"at":"\(at)","family":"\(family)","lossPct":\(lossField),"rttAvgMs":\(rttField),"jitterMs":1}
        """
    }

    // MARK: État d'une adresse

    func testSansMesureAucunVerdict() {
        let empty: [SentinelleSeriesPoint] = []
        XCTAssertEqual(empty.addressState, .unknown)
        XCTAssertNil(empty.addressMetrics)
    }

    func testToutPerduDonneUneAdresseTombee() throws {
        let series = try points((0..<3).map { point(minute: $0, family: "v6", loss: 100, rtt: nil) })
        XCTAssertEqual(series.addressState, .down)
    }

    func testUnePerteIsoleeNeSuffitPasAConclureALaPanne() throws {
        let series = try points([
            point(minute: 0, family: "v4", loss: 0),
            point(minute: 1, family: "v4", loss: 20),
            point(minute: 2, family: "v4", loss: 0),
        ])
        XCTAssertEqual(series.addressState, .degraded)
    }

    func testToutRepondDonneUneAdresseEnLigne() throws {
        let series = try points((0..<3).map { point(minute: $0, family: "v4", loss: 0) })
        XCTAssertEqual(series.addressState, .up)
    }

    /// Le serveur n'a pas renvoyé `lossPct` : inventer « en ligne » serait aussi
    /// faux qu'inventer « tombée ».
    func testSansTauxDePerteOnNeConclutRien() throws {
        let series = try points((0..<3).map { point(minute: $0, family: "v4", loss: nil) })
        XCTAssertEqual(series.addressState, .unknown)
    }

    // MARK: Agrégats

    func testLaFamilleMorteEstVisibleSurSesPropresAgregats() throws {
        let series = try points((0..<4).map { point(minute: $0, family: "v6", loss: 100, rtt: nil) })
        let metrics = try XCTUnwrap(series.addressMetrics)
        XCTAssertEqual(metrics.uptimePct, 0, accuracy: 1e-9)
        // Aucune réponse : pas de latence à avancer, et surtout pas un zéro.
        XCTAssertNil(metrics.rttMs)
    }

    /// Le cas réel : IPv6 épinglée sur l'adresse du téléphone, donc morte,
    /// pendant que l'IPv4 de la box n'a jamais cessé de répondre.
    func testLaBoxResteJoignableTantQuUneFamilleRepond() throws {
        let series = try points((0..<4).flatMap { minute in
            [
                point(minute: minute, family: "v4", loss: 0),
                point(minute: minute, family: "v6", loss: 100, rtt: nil),
            ]
        })
        let box = try XCTUnwrap(series.boxMetrics)
        XCTAssertEqual(box.uptimePct, 100, accuracy: 1e-9)

        // …mais la lecture par famille, elle, ne masque rien.
        XCTAssertEqual(series.inFamily(.v6).addressState, .down)
        XCTAssertEqual(series.inFamily(.v4).addressState, .up)
    }

    // MARK: Décodage

    /// Une famille inconnue ne doit pas emporter tout le tableau : le point
    /// existe, il n'est simplement rattaché à aucune pile.
    func testUneFamilleInattendueNeCassePasLeDecodage() throws {
        let series = try points([point(minute: 0, family: "v9", loss: 0)])
        XCTAssertEqual(series.count, 1)
        XCTAssertNil(series[0].family)
        XCTAssertTrue(series.inFamily(.v4).isEmpty)
    }

    /// Une cible suivie dans une seule famille doit proposer l'autre — c'est
    /// tout l'objet de la ligne « Suivie en IPv4 seulement ».
    func testUneCibleSuivieEnIpv4ProposeLIpv6() throws {
        let target = try JSONDecoder.signalQuest.decode(SentinelleTarget.self, from: Data("""
        {"id":"t1","label":"Ma box","hostname":null,"ipv4":"79.88.27.93","ipv6":null,
         "resolvedIpv4":null,"resolvedIpv6":null,"status":"up","protocol":"icmp","isActive":true}
        """.utf8))
        XCTAssertEqual(target.missingFamily, .v6)
        XCTAssertEqual(target.addresses.map(\.family), [.v4])
        XCTAssertFalse(target.addresses[0].fromHostname)
    }

    /// Une cible en nom d'hôte n'a RIEN à proposer : ses deux familles sont
    /// résolues à chaque cycle, et elles ne se saisissent pas.
    func testUneCibleEnNomDHoteNeProposeRien() throws {
        let target = try JSONDecoder.signalQuest.decode(SentinelleTarget.self, from: Data("""
        {"id":"t2","label":"Ma box","hostname":"box.exemple.fr","ipv4":null,"ipv6":null,
         "resolvedIpv4":"79.88.27.93","resolvedIpv6":"2a04:800:3622:f901::1",
         "status":"up","protocol":"icmp","isActive":true}
        """.utf8))
        XCTAssertNil(target.missingFamily)
        XCTAssertEqual(target.addresses.count, 2)
        XCTAssertTrue(target.addresses.allSatisfy(\.fromHostname))
    }

    // MARK: Tracé

    /// Une coupure doit laisser un TROU dans la courbe : un segment qui la
    /// traverserait dessinerait une ligne en bonne santé pendant la panne.
    func testUneCoupureBriseLeTraceEnDeuxSegments() throws {
        let series = try points([
            point(minute: 0, family: "v4", loss: 0),
            point(minute: 1, family: "v4", loss: 0),
            point(minute: 2, family: "v4", loss: 100, rtt: nil),
            point(minute: 3, family: "v4", loss: 0),
            point(minute: 4, family: "v4", loss: 0),
        ])
        let latency = SentinelleLatencySeries(points: series, family: .v4)
        XCTAssertEqual(Set(latency.samples.map(\.segment)), [0, 1])
        XCTAssertEqual(latency.lostCount, 1)
        // La plage perdue est élargie d'un demi-pas de chaque côté, sinon elle
        // n'aurait aucune largeur et resterait invisible.
        XCTAssertEqual(latency.outages.count, 1)
        let span = try XCTUnwrap(latency.outages.first)
        XCTAssertGreaterThan(span.end.timeIntervalSince(span.start), 0)
    }

    func testUneFenetreEntierementPerdueSeDistingueDUneFenetreVide() throws {
        let allLost = SentinelleLatencySeries(
            points: try points((0..<3).map { point(minute: $0, family: "v4", loss: 100, rtt: nil) }),
            family: .v4
        )
        XCTAssertTrue(allLost.allLost)
        XCTAssertFalse(allLost.isEmpty)

        let empty = SentinelleLatencySeries(points: [], family: .v4)
        XCTAssertFalse(empty.allLost)
        XCTAssertTrue(empty.isEmpty)
    }
}

/// Ordre et regroupement de la liste des box.
///
/// `SentinelleListOrder.swift` affirme dans son en-tête que « les trois
/// plateformes doivent trier IDENTIQUEMENT » et renvoie aux huit tests du web
/// comme référence normative — sans qu'aucun test iOS ne le vérifie. Ce sont les
/// mêmes cas que `list-order.test.ts` et que le portage Kotlin.
final class SentinelleListOrderTests: XCTestCase {

    private struct Box: SentinelleListOrder.Orderable {
        let orderLabel: String
        let orderStatus: String
        var orderOperator: String?
        var orderUptimePct: Double?
    }

    func testLeTriParEtatMetLePireEnTete() {
        // C'est la raison d'ouvrir la page : une liste qui commence par ce qui va
        // bien oblige à chercher ce qui ne va pas.
        let boxes = [
            Box(orderLabel: "saine", orderStatus: "up"),
            Box(orderLabel: "inconnue", orderStatus: "unknown"),
            Box(orderLabel: "morte", orderStatus: "down"),
            Box(orderLabel: "moyenne", orderStatus: "degraded"),
        ]
        XCTAssertEqual(
            SentinelleListOrder.sorted(boxes, by: .state).map(\.orderLabel),
            ["morte", "moyenne", "inconnue", "saine"]
        )
    }

    func testUneBoxSansMesurePasseEnQueueDuTriParDisponibilite() {
        // Sans donnée elle n'est pas « parfaite », elle est inconnue : la placer
        // devant une box à 91 % ferait passer l'ignorance pour une bonne nouvelle.
        let boxes = [
            Box(orderLabel: "sans mesure", orderStatus: "unknown", orderUptimePct: nil),
            Box(orderLabel: "bonne", orderStatus: "up", orderUptimePct: 99.9),
            Box(orderLabel: "mediocre", orderStatus: "degraded", orderUptimePct: 91.0),
        ]
        XCTAssertEqual(
            SentinelleListOrder.sorted(boxes, by: .uptime).map(\.orderLabel),
            ["mediocre", "bonne", "sans mesure"]
        )
    }

    func testLOperateurInconnuFormeUnGroupePlaceEnDernier() {
        // Les fondre dans un groupe existant serait un mensonge ; les cacher
        // ferait disparaître une connexion de la liste.
        let boxes = [
            Box(orderLabel: "x", orderStatus: "up", orderOperator: nil),
            Box(orderLabel: "y", orderStatus: "up", orderOperator: "SFR"),
            Box(orderLabel: "z", orderStatus: "up", orderOperator: "FREE"),
        ]
        let buckets = SentinelleListOrder.grouped(boxes, by: .operatorKey, sort: .name)
        XCTAssertEqual(buckets.map(\.key), ["FREE", "SFR", SentinelleListOrder.unknownOperator])
    }

    func testLeTriDemandeSAppliqueDansChaqueGroupe() {
        let boxes = [
            Box(orderLabel: "sfr-saine", orderStatus: "up", orderOperator: "SFR"),
            Box(orderLabel: "sfr-morte", orderStatus: "down", orderOperator: "SFR"),
            Box(orderLabel: "free-saine", orderStatus: "up", orderOperator: "FREE"),
        ]
        let buckets = SentinelleListOrder.grouped(boxes, by: .operatorKey, sort: .state)
        let sfr = buckets.first { $0.key == "SFR" }
        XCTAssertEqual(sfr?.boxes.map(\.orderLabel), ["sfr-morte", "sfr-saine"])
    }

    func testSansRegroupementLaCleEstNulle() {
        let boxes = [Box(orderLabel: "b", orderStatus: "up"), Box(orderLabel: "a", orderStatus: "down")]
        let buckets = SentinelleListOrder.grouped(boxes, by: .none, sort: .state)
        XCTAssertEqual(buckets.count, 1)
        XCTAssertNil(buckets[0].key)
        XCTAssertEqual(buckets[0].boxes.map(\.orderLabel), ["a", "b"])
    }
}

/// Extraction du jeton d'un lien de partage.
///
/// `SentinelleShareLink.swift` annonce une parité stricte avec Android sans
/// qu'aucun test ne la vérifie — alors que c'est le premier geste de quelqu'un
/// qui vient de recevoir un lien par message.
final class SentinelleShareLinkTests: XCTestCase {

    func testUneUrlComplete() {
        XCTAssertEqual(
            SentinelleShareLink.extractSlug("https://signalquest.fr/sentinelle/p/AbC123xyz"),
            "AbC123xyz"
        )
    }

    func testUnJetonNu() {
        // On accepte le code seul : exiger « extrayez le jeton » serait une
        // demande gratuite adressée à quelqu'un qui vient de coller un message.
        XCTAssertEqual(SentinelleShareLink.extractSlug("AbC123xyz"), "AbC123xyz")
    }

    func testLesEspacesEtLaPonctuationSontRognes() {
        XCTAssertEqual(
            SentinelleShareLink.extractSlug("  https://signalquest.fr/sentinelle/p/AbC123xyz  "),
            "AbC123xyz"
        )
    }

    func testUneChaineVideNeDonneRien() {
        XCTAssertNil(SentinelleShareLink.extractSlug("   "))
    }
}
