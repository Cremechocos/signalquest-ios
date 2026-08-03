import SwiftUI

/// Les termes radio de la fiche antenne, expliqués avec les chiffres du site
/// qu'on est en train de regarder.
///
/// « Dégagement Fresnel : 312 % » ne veut rien dire pour qui n'a pas fait de
/// radio, et une définition générique ne vaut guère mieux. Chaque entrée dit
/// donc ce qu'est la grandeur, ce que vaut CE site, et ce qu'il faut en conclure.
struct AntennaGlossaryEntry: Identifiable, Equatable {
    var id: String { title }
    let title: String
    /// Ce que la grandeur mesure, en une ou deux phrases.
    let definition: String
    /// Lecture de la valeur du site en cours — nil quand elle est inconnue.
    let reading: String?
    /// Repères chiffrés, quand ils aident à situer la valeur.
    let scale: [(String, String)]

    static func == (lhs: AntennaGlossaryEntry, rhs: AntennaGlossaryEntry) -> Bool {
        lhs.title == rhs.title && lhs.reading == rhs.reading
    }
}

enum AntennaGlossary {
    static func distance(_ meters: Double) -> AntennaGlossaryEntry {
        AntennaGlossaryEntry(
            title: String(localized: "Distance"),
            definition: String(localized: "La distance à vol d'oiseau entre toi et le pied du support, mesurée sur l'ellipsoïde terrestre. Ce n'est pas la longueur du trajet radio, qui monte jusqu'aux antennes."),
            reading: String(localized: "Tu es à \(SQUnits.distance(meters: meters)) du site."),
            scale: [
                (String(localized: "< 300 m"), String(localized: "très proche, le signal dépend surtout de l'orientation du secteur")),
                (String(localized: "300 m – 2 km"), String(localized: "portée urbaine typique en 3500 MHz")),
                (String(localized: "> 5 km"), String(localized: "seules les bandes basses (700, 800 MHz) portent aussi loin")),
            ]
        )
    }

    static func elevationGap(user: Double?, site: Double?) -> AntennaGlossaryEntry {
        let reading: String?
        if let user, let site {
            let delta = site - user
            reading = delta >= 0
                ? String(localized: "Le site domine ta position de \(Int(delta.rounded())) m.")
                : String(localized: "Tu domines le site de \(Int(abs(delta).rounded())) m.")
        } else {
            reading = nil
        }
        return AntennaGlossaryEntry(
            title: String(localized: "Dénivelé"),
            definition: String(localized: "L'écart d'altitude entre le sol sous tes pieds et le sol au pied du support. Un site perché voit par-dessus les obstacles ; un site en contrebas se fait masquer par le moindre relief."),
            reading: reading,
            scale: []
        )
    }

    static func altitude(_ meters: Double?, isSite: Bool) -> AntennaGlossaryEntry {
        AntennaGlossaryEntry(
            title: isSite ? String(localized: "Altitude du site") : String(localized: "Ton altitude"),
            definition: String(localized: "Altitude du sol au-dessus du niveau de la mer, lue dans le modèle numérique de terrain de l'IGN — pas dans le GPS, dont la précision verticale est bien plus faible."),
            reading: meters.map { String(localized: "\(Int($0.rounded())) m au-dessus du niveau de la mer.") },
            scale: []
        )
    }

    static func supportHeight(_ meters: Double?, label: String?) -> AntennaGlossaryEntry {
        AntennaGlossaryEntry(
            title: String(localized: "Hauteur du support"),
            definition: String(localized: "La hauteur totale de la structure qui porte les antennes — pylône, château d'eau, clocher, toit d'immeuble. Elle dépasse souvent la hauteur des antennes elles-mêmes."),
            reading: meters.map { value in
                let kind = label ?? String(localized: "support")
                return String(localized: "Ce \(kind.lowercased()) mesure \(Int(value.rounded())) m.")
            },
            scale: []
        )
    }

    static func antennaHeight(_ meters: Double?, isEstimated: Bool) -> AntennaGlossaryEntry {
        AntennaGlossaryEntry(
            title: String(localized: "Hauteur d'antenne"),
            definition: String(localized: "La hauteur à laquelle les antennes rayonnent, au-dessus du sol du site. C'est elle que vise la ligne de visée, et elle qui détermine jusqu'où le signal passe au-dessus des obstacles."),
            reading: meters.map { value in
                isEstimated
                    ? String(localized: "Antennes à environ \(Int(value.rounded())) m — la hauteur exacte n'étant pas publiée, celle du support est utilisée.")
                    : String(localized: "Antennes à \(Int(value.rounded())) m au-dessus du sol du site.")
            },
            scale: []
        )
    }

    static func downtilt(_ degrees: Double?) -> AntennaGlossaryEntry {
        AntennaGlossaryEntry(
            title: String(localized: "Tilt"),
            definition: String(localized: "L'inclinaison d'une antenne vers le bas. Les opérateurs l'utilisent pour concentrer l'énergie sur la zone à couvrir plutôt que de l'envoyer à l'horizon, où elle brouillerait les cellules voisines. Le chiffre donné ici est purement géométrique : c'est l'angle qui pointerait exactement sur toi."),
            reading: degrees.map { value in
                let rounded = String(format: "%.1f", abs(value)).replacingOccurrences(of: ".", with: ",")
                return value >= 0
                    ? String(localized: "Une antenne inclinée de \(rounded)° vers le bas te viserait exactement.")
                    : String(localized: "Tu es au-dessus de l'antenne : il faudrait la relever de \(rounded)° pour te viser.")
            },
            scale: [
                (String(localized: "0 – 3°"), String(localized: "couverture lointaine, typique d'un site rural")),
                (String(localized: "3 – 8°"), String(localized: "couverture urbaine classique")),
                (String(localized: "> 10°"), String(localized: "tu es très près du pied du support")),
            ]
        )
    }

    static func lineOfSight(_ verdict: AntennaSightGeometry.SightVerdict?) -> AntennaGlossaryEntry {
        let reading: String?
        switch verdict?.level {
        case .clear:
            reading = String(localized: "Rien ne coupe la droite entre tes yeux et les antennes.")
        case .grazing:
            reading = String(localized: "La droite passe, mais un obstacle entame la zone de Fresnel : le signal s'atténue sans être coupé.")
        case .blocked:
            let distance = verdict?.obstacleDistanceMeters.map { SQUnits.distance(meters: $0) }
            reading = distance.map { String(localized: "Un obstacle coupe la droite à \($0).") }
                ?? String(localized: "Un obstacle coupe la droite.")
        case nil:
            reading = nil
        }
        return AntennaGlossaryEntry(
            title: String(localized: "Ligne de visée"),
            definition: String(localized: "La droite entre tes yeux et les antennes. Quand elle est dégagée, la liaison est dite « en visibilité directe » : c'est le cas le plus favorable. Sinon le signal doit contourner ou traverser, et perd beaucoup."),
            reading: reading,
            scale: []
        )
    }

    static func fresnelClearance(_ ratio: Double?) -> AntennaGlossaryEntry {
        AntennaGlossaryEntry(
            title: String(localized: "Dégagement Fresnel"),
            definition: String(localized: "Une onde n'emprunte pas seulement la droite entre les deux points : elle occupe un fuseau autour d'elle, la première zone de Fresnel. Tant que ce fuseau reste libre, la liaison se comporte comme en visibilité directe. Le chiffre indique quelle part en reste dégagée."),
            reading: ratio.map { value in
                let percent = Int((value * 100).rounded())
                if percent < 0 { return String(localized: "La zone est obstruée : la ligne de visée elle-même est coupée.") }
                if percent >= 100 { return String(localized: "La zone est entièrement libre (\(percent) %) — la liaison se comporte comme en visibilité directe.") }
                if percent >= 60 { return String(localized: "\(percent) % de la zone reste libre : au-dessus du seuil, la liaison n'est pas pénalisée.") }
                return String(localized: "\(percent) % seulement : sous le seuil de 60 %, le signal s'atténue même sans obstacle franc.")
            },
            scale: [
                ("≥ 100 %", String(localized: "fuseau entièrement libre")),
                ("60 – 100 %", String(localized: "suffisant, c'est le seuil retenu par l'UIT")),
                ("< 60 %", String(localized: "atténuation par diffraction")),
                ("< 0 %", String(localized: "la droite est coupée")),
            ]
        )
    }

    static func fresnelRadius(_ meters: Double?, frequencyMhz: Double) -> AntennaGlossaryEntry {
        AntennaGlossaryEntry(
            title: String(localized: "Rayon de Fresnel"),
            definition: String(localized: "La demi-largeur du fuseau au point le plus large, à mi-parcours. Il grandit avec la distance et rétrécit quand la fréquence monte : une liaison en 700 MHz demande beaucoup plus de dégagement qu'en 3500 MHz."),
            reading: meters.map { String(localized: "Le fuseau atteint \(Int($0.rounded())) m de rayon, calculé à \(Int(frequencyMhz)) MHz — la bande la plus basse du site, la plus exigeante.") },
            scale: []
        )
    }
}

/// Feuille d'explication d'un terme, ouverte depuis le « i » d'une tuile.
struct AntennaGlossarySheet: View {
    let entry: AntennaGlossaryEntry
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SQSpace.lg) {
                    if let reading = entry.reading {
                        Text(reading)
                            .font(SQType.heading)
                            .foregroundStyle(SQColor.label)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(SQSpace.lg)
                            .background(SQColor.accentSoft, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
                    }

                    Text(entry.definition)
                        .font(SQType.body)
                        .foregroundStyle(SQColor.label)
                        .fixedSize(horizontal: false, vertical: true)

                    if !entry.scale.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Repères").sqKicker()
                            ForEach(entry.scale, id: \.0) { bound, meaning in
                                HStack(alignment: .top, spacing: SQSpace.md) {
                                    Text(bound)
                                        .font(SQFont.archivo(12.5, .bold))
                                        .foregroundStyle(SQColor.brandRed)
                                        .frame(width: 92, alignment: .leading)
                                    Text(meaning)
                                        .font(SQType.caption)
                                        .foregroundStyle(SQColor.labelSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(SQSpace.lg)
                        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
                        .sqShadowCard()
                    }
                }
                .padding(SQSpace.lg + 2)
            }
            .signalQuestBackground()
            .navigationTitle(entry.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fermer") { dismiss() }
                        .tint(SQColor.brandRed)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// Tuile de mesure avec son « i ». Le tap n'agrandit pas la valeur : il explique
/// ce qu'elle veut dire, avec le chiffre du site en exemple.
struct AntennaMetricTile: View {
    let label: String
    let value: String
    var highlight = false
    let entry: AntennaGlossaryEntry
    @Binding var selection: AntennaGlossaryEntry?

    var body: some View {
        Button {
            Haptics.light()
            selection = entry
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(LocalizedStringKey(label))
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Spacer(minLength: 0)
                    Image(systemName: "info.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SQColor.labelTertiary)
                }
                Text(value)
                    .font(SQFont.archivo(17, .bold))
                    .foregroundStyle(highlight ? SQColor.brandRed : SQColor.label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(SQSpace.md)
            .background(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityLabel("\(label) : \(value)")
        .accessibilityHint("Toucher pour comprendre cette mesure")
    }
}
