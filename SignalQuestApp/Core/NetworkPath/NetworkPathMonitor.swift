import Foundation
@preconcurrency import CoreTelephony
import Network
import os
import CFNetwork

enum CellularRadioTechnology: String, Codable, Equatable, CaseIterable, Sendable {
    case twoG = "2G"
    case threeG = "3G"
    case fourG = "4G"
    case fiveGNSA = "5G NSA"
    case fiveGSA = "5G SA"

    var displayName: String { rawValue }

    static func map(_ radioAccessTechnology: String?) -> CellularRadioTechnology? {
        switch radioAccessTechnology {
        case CTRadioAccessTechnologyGPRS,
             CTRadioAccessTechnologyEdge,
             CTRadioAccessTechnologyCDMA1x:
            return .twoG
        case CTRadioAccessTechnologyWCDMA,
             CTRadioAccessTechnologyHSDPA,
             CTRadioAccessTechnologyHSUPA,
             CTRadioAccessTechnologyCDMAEVDORev0,
             CTRadioAccessTechnologyCDMAEVDORevA,
             CTRadioAccessTechnologyCDMAEVDORevB,
             CTRadioAccessTechnologyeHRPD:
            return .threeG
        case CTRadioAccessTechnologyLTE:
            return .fourG
        case CTRadioAccessTechnologyNRNSA:
            return .fiveGNSA
        case CTRadioAccessTechnologyNR:
            return .fiveGSA
        default:
            return nil
        }
    }
}

struct NetworkPathSnapshot: Equatable, Sendable {
    let usesWiFi: Bool
    let usesCellular: Bool
    let usesWired: Bool
    let isExpensive: Bool
    let isConstrained: Bool

    static let unknown = NetworkPathSnapshot(
        usesWiFi: false,
        usesCellular: false,
        usesWired: false,
        isExpensive: false,
        isConstrained: false
    )

    init(path: NWPath) {
        usesWiFi = path.usesInterfaceType(.wifi)
        usesCellular = path.usesInterfaceType(.cellular)
        usesWired = path.usesInterfaceType(.wiredEthernet)
        isExpensive = path.isExpensive
        isConstrained = path.isConstrained
    }

    init(usesWiFi: Bool, usesCellular: Bool, usesWired: Bool, isExpensive: Bool, isConstrained: Bool) {
        self.usesWiFi = usesWiFi
        self.usesCellular = usesCellular
        self.usesWired = usesWired
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
    }
}

struct NetworkPathStatus: Equatable, Sendable {
    let connection: NetworkConnectionKind
    let cellularTechnology: CellularRadioTechnology?
    let operatorName: String?
    let operatorMcc: Int?
    let operatorMnc: Int?
    let isExpensive: Bool
    let isConstrained: Bool

    static let unknown = NetworkPathStatus(
        connection: .other,
        cellularTechnology: nil,
        operatorName: nil,
        operatorMcc: nil,
        operatorMnc: nil,
        isExpensive: false,
        isConstrained: false
    )

    var displayName: String {
        switch connection {
        case .wifi:
            return "WiFi"
        case .cellular:
            return cellularTechnology?.displayName ?? "Cellulaire"
        case .wired:
            return "Ethernet"
        case .other:
            return "Autre"
        }
    }

    var shareDisplayName: String {
        switch connection {
        case .cellular:
            let technology = cellularTechnology?.displayName
            switch (operatorName, technology) {
            case let (.some(operatorName), .some(technology)):
                return "\(operatorName) \(technology)"
            case let (.some(operatorName), .none):
                return operatorName
            case let (.none, .some(technology)):
                return technology
            case (.none, .none):
                return "Cellulaire"
            }
        default:
            return displayName
        }
    }

    var speedtestConnectionType: String {
        switch connection {
        case .cellular:
            return cellularTechnology?.displayName ?? connection.rawValue
        default:
            return connection.rawValue
        }
    }

    static func map(
        _ snapshot: NetworkPathSnapshot,
        cellularTechnology: CellularRadioTechnology? = nil,
        operatorName: String? = nil,
        operatorMcc: Int? = nil,
        operatorMnc: Int? = nil
    ) -> NetworkPathStatus {
        let connection: NetworkConnectionKind
        if snapshot.usesCellular {
            connection = .cellular
        } else if snapshot.usesWiFi {
            connection = .wifi
        } else if snapshot.usesWired {
            connection = .wired
        } else {
            connection = .other
        }
        let activeCellularTechnology = connection == .cellular ? cellularTechnology : nil
        let activeOperatorName = connection == .cellular ? operatorName : nil
        let activeMcc = connection == .cellular ? operatorMcc : nil
        let activeMnc = connection == .cellular ? operatorMnc : nil
        return NetworkPathStatus(
            connection: connection,
            cellularTechnology: activeCellularTechnology,
            operatorName: activeOperatorName,
            operatorMcc: activeMcc,
            operatorMnc: activeMnc,
            isExpensive: snapshot.isExpensive,
            isConstrained: snapshot.isConstrained
        )
    }
}

@MainActor
final class NetworkPathMonitor: NSObject, ObservableObject, CTTelephonyNetworkInfoDelegate {
    @Published private(set) var status: NetworkPathStatus = .unknown
    /// `false` quand aucun chemin réseau n'est exploitable (mode avion, perte de
    /// connexion). Pilote la bannière hors-ligne globale.
    @Published private(set) var isOnline = true
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "SignalQuest.NetworkPathMonitor")
    private let telephony = CTTelephonyNetworkInfo()
    private var latestPathSnapshot: NetworkPathSnapshot = .unknown
    private var radioObserver: NSObjectProtocol?
    private var isStarted = false
    private static let logger = Logger(subsystem: "fr.signalquest.ios", category: "NetworkPath")

    override init() {
        super.init()
        telephony.delegate = self
    }

    func start() {
        guard !isStarted else {
            refreshStatus()
            return
        }
        isStarted = true
        telephony.delegate = self
        radioObserver = NotificationCenter.default.addObserver(
            forName: .CTServiceRadioAccessTechnologyDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshStatus()
            }
        }
        monitor.pathUpdateHandler = { [weak self] path in
            let snapshot = NetworkPathSnapshot(path: path)
            let satisfied = path.status == .satisfied
            Task { @MainActor in
                self?.latestPathSnapshot = snapshot
                self?.isOnline = satisfied
                self?.refreshStatus()
            }
        }
        monitor.start(queue: queue)
        refreshStatus()
    }

    func stop() {
        if let radioObserver {
            NotificationCenter.default.removeObserver(radioObserver)
            self.radioObserver = nil
        }
        telephony.delegate = nil
        monitor.cancel()
        isStarted = false
    }

    nonisolated func dataServiceIdentifierDidChange(_ identifier: String) {
        Task { @MainActor [weak self] in
            self?.refreshStatus()
        }
    }

    /// Force une relecture immédiate de l'opérateur/techno. Utile juste avant un
    /// speedtest pour repartir d'une lecture fraîche de CoreTelephony plutôt que
    /// du dernier statut publié.
    func refreshNow() {
        refreshStatus()
    }

    /// MCC/MNC de la SIM lus DIRECTEMENT (CoreTelephony), indépendamment du chemin
    /// réseau actif. Utile pour cibler l'opérateur de la SIM même quand l'app est
    /// sur WiFi (le `status` ne porte le PLMN que si le chemin actif est cellulaire).
    /// Peut être (nil, nil) si iOS masque le code réseau (16.4+).
    func simPLMN() -> (mcc: Int?, mnc: Int?) {
        currentCellularPLMN()
    }

    private func refreshStatus() {
        if latestPathSnapshot.usesCellular { logCarrierDiagnosticsIfNeeded() }
        let cellularTechnology = latestPathSnapshot.usesCellular ? currentCellularTechnology() : nil
        let operatorName = latestPathSnapshot.usesCellular ? currentCarrierName() : nil
        let plmn: (mcc: Int?, mnc: Int?) = latestPathSnapshot.usesCellular ? currentCellularPLMN() : (mcc: nil, mnc: nil)
        status = NetworkPathStatus.map(
            latestPathSnapshot,
            cellularTechnology: cellularTechnology,
            operatorName: operatorName,
            operatorMcc: plmn.mcc,
            operatorMnc: plmn.mnc
        )
    }

    private func currentCellularTechnology() -> CellularRadioTechnology? {
        guard let serviceTechnologies = telephony.serviceCurrentRadioAccessTechnology else {
            return nil
        }

        if let dataServiceIdentifier = telephony.dataServiceIdentifier,
           let technology = CellularRadioTechnology.map(serviceTechnologies[dataServiceIdentifier]) {
            return technology
        }

        for serviceIdentifier in serviceTechnologies.keys.sorted() {
            if let technology = CellularRadioTechnology.map(serviceTechnologies[serviceIdentifier]) {
                return technology
            }
        }
        return nil
    }

    private func currentCarrierName() -> String? {
        guard let providers = telephony.serviceSubscriberCellularProviders else {
            return nil
        }

        if let dataServiceIdentifier = telephony.dataServiceIdentifier,
           let carrierName = Self.normalizedCarrierName(providers[dataServiceIdentifier]?.carrierName) {
            return carrierName
        }

        for serviceIdentifier in providers.keys.sorted() {
            if let carrierName = Self.normalizedCarrierName(providers[serviceIdentifier]?.carrierName) {
                return carrierName
            }
        }
        return nil
    }

    /// Diagnostic (debug uniquement) : trace les valeurs BRUTES renvoyées par
    /// l'API dépréciée CoreTelephony pour chaque service SIM. Permet de constater
    /// sur l'appareil si `carrierName`/MCC/MNC remontent un vrai opérateur ou le
    /// placeholder « -- » / 65535 introduit par iOS 16.4+. Rien n'est loggé hors
    /// du flag `debugLogsEnabled`.
    private func logCarrierDiagnosticsIfNeeded() {
        #if DEBUG
        let dataService = telephony.dataServiceIdentifier ?? "nil"
        guard let providers = telephony.serviceSubscriberCellularProviders, !providers.isEmpty else {
            Self.logger.notice("SQ_CARRIER providers=nil/empty dataService=\(dataService, privacy: .public)")
            return
        }
        for (serviceId, carrier) in providers {
            Self.logger.notice("SQ_CARRIER service=\(serviceId, privacy: .public) name=\(carrier.carrierName ?? "nil", privacy: .public) mcc=\(carrier.mobileCountryCode ?? "nil", privacy: .public) mnc=\(carrier.mobileNetworkCode ?? "nil", privacy: .public) iso=\(carrier.isoCountryCode ?? "nil", privacy: .public) dataService=\(dataService, privacy: .public)")
        }
        #endif
    }

    private func currentCellularPLMN() -> (mcc: Int?, mnc: Int?) {
        guard let provider = currentCellularProvider(),
              let plmn = Self.plmn(from: provider) else {
            return (nil, nil)
        }
        return plmn
    }

    private func currentCellularProvider() -> CTCarrier? {
        guard let providers = telephony.serviceSubscriberCellularProviders else {
            return nil
        }
        if let dataServiceIdentifier = telephony.dataServiceIdentifier,
           let provider = providers[dataServiceIdentifier] {
            return provider
        }

        for serviceIdentifier in providers.keys.sorted() {
            if let provider = providers[serviceIdentifier] {
                return provider
            }
        }
        return nil
    }

    private static func normalizedCarrierName(_ value: String?) -> String? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              raw != "--" else {
            return nil
        }
        return raw
    }

    private static func plmn(from provider: CTCarrier) -> (mcc: Int?, mnc: Int?)? {
        let mcc = parsePLMNComponent(provider.mobileCountryCode)
        let mnc = parsePLMNComponent(provider.mobileNetworkCode)
        guard mcc != nil || mnc != nil else { return nil }
        return (mcc, mnc)
    }

    private static func parsePLMNComponent(_ value: String?) -> Int? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              raw != "--",
              raw.allSatisfy(\.isNumber),
              let parsed = Int(raw),
              // 65535 (0xFFFF) est le placeholder renvoyé par iOS 16+ quand le code
              // réseau n'est plus exposé : on ne le propage pas comme MCC/MNC réel.
              parsed != 65535,
              parsed > 0 else {
            return nil
        }
        return parsed
    }
}

extension NetworkConnectionKind {
    func isWiFiCellularBoundaryChange(to newConnection: NetworkConnectionKind) -> Bool {
        switch (self, newConnection) {
        case (.wifi, .cellular), (.cellular, .wifi):
            return true
        default:
            return false
        }
    }
}

extension NetworkPathStatus {
    /// Copie avec `operatorName` rempli par `fallback` quand l'API device
    /// (CoreTelephony) n'a rien renvoyé. Sert à injecter l'opérateur résolu par IP
    /// (backend) dans le résultat sans modifier le protocole du service.
    func merging(operatorName fallback: String?) -> NetworkPathStatus {
        guard operatorName == nil,
              let fallback = fallback?.trimmingCharacters(in: .whitespacesAndNewlines),
              !fallback.isEmpty else {
            return self
        }
        return NetworkPathStatus(
            connection: connection,
            cellularTechnology: cellularTechnology,
            operatorName: fallback,
            operatorMcc: operatorMcc,
            operatorMnc: operatorMnc,
            isExpensive: isExpensive,
            isConstrained: isConstrained
        )
    }
}

/// Détecte un tunnel VPN / relais actif sur l'appareil.
///
/// Sur iOS, l'unique signal client fiable est la présence d'interfaces réseau
/// « scoped » VPN (tap/tun/ppp/ipsec/utun) exposées par
/// `CFNetworkCopySystemProxySettings`. On ne peut **pas** récupérer l'IP publique
/// réelle derrière un VPN : le serveur ne voit que l'IP de sortie du tunnel, et
/// l'app elle-même ne voit que son IP locale (privée). Ce drapeau sert donc à NE
/// PAS faire confiance à la résolution opérateur par IP (l'IP refléterait le VPN,
/// pas le réseau réel) ; l'app retombe alors sur l'opérateur lu par CoreTelephony
/// ou sur la techno seule.
enum VPNDetector {
    private static let vpnInterfacePrefixes = ["tap", "tun", "ppp", "ipsec", "utun"]

    static func isActive() -> Bool {
        guard let proxies = CFNetworkCopySystemProxySettings()?.takeRetainedValue() else { return false }
        let settings = proxies as NSDictionary
        guard let scoped = settings["__SCOPED__"] as? [String: Any] else { return false }
        return scoped.keys.contains { interface in
            vpnInterfacePrefixes.contains { interface.hasPrefix($0) }
        }
    }
}

/// Opérateur résolu côté backend à partir de l'IP publique (lookup ASN), réponse
/// de `GET /api/speedtest/operator`. Champs nuls si inconnu / sous VPN / base ASN
/// absente.
struct DetectedOperator: Decodable, Equatable, Sendable {
    let operatorKey: String?
    let label: String?
    let shortLabel: String?
    let color: String?
    let viaVpn: Bool?
}

protocol NetworkOperatorServicing: Sendable {
    /// Résout l'opérateur via l'IP publique (ASN) côté backend. `viaVpn` = état du
    /// tunnel détecté sur l'appareil : sous VPN le backend renvoie un opérateur nul
    /// (l'IP refléterait le VPN). Renvoie `nil` en cas d'échec réseau.
    func resolve(viaVpn: Bool) async -> DetectedOperator?
}

final class NetworkOperatorService: NetworkOperatorServicing {
    private let api: APIClient

    init(api: APIClient) {
        self.api = api
    }

    func resolve(viaVpn: Bool) async -> DetectedOperator? {
        let endpoint = APIEndpoint(
            path: "/api/speedtest/operator",
            query: [URLQueryItem(name: "vpn", value: viaVpn ? "1" : "0")],
            authenticated: false
        )
        return try? await api.request(endpoint, as: DetectedOperator.self)
    }
}
