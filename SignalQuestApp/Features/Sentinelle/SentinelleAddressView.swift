import SwiftUI

/// La page d'UNE adresse : ce que vaut cette famille, et elle seule.
///
/// Superposer IPv4 et IPv6 sur une même courbe reviendrait à tracer deux réseaux
/// distincts sous un seul trait — une IPv6 morte disparaîtrait derrière une IPv4
/// en pleine forme. Tout ce qui est lu ici est donc filtré par famille, côté
/// serveur, et la réponse porte la famille réellement servie : c'est le seul
/// moyen honnête de savoir si l'écran montre bien CETTE adresse.
struct SentinelleAddressView: View {
    @ObservedObject var model: SentinelleViewModel
    let targetId: String
    let family: SentinelleFamily

    @State private var window: SentinelleWindow = .h24
    @State private var loadedWindow: SentinelleWindow?
    @State private var points: [SentinelleSeriesPoint]?
    @State private var servedFamily: SentinelleFamily?
    /// Instant sous le doigt : c'est LUI qui fait la navigation dans le temps,
    /// l'en-tête de la carte lisant alors cette mesure-là plutôt que la dernière.
    @State private var selected: SentinelleLatencySample?

    @State private var tab: SentinelleDetailTab = .diagnostic
    @State private var diagnostic: SentinelleDiagnostic?
    @State private var diagnosticFailed = false
    @State private var trends: SentinelleTrends?
    @State private var trendsFailed = false
    @State private var proof: SentinelleProof?
    @State private var proofFailed = false

    @State private var editing = false

    private var target: SentinelleTarget? { model.target(targetId) }
    private var address: SentinelleAddress? {
        target?.addresses.first { $0.family == family }
    }

    var body: some View {
        ScrollView {
            if let target, let address {
                VStack(spacing: SQSpace.md + 2) {
                    verdictCard(target, address)
                    latencyCard(address)
                    metricsCard(address)
                    tabPicker
                    section(target, address)
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
        .navigationTitle(family.label)
        .toolbarTitleInlineCompat()
        .signalQuestBackground()
        .toolbar {
            // L'action de modification vit dans la barre du haut : c'est une
            // action sur l'objet de la page entière, pas sur l'une de ses cartes.
            if let address, !address.fromHostname {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Modifier") {
                        Haptics.light()
                        editing = true
                    }
                    .tint(SQColor.brandRed)
                }
            }
        }
        .sheet(isPresented: $editing) {
            if let target, let address {
                SentinelleAddressSheet(
                    target: target,
                    family: family,
                    existing: address.address,
                    currentIp: { await model.currentIp() }
                ) { value in
                    Task { await model.setAddress(targetId: targetId, family: family, address: value) }
                }
            }
        }
        // La série se relit à chaque changement de fenêtre ET à chaque cycle de
        // rafraîchissement : sans ce second déclencheur, la courbe se figerait
        // pendant que le reste de l'écran continue de vivre.
        .task(id: seriesKey) { await loadSeries() }
        .task(id: tab) { await loadSection() }
    }

    private var seriesKey: String {
        "\(window.rawValue)-\(model.lastRefresh?.timeIntervalSince1970 ?? 0)"
    }

    // MARK: Verdict

    private func verdictCard(_ target: SentinelleTarget, _ address: SentinelleAddress) -> some View {
        // Tant que les points ne sont pas arrivés, on ne conclut RIEN : sans
        // cette nuance, une page qui charge annoncerait « aucune mesure ».
        let state = points?.addressState
        return GlassCard {
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                HStack(alignment: .top, spacing: SQSpace.sm + 2) {
                    SentinelleStatusDot(color: SentinelleWording.stateColor(state ?? .unknown), size: 12)
                        .padding(.top, 8)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(SentinelleWording.addressVerdict(target, address, state))
                            .font(SQType.title)
                            .foregroundStyle(SQColor.label)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(address.address)
                            .font(.system(.caption, design: .monospaced, weight: .medium))
                            .foregroundStyle(SQColor.labelSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    Spacer(minLength: 0)
                }
                if address.fromHostname, let hostname = target.hostname {
                    Text("Adresse obtenue en résolvant \(hostname) : elle suit le DNS, il n’y a rien à saisir ici.")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                familyMismatchNote(servedFamily)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Dit à quelle famille se rapporte vraiment ce qu'on affiche.
    ///
    /// Le serveur renvoie la famille qu'il a retenue ; tant qu'il ne sait pas
    /// répondre par famille, il retombe sur son défaut. Le taire laisserait
    /// croire que ces mesures sont celles de l'adresse ouverte.
    @ViewBuilder
    private func familyMismatchNote(_ actual: SentinelleFamily?) -> some View {
        if let actual, actual != family {
            Text("Mesures relevées en \(actual.label) : ce serveur ne sait pas encore isoler l’\(family.label).")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Latence

    private func latencyCard(_ address: SentinelleAddress) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: SQSpace.md) {
                SentinelleSectionTitle(title: "Latence", systemImage: "waveform.path.ecg")
                SentinelleWindowPicker(selection: $window) { selected = nil }

                if let points {
                    let series = SentinelleLatencySeries(points: points)
                    if series.samples.count >= 3 {
                        latencyHeader(series)
                        SentinelleLatencyChart(series: series, window: window, selected: $selected)
                            .frame(height: 148)
                        latencyFooter(series)
                    } else {
                        // Deux points ne font pas une courbe : plutôt que tracer
                        // un segment trompeur, on dit ce qui manque. Et « rien à
                        // tracer parce que rien ne répond » n'est PAS « rien à
                        // tracer parce qu'on vient de commencer » : le premier
                        // cas est la panne qu'on cherche justement à voir.
                        Text(emptyMessage(series, address))
                            .font(SQType.body)
                            .foregroundStyle(series.allLost ? SQColor.dangerInk : SQColor.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    ProgressView()
                        .tint(SQColor.brandRed)
                        .frame(maxWidth: .infinity, minHeight: 120)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// En-tête du graphe : la mesure sous le doigt, ou la dernière connue.
    private func latencyHeader(_ series: SentinelleLatencySeries) -> some View {
        let shown = selected ?? series.last
        let values = series.values
        return HStack(alignment: .bottom, spacing: SQSpace.md) {
            VStack(alignment: .leading, spacing: 1) {
                Text(SentinelleWording.ms(shown?.rttMs))
                    .font(SQFont.display(28, .bold))
                    .monospacedDigit()
                    .foregroundStyle(SQColor.label)
                Text(selected == nil
                    ? String(localized: "dernière mesure")
                    : (shown.map { $0.at.formatted(date: .abbreviated, time: .shortened) } ?? ""))
                    .font(SQType.micro)
                    .foregroundStyle(SQColor.labelSecondary)
            }
            Spacer(minLength: 0)
            Text("min \(SentinelleWording.ms(values.min())) · max \(SentinelleWording.ms(values.max()))")
                .font(SQType.micro)
                .monospacedDigit()
                .foregroundStyle(SQColor.labelSecondary)
        }
    }

    private func latencyFooter(_ series: SentinelleLatencySeries) -> some View {
        HStack(spacing: SQSpace.sm) {
            Text(window.startLabel)
                .font(SQType.micro)
                .foregroundStyle(SQColor.labelTertiary)
            Spacer(minLength: 0)
            Text(series.lostCount == 0
                ? String(localized: "aucune salve perdue")
                : SentinelleWording.lostBursts(series.lostCount))
                .font(SQType.micro)
                .foregroundStyle(series.lostCount == 0 ? SQColor.labelTertiary : SQColor.dangerInk)
            Spacer(minLength: 0)
            Text("maintenant")
                .font(SQType.micro)
                .foregroundStyle(SQColor.labelTertiary)
        }
    }

    private func emptyMessage(_ series: SentinelleLatencySeries, _ address: SentinelleAddress) -> String {
        if series.allLost {
            return String(localized: "Aucune réponse en \(address.familyLabel) sur \(window.periodLabel) : il n’y a pas de latence à tracer, seulement des pertes.")
        }
        if series.isEmpty {
            return String(localized: "Aucune mesure en \(address.familyLabel) sur cette période. La sonde en produit une par minute.")
        }
        return String(localized: "Pas encore assez de mesures pour tracer une courbe.")
    }

    // MARK: Mesures de la famille

    @ViewBuilder
    private func metricsCard(_ address: SentinelleAddress) -> some View {
        if let metrics = points?.addressMetrics {
            GlassCard {
                VStack(alignment: .leading, spacing: SQSpace.sm) {
                    SentinelleSectionTitle(
                        title: "En \(address.familyLabel), sur \(window.periodLabel)",
                        systemImage: "gauge.with.needle"
                    )
                    SentinelleMetricRow(
                        label: "Disponibilité",
                        hint: "cette famille seule",
                        value: SentinelleWording.percent(metrics.uptimePct, decimals: 2)
                    )
                    SentinelleMetricRow(
                        label: "Latence",
                        hint: "moyenne des réponses",
                        value: SentinelleWording.ms(metrics.rttMs)
                    )
                    SentinelleMetricRow(
                        label: "Gigue",
                        hint: "d’un ping au suivant",
                        value: SentinelleWording.ms(metrics.jitterMs)
                    )
                    SentinelleMetricRow(
                        label: "Perte",
                        hint: "moyenne des salves",
                        value: SentinelleWording.percent(metrics.lossPct)
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Onglets

    private var tabPicker: some View {
        HStack(spacing: 0) {
            ForEach(SentinelleDetailTab.allCases) { value in
                let isSelected = value == tab
                Button {
                    Haptics.selection()
                    tab = value
                } label: {
                    Text(LocalizedStringKey(value.label))
                        .font(SQFont.body(13, .semibold))
                        .foregroundStyle(isSelected ? SQColor.onAccent : SQColor.label)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, SQSpace.sm + 2)
                        .background(
                            isSelected ? AnyShapeStyle(SQColor.brandRed) : AnyShapeStyle(Color.clear),
                            in: Capsule(style: .continuous)
                        )
                }
                .buttonStyle(SQPressButtonStyle())
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .sqAnimation(SQMotion.fast, value: isSelected)
            }
        }
        .padding(3)
        .background(SQColor.surfaceMuted, in: Capsule(style: .continuous))
    }

    @ViewBuilder
    private func section(_ target: SentinelleTarget, _ address: SentinelleAddress) -> some View {
        switch tab {
        case .diagnostic: diagnosticCard(address)
        case .trends: trendsCard
        case .proof: proofCard(target, address)
        }
    }

    // MARK: Diagnostic — le chemin

    /// Une latence globale dit QUE la ligne s'est dégradée ; le relevé par saut
    /// dit OÙ. Toutes les barres partagent la MÊME échelle : normaliser chaque
    /// ligne sur son propre maximum ferait paraître un saut à 2 ms aussi chargé
    /// qu'un saut à 200 ms.
    private func diagnosticCard(_ address: SentinelleAddress) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: SQSpace.md) {
                SentinelleSectionTitle(title: "Le chemin jusqu’à vous", systemImage: "point.topleft.down.curvedto.point.bottomright.up")

                if diagnosticFailed {
                    unavailable
                } else if let hops = diagnostic?.hops {
                    if hops.isEmpty {
                        Text("Aucun relevé de chemin sur les dernières heures. Le premier arrive au plus tard un quart d’heure après la mise sous surveillance.")
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        familyMismatchNote(diagnostic?.family)
                        let peak = max(hops.compactMap(\.lastMs).max() ?? 10, 10)
                        VStack(spacing: SQSpace.md) {
                            ForEach(hops) { hop in
                                hopRow(hop, peak: peak)
                            }
                        }
                        Text("Chaque maillon est mesuré depuis nos serveurs. Un saut muet ne répond pas aux sondes mais laisse passer le trafic : ce n’est pas une panne.")
                            .font(SQType.micro)
                            .foregroundStyle(SQColor.labelTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    loading
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func hopRow(_ hop: SentinelleHop, peak: Double) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.xs + 2) {
            HStack(alignment: .firstTextBaseline, spacing: SQSpace.sm) {
                Text(hop.collapsed > 1 ? "·" : "\(hop.idx)")
                    .font(.system(.caption2, design: .monospaced, weight: .semibold))
                    .foregroundStyle(SQColor.labelTertiary)
                    .frame(width: 16, alignment: .trailing)
                Text(hop.label)
                    .font(SQFont.body(14, hop.alwaysQuiet ? .regular : .semibold))
                    .foregroundStyle(hop.alwaysQuiet ? SQColor.labelSecondary : SQColor.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: SQSpace.sm)
                Text(SentinelleWording.ms(hop.lastMs))
                    .font(SQFont.display(16, .bold))
                    .monospacedDigit()
                    .foregroundStyle(hop.lastMs == nil ? SQColor.labelTertiary : SQColor.label)
            }
            SentinelleBar(
                fraction: (hop.lastMs ?? 0) / peak,
                color: hop.alwaysQuiet ? SQColor.labelTertiary.opacity(0.4) : SQColor.brandRed,
                height: 6
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Saut \(hop.idx), \(hop.label)"))
        .accessibilityValue(Text(SentinelleWording.ms(hop.lastMs)))
    }

    // MARK: Tendances

    private var trendsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: SQSpace.md) {
                SentinelleSectionTitle(title: "Comment la ligne évolue", systemImage: "chart.xyaxis.line")

                if trendsFailed {
                    unavailable
                } else if let trends {
                    familyMismatchNote(trends.family)
                    // Chaque phrase n'apparaît que si le serveur a jugé la mesure
                    // tenable : il renvoie `nil` plutôt qu'un chiffre fragile, et
                    // l'écran respecte ce silence au lieu d'afficher un zéro.
                    Text(worstSlotSentence(trends))
                        .font(SQType.body)
                        .foregroundStyle(SQColor.label)
                        .fixedSize(horizontal: false, vertical: true)

                    if let peers = trends.peers, let betterThan = peers.betterThanPct {
                        Text("Votre connexion répond plus vite que \(betterThan) % des \(peers.peerCount) lignes comparables du même opérateur.")
                            .font(SQType.body)
                            .foregroundStyle(SQColor.label)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    driftChart(trends.drift)
                } else {
                    loading
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func worstSlotSentence(_ trends: SentinelleTrends) -> String {
        guard let worst = trends.seasonality?.worst, let day = SentinelleWording.weekday(worst.dow) else {
            return String(localized: "Aucun créneau ne se détache : la ligne se comporte de la même façon à toute heure.")
        }
        let hour = String(format: "%02d", worst.hour)
        return String(localized: "Le créneau le plus lent est le \(day) vers \(hour) h, à \(SentinelleWording.ms(worst.p50)).")
    }

    @ViewBuilder
    private func driftChart(_ weeks: [SentinelleTrends.DriftWeek]) -> some View {
        let measured = weeks.compactMap(\.p50)
        if measured.count >= 2 {
            let peak = max(measured.max() ?? 1, 1)
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                Text("Dérive sur douze semaines")
                    .font(SQType.micro)
                    .foregroundStyle(SQColor.labelSecondary)
                HStack(alignment: .bottom, spacing: SQSpace.xs) {
                    ForEach(weeks) { week in
                        // Une semaine sans mesure garde sa place, en creux : la
                        // retirer resserrerait le graphe et inventerait une
                        // continuité qui n'existe pas.
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(week.p50 == nil ? SQColor.fill : SQColor.brandRed.opacity(0.8))
                            .frame(height: max(60 * ((week.p50 ?? 0) / peak), week.p50 == nil ? 3 : 6))
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 60, alignment: .bottom)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Dérive sur douze semaines"))
            .accessibilityValue(Text("de \(SentinelleWording.ms(measured.first)) à \(SentinelleWording.ms(measured.last))"))
        } else {
            Text("Il faut au moins deux semaines de mesures pour parler de dérive.")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Preuve

    private func proofCard(_ target: SentinelleTarget, _ address: SentinelleAddress) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: SQSpace.md) {
                SentinelleSectionTitle(title: "Journal horodaté", systemImage: "doc.text.magnifyingglass")

                if proofFailed {
                    unavailable
                } else if let proof {
                    if let availability = proof.availability {
                        SentinelleMetricRow(
                            label: "Disponibilité",
                            // Le dénominateur est le temps RÉELLEMENT couvert :
                            // annoncer 30 jours après trois jours de mesures
                            // serait un chiffre faux, pas une approximation.
                            hint: "sur \(availability.coveredHours) h réellement mesurées",
                            value: SentinelleWording.percent(availability.uptimePct, decimals: 3)
                        )
                        SentinelleMetricRow(
                            label: "Indisponibilité",
                            hint: "cumul sur 30 jours",
                            value: SentinelleWording.duration(availability.downSeconds)
                        )
                    } else {
                        Text("Pas encore assez d’heures mesurées pour avancer une disponibilité opposable.")
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    let outages = proof.incidents.filter(\.isOutage)
                    if outages.isEmpty {
                        Text("Aucune coupure enregistrée en \(address.familyLabel) sur 30 jours.")
                            .font(SQType.body)
                            .foregroundStyle(SQColor.label)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        VStack(spacing: SQSpace.sm) {
                            ForEach(outages) { incident in
                                incidentRow(incident)
                            }
                        }
                    }

                    Text("Sonde ICMP depuis nos serveurs, cinq paquets par salve, une salve par minute — accélérée à une toutes les dix secondes dès qu’un paquet manque, afin de dater une coupure à la dizaine de secondes près. IPv4 et IPv6 sont mesurées séparément ; \(target.label) est réputée joignable dès qu’une des deux répond.")
                        .font(SQType.micro)
                        .foregroundStyle(SQColor.labelTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    loading
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func incidentRow(_ incident: SentinelleIncident) -> some View {
        HStack(alignment: .top, spacing: SQSpace.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(SentinelleWording.date(incident.startedAt))
                    .font(SQFont.body(13, .semibold))
                    .foregroundStyle(SQColor.label)
                Text(incident.family == nil
                    // Un incident sans famille vaut pour toute la box : le dire
                    // évite de l'attribuer à cette adresse-là.
                    ? String(localized: "\(SentinelleWording.cause(incident)) · toute la connexion")
                    : SentinelleWording.cause(incident))
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }
            Spacer(minLength: SQSpace.sm)
            Text(incident.endedAt == nil
                ? String(localized: "en cours")
                : SentinelleWording.duration(incident.durationSec))
                .font(SQFont.display(14, .bold))
                .monospacedDigit()
                .foregroundStyle(incident.endedAt == nil ? SQColor.dangerInk : SQColor.label)
        }
        .padding(.vertical, SQSpace.sm)
        .padding(.horizontal, SQSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    // MARK: États partagés

    private var loading: some View {
        ProgressView()
            .tint(SQColor.brandRed)
            .frame(maxWidth: .infinity, minHeight: 60)
    }

    private var unavailable: some View {
        Text("Cette lecture n’est pas encore disponible sur ce serveur.")
            .font(SQType.caption)
            .foregroundStyle(SQColor.labelSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Chargements

    private func loadSeries() async {
        // Repasser par « chargement » évite d'afficher un instant la courbe de
        // l'autre fenêtre — mais seulement quand la fenêtre a changé, sinon
        // chaque cycle de rafraîchissement ferait clignoter le graphe.
        if loadedWindow != window {
            points = nil
            selected = nil
        }
        do {
            let response = try await model.service.series(
                targetId: targetId, window: window, family: family
            )
            // Filtre REFAIT sur le champ `family` de chaque point : un serveur qui
            // ignorerait le paramètre renverrait les deux piles mélangées, et une
            // IPv6 morte se dissoudrait dans les mesures IPv4 — exactement la panne
            // que cet écran doit rendre visible.
            points = response.family == nil ? response.points.inFamily(family) : response.points
            servedFamily = response.family
            loadedWindow = window
        } catch is CancellationError {
            // Une tâche ANNULÉE n'a rien appris. Elle laissait pourtant un
            // tableau vide, et l'écran annonçait « Aucune mesure sur cette
            // période. La sonde en produit une par minute. » — une affirmation
            // fausse, sur la foi d'un simple changement de fenêtre.
            return
        } catch {
            points = points ?? []
        }
    }

    /// Les lectures longues ne sont chargées qu'à l'ouverture de leur onglet :
    /// elles coûtent des requêtes très différentes et personne ne les consulte
    /// toutes. Un échec se dit — le confondre avec « rien à montrer »
    /// déguiserait une route absente en ligne parfaitement saine.
    private func loadSection() async {
        switch tab {
        case .diagnostic:
            guard diagnostic == nil, !diagnosticFailed else { return }
            do { diagnostic = try await model.service.diagnostic(targetId: targetId, family: family) }
            catch { diagnosticFailed = true }
        case .trends:
            guard trends == nil, !trendsFailed else { return }
            do { trends = try await model.service.trends(targetId: targetId, family: family) }
            catch { trendsFailed = true }
        case .proof:
            guard proof == nil, !proofFailed else { return }
            do { proof = try await model.service.proof(targetId: targetId, family: family) }
            catch { proofFailed = true }
        }
    }
}

enum SentinelleDetailTab: String, CaseIterable, Identifiable {
    case diagnostic
    case trends
    case proof

    var id: String { rawValue }

    var label: String {
        switch self {
        case .diagnostic: return "Diagnostic"
        case .trends: return "Tendances"
        case .proof: return "Preuve"
        }
    }
}
