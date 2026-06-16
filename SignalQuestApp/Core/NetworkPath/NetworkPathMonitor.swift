import Foundation
@preconcurrency import CoreTelephony
import Network

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
    let isExpensive: Bool
    let isConstrained: Bool

    static let unknown = NetworkPathStatus(connection: .other, cellularTechnology: nil, operatorName: nil, isExpensive: false, isConstrained: false)

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

    static func map(_ snapshot: NetworkPathSnapshot, cellularTechnology: CellularRadioTechnology? = nil, operatorName: String? = nil) -> NetworkPathStatus {
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
        return NetworkPathStatus(
            connection: connection,
            cellularTechnology: activeCellularTechnology,
            operatorName: activeOperatorName,
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

    private func refreshStatus() {
        let cellularTechnology = latestPathSnapshot.usesCellular ? currentCellularTechnology() : nil
        let operatorName = latestPathSnapshot.usesCellular ? currentCarrierName() : nil
        status = NetworkPathStatus.map(
            latestPathSnapshot,
            cellularTechnology: cellularTechnology,
            operatorName: operatorName
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
        // `CTCarrier` / `serviceSubscriberCellularProviders` / `carrierName` sont
        // dépréciés SANS remplacement depuis iOS 16 (Apple renvoie « -- » pour des
        // raisons de confidentialité). On n'expose donc plus le nom d'opérateur via
        // CoreTelephony — c'est intentionnel et conforme à la direction Apple.
        nil
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
