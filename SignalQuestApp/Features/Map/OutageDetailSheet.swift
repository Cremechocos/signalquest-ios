import SwiftUI
import MapKit

/// Fiche d'un incident publié par l'opérateur, dans l'ordre de la maquette commune v12
/// (OUTAGE-MERGE, 11/11) : en-tête, dates, communauté, support, services déclarés, détail.
///
/// Le bloc Communauté n'existe que si le serveur a rattaché des pannes signalées à l'incident.
/// Le vote ne s'y propose que si le rattachement de la panne principale est SÛR : voter ici sur
/// une panne peut-être liée à un autre incident orienterait la mauvaise.
struct OutageDetailSheet: View {
    let site: OutageSiteLive
    /// Code opérateur → nom affiché, résolu par la carte selon le marché courant.
    var operatorLabel: (String) -> String = { $0 }
    /// Pannes signalées déjà chargées par la carte : elles disent la confiance du rattachement
    /// avant que la fiche de la panne principale arrive.
    var mapOutages: [CommunityOutage] = []
    /// `nil` = pas de bloc interactif (aperçus, tests).
    var service: CommunityOutageServicing?
    /// Ouvre la fiche du support. `nil` = pas de bouton.
    var onOpenSite: ((IncidentSupport) -> Void)?
    /// Un vote a changé une panne : la carte se recharge.
    var onChanged: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var services: AppServices

    /// La panne principale (`primaryOutageId`), chargée pour le vote.
    @State private var primary: CommunityOutage?
    @State private var voting = false
    @State private var errorMessage: String?
    /// Panne ouverte par-dessus la fiche, et celle dont la fiche se charge.
    @State private var openedOutage: CommunityOutage?
    @State private var openingOutageId: String?
    /// La fiche de la panne principale n'a pas pu se charger : la confiance reste inconnue.
    @State private var primaryLoadFailed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                header
                datesSection
                if let community = site.community { communitySection(community) }
                supportSection
                if !site.services.isEmpty { servicesSection }
                infoSection
            }
            .padding()
            .padding(.top, SQSpace.sm)
        }
        .presentationDetents([.height(440), .medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackgroundCompat(SQColor.bg)
        .task(id: site.community?.primaryOutageId) { await loadPrimary() }
        .sheet(item: $openedOutage) { outage in
            if let service {
                CommunityOutageDetailSheet(
                    outage: outage,
                    service: service,
                    operatorLabel: operatorLabel(outage.operatorKey),
                    onChanged: {
                        onChanged?()
                        Task { await loadPrimary(force: true) }
                    }
                )
            }
        }
    }

    /// En-tête Halo : l'opérateur en petites capitales, la commune, puis le type d'incident en
    /// MOT COLORÉ avec le triangle de son marqueur, suivi du département et de la région.
    var header: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm2) {
            HStack(alignment: .top, spacing: SQSpace.sm) {
                VStack(alignment: .leading, spacing: SQSpace.xs) {
                    if let op = site.operator {
                        Text(verbatim: operatorLabel(op)).sqKicker()
                    }
                    Text(site.commune?.capitalized ?? site.siteId ?? String(localized: "Site en panne"))
                        .font(SQType.title)
                        .foregroundStyle(SQColor.label)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                MapChipIconButton(systemImage: "xmark", label: "Fermer", identifier: "operatorOutage.close") {
                    dismiss()
                }
            }
            (Text(Image(systemName: issueGlyph))
                + Text(verbatim: " ")
                + Text(issueLabel).foregroundColor(OperatorIncidentCard.ink(for: issueKey))
                + Text(verbatim: placeSuffix).foregroundColor(SQColor.labelSecondary))
                .font(SQFont.body(13.5, .semibold, relativeTo: .subheadline))
                .foregroundStyle(OperatorIncidentCard.ink(for: issueKey))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// « · Isère · Auvergne-Rhône-Alpes », vide si ni l'un ni l'autre n'est servi.
    var placeSuffix: String {
        [site.departement, site.region]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { " · \($0)" }
            .joined()
    }

    var datesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            infoRow("Début", formattedDate(site.startedAt))
            infoRow("Rétablissement prévu", formattedDate(site.estimatedEnd) ?? String(localized: "Non communiqué"))
        }
        .padding(.vertical, SQSpace.xs)
        .sqCardBackground()
    }

    // MARK: Communauté

    /// Confiance du rattachement de la panne principale : la fiche de la panne si elle est
    /// chargée, sinon la tuile de la carte. `nil` tant que la fiche se charge, pour ne pas
    /// annoncer « incertain » une seconde avant le vote ; inconnue ensuite = incertaine.
    var primaryConfidence: OutageMatchConfidence? {
        guard let id = site.community?.primaryOutageId else { return .uncertain }
        if let known = primary?.operatorIncident?.matchConfidence
            ?? mapOutages.first(where: { $0.id == id })?.operatorIncident?.matchConfidence {
            return known
        }
        return primary != nil || primaryLoadFailed || service == nil ? .uncertain : nil
    }

    func communitySection(_ community: IncidentCommunity) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.xs2) {
            Text("Communauté").sqKicker().accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: SQSpace.md) {
                VStack(alignment: .leading, spacing: SQSpace.xs) {
                    Text(Self.membersLine(community.memberCount))
                        .font(SQFont.body(15, .semibold, relativeTo: .body))
                        .foregroundStyle(SQColor.label)
                    if let lead = community.leadMinutes {
                        Text("Signalée par la communauté \(Self.leadText(lead)) avant l’opérateur")
                            .font(SQType.subhead)
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)

                if primaryConfidence?.isSure == true {
                    if let primary, primary.state.isVisible, service != nil {
                        OutageArbitrationBlock(
                            outage: primary,
                            onVote: { _, kind in Task { await vote(kind) } },
                            isVoting: voting
                        )
                        .disabled(voting)
                    }
                } else if primaryConfidence != nil {
                    VStack(alignment: .leading, spacing: SQSpace.xs) {
                        Text("Rattachement incertain : cette panne signalée est peut-être liée à un autre incident proche.")
                            .font(SQType.subhead)
                            .foregroundStyle(OutageTint.degradedInk)
                            .fixedSize(horizontal: false, vertical: true)
                        linkButton(String(localized: "Voir la panne signalée"), id: community.primaryOutageId)
                    }
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.dangerInk)
                }
                // Rattachement incertain : « Voir la panne signalée » ouvre déjà la même
                // fiche, discussion comprise (parité Android 62cdc5e81).
                if service != nil, primaryConfidence?.isSure == true {
                    linkButton(
                        String(localized: "Discussion · \(Self.commentsText(community.commentCount))"),
                        id: community.primaryOutageId
                    )
                }
                if community.totalOutages >= 2 { outagesList(community) }
            }
            .padding(SQSpace.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .sqCardBackground()
        }
    }

    /// Les pannes rattachées, la plus ancienne d'abord : chacune ouvre sa propre fiche.
    func outagesList(_ community: IncidentCommunity) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(community.totalOutages) pannes signalées ici")
                .font(SQFont.body(13, .semibold, relativeTo: .footnote))
                .foregroundStyle(SQColor.labelSecondary)
                .padding(.bottom, SQSpace.xs)
            ForEach(Array(community.outageIds.enumerated()), id: \.element) { index, id in
                linkButton(Self.outageRowText(community.details(of: id), index: index), id: id)
            }
            let others = community.totalOutages - community.outageIds.count
            if others > 0 {
                Text("et \(others) autres pannes signalées")
                    .font(SQType.subhead)
                    .foregroundStyle(SQColor.labelSecondary)
                    .frame(minHeight: 44, alignment: .leading)
            }
        }
    }

    /// Une ligne qui ouvre la fiche d'une panne signalée, en 44 pt au moins.
    @ViewBuilder
    func linkButton(_ title: String, id: String) -> some View {
        if service != nil {
            Button {
                Task { await open(outageId: id) }
            } label: {
                HStack(spacing: SQSpace.sm) {
                    Text(title)
                        .font(SQFont.body(14, .semibold, relativeTo: .subheadline))
                        .foregroundStyle(SQColor.accentInk)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if openingOutageId == id {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(SQColor.labelSecondary)
                            .accessibilityHidden(true)
                    }
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(openingOutageId != nil)
        }
    }

    static func membersLine(_ count: Int) -> String {
        String(localized: "Confirmée par \(count) membres")
    }

    static func membersCount(_ count: Int) -> String {
        String(localized: "\(count) membres")
    }

    static func commentsText(_ count: Int) -> String {
        String(localized: "\(count) commentaires")
    }

    /// Moins d'une heure en minutes, moins de 48 h en heures, au-delà en jours.
    static func leadText(_ minutes: Int) -> String {
        if minutes < 60 { return String(localized: "\(minutes) min") }
        if minutes < 48 * 60 { return String(localized: "\(minutes / 60) h") }
        return String(localized: "\(minutes / (24 * 60)) j")
    }

    /// « Signalée le 11 nov. à 06:42 · 4 membres », sans compte s'il vaut 0, et « Panne
    /// signalée n » quand le serveur ne sert pas encore la date (avant r1.3).
    static func outageRowText(_ outage: IncidentCommunity.Outage?, index: Int) -> String {
        guard let date = outage?.reportedAt else { return String(localized: "Panne signalée \(index + 1)") }
        let day = date.formatted(.dateTime.day().month(.abbreviated))
        let time = date.formatted(date: .omitted, time: .shortened)
        let base = String(localized: "Signalée le \(day) à \(time)")
        guard let members = outage?.memberCount, members > 0 else { return base }
        return base + " · " + membersCount(members)
    }

    // MARK: Support

    @ViewBuilder
    var supportSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.xs2) {
            Text("Support").sqKicker().accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) {
                if let support = site.support {
                    if support.matchConfidence.isSure {
                        infoRow("Support", support.supId)
                    } else {
                        infoRow("Support probable", support.distanceMeters.map {
                            String(localized: "\(support.supId) · à \(SQUnits.distance(meters: Double($0)))")
                        } ?? support.supId)
                    }
                    infoRow("Adresse", support.displayAddress)
                    if let onOpenSite {
                        Button {
                            onOpenSite(support)
                        } label: {
                            Label("Fiche du site", systemImage: "antenna.radiowaves.left.and.right")
                                .font(SQFont.body(14, .semibold, relativeTo: .subheadline))
                                .foregroundStyle(SQColor.accentInk)
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, SQSpace.md)
                        .accessibilityIdentifier("operatorOutage.openSite")
                    }
                } else if let approx = site.approxAddress {
                    infoRow("Adresse approchée", String(localized: "Vers \(approx.label)"))
                    infoRow("Commune", site.commune?.capitalized)
                    Text("Source : Base Adresse Nationale")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .padding(.horizontal, SQSpace.md)
                        .padding(.vertical, SQSpace.sm)
                } else {
                    infoRow("Support", String(localized: "non trouvé à moins de \(SQUnits.distance(meters: 120))"))
                    infoRow("Commune", site.commune?.capitalized)
                }
            }
            .padding(.vertical, SQSpace.xs)
            .sqCardBackground()
        }
    }

    var servicesSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Services déclarés").sqKicker().accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
                ForEach(site.services, id: \.label) { service in
                    HStack(spacing: 6) {
                        Circle().fill(serviceColor(service.status)).frame(width: 8, height: 8)
                        Text(LocalizedStringKey(service.label))
                            .font(SQFont.body(13, .semibold, relativeTo: .footnote))
                            .foregroundStyle(SQColor.label)
                        Spacer(minLength: 0)
                        Text(serviceStatusLabel(service.status))
                            .font(SQFont.body(12, .bold, relativeTo: .caption2))
                            .foregroundStyle(serviceColor(service.status))
                    }
                    .padding(.horizontal, SQSpace.sm2)
                    .padding(.vertical, 7)
                    .background(serviceColor(service.status).opacity(0.12), in: Capsule(style: .continuous))
                }
            }
        }
    }

    var infoSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.xs2) {
        Text("Détail opérationnel").sqKicker().accessibilityAddTraits(.isHeader)
        VStack(alignment: .leading, spacing: 0) {
            infoRow("Raison", reasonText)
            if let detail = site.detail, detail != reasonText { infoRow("Détail", detail) }
            infoRow("Code site", site.siteId)
        }
        .padding(.vertical, SQSpace.xs)
        .sqCardBackground()
        }
    }

    @ViewBuilder
    func infoRow(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .top) {
                Text(LocalizedStringKey(label))
                    .font(SQType.subhead)
                    .foregroundStyle(SQColor.labelSecondary)
                Spacer()
                Text(value)
                    .font(SQFont.body(13.5, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(SQColor.label)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, SQSpace.md)
            .padding(.vertical, SQSpace.sm + 1)
            .accessibilityElement(children: .combine)
            Divider().padding(.leading, SQSpace.md)
        }
    }

    // MARK: Chargement et vote

    /// La fiche de la panne principale : vote, `myVote`, `canVote`. Un échec reste silencieux,
    /// le bloc garde ses comptes et ses liens.
    func loadPrimary(force: Bool = false) async {
        guard let service, let id = site.community?.primaryOutageId else { return }
        guard force || primary?.id != id else { return }
        do {
            primary = try await service.detail(outageId: id)
        } catch {
            if !error.isCancellation { primaryLoadFailed = true }
        }
    }

    func open(outageId: String) async {
        guard let service, openingOutageId == nil else { return }
        if let primary, primary.id == outageId { openedOutage = primary; return }
        openingOutageId = outageId
        errorMessage = nil
        do {
            openedOutage = try await service.detail(outageId: outageId)
        } catch {
            if !error.isCancellation { errorMessage = String(localized: "Impossible d’ouvrir cette panne signalée.") }
        }
        openingOutageId = nil
    }

    /// Le même vote que la fiche de la panne : position du moment, refus lus sur le code.
    func vote(_ kind: String) async {
        guard let service, let outage = primary, !voting else { return }
        voting = true
        errorMessage = nil
        let here = services.location.cachedLocation()
        do {
            let response = try await service.vote(
                outageId: outage.id,
                kind: kind,
                latitude: here?.coordinate.latitude,
                longitude: here?.coordinate.longitude,
                accuracyMeters: here.flatMap { $0.horizontalAccuracy > 0 ? $0.horizontalAccuracy : nil }
            )
            if let updated = response.outage { primary = updated }
            onChanged?()
        } catch {
            errorMessage = OutageWriteError.message(for: error)
        }
        voting = false
    }

    // MARK: Présentation

    var issueKey: String { (site.issueType ?? "").lowercased() }

    var issueLabel: String {
        switch issueKey {
        case "maintenance": return String(localized: "Maintenance programmée")
        case "degraded": return String(localized: "Service dégradé")
        default: return String(localized: "Panne / hors service")
        }
    }

    /// Teintes des pannes communautaires (`OutageTint`, identiques sur Android) :
    /// le jaune Tailwind d'avant tombait à 1,8:1 sur la crème (MES-36).
    var issueColor: Color { OperatorIncidentCard.tint(for: issueKey) }

    /// Triangle des incidents opérateur, comme leur marqueur sur la carte.
    var issueGlyph: String { OperatorIncidentCard.glyph(for: issueKey) }

    /// Code opérateur brut → libellé lisible (au lieu d'« INT » / « MAINT »).
    var reasonText: String {
        let code = site.reason ?? ""
        if let label = OutageSiteLive.reasonLabel(code: code) { return label }
        return site.detail ?? (code.isEmpty ? issueLabel : code)
    }

    func serviceStatusLabel(_ status: String) -> String {
        switch status.uppercased() {
        case "HS": return String(localized: "Hors service")
        case "DE": return String(localized: "Dégradé")
        case "OK": return "OK"
        default: return status
        }
    }

    func serviceColor(_ status: String) -> Color {
        switch status.uppercased() {
        case "HS": return OutageTint.down
        case "DE": return OutageTint.degraded
        case "OK": return OutageTint.resolved
        default: return SQColor.labelSecondary
        }
    }

    /// Parse une date backend (ISO avec/sans fraction, ou « jour seul ») et la
    /// formate en français lisible.
    func formattedDate(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let date: Date?
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: raw) {
            date = d
        } else {
            let iso2 = ISO8601DateFormatter()
            iso2.formatOptions = [.withInternetDateTime]
            if let d = iso2.date(from: raw) {
                date = d
            } else {
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.timeZone = TimeZone(secondsFromGMT: 0)
                f.dateFormat = "yyyy-MM-dd"
                date = f.date(from: raw)
            }
        }
        guard let date else { return raw }
        let out = DateFormatter()
        out.locale = Locale.autoupdatingCurrent
        out.dateStyle = .medium
        out.timeStyle = raw.contains("T") ? .short : .none
        return out.string(from: date)
    }
}

extension OutageSiteLive {
    /// Libellé d'un code opérateur connu (« INT », « MAINT »), nil sinon :
    /// partagé par cette fiche et CarPlay, où un code brut ne se lit pas au volant.
    static func reasonLabel(code: String) -> String? {
        switch code.uppercased() {
        case "INT": return String(localized: "Interruption de service")
        case "MAINT": return String(localized: "Maintenance programmée")
        default: return nil
        }
    }
}
