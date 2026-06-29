import CoreLocation

/// Géométrie de secteur d'antenne pour le mode Drive Test : relèvement (bearing)
/// entre deux points, test « dans le secteur », antenne la plus proche et sommets
/// d'un cône de secteur pour l'affichage carte. Math alignée sur `azimuthPath`
/// de la carte principale (`halfBeam = 32.5°`, soit ~65° d'ouverture de lobe).
enum AntennaSectorGeometry {
    /// Demi-ouverture de lobe par défaut (≈ 65° d'ouverture).
    static let defaultHalfBeamDegrees = 32.5

    private static let earthRadiusMeters = 6_371_000.0

    /// Relèvement géographique (compas : 0° = Nord, sens horaire) de `from` vers `to`.
    static func bearing(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let lat1 = from.latitude * .pi / 180
        let lat2 = to.latitude * .pi / 180
        let dLon = (to.longitude - from.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let degrees = atan2(y, x) * 180 / .pi
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Écart angulaire minimal (0…180°) entre deux caps.
    static func angularDistance(_ a: Double, _ b: Double) -> Double {
        let diff = abs(a - b).truncatingRemainder(dividingBy: 360)
        return diff > 180 ? 360 - diff : diff
    }

    /// L'utilisateur est-il dans le lobe d'un secteur d'azimut `azimuth` ? On compare
    /// le cap antenne→utilisateur à l'azimut du secteur (± demi-lobe).
    static func isWithinSector(
        antenna: CLLocationCoordinate2D,
        user: CLLocationCoordinate2D,
        azimuth: Double,
        halfBeamDegrees: Double = defaultHalfBeamDegrees
    ) -> Bool {
        let towardUser = bearing(from: antenna, to: user)
        return angularDistance(towardUser, azimuth) <= halfBeamDegrees
    }

    /// Secteur le plus aligné d'une antenne vers l'utilisateur, avec l'écart
    /// angulaire et le statut « dans le lobe ». `nil` si l'antenne n'a aucun azimut.
    static func bestSector(
        antenna: CLLocationCoordinate2D,
        azimuths: [Double],
        user: CLLocationCoordinate2D,
        halfBeamDegrees: Double = defaultHalfBeamDegrees
    ) -> (azimuth: Double, offset: Double, inSector: Bool)? {
        guard !azimuths.isEmpty else { return nil }
        let towardUser = bearing(from: antenna, to: user)
        let best = azimuths
            .map { (azimuth: $0, offset: angularDistance(towardUser, $0)) }
            .min { $0.offset < $1.offset }
        return best.map { ($0.azimuth, $0.offset, $0.offset <= halfBeamDegrees) }
    }

    /// Antenne mappable la plus proche de l'utilisateur (distance en mètres).
    static func nearest(
        to user: CLLocationCoordinate2D,
        among antennas: [AntennaSite]
    ) -> (site: AntennaSite, distanceMeters: Double)? {
        let userLocation = CLLocation(latitude: user.latitude, longitude: user.longitude)
        return antennas
            .compactMap { site -> (AntennaSite, Double)? in
                guard site.hasValidCoordinate, let lat = site.latitude, let lon = site.longitude else { return nil }
                let distance = userLocation.distance(from: CLLocation(latitude: lat, longitude: lon))
                return (site, distance)
            }
            .min { $0.1 < $1.1 }
            .map { (site: $0.0, distanceMeters: $0.1) }
    }

    /// Coordonnée destination à `distanceMeters` dans le relèvement `bearingDegrees`.
    static func destination(
        from origin: CLLocationCoordinate2D,
        bearingDegrees: Double,
        distanceMeters: Double
    ) -> CLLocationCoordinate2D {
        let angular = distanceMeters / earthRadiusMeters
        let bearing = bearingDegrees * .pi / 180
        let lat1 = origin.latitude * .pi / 180
        let lon1 = origin.longitude * .pi / 180
        let lat2 = asin(sin(lat1) * cos(angular) + cos(lat1) * sin(angular) * cos(bearing))
        let lon2 = lon1 + atan2(
            sin(bearing) * sin(angular) * cos(lat1),
            cos(angular) - sin(lat1) * sin(lat2)
        )
        return CLLocationCoordinate2D(latitude: lat2 * 180 / .pi, longitude: lon2 * 180 / .pi)
    }

    /// Sommets d'un cône de secteur (apex antenne → arc [azimut ± demi-lobe] à
    /// `lengthMeters`) pour tracer un polygone sur la carte.
    static func sectorConeCoordinates(
        apex: CLLocationCoordinate2D,
        azimuth: Double,
        halfBeamDegrees: Double = defaultHalfBeamDegrees,
        lengthMeters: Double,
        steps: Int = 8
    ) -> [CLLocationCoordinate2D] {
        var coordinates = [apex]
        let start = azimuth - halfBeamDegrees
        let end = azimuth + halfBeamDegrees
        let segments = max(1, steps)
        for index in 0...segments {
            let bearing = start + (end - start) * Double(index) / Double(segments)
            coordinates.append(destination(from: apex, bearingDegrees: bearing, distanceMeters: lengthMeters))
        }
        coordinates.append(apex)
        return coordinates
    }
}
