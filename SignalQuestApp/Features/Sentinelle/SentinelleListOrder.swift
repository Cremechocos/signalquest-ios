import Foundation

/// Sentinelle — ordre et regroupement de la liste des box.
///
/// Port de `apps/web/components/sentinelle/list-order.ts`, dont les 8 tests
/// fixent les règles, et de `SentinelleListOrder.kt`. Les trois plateformes
/// doivent trier IDENTIQUEMENT : sinon la même liste se lit différemment selon
/// l'appareil, et on ne peut plus se fier à ce qu'on a vu ailleurs.
///
/// Réglages purement locaux : un ordre d'affichage est une préférence de
/// lecture du moment, pas une propriété de la connexion.
enum SentinelleListOrder {

    enum Sort: String, CaseIterable, Identifiable {
        case state, name, uptime
        var id: String { rawValue }
        var label: String {
            switch self {
            case .state: return String(localized: "État")
            case .name: return String(localized: "Nom")
            case .uptime: return String(localized: "Dispo.")
            }
        }
    }

    enum Group: String, CaseIterable, Identifiable {
        case operatorKey, none
        var id: String { rawValue }
        var label: String {
            switch self {
            case .operatorKey: return String(localized: "Par opérateur")
            case .none: return String(localized: "Sans groupe")
            }
        }
    }

    static let unknownOperator = String(localized: "Opérateur inconnu")

    /// Ce qu'il faut d'une box pour l'ordonner. Volontairement minimal : les box
    /// à soi et les connexions suivies n'ont pas les mêmes champs, seul ce socle
    /// leur est commun.
    protocol Orderable {
        var orderLabel: String { get }
        var orderStatus: String { get }
        var orderOperator: String? { get }
        var orderUptimePct: Double? { get }
    }

    /// Le tri par ÉTAT met le pire en tête — c'est la raison d'ouvrir la page.
    /// Une liste qui commence par ce qui va bien oblige à chercher ce qui ne va
    /// pas.
    private static func weight(_ status: String) -> Int {
        switch status {
        case "down": return 0
        case "degraded": return 1
        case "up": return 3
        default: return 2
        }
    }

    static func sorted<T: Orderable>(_ boxes: [T], by sort: Sort) -> [T] {
        switch sort {
        case .name:
            return boxes.sorted { $0.orderLabel.localizedCompare($1.orderLabel) == .orderedAscending }
        case .uptime:
            // La moins disponible d'abord, pour la même raison que l'état. Une
            // box SANS mesure passe en queue : sans donnée elle n'est pas
            // « parfaite », elle est inconnue — la placer devant une box à 91 %
            // ferait passer l'ignorance pour une bonne nouvelle. D'où le 101,
            // hors de l'intervalle [0,100].
            return boxes.sorted {
                let a = $0.orderUptimePct ?? 101, b = $1.orderUptimePct ?? 101
                if a != b { return a < b }
                return $0.orderLabel.localizedCompare($1.orderLabel) == .orderedAscending
            }
        case .state:
            return boxes.sorted {
                let a = weight($0.orderStatus), b = weight($1.orderStatus)
                if a != b { return a < b }
                return $0.orderLabel.localizedCompare($1.orderLabel) == .orderedAscending
            }
        }
    }

    /// `key` vaut `nil` quand on ne regroupe pas : l'appelant n'affiche alors
    /// aucun en-tête.
    struct Bucket<T>: Identifiable {
        let key: String?
        let boxes: [T]
        var id: String { key ?? "all" }
    }

    /// Regroupe par opérateur en gardant l'ordre demandé DANS chaque groupe.
    ///
    /// Les box d'opérateur inconnu forment un groupe à part, placé en dernier :
    /// les fondre dans un groupe existant serait un mensonge, et les cacher
    /// ferait disparaître une connexion de la liste.
    static func grouped<T: Orderable>(_ boxes: [T], by group: Group, sort: Sort) -> [Bucket<T>] {
        let list = sorted(boxes, by: sort)
        guard group == .operatorKey else { return [Bucket(key: nil, boxes: list)] }

        var order: [String] = []
        var buckets: [String: [T]] = [:]
        for box in list {
            let key = box.orderOperator?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? unknownOperator
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(box)
        }

        return order
            .sorted { a, b in
                if a == unknownOperator { return false }
                if b == unknownOperator { return true }
                return a.localizedCompare(b) == .orderedAscending
            }
            .map { Bucket(key: $0, boxes: buckets[$0] ?? []) }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension SentinelleTarget: SentinelleListOrder.Orderable {
    var orderLabel: String { label }
    var orderStatus: String { status }
    var orderOperator: String? { operatorKey }
    // Une box à soi n'expose pas d'agrégat de disponibilité dans la liste : le
    // tri par dispo. la range donc en queue, comme toute box sans mesure.
    var orderUptimePct: Double? { nil }
}

extension SentinelleFollowedBox: SentinelleListOrder.Orderable {
    var orderLabel: String { displayName }
    var orderStatus: String { status }
    var orderOperator: String? { operatorKey }
    var orderUptimePct: Double? { uptimePct }
}
