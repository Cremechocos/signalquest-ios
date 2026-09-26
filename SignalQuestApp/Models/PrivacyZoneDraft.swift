import Foundation

enum PrivacyZoneType: String, CaseIterable, Identifiable, Sendable {
    case home, work, school, frequent, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .home: return String(localized: "Domicile")
        case .work: return String(localized: "Travail")
        case .school: return String(localized: "École")
        case .frequent: return String(localized: "Lieu fréquent")
        case .custom: return String(localized: "Personnalisée")
        }
    }
}

struct PrivacyZoneDraft: Equatable, Sendable {
    static let minimumRadius: Double = 100
    static let maximumRadius: Double = 20_000
    var name = ""
    var type: PrivacyZoneType = .custom
    var latitudeText = ""
    var longitudeText = ""
    var radius: Double = 500
    var isActive = true
    var hideSpeedtestsOnMap = true

    init(zone: PrivacyZone? = nil) {
        guard let zone else { return }
        name = zone.name
        type = PrivacyZoneType(rawValue: zone.type ?? "") ?? .custom
        latitudeText = zone.latitude.map(Self.coordinateText) ?? ""
        longitudeText = zone.longitude.map(Self.coordinateText) ?? ""
        radius = zone.radius ?? 500
        isActive = zone.isActive
        hideSpeedtestsOnMap = zone.hideSpeedtestsOnMap
    }

    var latitude: Double? { Self.coordinate(latitudeText) }
    var longitude: Double? { Self.coordinate(longitudeText) }
    var hasValidCoordinate: Bool {
        guard let latitude, let longitude else { return false }
        return latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }

    mutating func select(latitude: Double, longitude: Double) {
        latitudeText = Self.coordinateText(latitude)
        longitudeText = Self.coordinateText(longitude)
    }

    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ValidationError.name }
        guard hasValidCoordinate else { throw ValidationError.coordinate }
        guard radius.isFinite, (Self.minimumRadius...Self.maximumRadius).contains(radius) else { throw ValidationError.radius }
    }

    func createRequest() throws -> CreatePrivacyZoneRequest {
        try validate()
        guard let latitude, let longitude else { throw ValidationError.coordinate }
        return CreatePrivacyZoneRequest(name: name.trimmingCharacters(in: .whitespacesAndNewlines), type: type.rawValue,
            latitude: latitude, longitude: longitude, radius: radius.rounded(), hideSpeedtestsOnMap: hideSpeedtestsOnMap)
    }

    func updateRequest(original: PrivacyZone) throws -> UpdatePrivacyZoneRequest {
        try validate()
        let baseline = Self(zone: original)
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return UpdatePrivacyZoneRequest(id: original.id,
            name: cleanName == baseline.name ? nil : cleanName,
            type: type == baseline.type ? nil : type.rawValue,
            latitude: latitude == baseline.latitude ? nil : latitude,
            longitude: longitude == baseline.longitude ? nil : longitude,
            radius: radius == baseline.radius ? nil : radius.rounded(),
            isActive: isActive == baseline.isActive ? nil : isActive,
            hideSpeedtestsOnMap: hideSpeedtestsOnMap == baseline.hideSpeedtestsOnMap ? nil : hideSpeedtestsOnMap)
    }

    private static func coordinate(_ value: String) -> Double? {
        Double(value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "."))
    }

    private static func coordinateText(_ value: Double) -> String {
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    enum ValidationError: LocalizedError {
        case name, coordinate, radius
        var errorDescription: String? {
            switch self {
            case .name: return String(localized: "Donne un nom à cette zone.")
            case .coordinate: return String(localized: "Choisis une position valide pour cette zone.")
            case .radius: return String(localized: "Le rayon doit être compris entre 100 et 20 000 mètres.")
            }
        }
    }
}
