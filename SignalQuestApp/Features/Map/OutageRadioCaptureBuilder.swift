import Foundation

/**
 Compose la capture réseau jointe à un signalement de panne.

 ── Pourquoi c'est si peu, et pourquoi c'est quand même utile ──

 iOS n'expose ni RSRP, ni RSRQ, ni PCI, ni identifiant de cellule, ni bande, ni ARFCN. Ce n'est pas
 une lacune de cette fonction : c'est une limite des API publiques d'Apple, actée dans `CLAUDE.md`
 (« ne tente pas d'ajouter du scan modem ») et dans le README. Le détail radio d'une panne vient
 d'Android ; iOS apporte autre chose — un constat daté, situé, et honnêtement étiqueté.

 Ce qui reste lisible permet de signaler la génération et l'opérateur exposés, ainsi que la
 disponibilité du chemin Internet. Un chemin indisponible ne prouve pas, à lui seul, l'absence
 de service cellulaire.

 ── Ce que cette fonction refuse de faire ──

 Elle n'invente aucune valeur absente. Pas de `serving` fabriqué à partir de la génération, pas de
 niveau estimé : le serveur étiquette la capture « partielle — iOS » à partir de `platform`, et
 remplir des champs vides de valeurs plausibles ferait exactement ce que cette étiquette existe
 pour empêcher.
 */
enum OutageRadioCaptureBuilder {

    /// Version du format partagé (`@sq/core/outage-radio-context`).
    static let version = 1

    /**
     Construit la capture depuis l'état réseau courant.

     - Parameters:
       - status: l'état lu par `NetworkPathMonitor` — génération, opérateur, chemin.
       - position: la position, si elle est connue. Jamais publiée par le serveur.
       - pingMs: la latence mesurée, quand une sonde a pu tourner.
       - isOnline: `NetworkPathMonitor.isOnline`, état du chemin Internet. Hors ligne ne
         prouve pas une absence de service cellulaire (VPN, politique réseau, données coupées).
       - viaVpn: un tunnel fausse l'attribution d'opérateur par IP ; le dire évite un faux constat.
     */
    static func make(
        status: NetworkPathStatus,
        isOnline: Bool,
        position: (latitude: Double, longitude: Double, accuracy: Double?)?,
        pingMs: Double? = nil,
        viaVpn: Bool? = nil,
        now: Date = Date()
    ) -> OutageRadioCapture {
        // Seul un chemin Internet cellulaire actif prouve ici un service positif. Ni un
        // chemin IP indisponible ni le Wi-Fi ne prouvent une coupure du réseau mobile.
        let state = isOnline && status.connection == .cellular ? "in_service" : "unknown"

        let capturedAt = ISO8601DateFormatter().string(from: now)

        return OutageRadioCapture(
            v: version,
            platform: "ios",
            capturedAt: capturedAt,
            state: state,
            // La génération courante tient lieu de « technologie de repli » : c'est la seule
            // information de niveau radio qu'iOS rende, et elle dit si le téléphone est retombé.
            fallbackTechnology: isOnline ? status.cellularTechnology?.displayName : nil,
            connection: isOnline ? connectionToken(status.connection) : "other",
            viaVpn: viaVpn,
            operator: OutageRadioOperator(
                name: isOnline ? status.operatorName : nil,
                mcc: isOnline ? status.operatorMcc : nil,
                mnc: isOnline ? status.operatorMnc : nil,
                // `sim` seulement quand CoreTelephony a répondu : depuis iOS 16.4 il rend souvent
                // un placeholder, et l'opérateur vient alors d'une résolution serveur par IP.
                source: isOnline && status.operatorName != nil ? "sim" : "unknown"
            ),
            position: position.map {
                OutageRadioPosition(lat: $0.latitude, lng: $0.longitude, accuracyM: $0.accuracy)
            },
            probe: pingMs.map { OutageRadioProbe(pingMs: $0, dnsOk: nil) }
        )
    }

    /// Le vocabulaire du contrat partagé, distinct des libellés affichés.
    private static func connectionToken(_ kind: NetworkConnectionKind) -> String {
        switch kind {
        case .wifi: return "wifi"
        case .cellular: return "cellular"
        case .wired: return "wired"
        case .other: return "other"
        }
    }

    /**
     Le résumé montré à la personne AVANT l'envoi.

     Rédigé ici et non par le serveur : il faut savoir ce qu'on joint au moment où on décide de le
     joindre. Le serveur, lui, rédige le résumé PUBLIC, qui est un autre texte pour un autre
     lecteur — et sans position.
     */
    static func previewText(status: NetworkPathStatus, isOnline: Bool) -> String {
        guard isOnline else {
            return String(localized: "Connexion indisponible") + " · "
                + String(localized: "État du réseau inconnu")
        }
        switch status.connection {
        case .cellular:
            let tech = status.cellularTechnology?.displayName ?? String(localized: "Cellulaire")
            if let name = status.operatorName {
                return "\(tech) · \(name)"
            }
            return tech
        case .wifi:
            return String(localized: "Wi-Fi — aucun réseau mobile mesurable")
        default:
            return String(localized: "État du réseau inconnu")
        }
    }
}
