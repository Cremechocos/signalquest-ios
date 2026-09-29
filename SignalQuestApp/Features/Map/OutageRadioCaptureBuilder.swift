import Foundation

/**
 Compose la capture réseau jointe à un signalement de panne.

 ── Pourquoi c'est si peu, et pourquoi c'est quand même utile ──

 iOS n'expose ni RSRP, ni RSRQ, ni PCI, ni identifiant de cellule, ni bande, ni ARFCN. Ce n'est pas
 une lacune de cette fonction : c'est une limite des API publiques d'Apple, actée dans `CLAUDE.md`
 (« ne tente pas d'ajouter du scan modem ») et dans le README. Le détail radio d'une panne vient
 d'Android ; iOS apporte autre chose — un constat daté, situé, et honnêtement étiqueté.

 Ce qui reste lisible suffit à établir ce qui compte : y avait-il du réseau, de quelle génération,
 chez quel opérateur. « Plus de réseau depuis 12 min, dernière vue 4G » est une contribution
 réelle. Seule exception (décision du 29/09) : quand iOS coupe les données mobiles à l'app,
 l'absence d'Internet ne dit rien du réseau, et l'état reste inconnu.

 ── Ce que cette fonction refuse de faire ──

 Elle n'invente aucune valeur absente. Pas de `serving` fabriqué à partir de la génération, pas de
 niveau estimé : le serveur étiquette la capture « partielle — iOS » à partir de `platform`, et
 remplir des champs vides de valeurs plausibles ferait exactement ce que cette étiquette existe
 pour empêcher.
 */
enum OutageRadioCaptureBuilder {

    /// Version du format partagé (`@sq/core/outage-radio-context`).
    static let version = 1

    /// Au-delà, « plus de réseau depuis… » raconterait une nuit en arrière-plan, pas une panne.
    static let lastServingMaxAge: TimeInterval = 3 * 3600

    /**
     Construit la capture depuis l'état réseau courant.

     - Parameters:
       - status: l'état lu par `NetworkPathMonitor` — génération, opérateur, chemin.
       - position: la position, si elle est connue. Jamais publiée par le serveur.
       - pingMs: la latence mesurée, quand une sonde a pu tourner.
       - isOnline: `NetworkPathMonitor.isOnline`. Hors ligne = plus aucun réseau utilisable,
         sauf si `cellularDataDenied` : iOS refuse alors les données mobiles à l'app.
       - lastCellularLoss: le cellulaire vu au moment de la perte (`NetworkPathMonitor`) ; les
         champs de `status` sont déjà vidés quand le chemin tombe.
       - viaVpn: un tunnel fausse l'attribution d'opérateur par IP ; le dire évite un faux constat.
     */
    static func make(
        status: NetworkPathStatus,
        isOnline: Bool,
        position: (latitude: Double, longitude: Double, accuracy: Double?)?,
        pingMs: Double? = nil,
        viaVpn: Bool? = nil,
        lastCellularLoss: CellularServiceLoss? = nil,
        cellularDataDenied: Bool = false,
        now: Date = Date()
    ) -> OutageRadioCapture {
        let state: String
        if isOnline {
            // Le Wi-Fi ne dit rien du réseau MOBILE : on ne prétend pas qu'il fonctionne.
            state = status.connection == .cellular ? "in_service" : "unknown"
        } else {
            state = cellularDataDenied ? "unknown" : "out_of_service"
        }
        let loss = state == "out_of_service" ? recentLoss(lastCellularLoss, now: now) : nil
        let formatter = ISO8601DateFormatter()

        return OutageRadioCapture(
            v: version,
            platform: "ios",
            capturedAt: formatter.string(from: now),
            state: state,
            lastServing: loss.map {
                OutageRadioLastServing(
                    technology: $0.technology.displayName,
                    seenAt: formatter.string(from: $0.lostAt),
                    ageSeconds: Int(now.timeIntervalSince($0.lostAt).rounded())
                )
            },
            // La génération courante tient lieu de « technologie de repli » : c'est la seule
            // information de niveau radio qu'iOS rende, et elle dit si le téléphone est retombé.
            fallbackTechnology: isOnline ? status.cellularTechnology?.displayName : nil,
            connection: isOnline ? connectionToken(status.connection) : "other",
            viaVpn: viaVpn,
            operator: isOnline
                ? OutageRadioOperator(
                    name: status.operatorName,
                    mcc: status.operatorMcc,
                    mnc: status.operatorMnc,
                    // `sim` seulement quand CoreTelephony a répondu : depuis iOS 16.4 il rend
                    // souvent un placeholder, et l'opérateur vient alors d'une résolution par IP.
                    source: status.operatorName != nil ? "sim" : "unknown"
                )
                : OutageRadioOperator(
                    name: loss?.operatorName,
                    mcc: loss?.operatorMcc,
                    mnc: loss?.operatorMnc,
                    source: loss?.operatorName != nil ? "sim" : "unknown"
                ),
            position: position.map {
                OutageRadioPosition(lat: $0.latitude, lng: $0.longitude, accuracyM: $0.accuracy)
            },
            probe: pingMs.map { OutageRadioProbe(pingMs: $0, dnsOk: nil) }
        )
    }

    private static func recentLoss(_ loss: CellularServiceLoss?, now: Date) -> CellularServiceLoss? {
        guard let loss else { return nil }
        let age = now.timeIntervalSince(loss.lostAt)
        return age >= 0 && age <= lastServingMaxAge ? loss : nil
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
    static func previewText(
        status: NetworkPathStatus,
        isOnline: Bool,
        lastCellularLoss: CellularServiceLoss? = nil,
        cellularDataDenied: Bool = false,
        now: Date = Date()
    ) -> String {
        guard isOnline else {
            if cellularDataDenied {
                return String(localized: "Données mobiles coupées pour SignalQuest") + " · "
                    + String(localized: "État du réseau inconnu")
            }
            if let loss = recentLoss(lastCellularLoss, now: now) {
                let minutes = max(1, Int((now.timeIntervalSince(loss.lostAt) / 60).rounded()))
                let technology = loss.technology.displayName
                return String(localized: "Aucun réseau depuis \(minutes) min · dernière vue \(technology)")
            }
            return String(localized: "Aucun réseau — le constat sera daté de maintenant")
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
