import Darwin
import Foundation

/// Écho ICMP — la mesure de latence de référence.
///
/// Le speedtest chronométrait jusqu'ici un `connect` TCP, et son chronomètre partait
/// AVANT `NWConnection.start()` : chaque échantillon englobait la résolution DNS,
/// l'évaluation de chemin et la création d'une file d'attente. D'où un ping
/// systématiquement au-dessus de ce que rapporte `ping` en ligne de commande.
///
/// iOS autorise l'ICMP **sans entitlement** via une socket `SOCK_DGRAM` (et non
/// `SOCK_RAW`, qui exige les privilèges root) : c'est le mécanisme de l'exemple
/// `SimplePing` d'Apple. Ici le chronomètre n'entoure que `send` → `recv`.
///
/// ## Deux pièges du mode `SOCK_DGRAM`
///
/// 1. **L'identifiant ne nous appartient pas.** En `SOCK_DGRAM`, le noyau réécrit le
///    champ identifiant de l'écho avec le sien pour démultiplexer les réponses entre
///    processus. Apparier les réponses sur l'identifiant qu'on a écrit ne marche donc
///    pas : on apparie sur le **numéro de séquence** et sur une signature placée dans
///    la charge utile.
/// 2. **L'en-tête IP est parfois présent.** Selon la pile, `recvfrom` rend le datagramme
///    avec ou sans en-tête IPv4. On le détecte (version 4 dans le quartet de poids fort)
///    et on le saute le cas échéant. En IPv6, l'en-tête n'est jamais livré.
struct ICMPPinger: Sendable {

    enum Failure: Error, Equatable {
        /// La socket ICMP n'a pas pu être ouverte — réseau restreint, sandbox, ou pile
        /// sans ICMP. C'est le signal qui déclenche le repli TCP.
        case socketUnavailable
        case hostUnresolved
        case timedOut
    }

    /// Un aller-retour réussi.
    struct Sample: Sendable {
        let rttMs: Double
        let sequence: UInt16
    }

    let host: String
    /// Délai maximal d'attente d'une réponse, par échantillon.
    let timeout: TimeInterval

    init(host: String, timeout: TimeInterval = 2) {
        self.host = host
        self.timeout = timeout
    }

    // MARK: Série

    /// Envoie `count` échos espacés de `intervalMs` et renvoie les allers-retours
    /// réussis. Les pertes ne lèvent pas d'erreur : sur un lien mobile, perdre un
    /// paquet est une information, pas une panne.
    ///
    /// Lève `socketUnavailable` ou `hostUnresolved` — les deux seuls cas où le repli
    /// TCP doit prendre la main, parce qu'aucun échantillon ne sera jamais produit.
    func ping(count: Int, intervalMs: Double) async throws -> [Sample] {
        let resolved = try Self.resolve(host: host)
        let handle = try ICMPSocketHandle(family: resolved.family)
        defer { handle.close() }

        var samples: [Sample] = []
        for sequence in 0..<UInt16(max(0, min(count, Int(UInt16.max)))) {
            if Task.isCancelled { break }
            if let sample = handle.roundTrip(
                to: resolved,
                sequence: sequence,
                timeout: timeout
            ) {
                samples.append(sample)
            }
            if sequence + 1 < UInt16(count) {
                try? await Task.sleep(nanoseconds: UInt64(max(0, intervalMs) * 1_000_000))
            }
        }
        return samples
    }

    // MARK: Résolution

    struct ResolvedHost: @unchecked Sendable {
        let family: Int32
        let storage: sockaddr_storage
        let length: socklen_t

        /// Adresse en clair (« 51.210.0.1 », « 2001:db8::1 »), à passer à la sonde TCP
        /// de repli : lui donner un NOM la ferait résoudre à chaque échantillon, dans
        /// la fenêtre chronométrée.
        var addressText: String? {
            var storage = self.storage
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = withUnsafePointer(to: &storage) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    getnameinfo(
                        address, length,
                        &buffer, socklen_t(buffer.count),
                        nil, 0,
                        NI_NUMERICHOST
                    )
                }
            }
            guard status == 0 else { return nil }
            return String(cString: buffer)
        }
    }

    /// Résout l'hôte UNE fois pour toute la série. C'est ce qui sort le DNS de la
    /// mesure : la sonde TCP repassait un nom d'hôte à chaque échantillon, donc chaque
    /// échantillon pouvait payer une résolution.
    static func resolve(host: String) throws -> ResolvedHost {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
            throw Failure.hostUnresolved
        }
        defer { freeaddrinfo(result) }

        // Préférer IPv4 quand les deux existent : les POP publics du catalogue
        // répondent tous en v4, et l'ICMPv6 est plus souvent filtré.
        var candidate: UnsafeMutablePointer<addrinfo>? = first
        var chosen: UnsafeMutablePointer<addrinfo>?
        while let node = candidate {
            if node.pointee.ai_family == AF_INET { chosen = node; break }
            if chosen == nil, node.pointee.ai_family == AF_INET6 { chosen = node }
            candidate = node.pointee.ai_next
        }
        guard let selected = chosen else { throw Failure.hostUnresolved }

        var storage = sockaddr_storage()
        memcpy(&storage, selected.pointee.ai_addr, Int(selected.pointee.ai_addrlen))
        return ResolvedHost(
            family: selected.pointee.ai_family,
            storage: storage,
            length: selected.pointee.ai_addrlen
        )
    }
}

// MARK: - Socket

/// Enveloppe d'une socket ICMP. Les appels sont bloquants et volontairement synchrones :
/// `recvfrom` avec `SO_RCVTIMEO` borne l'attente, et l'ensemble tourne hors du fil
/// principal (voir l'appelant).
private struct ICMPSocketHandle {
    let descriptor: Int32
    let family: Int32

    init(family: Int32) throws {
        let proto = family == AF_INET6 ? IPPROTO_ICMPV6 : IPPROTO_ICMP
        let fd = socket(family, SOCK_DGRAM, proto)
        guard fd >= 0 else { throw ICMPPinger.Failure.socketUnavailable }
        self.descriptor = fd
        self.family = family
    }

    func close() { Darwin.close(descriptor) }

    /// Un aller-retour. `nil` = perdu ou expiré ; ce n'est pas une erreur.
    func roundTrip(
        to target: ICMPPinger.ResolvedHost,
        sequence: UInt16,
        timeout: TimeInterval
    ) -> ICMPPinger.Sample? {
        var tv = timeval(
            tv_sec: Int(timeout),
            tv_usec: Int32((timeout - floor(timeout)) * 1_000_000)
        )
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let packet = ICMPPacket.echoRequest(family: family, sequence: sequence)
        var storage = target.storage
        let sent: Int = withUnsafePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                packet.withUnsafeBytes { buffer in
                    sendto(descriptor, buffer.baseAddress, buffer.count, 0, address, target.length)
                }
            }
        }
        guard sent > 0 else { return nil }

        // Le chronomètre démarre ICI, une fois le paquet parti : tout ce qui précède
        // (résolution, ouverture de socket, options) est hors mesure.
        let start = DispatchTime.now()
        let deadline = Date().addingTimeInterval(timeout)

        var buffer = [UInt8](repeating: 0, count: 1_024)
        // Une réponse d'un autre écho (autre séquence, ou trafic ICMP concurrent) ne
        // doit pas être comptée : on relit jusqu'à trouver LA nôtre ou expirer.
        while Date() < deadline {
            let received = buffer.withUnsafeMutableBytes { raw in
                recvfrom(descriptor, raw.baseAddress, raw.count, 0, nil, nil)
            }
            guard received > 0 else { return nil }
            let elapsedNs = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
            let payload = Data(buffer[0..<received])
            if ICMPPacket.isEchoReply(payload, family: family, sequence: sequence) {
                return ICMPPinger.Sample(rttMs: Double(elapsedNs) / 1_000_000, sequence: sequence)
            }
        }
        return nil
    }
}

// MARK: - Trames

/// Construction et lecture des trames ICMP. Volontairement séparé de la socket : c'est
/// la partie qu'on peut tester sans réseau, et c'est là que se logent les erreurs
/// silencieuses (somme de contrôle fausse, appariement trop laxiste).
enum ICMPPacket {

    static let echoRequestV4: UInt8 = 8
    static let echoReplyV4: UInt8 = 0
    static let echoRequestV6: UInt8 = 128
    static let echoReplyV6: UInt8 = 129

    /// Signature placée dans la charge utile. En `SOCK_DGRAM` le noyau réécrit
    /// l'identifiant, donc c'est elle — avec le numéro de séquence — qui distingue nos
    /// réponses de tout autre trafic ICMP de l'appareil.
    static let signature: [UInt8] = Array("SQPING".utf8)

    /// Écho complet, prêt à être envoyé.
    ///
    /// En IPv6 la somme de contrôle est calculée par le noyau (elle couvre un
    /// pseudo-en-tête que l'espace utilisateur ne connaît pas) : on laisse le champ à
    /// zéro. En IPv4 on la calcule nous-mêmes.
    static func echoRequest(family: Int32, sequence: UInt16, identifier: UInt16 = 0) -> Data {
        let isV6 = family == AF_INET6
        var packet = [UInt8]()
        packet.append(isV6 ? echoRequestV6 : echoRequestV4)   // type
        packet.append(0)                                       // code
        packet.append(contentsOf: [0, 0])                      // somme de contrôle
        packet.append(UInt8(identifier >> 8))
        packet.append(UInt8(identifier & 0xFF))
        packet.append(UInt8(sequence >> 8))
        packet.append(UInt8(sequence & 0xFF))
        packet.append(contentsOf: signature)

        if !isV6 {
            let sum = checksum(packet)
            packet[2] = UInt8(sum >> 8)
            packet[3] = UInt8(sum & 0xFF)
        }
        return Data(packet)
    }

    /// Somme de contrôle Internet (RFC 1071) : complément à un de la somme en
    /// complément à un des mots de 16 bits.
    static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var index = 0
        while index + 1 < bytes.count {
            sum += UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1])
            index += 2
        }
        if index < bytes.count {
            // Longueur impaire : le dernier octet est complété à droite par un zéro.
            sum += UInt32(bytes[index]) << 8
        }
        while sum >> 16 != 0 {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }
        return UInt16(truncatingIfNeeded: ~sum)
    }

    /// Vrai si le datagramme est la réponse à NOTRE écho de ce numéro de séquence.
    ///
    /// Trois vérifications, et les trois comptent : le type (une réponse, pas notre
    /// propre écho renvoyé en boucle), la séquence (pas la réponse d'un échantillon
    /// précédent arrivée en retard — la compter fausserait le RTT à la baisse) et la
    /// signature (pas le ping d'un autre processus).
    static func isEchoReply(_ data: Data, family: Int32, sequence: UInt16) -> Bool {
        let body = strippingIPv4Header(data, family: family)
        guard body.count >= 8 + signature.count else { return false }
        let bytes = [UInt8](body)

        let expectedType = family == AF_INET6 ? echoReplyV6 : echoReplyV4
        guard bytes[0] == expectedType, bytes[1] == 0 else { return false }

        let replySequence = UInt16(bytes[6]) << 8 | UInt16(bytes[7])
        guard replySequence == sequence else { return false }

        return Array(bytes[8..<(8 + signature.count)]) == signature
    }

    /// Retire l'en-tête IPv4 si la pile l'a livré. En `SOCK_DGRAM` le comportement
    /// varie ; en IPv6 l'en-tête n'est jamais présent.
    static func strippingIPv4Header(_ data: Data, family: Int32) -> Data {
        guard family != AF_INET6, let first = data.first else { return data }
        guard first >> 4 == 4 else { return data }
        let headerLength = Int(first & 0x0F) * 4
        guard headerLength >= 20, data.count > headerLength else { return data }
        return data.subdata(in: headerLength..<data.count)
    }
}
