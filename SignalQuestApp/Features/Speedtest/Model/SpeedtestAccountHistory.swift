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
        // Heure de mesure servie (MEASURED-AT-1) : c'est le `createdAt` local
        // envoyé tel quel. 1 s de marge couvre une route qui servirait la
        // seconde sans millisecondes ; la fenêtre de 24 h ne sert plus qu'aux
        // tests d'avant le champ.
        if let measured = test.measuredAt {
            return abs(local.createdAt.timeIntervalSince(measured)) <= 1
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
    /// `includesPrivateDetails` faux pour le test d'un autre membre : ni adresse,
    /// ni position, ni modèle d'appareil (revue q34, constat 2).
    static func runResult(from detail: SpeedtestDetail, includesPrivateDetails: Bool = true) -> SpeedtestRunResult {
        let download = detail.averageSpeed ?? detail.downloadAvg ?? detail.downloadSpeed ?? 0
        let upload = detail.uploadAvg ?? detail.uploadSpeed
        let technology = cellularTechnology(detail.networkType)
        let coordinate = includesPrivateDetails ? detail.latitude.flatMap { lat in
            detail.longitude.map { Coordinates(latitude: lat, longitude: $0) }
        } : nil
        return SpeedtestRunResult(
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
            networkOperatorName: detail.mobileOperator,
            networkOperatorMcc: detail.mcc,
            networkOperatorMnc: detail.mnc,
            address: includesPrivateDetails ? detail.address : nil,
            coordinate: coordinate,
            serverName: detail.server,
            downloadServerName: detail.downloadServerName,
            downloadServerId: detail.downloadServerId,
            createdAt: detail.measuredAt ?? detail.timestamp ?? detail.createdAt ?? Date(),
            uploadMeasurementSource: detail.uploadMeasurementSource,
            deviceModel: includesPrivateDetails ? detail.deviceModel : nil,
            measurementTrace: detail.measurementTrace,
            methodologyVersion: detail.methodologyVersion,
            pingServerHost: detail.pingServerHost,
            pingServerPort: detail.pingServerPort,
            uploadServerHost: detail.uploadServerHost,
            uploadServerPort: detail.uploadServerPort
        )
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

    static func connectionKind(_ raw: String?, technology: CellularRadioTechnology?) -> NetworkConnectionKind {
        switch raw?.uppercased() {
        case "WIFI", "WI-FI": return .wifi
        case "CELLULAR", "MOBILE": return .cellular
        case "WIRED", "ETHERNET": return .wired
        default: return technology == nil ? .other : .cellular
        }
    }
}
