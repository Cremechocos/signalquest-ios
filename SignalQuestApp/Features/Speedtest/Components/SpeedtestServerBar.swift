import SwiftUI

struct SpeedtestServerBar: View {
    /// Opérateur mobile (Orange, SFR…) lu via CoreTelephony. nil/vide en WiFi ou
    /// quand l'API ne le renvoie pas (placeholder iOS 16.4+).
    let operatorName: String?
    /// Technologie d'accès (5G NSA, 4G, WiFi…).
    let network: String
    /// Serveur de download/ping actif (CDN AWS CloudFront par défaut).
    let server: String
    /// Connexion disponible : le point est vert en ligne, rouge hors ligne.
    var isOnline: Bool = true
    /// Ouvre la page « Serveur de test » ; `nil` pendant une mesure.
    var action: (() -> Void)? = nil

    /// « 5G NSA · Orange · CloudFront Paris » ou « Wi‑Fi · SFR · Lyon BBR » :
    /// le lien réellement utilisé est toujours annoncé avant son fournisseur.
    var label: String {
        var parts: [String] = [network]
        if let op = operatorName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !op.isEmpty, op != network {
            parts.append(op)
        }
        parts.append(server)
        return parts.joined(separator: " · ")
    }

    var body: some View {
        if let action {
            Button {
                Haptics.selection()
                action()
            } label: {
                pill(showsChevron: true)
            }
            .buttonStyle(SQPressButtonStyle())
            .accessibilityHint("Ouvre le choix du serveur de test")
            .accessibilityIdentifier("speedtest.networkBar")
        } else {
            pill(showsChevron: false)
                .accessibilityIdentifier("speedtest.networkBar")
        }
    }

    private func pill(showsChevron: Bool) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(isOnline ? SQColor.success : SQColor.danger)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(LocalizedStringKey(label))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(SQColor.label)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(SQColor.labelSecondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 7)
        .frame(minHeight: 44)
        .padding(.horizontal, SQSpace.md2)
        .sqSurface(SQColor.surface, in: Capsule(style: .continuous))
        .sqShadowSoft()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Réseau : \(label)")
    }
}
