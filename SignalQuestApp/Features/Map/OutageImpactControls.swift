import SwiftUI

/**
 Les contrôles partagés des deux blocs facultatifs du signalement : fréquences et secteurs.

 Sortis de `OutageReportSheet` parce qu'ils ont leur propre géométrie et leurs propres règles
 d'accessibilité, et que la feuille dépasse déjà les 400 lignes.
 */

/// Une bande proposée par le formulaire, telle que le site la porte.
struct OutageBandOption: Equatable, Identifiable {
    /// Jeton envoyé au serveur : `b28`, `n78`.
    let token: String
    /// L'identifiant 3GPP lisible : « B28 ».
    let label: String
    /// La fréquence marketing en MHz. `nil` quand le référentiel ne la donne pas.
    let freqMhz: Int?

    var id: String { token }

    /// « B28 · 700 » — l'identifiant seul ne parle qu'aux experts, la fréquence seule est ambiguë.
    var displayLabel: String {
        guard let freqMhz else { return label }
        return "\(label) · \(freqMhz)"
    }
}

/**
 Une rangée de puces qui passe à la ligne.

 `LazyVGrid` avec des colonnes adaptatives, et non un `HStack` : les libellés de bande ont des
 largeurs très différentes (« B3 · 1800 » contre « n78 · 3500 »), et un `HStack` les aurait
 comprimés jusqu'à la troncature sur un iPhone SE.
 */
struct OutageWrapRow<Item, ID: Hashable, Content: View>: View {
    let items: [Item]
    let id: KeyPath<Item, ID>
    @ViewBuilder let content: (Item) -> Content

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 104), spacing: SQSpace.sm)],
            alignment: .leading,
            spacing: SQSpace.sm
        ) {
            ForEach(items, id: id) { item in
                content(item)
            }
        }
    }
}

/**
 Le radar des secteurs — un APERÇU, jamais le contrôle.

 Un cône de 65° dans 118 points donne une cible tactile très inférieure aux 44 points exigés, et il
 serait inatteignable à VoiceOver. Ce sont les puces d'azimut, à côté, qui portent la sélection ;
 le radar montre seulement où pointent les secteurs choisis. D'où `accessibilityHidden` : le lire
 ne dirait rien de plus que les puces, et allongerait le parcours.
 */
struct OutageSectorRadar: View {
    let azimuths: [Int]
    let selected: Set<Int>
    let tint: Color

    private let size: CGFloat = 118
    private let beamwidth: Double = 65

    var body: some View {
        Canvas { context, canvasSize in
            let radius = min(canvasSize.width, canvasSize.height) / 2 - 3
            let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)

            context.stroke(
                Path(ellipseIn: CGRect(
                    x: center.x - radius, y: center.y - radius,
                    width: radius * 2, height: radius * 2
                )),
                with: .color(SQColor.separator),
                lineWidth: 1
            )

            for azimuth in azimuths {
                var path = Path()
                path.move(to: center)
                // −90 : un azimut se compte depuis le NORD, un angle de dessin depuis l'est.
                path.addArc(
                    center: center,
                    radius: radius,
                    startAngle: .degrees(Double(azimuth) - beamwidth / 2 - 90),
                    endAngle: .degrees(Double(azimuth) + beamwidth / 2 - 90),
                    clockwise: false
                )
                path.closeSubpath()
                let isSelected = selected.contains(azimuth)
                context.fill(path, with: .color(isSelected ? tint.opacity(0.22) : SQColor.fill))
                if isSelected {
                    context.stroke(path, with: .color(tint), lineWidth: 2)
                }
            }

            context.fill(
                Path(ellipseIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)),
                with: .color(SQColor.label)
            )
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
