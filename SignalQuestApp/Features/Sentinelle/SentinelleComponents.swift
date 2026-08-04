import SwiftUI

/// Briques partagées par les trois écrans Sentinelle : pastilles d'état, lignes
/// de mesure, barres proportionnelles, feuilles de saisie, et la formulation des
/// verdicts.
///
/// Les verdicts vivent ici plutôt que dans chaque vue parce qu'ils sont la seule
/// chose que l'utilisateur lit vraiment : une phrase écrite de SON point de vue
/// (« ma box ne répond plus »), jamais de celui du système (« status: down »).

// MARK: - Pastilles d'état

/// Pastille d'état. Les couleurs sont SÉMANTIQUES et ne suivent pas l'accent de
/// la DA : un état se lit à sa couleur, pas à celle du bouton d'à côté.
struct SentinelleStatusDot: View {
    let color: Color
    var size: CGFloat = 10

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .sqDecorative()
    }
}

// MARK: - Titres et mesures

/// En-tête de carte : pastille d'icône brique + titre Bricolage, comme dans
/// `ANFRStatsView`.
struct SentinelleSectionTitle: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: SQSpace.sm) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SQColor.brandRed)
                .frame(width: 32, height: 32)
                .background(SQColor.accentSoft, in: Circle())
                .sqDecorative()
            Text(LocalizedStringKey(title))
                .font(SQType.heading)
                .foregroundStyle(SQColor.label)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sqHeader()
    }
}

/// Une mesure : son nom, ce qu'elle recouvre exactement, sa valeur.
///
/// L'indice n'est pas décoratif — « disponibilité » ne veut pas dire la même
/// chose pour une famille seule et pour la box entière, et c'est lui qui le dit.
struct SentinelleMetricRow: View {
    let label: String
    let hint: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: SQSpace.md) {
            VStack(alignment: .leading, spacing: 1) {
                Text(LocalizedStringKey(label))
                    .font(SQType.body)
                    .foregroundStyle(SQColor.label)
                Text(LocalizedStringKey(hint))
                    .font(SQType.micro)
                    .foregroundStyle(SQColor.labelSecondary)
            }
            Spacer(minLength: SQSpace.sm)
            Text(value)
                .font(SQFont.display(16, .bold))
                .monospacedDigit()
                .foregroundStyle(SQColor.label)
        }
        .padding(.vertical, SQSpace.sm - 2)
        .sqMetric(name: NSLocalizedString(label, comment: ""), value: value)
    }
}

/// Sélecteur de fenêtre de lecture.
///
/// Partagé par la page d'une box et par celle d'une adresse : deux graphes qui
/// se lisent de la même façon doivent se piloter de la même façon, et un
/// deuxième exemplaire finirait par en diverger.
struct SentinelleWindowPicker: View {
    @Binding var selection: SentinelleWindow
    /// Joué avant le changement. La page d'une adresse y lâche son curseur de
    /// lecture, qui pointerait sinon une mesure d'une autre fenêtre.
    var onSelect: () -> Void = {}

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: SQSpace.sm) {
                ForEach(SentinelleWindow.allCases) { value in
                    let isSelected = value == selection
                    Button {
                        Haptics.selection()
                        onSelect()
                        selection = value
                    } label: {
                        Text(value.label)
                            .font(SQFont.body(13, .semibold))
                            .padding(.horizontal, SQSpace.md)
                            .frame(height: 34)
                            .background(
                                isSelected ? AnyShapeStyle(SQColor.brandRed) : AnyShapeStyle(SQColor.surfaceMuted),
                                in: Capsule(style: .continuous)
                            )
                            .foregroundStyle(isSelected ? SQColor.onAccent : SQColor.label)
                    }
                    .buttonStyle(SQPressButtonStyle())
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .sqAnimation(SQMotion.fast, value: isSelected)
                }
            }
            .padding(.horizontal, 2)
        }
    }
}

/// Barre proportionnelle sur une échelle COMMUNE à toutes les lignes d'une
/// carte. Normaliser chaque ligne sur son propre maximum ferait paraître un
/// saut à 2 ms aussi chargé qu'un saut à 200 ms.
struct SentinelleBar: View {
    let fraction: Double
    var color: Color = SQColor.brandRed
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(SQColor.surfaceMuted)
                Capsule()
                    .fill(color)
                    .frame(width: proxy.size.width * fraction.clamped(to: 0...1))
            }
        }
        .frame(height: height)
        .sqDecorative()
    }
}

// MARK: - Saisie

/// Champ de saisie de la DA : fond `SurfaceMuted`, rayon 14, aucune bordure.
struct SentinelleField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    /// Phrase d'aide, souvent dynamique (elle dépend de ce que le serveur a vu).
    var hint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.xs + 2) {
            Text(LocalizedStringKey(title))
                .font(SQType.micro)
                .foregroundStyle(SQColor.labelSecondary)
            TextField(LocalizedStringKey(placeholder), text: $text)
                .font(SQType.body)
                .foregroundStyle(SQColor.label)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .padding(.horizontal, SQSpace.lg)
                .frame(minHeight: 48)
                .background(
                    SQColor.surfaceMuted,
                    in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
                )
            if let hint {
                Text(hint)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Adresse publique vue par le serveur, avec ce qu'on en retient et POURQUOI.
///
/// L'avertissement n'est pas décoratif : sans lui, remplacer l'adresse observée
/// par la passerelle du préfixe passerait pour une erreur de saisie.
struct SentinelleDetectedAddress: View {
    let ip: String
    let family: SentinelleFamily
    let suggestion: SentinelleIpv6Suggestion
    let onUse: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            HStack(alignment: .center, spacing: SQSpace.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Utiliser ma connexion actuelle")
                        .font(SQType.body)
                        .foregroundStyle(SQColor.label)
                    Text("Détectée en \(family.label) · \(ip)")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(SQColor.labelSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Spacer(minLength: SQSpace.sm)
                Button("Utiliser") {
                    Haptics.selection()
                    onUse()
                }
                .font(SQFont.body(13, .semibold))
                .foregroundStyle(SQColor.accentInk)
                .padding(.horizontal, SQSpace.md)
                .padding(.vertical, SQSpace.sm)
                .background(SQColor.accentSoft, in: Capsule(style: .continuous))
                .buttonStyle(SQPressButtonStyle())
            }

            if let warning = suggestion.warning {
                VStack(alignment: .leading, spacing: SQSpace.sm) {
                    Text(warning)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.label)
                        .fixedSize(horizontal: false, vertical: true)
                    if let prefix = suggestion.prefix {
                        Text("Préfixe \(prefix.label)\nProposé \(suggestion.suggested)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(SQSpace.md)
                .background(
                    SQColor.warningSoft,
                    in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
                )
            }
        }
        .padding(.top, SQSpace.xs)
    }
}

/// Enveloppe commune des deux feuilles de saisie : poignée, titre, explication.
private struct SentinelleSheetShell<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                SQSheetHandle()
                Text(title)
                    .font(SQType.title)
                    .foregroundStyle(SQColor.label)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                content()
            }
            .padding(SQSpace.lg)
            .sqReadableWidth()
        }
        .background(SQColor.bg)
        .presentationDetents([.medium, .large])
        .presentationBackgroundCompat(.ultraThinMaterial)
    }
}

/// Création d'une connexion. Le bouton n'existe qu'au niveau ACCUEIL : compléter
/// une box existante est une MODIFICATION, et elle se fait depuis sa page.
struct SentinelleCreateSheet: View {
    let quota: SentinelleQuota?
    let currentIp: () async -> SentinelleCurrentIp?
    let onCreate: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var address = ""
    @State private var detected: SentinelleCurrentIp?

    var body: some View {
        SentinelleSheetShell(
            title: String(localized: "Nouvelle connexion"),
            subtitle: String(localized: "Sentinelle l’interrogera chaque minute depuis nos serveurs — téléphone éteint compris.")
        ) {
            SentinelleField(title: "Nom", placeholder: "Ma box", text: $label)
            SentinelleField(
                title: "Adresse ou nom d’hôte",
                placeholder: "79.88.27.93",
                text: $address,
                hint: detectionHint
            )

            if let detected, detected.usable, let ip = detected.ip, let family = detected.family {
                // Même en création : proposer l'IPv6 vue telle quelle
                // enregistrerait l'adresse du téléphone, pas celle de la box.
                let suggestion = SentinelleIpv6.suggestBoxAddress(observed: ip)
                SentinelleDetectedAddress(ip: ip, family: family, suggestion: suggestion) {
                    address = suggestion.suggested
                }
            }

            GradientButton("Commencer la surveillance", systemImage: "dot.radiowaves.left.and.right") {
                onCreate(
                    label.trimmingCharacters(in: .whitespacesAndNewlines),
                    address.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                dismiss()
            }
            .disabled(!isValid)
            .opacity(isValid ? 1 : 0.5)

            if let quota {
                Text(String(localized: "\(SentinelleWording.monitored(quota.used)) sur \(quota.max)."))
                    .font(SQType.micro)
                    .foregroundStyle(SQColor.labelSecondary)
            }
        }
        .task { detected = await currentIp() }
    }

    private var isValid: Bool {
        !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var detectionHint: String? {
        guard let detected else { return nil }
        if detected.usable { return nil }
        // Derrière un CGNAT, l'adresse vue par le serveur n'est pas joignable de
        // l'extérieur : le dire vaut mieux que de laisser créer une cible morte.
        return detected.message
            ?? String(localized: "Votre connexion actuelle n’est pas joignable depuis l’extérieur.")
    }
}

/// Saisie de l'adresse d'UNE famille — ajout de la famille manquante ou
/// correction d'une adresse existante. Dans les deux cas c'est une modification :
/// la box reste une seule connexion, avec un seul historique et un seul quota.
struct SentinelleAddressSheet: View {
    let target: SentinelleTarget
    let family: SentinelleFamily
    /// Valeur actuelle quand il s'agit d'une correction ; nulle pour un ajout.
    let existing: String?
    let currentIp: () async -> SentinelleCurrentIp?
    let onSubmit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var detected: SentinelleCurrentIp?
    @State private var touched = false

    var body: some View {
        // L'adresse vue par le serveur n'est utile que si elle appartient à la
        // famille visée : un téléphone connecté en IPv4 ne peut pas révéler
        // l'IPv6 de la box.
        let usable = detected.flatMap { $0.usable && $0.family == family ? $0 : nil }
        let suggestion = usable?.ip.map { SentinelleIpv6.suggestBoxAddress(observed: $0) }

        return SentinelleSheetShell(
            title: existing == nil
                ? String(localized: "Ajouter l’\(family.label)")
                : String(localized: "Modifier l’\(family.label)"),
            subtitle: String(localized: "Cette adresse rejoint « \(target.label) » : même historique, même alerte, même quota. Ce n’est pas une seconde connexion.")
        ) {
            SentinelleField(
                title: "\(family.label) de « \(target.label) »",
                placeholder: family == .v6 ? "2a01:cb00:1234:5600::1" : "79.88.27.93",
                text: $draft,
                hint: hint(usable: usable)
            )

            if let usable, let ip = usable.ip, let suggestion {
                // Reproposer l'adresse détectée reste utile même en correction :
                // c'est le geste par lequel on répare une IPv6 devenue morte.
                SentinelleDetectedAddress(ip: ip, family: family, suggestion: suggestion) {
                    draft = suggestion.suggested
                    touched = true
                }
            }

            GradientButton(
                existing == nil
                    ? String(localized: "Ajouter cette adresse")
                    : String(localized: "Enregistrer"),
                systemImage: "checkmark"
            ) {
                onSubmit(draft.trimmingCharacters(in: .whitespacesAndNewlines))
                dismiss()
            }
            .disabled(!isValid)
            .opacity(isValid ? 1 : 0.5)
        }
        .onAppear { if draft.isEmpty, !touched { draft = existing ?? "" } }
        .task {
            detected = await currentIp()
            // Préremplissage : on n'écrase JAMAIS ce que l'utilisateur a commencé
            // à taper, et la proposition passe par le calcul de préfixe /64.
            if !touched, draft.isEmpty, let ip = detected?.ip,
               detected?.usable == true, detected?.family == family {
                draft = SentinelleIpv6.suggestBoxAddress(observed: ip).suggested
            }
        }
        .onChangeCompat(of: draft) { _, _ in touched = true }
    }

    private var isValid: Bool {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && value != existing
    }

    private func hint(usable: SentinelleCurrentIp?) -> String {
        if usable != nil {
            return String(localized: "Déduite de la connexion depuis laquelle vous consultez.")
        }
        if detected?.usable == false {
            return String(localized: "Votre connexion actuelle n’est pas joignable de l’extérieur — saisissez l’adresse.")
        }
        return String(localized: "Depuis votre box, cherchez son adresse \(family.label) publique.")
    }
}

// MARK: - Formulation

enum SentinelleWording {

    static func statusColor(_ status: String) -> Color {
        switch status {
        case "up": return SQColor.success
        case "down": return SQColor.danger
        case "degraded": return SQColor.warning
        default: return SQColor.labelTertiary
        }
    }

    static func stateColor(_ state: SentinelleAddressState) -> Color {
        switch state {
        case .up: return SQColor.success
        case .degraded: return SQColor.warning
        case .down: return SQColor.danger
        case .unknown: return SQColor.labelTertiary
        }
    }

    /// Phrase d'état d'une box, écrite du point de vue de l'utilisateur.
    static func verdict(_ target: SentinelleTarget) -> String {
        switch target.status {
        case "up": return String(localized: "\(target.label) répond normalement.")
        case "down": return String(localized: "\(target.label) ne répond plus.")
        case "degraded": return String(localized: "\(target.label) répond mal.")
        default: return String(localized: "\(target.label) · en attente de mesure")
        }
    }

    static func addressVerdict(
        _ target: SentinelleTarget,
        _ address: SentinelleAddress,
        _ state: SentinelleAddressState?
    ) -> String {
        switch state {
        case .up: return String(localized: "\(target.label) répond en \(address.familyLabel).")
        case .degraded: return String(localized: "\(target.label) répond mal en \(address.familyLabel).")
        case .down: return String(localized: "Plus aucune réponse en \(address.familyLabel).")
        case .unknown: return String(localized: "Aucune mesure en \(address.familyLabel) pour l’instant.")
        // Mesures pas encore arrivées : on ne conclut RIEN, sinon une page qui
        // charge annoncerait « aucune mesure ».
        case nil: return String(localized: "\(address.familyLabel) de \(target.label)")
        }
    }

    /// Ce qu'on peut dire d'une adresse en une ligne, sans jamais forcer un chiffre.
    static func addressStateLabel(_ state: SentinelleAddressState, _ metrics: SentinelleMetrics?) -> String {
        let rtt = metrics?.rttMs.map { " · \(ms($0))" } ?? ""
        switch state {
        case .up: return String(localized: "Répond\(rtt)")
        case .degraded: return String(localized: "Réponses irrégulières\(rtt)")
        case .down: return String(localized: "Ne répond plus")
        case .unknown: return String(localized: "En attente de mesure")
        }
    }

    static func cause(_ incident: SentinelleIncident) -> String {
        switch incident.cause {
        case "local": return String(localized: "votre connexion")
        case "isp": return String(localized: "réseau opérateur")
        case "transit": return String(localized: "transit")
        default:
            let others = incident.correlatedUsers ?? 0
            return others > 0
                ? String(localized: "\(others) autre abonné touché")
                : String(localized: "origine non déterminée")
        }
    }

    /// Décomptes : le pluriel passe par une variation du catalogue, jamais par un
    /// « (s) » ni par un `n > 1` interpolé — cette règle-là est FRANÇAISE, et en
    /// anglais zéro prend le pluriel (cf. `PluralVariationTests`).
    static func outages(_ count: Int) -> String {
        String(localized: "\(count) coupure")
    }

    static func lostBursts(_ count: Int) -> String {
        String(localized: "\(count) salve perdue")
    }

    static func monitored(_ count: Int) -> String {
        String(localized: "\(count) connexion surveillée")
    }

    /// 0 = lundi, comme la saisonnalité du serveur.
    static func weekday(_ index: Int) -> String? {
        let days = [
            String(localized: "lundi"), String(localized: "mardi"), String(localized: "mercredi"),
            String(localized: "jeudi"), String(localized: "vendredi"), String(localized: "samedi"),
            String(localized: "dimanche"),
        ]
        return days.indices.contains(index) ? days[index] : nil
    }

    // MARK: Nombres

    /// Sous 10 ms, l'entier écrase la différence entre 2 et 9 ms — c'est
    /// pourtant l'écart entre une fibre proche et une fibre lointaine.
    ///
    /// Mise en forme LOCALISÉE : `String(format:)` écrirait « 9.4 » là où le
    /// français attend « 9,4 », et tout l'écran est en français.
    static func ms(_ value: Double?) -> String {
        guard let value else { return "—" }
        let digits = value < 10 ? 1 : 0
        return "\(value.formatted(.number.precision(.fractionLength(digits)))) ms"
    }

    static func percent(_ value: Double?, decimals: Int = 1) -> String {
        guard let value else { return "—" }
        return "\(value.formatted(.number.precision(.fractionLength(decimals)))) %"
    }

    static func duration(_ seconds: Int?) -> String {
        guard let seconds else { return "—" }
        if seconds < 60 { return "\(seconds) s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) min" }
        return String(format: "%d h %02d", minutes / 60, minutes % 60)
    }

    /// Les dates arrivent en ISO 8601 ; on les rend dans le format local.
    static func date(_ iso: String?) -> String {
        SignalFormatters.date(iso, includingTime: true) ?? "—"
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
