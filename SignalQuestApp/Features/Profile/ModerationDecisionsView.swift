import SwiftUI

// MARK: - Textes

/// Libellés d'une décision, calculés hors des vues pour être testés. Les textes
/// du serveur (motif, règle, issue du recours) arrivent déjà traduits ; ceux-ci
/// disent le reste, avec les mêmes mots qu'Android.
enum ModerationDecisionText {
    static func action(_ action: String) -> String {
        switch action {
        case "removed": String(localized: "Contenu retiré")
        case "hidden": String(localized: "Contenu masqué")
        case "rejected": String(localized: "Contenu refusé")
        case "warning": String(localized: "Avertissement")
        case "account_suspended": String(localized: "Compte suspendu")
        case "photo_upload_banned": String(localized: "Envoi de photos suspendu")
        case "none": String(localized: "Aucune mesure prise")
        default: String(localized: "Décision de l’équipe")
        }
    }

    static func target(_ type: String) -> String {
        switch type {
        case "photo": String(localized: "Ta photo")
        // `comment` : un commentaire sous une photo (contrat MOD-1).
        case "comment": String(localized: "Ton commentaire sur une photo")
        case "message": String(localized: "Ton message")
        case "social_post": String(localized: "Ta publication")
        case "social_comment": String(localized: "Ton commentaire")
        case "social_story": String(localized: "Ta story")
        case "site_comment": String(localized: "Ton message sur un site")
        case "room_message": String(localized: "Ton message dans un salon")
        case "signal_rating": String(localized: "Ta note de réseau")
        case "custom_site": String(localized: "Ton site communautaire")
        case "account": String(localized: "Ton compte")
        default: String(localized: "Ton contenu")
        }
    }

    /// « Ta publication du 20 novembre 2026 », ou le type seul sans date.
    static func targetLine(_ value: ModerationDecision.Target) -> String {
        let label = target(value.type)
        guard let created = value.createdAt else { return label }
        return String(localized: "\(label) du \(day(created))")
    }

    static func decidedBy(automated: Bool) -> String {
        // G7 : un masquage automatique suit un seuil de signalements, avant tout regard
        // de l'équipe ; « par un filtre » aurait été inexact.
        automated ? String(localized: "Décidé automatiquement, sans examen humain")
            : String(localized: "Décidé par un modérateur")
    }

    /// Ce que la décision change, ou `nil` pour une action inconnue.
    static func scope(_ decision: ModerationDecision) -> String? {
        let until = decision.accountRestriction?.until ?? decision.until
        switch decision.accountRestriction?.type ?? decision.action {
        case "removed": return String(localized: "Retiré pour tout le monde")
        case "hidden": return String(localized: "Masqué pour tout le monde")
        case "rejected": return String(localized: "Refusé avant publication")
        case "warning": return String(localized: "Rien n’est retiré : simple avertissement")
        case "none": return String(localized: "Aucune mesure sur le contenu")
        case "suspended", "account_suspended":
            return until.map { String(localized: "Compte suspendu jusqu’au \(day($0))") }
                ?? String(localized: "Compte suspendu, sans date de fin")
        case "photo_upload_banned":
            return until.map { String(localized: "Envoi de photos bloqué jusqu’au \(day($0))") }
                ?? String(localized: "Envoi de photos bloqué, sans date de fin")
        default: return nil
        }
    }

    static func rule(_ rule: ModerationDecision.Rule?) -> String {
        guard let rule else { return String(localized: "Aucune règle citée") }
        return "\(rule.id) · \(rule.title)"
    }

    /// L'état du recours en une phrase, ou `nil` quand l'issue a son propre bloc.
    static func appealStatus(_ appeal: ModerationDecision.Appeal) -> String? {
        switch appeal.status {
        case "none":
            guard appeal.possible else { return String(localized: "Cette décision ne peut plus être contestée.") }
            return appeal.deadline.map { String(localized: "Tu peux contester jusqu’au \(day($0)) ; une autre personne réexamine.") }
                ?? String(localized: "Tu peux contester ; une autre personne réexamine.")
        case "pending":
            return appeal.filedAt.map { String(localized: "Contestation envoyée le \(day($0)) : une autre personne réexamine la décision.") }
                ?? String(localized: "Contestation envoyée : une autre personne réexamine la décision.")
        case "accepted", "rejected":
            return nil
        default:
            // Un état plus récent du contrat : son libellé serveur, sinon rien d'inventé.
            return appeal.outcomeLabel
        }
    }

    /// Pastille de l'état du recours dans la liste.
    static func appealPill(_ appeal: ModerationDecision.Appeal) -> String? {
        switch appeal.status {
        case "pending": String(localized: "Contestée")
        case "accepted": String(localized: "Contestation acceptée")
        case "rejected": String(localized: "Contestation refusée")
        default: nil
        }
    }

    static func appealError(_ error: Error) -> String {
        if let api = error as? APIError {
            if api.isOffline { return String(localized: "Hors ligne : ta contestation n’est pas partie.") }
            if case .http(let status, let code, _, _, _) = api {
                if code == "APPEAL_EXISTS" || status == 409 {
                    return String(localized: "Une contestation est déjà en cours pour cette décision.")
                }
                if code == "APPEAL_CLOSED" || status == 422 { return String(localized: "Le délai pour contester est passé.") }
                if code == "NOT_FOUND" || status == 404 {
                    return String(localized: "Cette décision n’existe plus ou ne concerne pas ton compte.")
                }
                if code == "INVALID_PARAMS" || status == 400 {
                    return String(localized: "Ton message doit faire entre \(ModerationAppealLimits.minimum) et \(ModerationAppealLimits.maximum) caractères.")
                }
            }
        }
        return String(localized: "La contestation n’a pas pu être envoyée. Réessaie.")
    }

    static func day(_ date: Date) -> String {
        // Espaces insécables : « 21 novembre 2026 » ne se coupe jamais en fin de ligne.
        date.formatted(.dateTime.day().month(.wide).year()).replacingOccurrences(of: " ", with: "\u{00A0}")
    }

    static func icon(_ decision: ModerationDecision) -> String {
        switch decision.action {
        case "account_suspended": "person.crop.circle.badge.xmark"
        case "photo_upload_banned": "photo.badge.exclamationmark"
        case "warning": "exclamationmark.bubble"
        case "hidden": "eye.slash"
        case "none": "checkmark.shield"
        default: "exclamationmark.shield"
        }
    }
}

/// Capsule d'état (nouveau, contestée, issue du recours).
private struct ModerationPill: View {
    let text: String
    var tint: Color = SQColor.label
    var fill: Color = SQColor.chip

    var body: some View {
        Text(verbatim: text)
            .font(SQFont.body(12, .semibold, relativeTo: .caption))
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(tint)
            .padding(.horizontal, SQSpace.sm2)
            .padding(.vertical, 5)
            .frame(minHeight: 26)
            .background(fill, in: Capsule(style: .continuous))
    }
}

// MARK: - Liste

/// « Décisions de modération » : ce que l'équipe a décidé sur les contenus du
/// compte, avec motif, règle et recours (DSA, art. 17 et 20).
struct ModerationDecisionsView: View {
    @EnvironmentObject private var session: AuthSessionViewModel
    let service: ModerationDecisionsServicing
    @State private var decisions: [ModerationDecision] = []
    @State private var nextCursor: String?
    /// Décisions non vues à l'ouverture : les premières de la liste.
    @State private var newCount = 0
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var loadError: String?
    @State private var loaded = false

    private var isSignedOut: Bool {
        if case .authenticated = session.state { return false }
        return true
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                SQSettingsHeader(title: "Décisions de modération",
                                 subtitle: "Ce que l’équipe a décidé sur tes contenus",
                                 backIdentifier: "moderation.back")
                NavigationLink {
                    CommunityRulesView(service: service)
                } label: {
                    Label("Règles de la communauté", systemImage: "book.closed")
                        .font(SQFont.body(15, .semibold, relativeTo: .body))
                        .foregroundStyle(SQColor.accentInk)
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier("moderation.rules")
                if isSignedOut {
                    EmptyStateView(title: "Décisions de modération",
                                   message: "Connecte-toi pour voir les décisions qui concernent ton compte.",
                                   systemImage: "person.crop.circle")
                } else {
                    content
                }
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.vertical, SQSpace.sm)
        }
        .sqReadableWidth()
        .signalQuestBackground()
        .navigationTitle("Décisions de modération")
        .toolbar(.hidden, for: .navigationBar)
        .sqKeepsSwipeBack()
        .task { if !isSignedOut, !loaded { await load() } }
        .refreshable { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && decisions.isEmpty {
            SQSpinner().tint(SQColor.brandRed).frame(maxWidth: .infinity).padding(.top, SQSpace.xl)
        } else if let loadError, decisions.isEmpty {
            ErrorStateView(title: "Décisions indisponibles", message: loadError) { Task { await load() } }
        } else if decisions.isEmpty {
            EmptyStateView(title: "Aucune décision sur ton compte",
                           message: "Si l’équipe retire ou masque un de tes contenus, tu verras ici le motif, la règle concernée et comment contester.",
                           systemImage: "checkmark.shield")
                .accessibilityIdentifier("moderation.empty")
        } else {
            if let loadError { SQInlineError(message: loadError) }
            VStack(spacing: 0) {
                ForEach(Array(decisions.enumerated()), id: \.element.id) { index, decision in
                    if index > 0 { Divider() }
                    NavigationLink {
                        ModerationDecisionDetailView(service: service, decision: decision, onUpdate: { updated in
                            if let position = decisions.firstIndex(where: { $0.id == updated.id }) {
                                decisions[position] = updated
                            }
                        })
                    } label: {
                        ModerationDecisionRow(decision: decision, isNew: index < newCount)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("moderation.row.\(decision.id)")
                }
            }
            .padding(.horizontal, SQSpace.lg)
            .sqCardBackground()
            if nextCursor != nil {
                GradientButton("Afficher plus", isBusy: isLoadingMore, style: .secondary) {
                    Task { await loadMore() }
                }
                .disabled(isLoadingMore)
                .accessibilityIdentifier("moderation.more")
            }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await service.page(cursor: nil, limit: 20)
            decisions = page.decisions
            nextCursor = page.nextCursor
            newCount = page.unseenCount
            loadError = nil
            loaded = true
            // Vues dès l'ouverture, comme sur Android : la pastille se vide sur tous les appareils.
            if page.unseenCount > 0, let newest = page.decisions.first {
                _ = try? await service.markSeen(upTo: newest.id)
            }
        } catch {
            if !error.isCancellation { loadError = error.userFacingMessage }
        }
    }

    private func loadMore() async {
        guard let cursor = nextCursor, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await service.page(cursor: cursor, limit: 20)
            let known = Set(decisions.map(\.id))
            decisions.append(contentsOf: page.decisions.filter { !known.contains($0.id) })
            nextCursor = page.nextCursor
            loadError = nil
        } catch {
            if !error.isCancellation { loadError = error.userFacingMessage }
        }
    }
}

private struct ModerationDecisionRow: View {
    let decision: ModerationDecision
    let isNew: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: .top, spacing: SQSpace.md) {
            if !dynamicTypeSize.isAccessibilitySize {
                ProfileMenuIcon(systemImage: ModerationDecisionText.icon(decision))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: ModerationDecisionText.action(decision.action))
                    .font(SQFont.body(15, .semibold, relativeTo: .body))
                    .foregroundStyle(SQColor.label)
                Text(verbatim: subtitle)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                let pills = self.pills
                if !pills.isEmpty {
                    FlowLayout(spacing: SQSpace.xs) {
                        ForEach(pills, id: \.text) { pill in pill }
                    }
                    .padding(.top, 2)
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(uiColor: .tertiaryLabel))
                .accessibilityHidden(true)
        }
        .padding(.vertical, SQSpace.md)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        let reason = decision.reason.label ?? String(localized: "Motif non précisé")
        var parts = [ModerationDecisionText.target(decision.target.type), reason]
        if let decided = decision.decidedAt { parts.append(ModerationDecisionText.day(decided)) }
        return parts.joined(separator: " · ")
    }

    private var pills: [ModerationPill] {
        var pills: [ModerationPill] = []
        if isNew { pills.append(ModerationPill(text: String(localized: "Nouveau"), tint: SQColor.accentInk, fill: SQColor.accentSoft)) }
        if let appeal = ModerationDecisionText.appealPill(decision.appeal) {
            switch decision.appeal.status {
            case "accepted": pills.append(ModerationPill(text: appeal, tint: OutageTint.resolvedInk, fill: SQColor.successSoft))
            case "pending": pills.append(ModerationPill(text: appeal, tint: OutageTint.degradedInk, fill: SQColor.warningSoft))
            default: pills.append(ModerationPill(text: appeal))
            }
        }
        return pills
    }
}

// MARK: - Détail

struct ModerationDecisionDetailView: View {
    let service: ModerationDecisionsServicing
    private let decisionId: String
    var onUpdate: ((ModerationDecision) -> Void)?
    var onClose: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var decision: ModerationDecision?
    @State private var thumbnail: UIImage?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var notFound = false
    @State private var showAppeal = false
    /// « Contestation envoyée. », annoncé à VoiceOver après l'envoi.
    @State private var notice: String?

    init(service: ModerationDecisionsServicing, decision: ModerationDecision? = nil, decisionId: String? = nil,
         onClose: (() -> Void)? = nil, onUpdate: ((ModerationDecision) -> Void)? = nil) {
        self.service = service
        self.decisionId = decision?.id ?? decisionId ?? ""
        self.onClose = onClose
        self.onUpdate = onUpdate
        _decision = State(initialValue: decision)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                MapChipIconButton(systemImage: onClose == nil ? "chevron.left" : "xmark",
                                  label: onClose == nil ? "Retour" : "Fermer", identifier: "moderation.detail.back") {
                    if let onClose { onClose() } else { dismiss() }
                }
                if let decision {
                    header(decision)
                    contentCard(decision)
                    factsCard(decision)
                    if let note = decision.reason.text {
                        noteCard(title: "Précision du modérateur", text: note)
                    }
                    NavigationLink {
                        CommunityRulesView(service: service, version: decision.rule?.version, highlightedRuleId: decision.rule?.id)
                    } label: {
                        Label("Lire les règles", systemImage: "book.closed")
                            .font(SQFont.body(15, .semibold, relativeTo: .body))
                            .foregroundStyle(SQColor.accentInk)
                            .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("moderation.detail.rules")
                    appealCard(decision)
                } else if isLoading {
                    SQSpinner().tint(SQColor.brandRed).frame(maxWidth: .infinity).padding(.top, SQSpace.xl)
                } else if notFound {
                    EmptyStateView(title: "Décision de modération",
                                   message: "Cette décision n’existe plus ou ne concerne pas ton compte.",
                                   systemImage: "questionmark.circle")
                } else if let loadError {
                    ErrorStateView(title: "Décision indisponible", message: loadError) { Task { await load() } }
                }
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.vertical, SQSpace.sm)
        }
        .sqReadableWidth()
        .signalQuestBackground()
        .navigationTitle("Décision de modération")
        .toolbar(.hidden, for: .navigationBar)
        .sqKeepsSwipeBack()
        .task { await loadIfNeeded() }
        .task(id: decision?.target.thumbnailPath) { await loadThumbnail() }
        .sheet(isPresented: $showAppeal) {
            if let decision {
                ModerationAppealSheet(service: service, decision: decision) { updated in
                    apply(updated)
                    notice = String(localized: "Contestation envoyée.")
                } onStale: {
                    Task { await load() }
                }
            }
        }
    }

    private func header(_ decision: ModerationDecision) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text(verbatim: ModerationDecisionText.targetLine(decision.target))
                .sqKicker()
            Text(verbatim: ModerationDecisionText.action(decision.action))
                .font(SQFont.display(26, .bold, relativeTo: .title))
                .foregroundStyle(SQColor.label)
                .fixedSize(horizontal: false, vertical: true)
                .sqHeader()
            if let decided = decision.decidedAt {
                Text(verbatim: String(localized: "Décidé le \(ModerationDecisionText.day(decided))"))
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("moderation.detail.header")
    }

    @ViewBuilder
    private func contentCard(_ decision: ModerationDecision) -> some View {
        let excerpt = decision.target.excerpt
        if thumbnail != nil || excerpt != nil {
            VStack(alignment: .leading, spacing: SQSpace.md) {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 96, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                        .accessibilityLabel(Text("Vignette du contenu concerné"))
                }
                if let excerpt {
                    Text(verbatim: String(localized: "« \(excerpt) »"))
                        .font(SQType.body)
                        .foregroundStyle(SQColor.label)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(SQSpace.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .sqCardBackground()
        }
    }

    private func factsCard(_ decision: ModerationDecision) -> some View {
        VStack(spacing: SQSpace.sm2) {
            SQFactRow(label: "Motif", value: decision.reason.label ?? String(localized: "Motif non précisé"))
            SQFactRow(label: "Règle", value: ModerationDecisionText.rule(decision.rule))
            if let scope = ModerationDecisionText.scope(decision) {
                SQFactRow(label: "Portée", value: scope)
            }
            // Pleine largeur : dans la colonne de valeur d'une rangée, la mention se
            // coupait au milieu (« Automatiquement / , sans… »). DSA art. 17 : elle doit se lire.
            HStack(alignment: .firstTextBaseline, spacing: SQSpace.sm) {
                Image(systemName: decision.automated ? "gearshape.2" : "person")
                    .font(SQType.subhead(.regular))
                    .foregroundStyle(SQColor.labelSecondary)
                    .accessibilityHidden(true)
                Text(verbatim: ModerationDecisionText.decidedBy(automated: decision.automated))
                    .font(SQType.subhead(.semibold))
                    .foregroundStyle(SQColor.label)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, SQSpace.xs)
        }
        .padding(SQSpace.lg)
        .sqCardBackground()
        .accessibilityIdentifier("moderation.detail.facts")
    }

    private func noteCard(title: LocalizedStringKey, text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(SQFont.body(12, .semibold, relativeTo: .caption))
                .foregroundStyle(SQColor.labelSecondary)
            Text(verbatim: text)
                .font(SQType.body)
                .foregroundStyle(SQColor.label)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(SQSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sqCardBackground()
        .accessibilityElement(children: .combine)
    }

    private func appealCard(_ decision: ModerationDecision) -> some View {
        let appeal = decision.appeal
        return VStack(alignment: .leading, spacing: SQSpace.md) {
            Text("Recours").sqKicker()
            if appeal.status == "accepted" || appeal.status == "rejected" {
                VStack(alignment: .leading, spacing: SQSpace.xs) {
                    Text(verbatim: appeal.outcomeLabel ?? ModerationDecisionText.appealPill(appeal) ?? "")
                        .font(SQFont.body(16, .semibold, relativeTo: .body))
                        .foregroundStyle(appeal.status == "accepted" ? OutageTint.resolvedInk : SQColor.label)
                        .fixedSize(horizontal: false, vertical: true)
                    if let reviewed = appeal.decidedAt {
                        Text(verbatim: String(localized: "Réexaminée le \(ModerationDecisionText.day(reviewed))"))
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                }
                .accessibilityElement(children: .combine)
                if let note = appeal.outcomeText {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Précision de la personne qui a réexaminé")
                            .font(SQFont.body(12, .semibold, relativeTo: .caption))
                            .foregroundStyle(SQColor.labelSecondary)
                        Text(verbatim: note)
                            .font(SQType.body)
                            .foregroundStyle(SQColor.label)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if let status = ModerationDecisionText.appealStatus(appeal) {
                Text(verbatim: status)
                    .font(SQType.callout)
                    .foregroundStyle(SQColor.label)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("moderation.detail.appealStatus")
            }
            if appeal.possible && appeal.status == "none" {
                GradientButton("Contester la décision", systemImage: "arrow.uturn.backward") { showAppeal = true }
                    .accessibilityIdentifier("moderation.detail.appeal")
            }
        }
        .padding(SQSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        // L'envoi se lit déjà dans la ligne d'état (« Contestation envoyée le… ») :
        // la confirmation n'est qu'annoncée à VoiceOver, sans doublon à l'écran.
        .background { if let notice { Color.clear.sqAnnounce(notice) } }
        .sqCardBackground()
    }

    private func apply(_ updated: ModerationDecision) {
        decision = updated
        onUpdate?(updated)
    }

    private func loadIfNeeded() async {
        if decision == nil { await load() }
        // Ouverte par un push : vue, avec toutes les plus anciennes, comme dans la liste.
        if onClose != nil, let id = decision?.id {
            _ = try? await service.markSeen(upTo: id)
        }
    }

    private func load() async {
        guard !decisionId.isEmpty else { notFound = true; return }
        isLoading = true
        defer { isLoading = false }
        do {
            apply(try await service.decision(id: decisionId))
            loadError = nil
            notFound = false
        } catch {
            if case APIError.http(404, _, _, _, _) = error {
                notFound = true
            } else if !error.isCancellation {
                loadError = error.userFacingMessage
            }
        }
    }

    private func loadThumbnail() async {
        guard let path = decision?.target.thumbnailPath, thumbnail == nil,
              let data = try? await service.thumbnail(path: path) else { return }
        thumbnail = UIImage(data: data)
    }
}

// MARK: - Recours

private struct ModerationAppealSheet: View {
    let service: ModerationDecisionsServicing
    let decision: ModerationDecision
    let onFiled: (ModerationDecision) -> Void
    /// Un recours déjà déposé ou un délai passé : la décision affichée n'est plus à jour.
    let onStale: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var isSending = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private var trimmedCount: Int { message.trimmingCharacters(in: .whitespacesAndNewlines).count }
    private var canSend: Bool {
        (ModerationAppealLimits.minimum...ModerationAppealLimits.maximum).contains(trimmedCount) && !isSending
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SQSpace.lg) {
                    Text("Explique pourquoi la décision te semble injuste. Une autre personne que celle qui a décidé lit ton message.")
                        .font(SQType.callout)
                        .foregroundStyle(SQColor.label)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: SQSpace.xs) {
                        Text("Ton message")
                            .font(SQFont.body(13, .semibold, relativeTo: .footnote))
                            .foregroundStyle(SQColor.labelSecondary)
                        TextEditor(text: $message)
                            .font(SQType.body)
                            .foregroundStyle(SQColor.label)
                            .focused($focused)
                            .frame(minHeight: 160)
                            .scrollContentBackground(.hidden)
                            .padding(SQSpace.sm)
                            // Fond de la couleur de la feuille : le filet dessine le champ (comme ReportSheet).
                            .sqFieldSurface(in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
                            .accessibilityLabel(Text("Ton message"))
                            .accessibilityIdentifier("moderation.appeal.field")
                            .onChangeCompat(of: message) { _, value in
                                if value.count > ModerationAppealLimits.maximum {
                                    message = String(value.prefix(ModerationAppealLimits.maximum))
                                }
                            }
                        HStack {
                            if trimmedCount < ModerationAppealLimits.minimum {
                                Text(verbatim: String(localized: "Au moins \(ModerationAppealLimits.minimum) caractères"))
                            }
                            Spacer(minLength: SQSpace.sm)
                            Text(verbatim: "\(trimmedCount) / \(ModerationAppealLimits.maximum)")
                                .monospacedDigit()
                        }
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                    }
                    if let error { SQInlineError(message: error) }
                    GradientButton("Envoyer la contestation", systemImage: "paperplane", isBusy: isSending) {
                        Task { await send() }
                    }
                    .disabled(!canSend)
                    .accessibilityIdentifier("moderation.appeal.send")
                }
                .padding(.horizontal, SQSpace.lg)
                .padding(.vertical, SQSpace.md)
            }
            .sqReadableWidth()
            .signalQuestBackground()
            .navigationTitle("Contester la décision")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                        .disabled(isSending)
                }
            }
            .onAppear { focused = true }
        }
        .interactiveDismissDisabled(isSending)
    }

    private func send() async {
        guard canSend else { return }
        isSending = true
        defer { isSending = false }
        do {
            let updated = try await service.appeal(decisionId: decision.id, message: message)
            onFiled(updated)
            dismiss()
        } catch {
            guard !error.isCancellation else { return }
            self.error = ModerationDecisionText.appealError(error)
            if case APIError.http(let status, _, _, _, _) = error, [404, 409, 422].contains(status) { onStale() }
        }
    }
}

// MARK: - Règles de la communauté

/// Règles citées par les décisions, dans la version en vigueur au moment de la
/// décision quand on vient d'une décision, et dans le ton choisi (ADDR-1).
struct CommunityRulesView: View {
    let service: ModerationDecisionsServicing
    var version: String?
    var highlightedRuleId: String?
    @State private var document: CommunityRulesDocument?
    @State private var loadError: String?
    @State private var isLoading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                SQSettingsHeader(title: "Règles de la communauté", backIdentifier: "rules.back")
                if let document {
                    if let effective = document.effectiveDate {
                        Text(verbatim: String(localized: "Version du \(ModerationDecisionText.day(effective)) · \(document.version)"))
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                    if document.fallback {
                        Text("Ces règles ne sont pas encore traduites dans ta langue : elles s’affichent en anglais.")
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(document.rules.enumerated()), id: \.element.id) { index, rule in
                            if index > 0 { Divider() }
                            ruleRow(rule)
                        }
                    }
                    .padding(.horizontal, SQSpace.lg)
                    .sqCardBackground()
                } else if isLoading {
                    SQSpinner().tint(SQColor.brandRed).frame(maxWidth: .infinity).padding(.top, SQSpace.xl)
                } else if let loadError {
                    ErrorStateView(title: "Impossible de charger les règles.", message: loadError) { Task { await load() } }
                }
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.vertical, SQSpace.sm)
        }
        .sqReadableWidth()
        .signalQuestBackground()
        .navigationTitle("Règles de la communauté")
        .toolbar(.hidden, for: .navigationBar)
        .sqKeepsSwipeBack()
        .task { if document == nil { await load() } }
    }

    private func ruleRow(_ rule: CommunityRulesDocument.Rule) -> some View {
        let highlighted = rule.id == highlightedRuleId
        return VStack(alignment: .leading, spacing: SQSpace.xs) {
            HStack(alignment: .firstTextBaseline, spacing: SQSpace.sm) {
                Text(verbatim: rule.id)
                    .font(SQFont.body(13, .bold, relativeTo: .footnote))
                    .foregroundStyle(highlighted ? SQColor.accentInk : SQColor.labelSecondary)
                Text(verbatim: rule.title)
                    .font(SQFont.body(15, .semibold, relativeTo: .body))
                    .foregroundStyle(SQColor.label)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(verbatim: rule.summary)
                .font(SQType.callout)
                .foregroundStyle(SQColor.label)
                .fixedSize(horizontal: false, vertical: true)
            if !rule.text.isEmpty, rule.text != rule.summary {
                Text(verbatim: rule.text)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, SQSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .leading) {
            if highlighted {
                // La règle citée par la décision : un filet carmin, pas seulement une couleur de texte.
                Rectangle().fill(SQColor.accentInk).frame(width: 3).offset(x: -SQSpace.lg + 2)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(highlighted ? .isSelected : [])
        .accessibilityIdentifier("rules.rule.\(rule.id)")
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            document = try await service.communityRules(version: version)
            loadError = nil
        } catch {
            if !error.isCancellation { loadError = error.userFacingMessage }
        }
    }
}
