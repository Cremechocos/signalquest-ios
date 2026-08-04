import Foundation

/// Sentinelle — déduire l'adresse de la BOX à partir d'une adresse IPv6 vue.
///
/// Le piège que ce module existe pour éviter : en IPv4 il y a du NAT, donc
/// « mon adresse publique » EST celle de la box. En IPv6 il n'y en a pas —
/// chaque appareil porte sa propre adresse publique. Épingler « mon adresse
/// actuelle » épingle donc le TÉLÉPHONE, pas la box. Pire, les extensions de
/// confidentialité (RFC 4941) font tourner cette adresse tous les jours : la
/// cible enregistrée meurt en silence au bout de quelques heures.
///
/// Ce qui reste stable, c'est le PRÉFIXE /64 délégué par l'opérateur. On le
/// conserve et on propose l'adresse conventionnelle de la passerelle,
/// `<préfixe>::1`, qui est celle que servent la plupart des box grand public.
/// C'est une PROPOSITION, jamais une certitude : l'utilisateur doit pouvoir la
/// corriger, et l'interface doit le dire.
///
/// Transposition de `apps/web/lib/sentinelle/ipv6-prefix.ts` (et de son portage
/// Kotlin), cas de test compris. Le calcul est refait ici plutôt que demandé au
/// serveur parce qu'il porte sur une adresse que l'utilisateur est en train de
/// TAPER : un aller-retour réseau à chaque frappe rendrait la proposition
/// inutilisable.

/// Un préfixe /64 tel qu'on le manipule : les quatre premiers groupes.
struct SentinelleIpv6Prefix: Equatable, Sendable {
    /// Forme normalisée, sans compression, ex. « 2a04 », « 0800 », « 3622 », « f901 ».
    let groups: [String]
    /// Écriture lisible du préfixe, ex. « 2a04:800:3622:f901::/64 ».
    let label: String
    /// Adresse conventionnelle de la passerelle, ex. « 2a04:800:3622:f901::1 ».
    let gateway: String
}

/// Ce qu'il faut proposer à l'utilisateur pour une adresse IPv6 observée.
///
/// `suggested` est ce qu'on préremplit ; `warning` explique pourquoi ce n'est
/// pas l'adresse observée, quand c'est le cas. Rien n'est décidé à sa place :
/// le champ reste modifiable.
struct SentinelleIpv6Suggestion: Equatable, Sendable {
    let suggested: String
    let prefix: SentinelleIpv6Prefix?
    let warning: String?
}

enum SentinelleIpv6 {

    /// Développe une adresse IPv6 en huit groupes. Renvoie `nil` si l'entrée
    /// n'est pas une adresse IPv6 exploitable — y compris les formes
    /// IPv4-mappées, qui n'ont pas de préfixe délégué et n'ont rien à faire ici.
    static func expand(_ input: String) -> [String]? {
        var address = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if address.hasPrefix("[") { address.removeFirst() }
        if address.hasSuffix("]") { address.removeLast() }
        // Identifiant de zone (`fe80::1%en0`) : il désigne une interface locale,
        // pas un réseau.
        address = String(address.prefix(while: { $0 != "%" }))

        guard !address.isEmpty, !address.contains(".") else { return nil }
        guard address.allSatisfy({ hexDigits.contains($0) || $0 == ":" }) else { return nil }

        let doubleColon = address.components(separatedBy: "::")
        guard doubleColon.count <= 2 else { return nil }

        let head = doubleColon[0].isEmpty ? [] : doubleColon[0].components(separatedBy: ":")
        let tail: [String]?
        if doubleColon.count < 2 {
            tail = nil
        } else {
            tail = doubleColon[1].isEmpty ? [] : doubleColon[1].components(separatedBy: ":")
        }

        guard let tail else {
            // Sans `::`, l'adresse doit être complète.
            guard head.count == 8, head.allSatisfy(isGroup) else { return nil }
            return head.map(pad)
        }

        let missing = 8 - head.count - tail.count
        guard missing >= 1 else { return nil }
        let groups = head + Array(repeating: "0", count: missing) + tail
        guard groups.count == 8, groups.allSatisfy(isGroup) else { return nil }
        return groups.map(pad)
    }

    /// Extrait le /64 d'une adresse IPv6 et propose l'adresse de passerelle.
    ///
    /// Renvoie `nil` pour tout ce qui n'a pas de préfixe délégué exploitable :
    /// adresse invalide, boucle locale, lien-local (`fe80::/10`) ou adresse
    /// unique locale (`fc00::/7`). Sonder ces plages n'aurait aucun sens depuis
    /// nos serveurs, et la validation de cible les refuserait de toute façon.
    static func prefix(of input: String) -> SentinelleIpv6Prefix? {
        guard let groups = expand(input) else { return nil }

        // Couvre `::` comme `::1` : ni l'un ni l'autre ne décrit un réseau domestique.
        if groups.prefix(7).allSatisfy({ $0 == "0000" }) { return nil }

        guard let first = UInt32(groups[0], radix: 16) else { return nil }
        // fe80::/10 (lien-local) et fc00::/7 (unique local).
        if first & 0xffc0 == 0xfe80 { return nil }
        if first & 0xfe00 == 0xfc00 { return nil }

        let head = Array(groups.prefix(4))
        let readable = head.map(trimLeadingZeros).joined(separator: ":")
        return SentinelleIpv6Prefix(
            groups: head,
            label: "\(readable)::/64",
            gateway: "\(readable)::1"
        )
    }

    /// Repère une adresse qui porte les marques d'une extension de confidentialité.
    ///
    /// On ne peut pas le prouver depuis l'extérieur, mais deux indices suffisent
    /// à justifier un avertissement : un identifiant d'interface qui n'est PAS
    /// au format EUI-64 (`....ff:fe..`) et qui n'est pas une valeur courte
    /// configurée à la main (`::1`, `::2`…). Dans ce cas l'adresse changera, et
    /// l'épingler revient à programmer une fausse alerte pour dans quelques heures.
    static func looksTemporary(_ input: String) -> Bool {
        guard let groups = expand(input) else { return false }

        let interfaceId = Array(groups.suffix(4))
        // EUI-64 : le motif ff:fe est inséré au milieu de l'adresse MAC.
        if interfaceId[1].hasSuffix("ff") && interfaceId[2].hasPrefix("fe") { return false }

        // Adresse configurée à la main : presque tous les groupes à zéro.
        if interfaceId.filter({ $0 == "0000" }).count >= 3 { return false }

        return true
    }

    /// Voir ``SentinelleIpv6Suggestion``.
    static func suggestBoxAddress(observed: String) -> SentinelleIpv6Suggestion {
        guard let prefix = prefix(of: observed) else {
            return SentinelleIpv6Suggestion(suggested: observed, prefix: nil, warning: nil)
        }

        guard looksTemporary(observed) else {
            return SentinelleIpv6Suggestion(suggested: observed, prefix: prefix, warning: nil)
        }

        return SentinelleIpv6Suggestion(
            suggested: prefix.gateway,
            prefix: prefix,
            // Littéral d'un seul tenant : `String(localized:)` attend une
            // `LocalizationValue`, et deux littéraux concaténés par `+` donnent
            // une `String` — la clé serait perdue pour le catalogue.
            warning: String(localized: "L’adresse IPv6 de cet appareil change régulièrement : la surveiller reviendrait à déclencher une fausse alerte dès demain. Nous proposons l’adresse habituelle de votre box sur le même préfixe — corrigez-la si la vôtre diffère.")
        )
    }

    private static let hexDigits = Set("0123456789abcdef")

    private static func isGroup(_ value: String) -> Bool {
        (1...4).contains(value.count) && value.allSatisfy { hexDigits.contains($0) }
    }

    private static func pad(_ value: String) -> String {
        String(repeating: "0", count: Swift.max(0, 4 - value.count)) + value
    }

    /// Retire les zéros de tête d'un groupe, pour l'écriture lisible.
    private static func trimLeadingZeros(_ group: String) -> String {
        let trimmed = group.drop(while: { $0 == "0" })
        return trimmed.isEmpty ? "0" : String(trimmed)
    }
}
