import SwiftUI

/// Couleurs de marque non thémées portées de la DA web
/// (map-nextjs/lib/operator-colors.ts et app/globals.css). Ces valeurs sont
/// identiques en light et dark : elles identifient un opérateur ou une
/// technologie, pas une surface.
enum SQBrand {
    // MARK: Accent signature (rouge plat de la landing --red / --red-deep)

    static let signatureStart = SQColor.brandRed
    static let signatureEnd = SQColor.brandRedDeep

    static var signatureGradient: LinearGradient {
        LinearGradient(
            colors: [signatureStart, signatureEnd],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: Technologies (web --color-5g/4g/3g/2g)

    static func techColor(_ tech: String) -> Color {
        switch tech.uppercased() {
        // Alignées sur l'échelle de génération de la carte (MapAnnotation/DriveTest)
        // pour qu'un badge « 3G »/« 2G » d'une fiche ait la MÊME couleur que le point
        // correspondant sur la carte (UI-05). 5G/4G étaient déjà identiques.
        case "5G", "NR", "5G_SA", "5G_NSA": return Color(hex: 0x8B5CF6)
        case "4G", "LTE": return Color(hex: 0x3B82F6)
        case "3G", "UMTS": return Color(hex: 0x14B8A6)
        case "2G", "GSM": return Color(hex: 0xF59E0B)
        default: return Color(hex: 0x6B7280)
        }
    }

    // MARK: Opérateurs (gradients hero du SidePanel web)

    struct OperatorColors {
        let start: Color
        let end: Color
        let name: String

        var gradient: LinearGradient {
            LinearGradient(colors: [start, end], startPoint: .topLeading, endPoint: .bottomTrailing)
        }

        /// Couleur unique (marqueurs carte, pastilles) — le départ du gradient.
        var solid: Color { start }
    }

    private static let operators: [String: OperatorColors] = [
        "sfr": .init(start: Color(hex: 0xE2001A), end: Color(hex: 0xFF5A33), name: "SFR"),
        "bouygues": .init(start: Color(hex: 0x1A3A7F), end: Color(hex: 0x3B5BDB), name: "Bouygues"),
        "orange": .init(start: Color(hex: 0xFF6B35), end: Color(hex: 0xFFA44F), name: "Orange"),
        "free": .init(start: Color(hex: 0x52525B), end: Color(hex: 0x27272A), name: "Free"),
        "digicel": .init(start: Color(hex: 0xB91C1C), end: Color(hex: 0xF97316), name: "Digicel"),
        "outremer": .init(start: Color(hex: 0x8B5CF6), end: Color(hex: 0x22D3EE), name: "Outremer Telecom"),
        "srr": .init(start: Color(hex: 0x0EA5E9), end: Color(hex: 0x38BDF8), name: "SRR"),
        "telcooi": .init(start: Color(hex: 0x22C55E), end: Color(hex: 0x14B8A6), name: "Telco OI"),
        "zeop": .init(start: Color(hex: 0xF59E0B), end: Color(hex: 0xFCD34D), name: "Zeop"),
        "maore": .init(start: Color(hex: 0x0891B2), end: Color(hex: 0x67E8F9), name: "Maore Mobile"),
        "shared": .init(start: Color(hex: 0xE2001A), end: Color(hex: 0x1A3A7F), name: "SFR / Bouygues"),
        "bell": .init(start: Color(hex: 0x0F5BDC), end: Color(hex: 0x3B82F6), name: "Bell"),
        "rogers": .init(start: Color(hex: 0xD62D20), end: Color(hex: 0xEF4444), name: "Rogers"),
        "telus": .init(start: Color(hex: 0x00A67E), end: Color(hex: 0x34D399), name: "TELUS"),
        "videotron": .init(start: Color(hex: 0x7A3DF0), end: Color(hex: 0xA78BFA), name: "Videotron/Freedom"),
        "regional": .init(start: Color(hex: 0xD97706), end: Color(hex: 0xF59E0B), name: "Regional"),
    ]

    static let defaultOperator = operators["sfr"]!

    /// Résolution tolérante, même heuristique que getOperatorColors web.
    static func operatorColors(_ rawName: String?) -> OperatorColors {
        guard let rawName, !rawName.isEmpty else { return defaultOperator }
        let n = rawName.lowercased()
        if n.contains("sfr") && !n.contains("srr") { return operators["sfr"]! }
        if n.contains("bouygues") || n.contains("bytel") { return operators["bouygues"]! }
        if n.contains("orange") { return operators["orange"]! }
        if n.contains("free") && !n.contains("freedom") { return operators["free"]! }
        if n.contains("digicel") { return operators["digicel"]! }
        if n.contains("outremer") || n.contains("only") { return operators["outremer"]! }
        if n == "srr" || n.contains("réunionnaise") || n.contains("reunionnaise") { return operators["srr"]! }
        if n.contains("telco") && n.contains("oi") { return operators["telcooi"]! }
        if n.contains("zeop") { return operators["zeop"]! }
        if n.contains("maore") { return operators["maore"]! }
        if n.contains("bell") || n.contains("aliant") || n.contains("mts") { return operators["bell"]! }
        if n.contains("rogers") || n.contains("fido") { return operators["rogers"]! }
        if n.contains("telus") || n.contains("koodo") || n.contains("public mobile") { return operators["telus"]! }
        if n.contains("videotron") || n.contains("vidéotron") || n.contains("freedom") || n.contains("shaw") { return operators["videotron"]! }
        if n.contains("regional") || n.contains("sogetel") { return operators["regional"]! }
        return defaultOperator
    }

    static func operatorColor(_ rawName: String?) -> Color {
        operatorColors(rawName).solid
    }
}

extension Color {
    /// `Color(hex: 0xF15B00)` — pour les constantes de marque non thémées.
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}
