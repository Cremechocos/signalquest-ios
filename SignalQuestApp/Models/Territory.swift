import Foundation
import CoreLocation

/// Cellule de territoire (~2,2 km de côté), servie par
/// `GET /api/gamification/v2/territories`.
struct TerritoryCell: Decodable, Equatable, Identifiable {
    let cellKey: String
    let status: Status
    let bounds: Bounds
    let pointsCount: Int
    let userCount: Int
    let trustScore: Double
    let lastObservedAt: Date?
    let mine: Bool

    var id: String { cellKey }

    struct Bounds: Decodable, Equatable {
        let north: Double
        let south: Double
        let east: Double
        let west: Double
    }

    /// Statut d'une cellule. `virgin` — la zone blanche — était inatteignable
    /// avant le refactor SQL du backend : les cellules sans mesure n'étaient
    /// jamais construites. C'est pourtant l'état le plus intéressant du jeu.
    enum Status: String, Decodable, Equatable {
        case virgin
        case observed
        case reliable
        case complete
        case stale

        /// Un statut inconnu ne doit pas vider la carte : on retombe sur
        /// « observé », le plus neutre.
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Status(rawValue: raw) ?? .observed
        }
    }
}

/// Réponse complète, `truncated` compris.
struct TerritoryGrid: Decodable, Equatable {
    let cells: [TerritoryCell]
    /// `true` quand la bbox dépassait le plafond du serveur. Le client DOIT le
    /// dire : afficher une grille partielle sans le signaler laisserait croire
    /// que les cellules manquantes sont des zones blanches.
    let truncated: Bool
    let cellSize: Double

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cells = (try? c.decode([TerritoryCell].self, forKey: .cells)) ?? []
        truncated = (try? c.decode(Bool.self, forKey: .truncated)) ?? false
        cellSize = (try? c.decode(Double.self, forKey: .cellSize)) ?? 0.02
    }

    enum CodingKeys: String, CodingKey { case cells, truncated, cellSize }

    /// Répartition par statut, pour la légende et le résumé.
    func count(of status: TerritoryCell.Status) -> Int {
        cells.reduce(0) { $0 + ($1.status == status ? 1 : 0) }
    }
}
