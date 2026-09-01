import SwiftUI

/// La page d'une box : le verdict, ce que valent ses mesures, et surtout la
/// liste de SES adresses avec l'état de chacune.
///
/// C'est le cœur du modèle : une IPv6 morte se voit ici d'un coup d'œil, là où
/// une moyenne toutes familles confondues la dissoudrait.
struct SentinelleBoxView: View {
    @ObservedObject var model: SentinelleViewModel
    let targetId: String
    /// Vraie quand cette page tient lieu d'accueil (une seule box surveillée) :
    /// il n'y a alors nulle part où revenir, et le retrait de la connexion doit
    /// rester possible depuis ici.
    var isRoot = false

    @Environment(\.dismiss) private var dismiss
    @State private var openedFamily: SentinelleFamily?
    @State private var editing: EditingAddress?
    @State private var confirmDelete = false
    @State private var ownerLabel = ""
    @State private var ownerEmoji = ""

    /// Fenêtre du graphe comparé, et elle seule : les agrégats de la box et
    /// l'état de chaque adresse restent lus sur 24 h, sans quoi leurs libellés
    /// (« sur 24 heures ») cesseraient de dire ce qu'ils montrent.
    @State private var window: SentinelleWindow = .h24
    /// Points des fenêtres AUTRES que 24 h : celle-ci est déjà en mémoire pour
    /// toute la page, la relire coûterait une requête pour le même résultat.
    @State private var otherWindowPoints: [SentinelleSeriesPoint]?
    @State private var loadedWindow: SentinelleWindow?

    /// Une adresse en cours de saisie : la famille visée, et la valeur existante
    /// s'il s'agit d'une correction.
    private struct EditingAddress: Identifiable {
        let family: SentinelleFamily
        let existing: String?
        var id: SentinelleFamily { family }
    }

    private var target: SentinelleTarget? { model.target(targetId) }
    private var points: [SentinelleSeriesPoint] { model.points[targetId] ?? [] }
    private var incidents: [SentinelleIncident]? { model.incidents[targetId] }

    var body: some View {
        ScrollView {
            if let target {
                VStack(spacing: SQSpace.md + 2) {
                    verdictCard(target)
                    if hasBothFamilies { comparisonCard }
                    metricsCard
                    // Les abonnés se gèrent depuis la page de la BOX : on partage
                    // une connexion, pas une pile réseau.
                    SentinelleFollowersCard(target: target, service: model.service)
                    addressesCard(target)
                    ownerCard(target)
                    deleteRow(target)
                    SentinelleFreshness(date: model.lastRefresh)
                }
                .padding(.horizontal, SQSpace.lg)
                // Rien ne sépare visuellement la barre de navigation du contenu :
                // une marge pleine y creusait un vide que l'utilisateur a
                // signalé. Même valeur qu'Android.
                .padding(.top, SQSpace.sm)
                .padding(.bottom, SQSpace.huge)
                .sqReadableWidth()
            }
        }
        .navigationTitle(target?.label ?? String(localized: "Ma connexion"))
        .toolbarTitleInlineCompat()
        .signalQuestBackground()
        .navigationDestinationItemCompat($openedFamily) { family in
            SentinelleAddressView(model: model, targetId: targetId, family: family)
        }
        // La série comparée se relit à chaque changement de fenêtre ET à chaque
        // cycle de rafraîchissement : sans ce second déclencheur, la courbe se
        // figerait pendant que le reste de l'écran continue de vivre.
        .task(id: comparisonKey) { await loadComparison() }
        .sheet(item: $editing) { editing in
            if let target {
                SentinelleAddressSheet(
                    target: target,
                    family: editing.family,
                    existing: editing.existing,
                    currentIp: { await model.currentIp() }
                ) { address in
                    Task { await model.setAddress(targetId: targetId, family: editing.family, address: address) }
                }
            }
        }
        .confirmationDialog(
            "Supprimer cette connexion ?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Supprimer et effacer l’historique", role: .destructive) {
                Task {
                    // Sur une page poussée, la cible disparaît sous nos pieds :
                    // on referme plutôt que de laisser un écran vide.
                    if await model.delete(targetId: targetId), !isRoot { dismiss() }
                }
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Les mesures, les coupures et les relevés de chemin partent avec elle. C’est sans retour.")
        }
    }

    // MARK: Verdict

    private func verdictCard(_ target: SentinelleTarget) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                HStack(alignment: .top, spacing: SQSpace.sm + 2) {
                    SentinelleStatusDot(color: SentinelleWording.statusColor(target.status), size: 12)
                        .padding(.top, 8)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(SentinelleWording.verdict(target))
                            .font(SQType.title)
                            .foregroundStyle(SQColor.label)
                            .fixedSize(horizontal: false, vertical: true)
                        if let hostname = target.hostname {
                            Text(hostname)
                                .font(.system(.caption, design: .monospaced, weight: .medium))
                                .foregroundStyle(SQColor.labelSecondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                if let probe = SignalFormatters.date(target.lastProbeAt, includingTime: true, relative: true) {
                    Text("Dernière salve \(probe).")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                }
                SentinelleSuspendedNote(target: target)
                SentinelleOutagesLine(incidents: incidents)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Comparaison des deux familles

    private var hasBothFamilies: Bool {
        SentinelleFamily.allCases.allSatisfy { family in
            SentinelleLatencySeries(points: points, family: family).samples.count >= 2
        }
    }

    private var comparisonCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: SQSpace.md) {
                SentinelleSectionTitle(title: "IPv4 et IPv6, côte à côte", systemImage: "arrow.left.arrow.right")
                Text("Deux piles réseau distinctes, mesurées séparément. Les superposer est le seul moyen de voir laquelle décroche.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                SentinelleWindowPicker(selection: $window)
                comparisonChart
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Points tracés : ceux de la fenêtre choisie, ou ceux de la page pour 24 h.
    private var comparisonPoints: [SentinelleSeriesPoint]? {
        window == .h24 ? points : otherWindowPoints
    }

    @ViewBuilder
    private var comparisonChart: some View {
        if let comparisonPoints {
            let series = SentinelleFamily.allCases.map {
                SentinelleLatencySeries(points: comparisonPoints, family: $0)
            }
            if series.contains(where: { $0.samples.count >= 2 }) {
                SentinelleFamilyChart(points: comparisonPoints, window: window)
                    .frame(height: 150)
                HStack(spacing: SQSpace.lg) {
                    ForEach(SentinelleFamily.allCases) { family in
                        SentinelleFamilyChart.legend(for: family)
                    }
                    Spacer(minLength: 0)
                }
            } else {
                // « Rien à tracer parce que rien n'a répondu » n'est PAS « rien à
                // tracer parce qu'on vient de commencer » : le premier cas est la
                // panne que cet écran doit rendre visible.
                Text(series.contains(where: \.allLost)
                    ? String(localized: "Aucune réponse sur \(window.periodLabel), dans aucune des deux familles : il n’y a pas de latence à comparer.")
                    : String(localized: "Pas encore assez de mesures sur \(window.periodLabel) pour comparer les deux familles."))
                    .font(SQType.body)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            ProgressView()
                .tint(SQColor.brandRed)
                .frame(maxWidth: .infinity, minHeight: 150)
        }
    }

    private var comparisonKey: String {
        "\(window.rawValue)-\(model.lastRefresh?.timeIntervalSince1970 ?? 0)"
    }

    private func loadComparison() async {
        // 24 h est déjà chargée pour toute la page : rien à demander.
        guard window != .h24 else { return }
        // Repasser par « chargement » évite d'afficher un instant la courbe de
        // l'autre fenêtre — mais seulement quand la fenêtre a changé, sinon
        // chaque cycle de rafraîchissement ferait clignoter le graphe.
        if loadedWindow != window { otherWindowPoints = nil }
        do {
            let response = try await model.service.series(
                targetId: targetId, window: window, family: nil
            )
            otherWindowPoints = response.points
            loadedWindow = window
        } catch is CancellationError {
            // Annulée ≠ vide : on garde ce qu'on avait plutôt que d'annoncer une
            // absence de mesure qu'on n'a pas constatée.
            return
        } catch {
            otherWindowPoints = otherWindowPoints ?? []
        }
    }

    // MARK: Mesures de la box

    @ViewBuilder
    private var metricsCard: some View {
        if let metrics = points.boxMetrics {
            GlassCard {
                VStack(alignment: .leading, spacing: SQSpace.sm) {
                    SentinelleSectionTitle(title: "Toutes familles confondues", systemImage: "gauge.with.needle")
                    SentinelleMetricRow(
                        label: "Disponibilité",
                        hint: "sur 24 heures",
                        value: SentinelleWording.percent(metrics.uptimePct, decimals: 2)
                    )
                    SentinelleMetricRow(
                        label: "Latence",
                        hint: "moyenne récente",
                        value: SentinelleWording.ms(metrics.rttMs)
                    )
                    SentinelleMetricRow(
                        label: "Gigue",
                        hint: "d’un ping au suivant",
                        value: SentinelleWording.ms(metrics.jitterMs)
                    )
                    SentinelleMetricRow(
                        label: "Perte",
                        hint: "meilleure famille",
                        value: SentinelleWording.percent(metrics.lossPct)
                    )
                    Text("La box est réputée joignable dès qu’UNE de ses adresses répond : c’est pourquoi ces nombres peuvent rester bons alors qu’une famille est tombée.")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, SQSpace.xs)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Adresses

    private func addressesCard(_ target: SentinelleTarget) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                SentinelleSectionTitle(title: "Adresses surveillées", systemImage: "point.3.connected.trianglepath.dotted")
                Text(target.hostname != nil
                    ? "Résolues depuis le nom d’hôte à chaque cycle : elles se consultent, elles ne se saisissent pas."
                    : "Chaque famille est sondée séparément, et répond — ou pas — pour son propre compte.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if target.addresses.isEmpty {
                    Text("Aucune adresse connue pour l’instant : la première résolution arrive au prochain cycle de sonde.")
                        .font(SQType.body)
                        .foregroundStyle(SQColor.label)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, SQSpace.xs)
                }

                ForEach(target.addresses) { address in
                    addressRow(address)
                }

                if let missing = target.missingFamily {
                    missingFamilyRow(missing)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Ligne cliquable — et rien d'autre. La modification de l'adresse vit sur
    /// SA page, dans la barre du haut : un bouton « Modifier » posé ici ferait
    /// deux cibles concurrentes sur une même ligne.
    private func addressRow(_ address: SentinelleAddress) -> some View {
        let familyPoints = points.inFamily(address.family)
        let state = familyPoints.addressState
        return Button {
            Haptics.light()
            openedFamily = address.family
        } label: {
            HStack(spacing: SQSpace.sm + 2) {
                SentinelleStatusDot(color: SentinelleWording.stateColor(state))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: SQSpace.sm) {
                        Text(address.familyLabel)
                            .font(SQFont.body(14, .semibold))
                            .foregroundStyle(SQColor.label)
                        Text(SentinelleWording.addressStateLabel(state, familyPoints.addressMetrics))
                            .font(SQType.caption)
                            .foregroundStyle(state == .down ? SQColor.dangerInk : SQColor.labelSecondary)
                            .lineLimit(1)
                    }
                    Text(address.address)
                        .font(.system(.caption, design: .monospaced, weight: .medium))
                        .foregroundStyle(SQColor.labelSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                Spacer(minLength: SQSpace.sm)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SQColor.labelTertiary)
                    .sqDecorative()
            }
            .padding(.vertical, SQSpace.sm + 2)
            .padding(.horizontal, SQSpace.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                SQColor.surfaceMuted,
                in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
            )
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityLabel(Text("\(address.familyLabel) · \(address.address)"))
        .accessibilityValue(Text(SentinelleWording.addressStateLabel(state, familyPoints.addressMetrics)))
    }

    /// Invitation à compléter une box suivie dans une seule famille.
    ///
    /// Registre d'invitation et non d'alerte : surface neutre, action douce. La
    /// cible fonctionne, elle est seulement incomplète — un bandeau rouge ferait
    /// croire à une panne.
    private func missingFamilyRow(_ family: SentinelleFamily) -> some View {
        HStack(spacing: SQSpace.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Suivie en \(family.other.label) seulement")
                    .font(SQFont.body(14, .semibold))
                    .foregroundStyle(SQColor.label)
                Text("Son \(family.label) tomberait sans que vous le sachiez.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: SQSpace.sm)
            Button {
                Haptics.light()
                editing = EditingAddress(family: family, existing: nil)
            } label: {
                Text("+ \(family.label)")
                    .font(SQFont.body(13, .semibold))
                    .foregroundStyle(SQColor.accentInk)
                    .padding(.horizontal, SQSpace.md)
                    .padding(.vertical, SQSpace.sm)
                    .background(SQColor.accentSoft, in: Capsule(style: .continuous))
            }
            .buttonStyle(SQPressButtonStyle())
        }
        .padding(.vertical, SQSpace.sm)
        .padding(.horizontal, SQSpace.md)
        .background(SQColor.fill, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
    }

    // MARK: Attribution

    /// À qui appartient cette box — modifiable APRÈS coup.
    ///
    /// Le champ n'existait que dans la feuille de création : une box ajoutée sans
    /// étiquette ne pouvait plus jamais en recevoir. `SentinelleService.setOwner`
    /// était écrit, documenté, et n'avait aucun appelant.
    ///
    /// L'étiquette n'est pas un rangement mais une question de langue : sur un
    /// lien partagé, « Votre connexion est en ligne » est FAUX, celui qui lit
    /// regarde la connexion de quelqu'un d'autre.
    private func ownerCard(_ target: SentinelleTarget) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                SentinelleSectionTitle(title: "À qui appartient cette connexion", systemImage: "person.crop.circle")
                Text("Sert à parler juste sur un lien partagé : « Votre connexion » y serait faux.")
                    .font(SQFont.body(12))
                    .foregroundStyle(SQColor.labelSecondary)

                SentinelleOwnerField(label: $ownerLabel, emoji: $ownerEmoji)

                if ownerChanged(target) {
                    HStack(spacing: SQSpace.sm) {
                        Button("Annuler") {
                            ownerLabel = target.ownerLabel ?? ""
                            ownerEmoji = target.ownerEmoji ?? ""
                        }
                        .font(SQFont.body(14))
                        .foregroundStyle(SQColor.labelSecondary)
                        .padding(.vertical, SQSpace.sm)

                        Spacer()

                        Button("Enregistrer") {
                            Task {
                                try? await model.service.setOwner(
                                    targetId: target.id,
                                    ownerLabel: ownerLabel.isEmpty ? nil : ownerLabel,
                                    ownerEmoji: ownerEmoji.isEmpty ? nil : ownerEmoji
                                )
                                await model.load(silently: true)
                            }
                        }
                        .font(SQFont.body(14, .semibold))
                        .foregroundStyle(SQColor.accentInk)
                        .padding(.vertical, SQSpace.sm)
                        .padding(.horizontal, SQSpace.md)
                        .background(SQColor.accentSoft, in: Capsule(style: .continuous))
                    }
                }
            }
        }
        .task(id: target.id) {
            ownerLabel = target.ownerLabel ?? ""
            ownerEmoji = target.ownerEmoji ?? ""
        }
    }

    private func ownerChanged(_ target: SentinelleTarget) -> Bool {
        ownerLabel != (target.ownerLabel ?? "") || ownerEmoji != (target.ownerEmoji ?? "")
    }

    // MARK: Retrait

    private func deleteRow(_ target: SentinelleTarget) -> some View {
        Button(role: .destructive) {
            Haptics.warning()
            confirmDelete = true
        } label: {
            Text("Ne plus surveiller cette connexion")
                .font(SQFont.body(14, .semibold))
                .foregroundStyle(SQColor.dangerInk)
                .frame(maxWidth: .infinity)
                .padding(.vertical, SQSpace.md + 2)
                .background(SQColor.dangerSoft, in: Capsule(style: .continuous))
        }
        .buttonStyle(SQPressButtonStyle())
        .disabled(model.isBusy)
        .padding(.top, SQSpace.sm)
    }
}
