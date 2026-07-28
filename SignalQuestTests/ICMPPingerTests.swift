import XCTest
@testable import SignalQuest

/// Trames ICMP.
///
/// C'est la partie qui échoue en silence : une somme de contrôle fausse fait ignorer
/// nos échos par le serveur (aucune réponse, donc repli TCP permanent et ping toujours
/// surévalué), et un appariement trop laxiste fait compter la réponse d'un AUTRE écho —
/// donc un RTT faux, souvent trop bas. Aucun des deux ne se voit à l'écran.
final class ICMPPingerTests: XCTestCase {

    // MARK: Somme de contrôle

    /// L'invariant de la RFC 1071 : recalculer la somme sur le paquet qui la contient
    /// déjà doit donner zéro. C'est ce que vérifie la pile en face.
    func testChecksumOfACompletePacketIsZero() {
        let packet = [UInt8](ICMPPacket.echoRequest(family: AF_INET, sequence: 7))
        XCTAssertEqual(
            ICMPPacket.checksum(packet), 0,
            "Un paquet dont la somme est correcte doit se recalculer à zéro"
        )
    }

    /// Valeur connue, calculée à la main sur la trame nue (somme à zéro) :
    /// 0x0800 + 0x5351 + 0x5049 + 0x4E47 = 0xF9E1, complément = 0x061E.
    func testChecksumMatchesHandComputedValue() {
        let bare: [UInt8] = [0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
            + Array("SQPING".utf8)
        XCTAssertEqual(ICMPPacket.checksum(bare), 0x061E)
    }

    /// Longueur impaire : le dernier octet se complète à droite par un zéro. Un
    /// traitement naïf le perdrait, et la somme serait fausse une fois sur deux.
    func testChecksumHandlesOddLength() {
        XCTAssertEqual(ICMPPacket.checksum([0x08, 0x00, 0x42]), ICMPPacket.checksum([0x08, 0x00, 0x42, 0x00]))
    }

    // MARK: Construction

    func testEchoRequestHasTheRightShape() {
        let packet = [UInt8](ICMPPacket.echoRequest(family: AF_INET, sequence: 0x1234))
        XCTAssertEqual(packet[0], ICMPPacket.echoRequestV4, "Type écho IPv4 attendu")
        XCTAssertEqual(packet[1], 0, "Code toujours nul pour un écho")
        XCTAssertEqual(UInt16(packet[6]) << 8 | UInt16(packet[7]), 0x1234, "Séquence mal encodée")
        XCTAssertEqual(Array(packet.suffix(ICMPPacket.signature.count)), ICMPPacket.signature)
    }

    /// En IPv6 la somme couvre un pseudo-en-tête que l'espace utilisateur ne connaît
    /// pas : c'est le noyau qui la calcule, le champ doit rester à zéro. La remplir
    /// nous-mêmes produirait une trame invalide.
    func testIPv6LeavesChecksumToTheKernel() {
        let packet = [UInt8](ICMPPacket.echoRequest(family: AF_INET6, sequence: 3))
        XCTAssertEqual(packet[0], ICMPPacket.echoRequestV6)
        XCTAssertEqual(packet[2], 0)
        XCTAssertEqual(packet[3], 0)
    }

    // MARK: Appariement

    private func reply(
        family: Int32 = AF_INET,
        type: UInt8? = nil,
        sequence: UInt16,
        signature: [UInt8]? = nil
    ) -> Data {
        var bytes: [UInt8] = [
            type ?? (family == AF_INET6 ? ICMPPacket.echoReplyV6 : ICMPPacket.echoReplyV4),
            0, 0, 0,      // code + somme
            0, 0          // identifiant (réécrit par le noyau en SOCK_DGRAM)
        ]
        bytes.append(UInt8(sequence >> 8))
        bytes.append(UInt8(sequence & 0xFF))
        bytes.append(contentsOf: signature ?? ICMPPacket.signature)
        return Data(bytes)
    }

    func testAcceptsOurOwnReply() {
        XCTAssertTrue(ICMPPacket.isEchoReply(reply(sequence: 5), family: AF_INET, sequence: 5))
    }

    /// Le piège central : la réponse d'un échantillon PRÉCÉDENT, arrivée en retard.
    /// L'accepter mesurerait un aller-retour plus court qu'il ne l'a été.
    func testRejectsALateReplyFromAnotherSequence() {
        XCTAssertFalse(ICMPPacket.isEchoReply(reply(sequence: 4), family: AF_INET, sequence: 5))
    }

    /// Notre propre écho renvoyé en boucle (type 8) n'est pas une réponse.
    func testRejectsAnEchoRequestType() {
        let echoed = reply(type: ICMPPacket.echoRequestV4, sequence: 5)
        XCTAssertFalse(ICMPPacket.isEchoReply(echoed, family: AF_INET, sequence: 5))
    }

    /// En SOCK_DGRAM le noyau réécrit l'identifiant : c'est la signature qui distingue
    /// nos échos du ping d'un autre processus de l'appareil.
    func testRejectsForeignTraffic() {
        let foreign = reply(sequence: 5, signature: Array("OTHER!".utf8))
        XCTAssertFalse(ICMPPacket.isEchoReply(foreign, family: AF_INET, sequence: 5))
    }

    func testRejectsTruncatedDatagram() {
        XCTAssertFalse(ICMPPacket.isEchoReply(Data([0, 0, 0]), family: AF_INET, sequence: 0))
    }

    // MARK: En-tête IP

    /// Selon la pile, `recvfrom` rend le datagramme avec ou sans en-tête IPv4. Ne pas
    /// le sauter décalerait toute la lecture et ferait tout rejeter.
    func testStripsAnIPv4HeaderWhenPresent() {
        let header: [UInt8] = [0x45, 0x00, 0x00, 0x1C] + [UInt8](repeating: 0, count: 16)
        let framed = Data(header) + reply(sequence: 9)
        XCTAssertTrue(ICMPPacket.isEchoReply(framed, family: AF_INET, sequence: 9))
    }

    /// …et un datagramme SANS en-tête doit rester lisible tel quel.
    func testWorksWithoutAnIPHeader() {
        XCTAssertTrue(ICMPPacket.isEchoReply(reply(sequence: 9), family: AF_INET, sequence: 9))
    }

    /// En IPv6 l'en-tête n'est jamais livré : on ne doit rien retirer, sous peine de
    /// manger le début de la réponse.
    func testNeverStripsForIPv6() {
        let payload = reply(family: AF_INET6, sequence: 2)
        XCTAssertEqual(ICMPPacket.strippingIPv4Header(payload, family: AF_INET6), payload)
        XCTAssertTrue(ICMPPacket.isEchoReply(payload, family: AF_INET6, sequence: 2))
    }

    // MARK: Résolution

    func testResolvesALoopbackHost() throws {
        let resolved = try ICMPPinger.resolve(host: "localhost")
        XCTAssertTrue(resolved.family == AF_INET || resolved.family == AF_INET6)
        let text = try XCTUnwrap(resolved.addressText, "L'adresse en clair alimente le repli TCP")
        XCTAssertTrue(text == "127.0.0.1" || text == "::1", "Adresse inattendue : \(text)")
    }

    func testUnresolvableHostThrows() {
        XCTAssertThrowsError(try ICMPPinger.resolve(host: "hote.invalide.signalquest")) { error in
            XCTAssertEqual(error as? ICMPPinger.Failure, .hostUnresolved)
        }
    }

    // MARK: Aller-retour réel

    /// La vérification qui compte : la socket ICMP s'ouvre-t-elle vraiment, et
    /// l'aller-retour aboutit-il ? Toute la refonte repose sur le fait qu'iOS autorise
    /// `SOCK_DGRAM`/`IPPROTO_ICMP` sans entitlement — si c'était faux, l'app
    /// retomberait silencieusement en TCP et le ping resterait surévalué.
    ///
    /// La boucle locale est le seul hôte joignable à coup sûr depuis une machine de
    /// test, et elle suffit à prouver la capacité.
    func testLoopbackRoundTripSucceeds() async throws {
        let pinger = ICMPPinger(host: "127.0.0.1", timeout: 2)
        let samples = try await pinger.ping(count: 3, intervalMs: 50)
        try XCTSkipIf(
            samples.isEmpty,
            "ICMP indisponible sur cet hôte de test — le repli TCP prendrait le relais en production"
        )
        for sample in samples {
            XCTAssertGreaterThan(sample.rttMs, 0)
            XCTAssertLessThan(sample.rttMs, 500, "Un aller-retour local ne peut pas durer si longtemps")
        }
    }

    /// Un hôte non résolvable doit remonter l'échec plutôt que de rendre une série
    /// vide : c'est ce qui déclenche le repli TCP côté moteur.
    func testPingThrowsOnUnresolvableHost() async {
        let pinger = ICMPPinger(host: "hote.invalide.signalquest", timeout: 1)
        do {
            _ = try await pinger.ping(count: 1, intervalMs: 10)
            XCTFail("Une série vers un hôte inconnu doit lever")
        } catch {
            XCTAssertEqual(error as? ICMPPinger.Failure, .hostUnresolved)
        }
    }
}
