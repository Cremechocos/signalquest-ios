import Foundation

/// Convention de numérotation de secteur par opérateur — porté fidèlement depuis
/// Android (`map/presentation/SectorNumbering.kt`). La valeur SOUMISE au serveur
/// doit suivre la convention de l'opérateur, sinon un `index + 1` naïf écrit une
/// valeur FAUSSE pour SFR et pollue la base communautaire (SECTOR-TELECOM-01).
///
/// - SFR (MCC 208, MNC 8/10/11/13) numérote les secteurs à partir de **0**.
/// - Orange (1/2), Bouygues (20), Free (15/16) à partir de **1**.
/// - Par défaut (opérateur inconnu) : `legacy` = affiche 1-based, soumet 0-based
///   (comportement historique conservé pour ne rien casser hors-FR).
///
/// En base 1 (`SQFeatures.sectorBaseOne`, contrat SECTOR-BASE-1 §5) : TOUS les
/// opérateurs passent à partir de **1**, à l'écriture comme à la lecture (SFR, zone
/// blanche, DROM, Canada, Belgique, Suisse…) ; le mode `legacy` disparaît, comme chez
/// Android, et le serveur numérote déjà tout opérateur inconnu en base 1.
enum SectorNumbering {
    enum Mode { case zeroBased, oneBased, legacy }

    /// Numéro de secteur AFFICHÉ pour un index d'azimut (0 = premier azimut trié),
    /// cohérent avec la valeur soumise.
    static func displayValue(index: Int, mccMnc: String? = nil, operatorName: String?,
                             sectorBaseOne: Bool = SQFeatures.sectorBaseOne) -> Int {
        switch resolveMode(mccMnc: mccMnc, operatorName: operatorName, sectorBaseOne: sectorBaseOne) {
        case .zeroBased: return index
        case .oneBased, .legacy: return index + 1
        }
    }

    /// Valeur de secteur à SOUMETTRE pour l'azimut à l'index donné.
    static func submissionValue(index: Int, mccMnc: String? = nil, operatorName: String?,
                                sectorBaseOne: Bool = SQFeatures.sectorBaseOne) -> Int {
        switch resolveMode(mccMnc: mccMnc, operatorName: operatorName, sectorBaseOne: sectorBaseOne) {
        case .oneBased: return index + 1
        case .zeroBased, .legacy: return index
        }
    }

    /// Index d'azimut (0-based) correspondant à une valeur de secteur stockée, en
    /// tolérant les deux conventions ; `nil` si rien ne tombe dans la plage.
    static func index(forStoredValue value: Int, azimuthCount: Int, mccMnc: String? = nil, operatorName: String?,
                      sectorBaseOne: Bool = SQFeatures.sectorBaseOne) -> Int? {
        guard azimuthCount > 0 else { return nil }
        let direct = (0..<azimuthCount).contains(value) ? value : nil
        let oneBased = (0..<azimuthCount).contains(value - 1) ? value - 1 : nil
        switch resolveMode(mccMnc: mccMnc, operatorName: operatorName, sectorBaseOne: sectorBaseOne) {
        case .oneBased: return oneBased ?? direct
        case .zeroBased, .legacy: return direct ?? oneBased
        }
    }

    /// Secteur déduit du PCI via la convention PSS (PCI mod 3), dans la numérotation
    /// de l'opérateur — bien plus fiable que le bearing antenne→utilisateur. `nil` si PCI < 0.
    static func sectorValue(forPci pci: Int, mccMnc: String? = nil, operatorName: String?,
                            sectorBaseOne: Bool = SQFeatures.sectorBaseOne) -> Int? {
        guard pci >= 0 else { return nil }
        return submissionValue(index: pci % 3, mccMnc: mccMnc, operatorName: operatorName, sectorBaseOne: sectorBaseOne)
    }

    /// PLMN (« 20810 ») d'une identification, quand son MCC et son MNC sont connus.
    /// Le MNC garde ses deux chiffres : c'est la forme que `resolveMode` lit.
    static func plmn(mcc: Int?, mnc: Int?) -> String? {
        guard let mcc, let mnc else { return nil }
        return String(format: "%03d%02d", mcc, mnc)
    }

    static func resolveMode(mccMnc: String?, operatorName: String?,
                            sectorBaseOne: Bool = SQFeatures.sectorBaseOne) -> Mode {
        // « Tout en base 1 » (décision d'Alexandre du 16/11) : plus de base 0 ni de legacy.
        if sectorBaseOne { return .oneBased }

        let code = (mccMnc ?? "").filter(\.isNumber)
        let mcc = String(code.prefix(3))
        let mncRaw = String(code.dropFirst(3))
        let trimmed = String(mncRaw.drop(while: { $0 == "0" }))
        let mnc = trimmed.isEmpty ? mncRaw : trimmed
        let name = (operatorName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        if mcc == "208" && ["1", "2", "15", "16", "20"].contains(mnc) { return .oneBased }
        if mcc == "208" && ["8", "10", "11", "13"].contains(mnc) { return .zeroBased }

        if name.contains("BOUYGUES") || name.contains("BYTEL") || name.contains("ORANGE")
            || (name.contains("FREE") && !name.contains("FREEDOM")) {
            return .oneBased
        }
        if name.contains("SFR") { return .zeroBased }
        return .legacy
    }
}

/// Ordre des cônes d'un support, dans lequel le serveur numérote les secteurs (contrat
/// sector-numbering-v1, `clusteredSectorAzimuths` puis `orderSectorAzimuths`). Bouygues
/// en zone très dense ou sur un Crozon qu'il mène, et SFR sur un Crozon mené par
/// Bouygues (SECTOR-NORTH-2), partent de l'azimut le plus proche du nord ; les autres
/// dans l'ordre croissant. Le numéro d'une cellule ne change pas : seul le cône qu'il
/// désigne change.
///
/// N'agit qu'en base 1 (`SQFeatures.sectorBaseOne`), avec l'en-tête : une build sans
/// l'en-tête garde l'ordre servi, et le serveur lui convertit les numéros SFR.
enum SectorOrientation {
    struct Context: Equatable, Sendable {
        var operatorName: String?
        var sharingType: String?
        var crozonLeader: String?
        var isZTD = false
    }

    /// Deux azimuts à 20° ou moins appartiennent au même secteur physique (doublons par bande).
    static let clusterToleranceDegrees = 20.0

    static func usesNorthFirst(_ context: Context) -> Bool {
        let name = (context.operatorName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let sharing = (context.sharingType ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let leader = (context.crozonLeader ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if name.contains("SFR") { return sharing == "crozon" && leader == "BOUYGUES" }
        guard name.contains("BOUYGUES") || name.contains("BYTEL") else { return false }
        if sharing == "zb" { return false }
        if sharing == "crozon" { return leader == "BOUYGUES" }
        return context.isZTD
    }

    /// Un azimut par secteur physique, trié : regroupement glouton à 20°, bouclage 360° → 0°
    /// compris, moyenne circulaire de chaque groupe.
    static func clustered(_ azimuths: [Double]) -> [Double] {
        let normalized = azimuths.filter(\.isFinite).map(normalize).sorted()
        guard let first = normalized.first, let last = normalized.last else { return [] }
        var groups: [[Double]] = [[first]]
        for (previous, value) in zip(normalized, normalized.dropFirst()) {
            if value - previous > clusterToleranceDegrees {
                groups.append([value])
            } else {
                groups[groups.count - 1].append(value)
            }
        }
        if groups.count > 1, 360 - last + first <= clusterToleranceDegrees {
            let tail = groups.removeLast()
            groups[0] = tail + groups[0]
        }
        return groups.map(circularMean).sorted()
    }

    /// Ordre de numérotation : croissant, ou à partir du plus proche du nord.
    static func ordered(_ azimuths: [Double], context: Context) -> [Double] {
        let sorted = azimuths.filter(\.isFinite).map(normalize).sorted()
        guard usesNorthFirst(context), sorted.count >= 2 else { return sorted }
        let northDistance = { (angle: Double) in min(angle, 360 - angle) }
        var start = 0
        for index in sorted.indices.dropFirst() where northDistance(sorted[index]) < northDistance(sorted[start]) {
            start = index
        }
        return Array(sorted[start...] + sorted[..<start])
    }

    /// Cônes dans l'ordre des numéros : le k-ième porte le secteur k (base 1). Sans la base 1,
    /// les azimuts tels quels (comportement des builds sans l'en-tête).
    static func numberedCones(_ azimuths: [Double], context: Context,
                              sectorBaseOne: Bool = SQFeatures.sectorBaseOne) -> [Double] {
        guard sectorBaseOne else { return azimuths }
        return ordered(clustered(azimuths), context: context)
    }

    /// Rang, dans `cones`, du cône le plus proche d'un azimut.
    static func nearestIndex(of azimuth: Double, in cones: [Double]) -> Int? {
        let target = normalize(azimuth)
        let gap = { (cone: Double) -> Double in
            let difference = abs(normalize(cone) - target)
            return min(difference, 360 - difference)
        }
        return cones.indices.min { gap(cones[$0]) < gap(cones[$1]) }
    }

    private static func normalize(_ angle: Double) -> Double {
        let value = angle.truncatingRemainder(dividingBy: 360)
        return value < 0 ? value + 360 : value
    }

    private static func circularMean(_ angles: [Double]) -> Double {
        var x = 0.0
        var y = 0.0
        for angle in angles {
            x += cos(angle * .pi / 180)
            y += sin(angle * .pi / 180)
        }
        return normalize(atan2(y, x) * 180 / .pi)
    }
}
