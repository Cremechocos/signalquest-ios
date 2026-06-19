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
enum SectorNumbering {
    enum Mode { case zeroBased, oneBased, legacy }

    /// Numéro de secteur AFFICHÉ pour un index d'azimut (0 = premier azimut trié),
    /// cohérent avec la valeur soumise.
    static func displayValue(index: Int, mccMnc: String? = nil, operatorName: String?) -> Int {
        switch resolveMode(mccMnc: mccMnc, operatorName: operatorName) {
        case .zeroBased: return index
        case .oneBased, .legacy: return index + 1
        }
    }

    /// Valeur de secteur à SOUMETTRE pour l'azimut à l'index donné.
    static func submissionValue(index: Int, mccMnc: String? = nil, operatorName: String?) -> Int {
        switch resolveMode(mccMnc: mccMnc, operatorName: operatorName) {
        case .oneBased: return index + 1
        case .zeroBased, .legacy: return index
        }
    }

    /// Index d'azimut (0-based) correspondant à une valeur de secteur stockée, en
    /// tolérant les deux conventions ; `nil` si rien ne tombe dans la plage.
    static func index(forStoredValue value: Int, azimuthCount: Int, mccMnc: String? = nil, operatorName: String?) -> Int? {
        guard azimuthCount > 0 else { return nil }
        let direct = (0..<azimuthCount).contains(value) ? value : nil
        let oneBased = (0..<azimuthCount).contains(value - 1) ? value - 1 : nil
        switch resolveMode(mccMnc: mccMnc, operatorName: operatorName) {
        case .oneBased: return oneBased ?? direct
        case .zeroBased, .legacy: return direct ?? oneBased
        }
    }

    /// Secteur déduit du PCI via la convention PSS (PCI mod 3), dans la numérotation
    /// de l'opérateur — bien plus fiable que le bearing antenne→utilisateur. `nil` si PCI < 0.
    static func sectorValue(forPci pci: Int, mccMnc: String? = nil, operatorName: String?) -> Int? {
        guard pci >= 0 else { return nil }
        return submissionValue(index: pci % 3, mccMnc: mccMnc, operatorName: operatorName)
    }

    static func resolveMode(mccMnc: String?, operatorName: String?) -> Mode {
        let code = (mccMnc ?? "").filter(\.isNumber)
        let mcc = String(code.prefix(3))
        let mncRaw = String(code.dropFirst(3))
        let trimmed = String(mncRaw.drop(while: { $0 == "0" }))
        let mnc = trimmed.isEmpty ? mncRaw : trimmed
        if mcc == "208" && ["1", "2", "15", "16", "20"].contains(mnc) { return .oneBased }
        if mcc == "208" && ["8", "10", "11", "13"].contains(mnc) { return .zeroBased }

        let name = (operatorName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if name.contains("BOUYGUES") || name.contains("BYTEL") || name.contains("ORANGE")
            || (name.contains("FREE") && !name.contains("FREEDOM")) {
            return .oneBased
        }
        if name.contains("SFR") { return .zeroBased }
        return .legacy
    }
}
