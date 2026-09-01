import SwiftUI

struct SpeedtestServerBar: View {
    /// Opérateur mobile (Orange, SFR…) lu via CoreTelephony. nil/vide en WiFi ou
    /// quand l'API ne le renvoie pas (placeholder iOS 16.4+).
    let operatorName: String?
    /// Technologie d'accès (5G NSA, 4G, WiFi…).
    let network: String
    /// Serveur de download/ping actif (CDN AWS CloudFront par défaut).
    let server: String

    /// « Orange · 5G NSA · CloudFront Paris » — l'opérateur quand il est connu.
    var label: String {
        var parts: [String] = []
        if let op = operatorName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !op.isEmpty, op != network {
            parts.append(op)
        }
        parts.append(network)
        parts.append(server)
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(SQColor.success)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(LocalizedStringKey(label))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(SQColor.label)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, SQSpace.md + 2)
        .background(SQColor.surface, in: Capsule(style: .continuous))
        .sqShadowSoft()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Réseau : \(label)")
    }
}
