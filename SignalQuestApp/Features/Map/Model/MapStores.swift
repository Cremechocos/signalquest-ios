import SwiftUI
import CoreLocation
import MapKit

/// Persists the last viewed map region so the app reopens where the user left
/// off instead of a fixed location. (UserDefaults use is declared in
/// PrivacyInfo.xcprivacy under reason CA92.1.)
enum MapRegionStore {
    static let key = "map.lastRegion.v1"

    /// Efface la région mémorisée (QA `--reset-map` : repart sur la France).
    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    static func save(_ region: MKCoordinateRegion) {
        guard region.center.latitude.isFinite, region.center.longitude.isFinite,
              region.span.longitudeDelta > 0, region.span.latitudeDelta > 0 else { return }
        UserDefaults.standard.set([
            "lat": region.center.latitude,
            "lon": region.center.longitude,
            "latD": region.span.latitudeDelta,
            "lonD": region.span.longitudeDelta
        ], forKey: key)
    }

    static func lastRegion() -> MKCoordinateRegion? {
        guard let dict = UserDefaults.standard.dictionary(forKey: key) as? [String: Double],
              let lat = dict["lat"], let lon = dict["lon"],
              let latD = dict["latD"], let lonD = dict["lonD"],
              lat.isFinite, lon.isFinite, latD > 0, lonD > 0 else { return nil }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            span: MKCoordinateSpan(latitudeDelta: latD, longitudeDelta: lonD)
        )
    }
}

/// Persiste le dernier marché + opérateur sélectionnés sur la carte, pour rouvrir
/// sur le choix de l'utilisateur plutôt que sur un défaut codé en dur (France).
/// (UserDefaults déclaré dans PrivacyInfo.xcprivacy sous la raison CA92.1.)
/// Internal (pas `private`) : réutilisé par le mode Drive Test pour cibler le bon
/// marché lors du chargement des antennes proches.
/// Persistance locale des couches actives de la carte (mémorisées entre navigations /
/// relances). Défaut : antennes seule — l'utilisateur active le reste à la demande.
enum MapFilterStore {
    static let key = "map.lastFilters.v1"

    /// Couches par défaut : antennes seule.
    static let defaultFilters: Set<MapDisplayItem.Kind> = [.antenna]

    static func save(_ filters: Set<MapDisplayItem.Kind>) {
        UserDefaults.standard.set(filters.map(\.rawValue), forKey: key)
    }

    /// Couches mémorisées (éventuellement vide si tout désactivé), ou `nil` si jamais
    /// enregistrées → l'appelant retombe sur `defaultFilters`.
    static func lastFilters() -> Set<MapDisplayItem.Kind>? {
        guard let raw = UserDefaults.standard.array(forKey: key) as? [String] else { return nil }
        return Set(raw.compactMap(MapDisplayItem.Kind.init(rawValue:)))
    }

    static func reset() { UserDefaults.standard.removeObject(forKey: key) }
}

enum MapMarketStore {
    static let marketKey = "map.lastMarket.v1"
    static let operatorKey = "map.lastOperator.v1"

    /// QA `--reset-map` : oublie le marché/opérateur pour rejouer la détection.
    static func reset() {
        UserDefaults.standard.removeObject(forKey: marketKey)
        UserDefaults.standard.removeObject(forKey: operatorKey)
    }

    static func save(market: String, operator op: String) {
        let market = market.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !market.isEmpty else { return }
        UserDefaults.standard.set(market, forKey: marketKey)
        let op = op.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(op.isEmpty ? "ALL" : op, forKey: operatorKey)
    }

    static func lastMarket() -> String? {
        guard let value = UserDefaults.standard.string(forKey: marketKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    static func lastOperator() -> String? {
        guard let value = UserDefaults.standard.string(forKey: operatorKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    /// Code marché utilisable AVANT le chargement du registre (init synchrone) :
    /// dernier choix persisté, sinon pays de la locale appareil, sinon "FR".
    static func initialMarketCode() -> String { lastMarket() ?? localeMarketCode() }

    static func initialOperatorKey() -> String { lastOperator() ?? "ALL" }

    /// Pays de la locale appareil (ISO, ex. "FR" / "CA"). Repli "FR" si absent —
    /// jamais affiché tel quel : la détection registre le corrige juste après.
    static func localeMarketCode() -> String {
        Locale.current.region?.identifier.uppercased() ?? "FR"
    }
}

/// Persiste les statuts prévisionnels visibles. Absence de clé = jamais réglé
/// → les 4 statuts. Tableau vide stocké = choix explicite « tout masquer ».
enum MapPlannedStatusStore {
    static let key = "map.planned.statusFilters.v1"

    static func load() -> Set<PlannedActivationStatus> {
        guard let raw = UserDefaults.standard.array(forKey: key) as? [String] else {
            return Set(PlannedActivationStatus.allCases)
        }
        return Set(raw.compactMap(PlannedActivationStatus.init(rawValue:)))
    }

    static func save(_ statuses: Set<PlannedActivationStatus>) {
        UserDefaults.standard.set(statuses.map(\.rawValue), forKey: key)
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
