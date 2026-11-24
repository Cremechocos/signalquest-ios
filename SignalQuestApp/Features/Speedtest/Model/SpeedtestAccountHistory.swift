import Foundation

/// Tests du compte absents de ce téléphone : réinstallation, autre iPhone, app
/// Android (UI-12). Un test local envoyé revient du serveur à quelques secondes
/// près ; un envoi retardé (hors réseau) se reconnaît à son débit identique.
enum SpeedtestAccountHistory {
    static let sameTestWindow: TimeInterval = 120
    static let delayedUploadWindow: TimeInterval = 24 * 3600

    static func accountOnly(_ account: [SocialShareableSpeedtest],
                            local: [SpeedtestRunResult]) -> [SocialShareableSpeedtest] {
        account.filter { test in
            !local.contains { isSameTest(test, $0) }
        }
    }

    static func isSameTest(_ test: SocialShareableSpeedtest, _ local: SpeedtestRunResult) -> Bool {
        // Heure de mesure servie (MEASURED-AT-1) : la fin de mesure locale
        // envoyée telle quelle ; le début (`createdAt`) reste reconnu pour les
        // tests envoyés le 09/11 avant ce correctif. 1 s de marge couvre une
        // route qui servirait la seconde sans millisecondes ; la fenêtre de
        // 24 h ne sert plus qu'aux tests d'avant le champ.
        if let measured = test.measuredAt {
            return abs(local.measurementEndedAt.timeIntervalSince(measured)) <= 1
                || abs(local.createdAt.timeIntervalSince(measured)) <= 1
        }
        guard let date = test.timestamp else { return false }
        let gap = abs(local.createdAt.timeIntervalSince(date))
        if gap <= sameTestWindow { return true }
        guard gap <= delayedUploadWindow, let download = test.downloadAverageMbps else { return false }
        let tolerance = max(0.05, local.downloadAverageMbps * 0.001)
        return abs(download - local.downloadAverageMbps) <= tolerance
    }
}

extension SpeedtestAccountHistory {
    /// Détail serveur d'un test du compte, mis à la forme d'un test local pour
    /// réutiliser la même fiche. Les ordres de repli sont ceux de la carte : la
    /// moyenne d'abord, puis le débit brut, qu'Android remplit avec le pic.
    /// `includesPrivateDetails` faux pour le test d'un autre membre : ni commune,
    /// ni adresse, ni position, ni modèle d'appareil (revue q34, constat 2).
    static func runResult(from detail: SpeedtestDetail, includesPrivateDetails: Bool = true) -> SpeedtestRunResult {
        let download = detail.averageSpeed ?? detail.downloadAvg ?? detail.downloadSpeed ?? 0
        let upload = detail.uploadAvg ?? detail.uploadSpeed
        // La technologie est servie dans `connectionType` (voir `servedTechnology`).
        let technology = cellularTechnology(detail.networkType) ?? cellularTechnology(detail.connectionType)
        let coordinate = includesPrivateDetails ? detail.latitude.flatMap { lat in
            detail.longitude.map { Coordinates(latitude: lat, longitude: $0) }
        } : nil
        var result = SpeedtestRunResult(
            id: UUID(uuidString: detail.id) ?? UUID(),
            label: detail.id,
            downloadMbps: download,
            downloadAverageMbps: download,
            downloadMaxMbps: detail.downloadMax ?? detail.downloadPeakMbps ?? detail.maxSpeed ?? download,
            downloadP90Mbps: detail.downloadP90,
            downloadP95Mbps: detail.downloadP95,
            uploadMbps: upload,
            uploadAverageMbps: upload,
            uploadMaxMbps: detail.uploadMax ?? detail.uploadPeakMbps ?? upload,
            uploadP90Mbps: detail.uploadP90,
            uploadP95Mbps: detail.uploadP95,
            pingMs: detail.pingAvg ?? detail.ping,
            pingMedianMs: detail.pingMedian,
            pingMinMs: detail.pingMin,
            pingMaxMs: detail.pingMax,
            jitterMs: detail.jitter,
            pingDlMs: detail.pingDl,
            jitterDlMs: detail.jitterDl,
            pingUlMs: detail.pingUl,
            jitterUlMs: detail.jitterUl,
            pingProtocol: detail.pingProtocol,
            durationSeconds: detail.testDuration ?? 0,
            connectionType: connectionKind(served: detail.connectionKind)
                ?? connectionKind(detail.connectionType, technology: technology),
            cellularTechnology: technology,
            networkOperatorName: operatorName(of: detail),
            networkOperatorMcc: detail.mcc,
            networkOperatorMnc: detail.mnc,
            // Le serveur ne le rend qu'au propriétaire ; jamais montré à un autre lecteur.
            wifiSSID: includesPrivateDetails ? detail.wifiSsid : nil,
            city: includesPrivateDetails ? detail.city : nil,
            address: includesPrivateDetails ? detail.address : nil,
            coordinate: coordinate,
            serverName: detail.server,
            downloadServerName: detail.downloadServerName,
            downloadServerId: detail.downloadServerId,
            downloadServerHost: detail.downloadServerHost,
            downloadServerPort: detail.downloadServerPort,
            engine: detail.engine,
            createdAt: detail.measuredAt ?? detail.timestamp ?? detail.createdAt ?? Date(),
            uploadMeasurementSource: detail.uploadMeasurementSource,
            deviceModel: includesPrivateDetails ? detail.deviceModel : nil,
            measurementTrace: detail.measurementTrace,
            methodologyVersion: detail.methodologyVersion,
            pingServerHost: detail.pingServerHost,
            pingServerPort: detail.pingServerPort,
            uploadServerHost: detail.uploadServerHost,
            uploadServerPort: detail.uploadServerPort,
            servedBrand: detail.operatorDisplay?.brand?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        // IOS-037 : ce que la fiche servie sait en plus (test Android compris).
        result.uploadServerName = detail.uploadServerName
        result.networkChangedDuringTest = (detail.transportChangedDuringTest == true || detail.radioTechChangedDuringTest == true)
            ? true : nil
        result.servedBufferbloatGrade = detail.bufferbloatGrade
        result.servedBufferbloatDeltaMs = detail.bufferbloatDeltaMs
        result.packetLossPct = detail.packetLossPct
        result.pingSampleCount = detail.pingSampleCount
        result.streamCount = detail.streams.flatMap { $0 > 0 ? $0 : nil }
        return result
    }

    /// Le réseau d'un test relu, seulement s'il désigne un opérateur reconnu
    /// (cmw9share0nonoperateur01) : la ligne enregistrée peut porter un nom qui n'en est
    /// pas un (« Cloudflare, Inc. », nom d'AS d'une ancienne version), que l'image et la
    /// légende de partage annonceraient comme opérateur. Avec MVNO-1 r3, le serveur dit
    /// lui-même s'il a reconnu le réseau (`networkKey`) ; sans, seul un nom de la palette
    /// des opérateurs est gardé. Mieux vaut aucun nom qu'un faux.
    static func operatorName(of detail: SpeedtestDetail) -> String? {
        if let served = detail.operatorDisplay {
            guard served.networkKey?.trimmingCharacters(in: .whitespaces).isEmpty == false,
                  let network = served.network?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !network.isEmpty else { return nil }
            return network
        }
        return knownOperatorName(detail.mobileOperator)
    }

    /// L'opérateur à afficher sur une ligne (MVNO-1 r3) : « <marque> · réseau <réseau> »
    /// quand l'API sert une marque, sinon le réseau reconnu seul ; sans `operatorDisplay`
    /// (serveur antérieur), le nom brut s'il désigne un opérateur connu.
    static func operatorLabel(display: SpeedtestServedOperatorDisplay?, raw: String?) -> String? {
        guard let display else { return knownOperatorName(raw) }
        let network: String? = {
            guard display.networkKey?.trimmingCharacters(in: .whitespaces).isEmpty == false,
                  let name = display.network?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { return nil }
            return name
        }()
        guard let brand = display.brand?.trimmingCharacters(in: .whitespacesAndNewlines), !brand.isEmpty else {
            return network
        }
        return network.map { String(localized: "\(brand) · réseau \($0)") } ?? brand
    }

    /// Un nom d'opérateur brut, gardé seulement s'il désigne un opérateur connu de la
    /// palette (France, outre-mer, Canada) : ailleurs, aucun nom plutôt qu'un faux.
    static func knownOperatorName(_ raw: String?) -> String? {
        guard let name = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty, SQBrand.operatorName(name) != nil else { return nil }
        return name
    }

    /// « 5G NSA », « LTE », « 4G »… tel que les trois apps l'envoient.
    static func cellularTechnology(_ raw: String?) -> CellularRadioTechnology? {
        guard let value = raw?.trimmingCharacters(in: .whitespaces).uppercased(), !value.isEmpty else { return nil }
        if let exact = CellularRadioTechnology(rawValue: value) { return exact }
        if value.hasPrefix("LTE") { return .fourG }
        // « 5G » seul ne dit pas NSA ou SA : on ne devine pas.
        return nil
    }

    /// Classement du serveur (CONN-KIND v1) : il reconnaît aussi « 5G », « NR » ou
    /// « LTE+ » envoyés par d'anciennes versions. `UNKNOWN` ou une valeur inconnue
    /// rendent la main à la lecture brute.
    static func connectionKind(served: String?) -> NetworkConnectionKind? {
        switch served {
        case "WIFI": return .wifi
        case "ETHERNET": return .wired
        case let kind? where kind.hasPrefix("CELLULAR"): return .cellular
        default: return nil
        }
    }

    /// Bandes et signal servis pour un test du compte (revue du détail, choix
    /// d'Alexandre du 22/11). Une valeur hors plage, une sentinelle ou une
    /// mesure qui n'existe pas dans la technologie du test ne donne pas de ligne.
    static func servedRadio(from detail: SpeedtestDetail) -> SpeedtestServedRadio {
        let technology = signalTechnology(servedTechnology(detail))
        let measures: [(SQQualityScale.Signal.Measure, String, Double?, String)] = [
            (.rsrp, "RSRP", detail.rsrp, "dBm"),
            (.rsrq, "RSRQ", detail.rsrq, "dB"),
            (.sinr, "SINR", detail.snr, "dB"),
        ]
        let readings: [SpeedtestServedRadio.Reading] = measures.compactMap { measure, label, value, unit in
            guard let value, value.isFinite else { return nil }
            let level = SQQualityScale.Signal(measure: measure, rsrp: detail.rsrp, rsrq: detail.rsrq,
                                              sinr: detail.snr, technology: technology)
            guard level != .unknown, level != .noService else { return nil }
            // Arrondi de l'échelle (Math.round) : la valeur et son niveau concordent.
            let rounded = Int((value + 0.5).rounded(.down))
            return SpeedtestServedRadio.Reading(label: label, value: "\(rounded) \(unit)", level: level)
        }
        return SpeedtestServedRadio(bands: bandsLine(detail.carriers ?? []), readings: readings)
    }

    /// « B3 + B7 · n78 » : dans l'ordre servi (la principale d'abord), une bande
    /// vue deux fois n'est écrite qu'une fois, la 4G et la 5G séparées par « · ».
    static func bandsLine(_ carriers: [SpeedtestServingCarrier]) -> String? {
        var groups: [(tech: String, labels: [String])] = []
        for carrier in carriers {
            let tech = carrier.tech.uppercased()
            guard tech == "LTE" || tech == "NR", (1...1024).contains(carrier.band) else { continue }
            let label = SQUnits.band(carrier.band, isNR: tech == "NR")
            if let index = groups.firstIndex(where: { $0.tech == tech }) {
                if !groups[index].labels.contains(label) { groups[index].labels.append(label) }
            } else {
                groups.append((tech, [label]))
            }
        }
        guard !groups.isEmpty else { return nil }
        return groups.map { $0.labels.joined(separator: " + ") }.joined(separator: " · ")
    }

    /// « 5G SA », « NR » → « 5G » ; « LTE », « 4G+ » → « 4G » : la technologie
    /// dans les termes de l'échelle, qui choisit la métrique et ses seuils.
    static func signalTechnology(_ raw: String?) -> String? {
        switch SQQualityScale.Generation(technology: raw) {
        case .fiveG: return "5G"
        case .fourG: return "4G"
        default: return raw
        }
    }

    /// Technologie d'un test servi. GET /api/speedtests/{id} la sert dans
    /// `connectionType` (« 5G SA »), `networkType` valant « CELLULAR » (lu sur la
    /// prod le 22/11) ; une forme plus ancienne la mettait dans `networkType`.
    /// Le premier des deux champs qui nomme une 4G ou une 5G l'emporte.
    static func servedTechnology(_ detail: SpeedtestDetail) -> String? {
        let named = [detail.networkType, detail.connectionType].first { raw in
            switch SQQualityScale.Generation(technology: raw) {
            case .fiveG, .fourG: return true
            default: return false
            }
        }
        return named ?? detail.networkType
    }

    static func connectionKind(_ raw: String?, technology: CellularRadioTechnology?) -> NetworkConnectionKind {
        switch raw?.uppercased() {
        case "WIFI", "WI-FI": return .wifi
        case "CELLULAR", "MOBILE": return .cellular
        case "WIRED", "ETHERNET": return .wired
        default: return technology == nil ? .other : .cellular
        }
    }
}

/// Radio d'un test du compte telle que le serveur la sert : seul un test fait
/// sur Android en porte, iOS ne lisant ni les bandes ni le signal.
struct SpeedtestServedRadio: Equatable {
    struct Reading: Equatable {
        /// « RSRP », « RSRQ », « SINR ».
        let label: String
        /// « -95 dBm ».
        let value: String
        let level: SQQualityScale.Signal
    }

    /// « B3 + B7 · n78 », `nil` sans porteuse servie.
    let bands: String?
    let readings: [Reading]

    var isEmpty: Bool { bands == nil && readings.isEmpty }
}
