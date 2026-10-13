import SwiftUI
import PhotosUI

struct ReportSheet: View {
    private let reasons: [ReportReason]
    private let notice: String?
    /// Sans champ libre : le signalement d'un message chiffré v2 ne porte que
    /// son motif en clair (§11, D.10).
    private let allowsComment: Bool
    private let submit: @MainActor (ReportReason, String?) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var inAppNotifications: SQInAppNotificationCenter
    @State private var reason: ReportReason
    @State private var note: String = ""
    @State private var isBusy = false
    @State private var error: String?

    init(target: ReportTarget, service: ReportsServicing) {
        self.init(reasons: ReportReason.allCases) { reason, comment in
            try await service.report(target, reason: reason, comment: comment)
        }
    }

    /// Signalement hors `/api/social/reports` (messages) : l'appelant fournit
    /// l'envoi, les motifs proposés et, au besoin, ce qu'il faut savoir avant.
    init(
        reasons: [ReportReason],
        notice: String? = nil,
        allowsComment: Bool = true,
        submit: @escaping @MainActor (ReportReason, String?) async throws -> Void
    ) {
        self.reasons = reasons
        self.notice = notice
        self.allowsComment = allowsComment
        self.submit = submit
        _reason = State(initialValue: reasons.first ?? .spam)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                MapChipIconButton(systemImage: "xmark", label: "Annuler", identifier: "report.cancel") { dismiss() }

                VStack(alignment: .leading, spacing: SQSpace.xs) {
                    Text("Signaler")
                        .font(SQFont.display(28, .bold, relativeTo: .largeTitle))
                        .foregroundStyle(SQColor.label)
                        .accessibilityAddTraits(.isHeader)
                    Text("Choisis ce qui ne va pas.")
                        .font(SQType.callout)
                        .foregroundStyle(SQColor.labelSecondary)
                }

                if let notice {
                    Label(notice, systemImage: "lock")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("report.notice")
                }

                reasonsCard

                if allowsComment {
                    VStack(alignment: .leading, spacing: SQSpace.sm) {
                        Text("Précisions (optionnel)")
                            .sqKicker()
                            .padding(.leading, SQSpace.xs)
                        TextField("Décris ce qui te pose problème", text: $note, axis: .vertical)
                            .font(SQType.body)
                            .lineLimit(3...6)
                            .padding(SQSpace.md)
                            .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
                            .accessibilityIdentifier("report.comment")
                    }
                }

                if let error {
                    Text(error)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.dangerInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("report.error")
                }

                GradientButton(String(localized: "Envoyer le signalement"), isBusy: isBusy) {
                    Task { await send() }
                }
                .disabled(isBusy)
                .accessibilityIdentifier("report.send")
            }
            .padding(SQSpace.lg)
        }
        .scrollDismissesKeyboard(.interactively)
        .sqSheet(background: SQColor.bg)
    }

    /// Motifs en boutons radio sur une carte : un seul choix, visible d'un coup d'œil.
    private var reasonsCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(reasons.enumerated()), id: \.element.id) { index, value in
                if index > 0 { Divider().padding(.leading, SQSpace.md) }
                let isSelected = value == reason
                Button {
                    reason = value
                } label: {
                    HStack(spacing: SQSpace.md) {
                        Text(value.label)
                            .font(SQType.body(.semibold))
                            .foregroundStyle(SQColor.label)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 22))
                            .foregroundStyle(isSelected ? SQColor.accentInk : SQColor.labelTertiary)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, SQSpace.md)
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier("report.reason.\(value.rawValue)")
            }
        }
        .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
    }

    private func send() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let comment = note.trimmingCharacters(in: .whitespacesAndNewlines)
            try await submit(reason, allowsComment && !comment.isEmpty ? note : nil)
            Haptics.success()
            dismiss()
            // La feuille se ferme : sans ce message, rien ne dit que le signalement est parti.
            inAppNotifications.show(SQInAppNotificationItem(
                body: String(localized: "Signalement envoyé. Merci, nous allons l'examiner."),
                variant: .success
            ))
        } catch {
            self.error = error.userFacingMessage
            Haptics.error()
        }
    }
}

// MARK: - Bugs et idées

/// Pastille d'un signalement : bug en rouge doux, idée en ambre, terminé en vert.
struct BugReportPastille: View {
    let report: BugReport

    var body: some View {
        let style = Self.style(for: report)
        Image(systemName: style.icon)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(style.tint)
            .frame(width: 38, height: 38)
            .background(style.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityHidden(true)
    }

    private static func style(for report: BugReport) -> (icon: String, tint: Color, fill: Color) {
        let icon = report.isIdea ? "lightbulb" : "ladybug"
        switch report.status {
        case .resolved: return (icon, SQColor.success, SQColor.successSoft)
        case .closed, .wontFix: return (icon, SQColor.ink2, SQColor.chip)
        case .open, .inProgress:
            return report.isIdea ? (icon, SQColor.warning, SQColor.warningSoft) : (icon, SQColor.dangerInk, SQColor.dangerSoft)
        }
    }
}

/// Capsule de statut d'un signalement ; la gêne utilise la même capsule, neutre.
struct BugStatusPill: View {
    let text: String
    var systemImage: String? = nil
    var tint: Color = SQColor.label
    var fill: Color = SQColor.chip

    init(status: BugStatus) {
        text = status.label
        switch status {
        case .open: break
        case .inProgress: tint = SQColor.warning; fill = SQColor.warningSoft
        case .resolved: tint = SQColor.success; fill = SQColor.successSoft; systemImage = "checkmark"
        case .closed, .wontFix: systemImage = "lock"
        }
    }

    init(text: String) { self.text = text }

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .bold))
                    .accessibilityHidden(true)
            }
            Text(verbatim: text)
                .font(SQFont.body(12, .semibold, relativeTo: .caption))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, SQSpace.sm2)
        .padding(.vertical, 5)
        .frame(minHeight: 26)
        .background(fill, in: Capsule(style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

extension PendingReportImage {
    /// Réduit et ré-encode en JPEG hors du fil principal (métadonnées retirées),
    /// puis fabrique la data-URL attendue par `/api/bugs`.
    static func prepare(_ item: PhotosPickerItem) async -> PendingReportImage? {
        guard let raw = try? await item.loadTransferable(type: Data.self) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            guard let jpeg = PhotoUploadPreparation.downscaledJPEG(from: raw, maxSide: 1400, quality: 0.8),
                  let image = UIImage(data: jpeg) else { return nil }
            return PendingReportImage(image: image, dataURL: "data:image/jpeg;base64,\(jpeg.base64EncodedString())")
        }.value
    }
}

/// « Bugs et idées » : mes signalements et les réponses de l'équipe, les mêmes
/// que sur le site (`/api/bugs?myBugs=true`).
struct BugReportsListView: View {
    enum Filter: Hashable { case all, open, inProgress, finished }

    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var session: AuthSessionViewModel
    @EnvironmentObject private var router: AppRouter
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var reports: [BugReport] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var filter: Filter = .all
    @State private var showComposer = false
    @State private var showSignup = false
    /// Ouvert par « Voir mon signalement », une fois le formulaire refermé.
    @State private var pendingOpen: BugReport?
    @State private var opened: BugReport?

    private var isSignedOut: Bool {
        if case .loggedOut = session.state { return true }
        return false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                SQSettingsHeader(title: "Bugs et idées",
                                 subtitle: "Tes signalements et les réponses de l'équipe, sur l'app comme sur le site.",
                                 backIdentifier: "bugs.back")
                if isSignedOut {
                    guestCard
                } else {
                    GradientButton(String(localized: "Nouveau signalement"), systemImage: "plus") { showComposer = true }
                        .accessibilityIdentifier("bugs.new")
                    content
                }
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.vertical, SQSpace.sm)
        }
        .sqReadableWidth()
        .signalQuestBackground()
        .navigationTitle("Bugs et idées")
        .toolbar(.hidden, for: .navigationBar)
        .sqKeepsSwipeBack()
        .task { if !isSignedOut { await load() } }
        .refreshable { await load() }
        .sheet(isPresented: $showComposer, onDismiss: {
            opened = pendingOpen
            pendingOpen = nil
        }) {
            BugReportComposerSheet(onSent: { report in
                reports.removeAll { $0.id == report.id }
                reports.insert(report, at: 0)
            }, onOpen: { pendingOpen = $0 })
        }
        .sheet(isPresented: $showSignup) {
            NavigationStack { SignupView() }
        }
        .navigationDestination(isPresented: Binding(get: { opened != nil }, set: { if !$0 { opened = nil } })) {
            if let opened {
                BugReportDetailView(service: services.bugReports, report: opened, onDeleted: { id in
                    reports.removeAll { $0.id == id }
                })
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && reports.isEmpty {
            SQSpinner().tint(SQColor.brandRed).frame(maxWidth: .infinity).padding(.top, SQSpace.xl)
        } else if let loadError, reports.isEmpty {
            ErrorStateView(title: "Signalements indisponibles", message: loadError) { Task { await load() } }
        } else if reports.isEmpty {
            EmptyStateView(title: "Aucun signalement pour l'instant",
                           message: "Un bug, un écran qui gêne, une idée ? Chaque signalement est lu par l'équipe, et tu suis sa réponse ici.",
                           systemImage: "bubble.left.and.bubble.right")
                .frame(maxWidth: .infinity)
                .padding(.top, SQSpace.lg)
                .accessibilityIdentifier("bugs.empty")
        } else {
            filterChips
            let visible = reports.filter(matches)
            if visible.isEmpty {
                Text("Aucun signalement dans ce filtre.")
                    .font(SQType.callout)
                    .foregroundStyle(SQColor.labelSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, SQSpace.lg)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, report in
                        if index > 0 { Divider() }
                        NavigationLink {
                            BugReportDetailView(service: services.bugReports, report: report, onDeleted: { id in
                                reports.removeAll { $0.id == id }
                            })
                        } label: {
                            row(report)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("bugs.row.\(report.id)")
                    }
                }
                .padding(.horizontal, SQSpace.lg)
                .sqCardBackground()
            }
        }
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: SQSpace.sm) {
                chip(.all, String(localized: "Tous · \(reports.count)"))
                chip(.open, String(localized: "Ouverts · \(count(.open))"))
                chip(.inProgress, String(localized: "En cours · \(count(.inProgress))"))
                chip(.finished, String(localized: "Résolus · \(count(.finished))"))
            }
        }
    }

    private func chip(_ value: Filter, _ label: String) -> some View {
        SQChip(label: label, isSelected: filter == value, selectedFill: SQColor.label, selectedInk: SQColor.onInk) {
            filter = value
        }
        .accessibilityIdentifier("bugs.filter.\(String(describing: value))")
    }

    private func count(_ value: Filter) -> Int {
        reports.filter { report in Self.matches(report, value) }.count
    }

    private func matches(_ report: BugReport) -> Bool { Self.matches(report, filter) }

    private static func matches(_ report: BugReport, _ filter: Filter) -> Bool {
        switch filter {
        case .all: return true
        case .open: return report.status == .open
        case .inProgress: return report.status == .inProgress
        case .finished: return report.status.isFinished
        }
    }

    private func row(_ report: BugReport) -> some View {
        HStack(alignment: .top, spacing: SQSpace.md) {
            BugReportPastille(report: report)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: report.title)
                    .font(SQFont.body(15, .semibold, relativeTo: .body))
                    .foregroundStyle(SQColor.label)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                Text(verbatim: Self.subtitle(report))
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                if report.adminResponse?.isEmpty == false, !report.status.isFinished {
                    Label("Réponse de l'équipe", systemImage: "bubble.left.fill")
                        .font(SQFont.body(12, .semibold, relativeTo: .caption))
                        .foregroundStyle(SQColor.accentInk)
                }
                if dynamicTypeSize.isAccessibilitySize {
                    BugStatusPill(status: report.status)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !dynamicTypeSize.isAccessibilitySize {
                BugStatusPill(status: report.status)
            }
        }
        .padding(.vertical, SQSpace.md)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// « Affichage · résolu le 2 oct. », « Idée · envoyée le 9 oct. »…
    static func subtitle(_ report: BugReport) -> String {
        let day: (Date) -> String = { $0.formatted(.dateTime.day().month(.abbreviated)) }
        let detail: String?
        switch report.status {
        case .resolved:
            detail = (report.resolvedAt ?? report.updatedAt).map { String(localized: "résolu le \(day($0))") }
        case .closed, .wontFix:
            detail = report.updatedAt.map { String(localized: "clos le \(day($0))") }
        case .inProgress:
            detail = (report.updatedAt ?? report.createdAt).map {
                String(localized: "mis à jour \($0.formatted(.relative(presentation: .named)))")
            }
        case .open:
            detail = report.createdAt.map {
                report.isIdea ? String(localized: "envoyée le \(day($0))") : String(localized: "envoyé le \(day($0))")
            }
        }
        return [report.category.label, detail].compactMap { $0 }.joined(separator: " · ")
    }

    private var guestCard: some View {
        VStack(spacing: SQSpace.md) {
            SQIconPastille(systemImage: "person", size: 46, tint: SQColor.chipInk, fill: SQColor.chip,
                           font: SQFont.body(22, .medium, relativeTo: .title3))
            Text("Connecte-toi pour envoyer un signalement")
                .font(SQType.stateTitle)
                .foregroundStyle(SQColor.label)
                .multilineTextAlignment(.center)
            Text("Ton compte permet à l'équipe de te répondre et de te prévenir quand c'est corrigé.")
                .font(SQType.callout)
                .foregroundStyle(SQColor.labelSecondary)
                .multilineTextAlignment(.center)
            GradientButton(String(localized: "Se connecter")) { router.selectedTab = .profile }
                .accessibilityIdentifier("bugs.guest.login")
            GradientButton(String(localized: "Créer un compte"), style: .secondary) { showSignup = true }
                .accessibilityIdentifier("bugs.guest.signup")
        }
        .frame(maxWidth: .infinity)
        .padding(SQSpace.lg)
        .sqCardBackground()
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            reports = try await services.bugReports.myReports()
                .sorted { ($0.updatedAt ?? $0.createdAt ?? .distantPast) > ($1.updatedAt ?? $1.createdAt ?? .distantPast) }
            loadError = nil
        } catch {
            if error.isCancellation { return }
            loadError = error.userFacingMessage
        }
    }
}

// MARK: Formulaire

/// Nouveau signalement : un bug (type, titre, ce qui s'est passé, captures,
/// détails facultatifs) ou une idée. L'appareil, le système, la version et la
/// connexion partent d'office et sont montrés ; le dernier speedtest et la
/// position approximative seulement si l'auteur les coche.
struct BugReportComposerSheet: View {
    enum Kind: Hashable { case bug, idea }

    let onSent: (BugReport) -> Void
    let onOpen: (BugReport) -> Void

    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    @State private var kind: Kind = .bug
    @State private var category: BugCategory?
    @State private var title = ""
    @State private var details = ""
    @State private var showsMore = false
    @State private var steps = ""
    @State private var expected = ""
    @State private var severity: BugSeverity = .medium
    @State private var images: [PendingReportImage] = []
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var attachmentError: String?
    @State private var includeSpeedtest = false
    @State private var includeLocation = false
    @State private var lastSpeedtest: SpeedtestRunResult?
    @State private var device: BugReportDevice?
    @State private var isSending = false
    @State private var error: String?
    @State private var sent: BugReport?
    /// Créée une fois par formulaire : un renvoi reste un seul signalement.
    @State private var submissionID = UUID()

    private var canSend: Bool {
        !isSending && device != nil
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasDraft: Bool {
        !title.isEmpty || !details.isEmpty || !images.isEmpty || !steps.isEmpty || !expected.isEmpty
    }

    var body: some View {
        Group {
            if let sent {
                success(sent)
            } else {
                form
            }
        }
        .sqSheet(background: SQColor.bg)
        .interactiveDismissDisabled(sent == nil && hasDraft)
        .task {
            device = .current(network: services.networkPath.status.displayName)
            lastSpeedtest = await services.speedtest.history().first
        }
        .onChangeCompat(of: pickerItems) { _, _ in
            Task { await processPicked() }
        }
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                MapChipIconButton(systemImage: "xmark", label: "Fermer", identifier: "bugs.composer.close") { dismiss() }
                Text("Nouveau signalement")
                    .font(SQFont.display(28, .bold, relativeTo: .largeTitle))
                    .foregroundStyle(SQColor.label)
                    .sqHeader()
                MapSegmented(selection: $kind, options: [(.bug, "Un bug"), (.idea, "Une idée")],
                             identifier: "bugs.composer.kind")

                if kind == .bug {
                    VStack(alignment: .leading, spacing: SQSpace.sm) {
                        fieldTitle("Ce qui ne va pas")
                        FlowLayout(spacing: SQSpace.sm) {
                            ForEach(BugCategory.bugKinds) { value in
                                SQChip(label: value.label, isSelected: category == value,
                                       selectedFill: SQColor.label, selectedInk: SQColor.onInk) {
                                    category = category == value ? nil : value
                                }
                                // Taille idéale imposée : sans elle, « Autre » se coupait en deux lignes.
                                .fixedSize()
                                .accessibilityIdentifier("bugs.composer.category.\(value.rawValue)")
                            }
                        }
                    }
                }

                field(kind == .bug ? "Titre" : "Ton idée en une phrase",
                      placeholder: kind == .bug ? "Ex. La carte reste blanche après la veille"
                                                : "Ex. Comparer deux speedtests côte à côte",
                      text: $title, limit: BugReportSubmission.titleLimit, lines: 1...3, identifier: "bugs.composer.title")
                field(kind == .bug ? "Que s'est-il passé ?" : "En quoi ce serait utile ?",
                      placeholder: kind == .bug ? "Décris ce que tu faisais et ce que tu as vu…"
                                                : "Explique ce que ça changerait pour toi…",
                      text: $details, limit: BugReportSubmission.descriptionLimit, lines: 4...10,
                      identifier: "bugs.composer.details")

                captures

                if kind == .idea {
                    Label("Les idées sont lues par l'équipe ; tu es prévenu si elle est retenue.", systemImage: "lightbulb")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    moreDetails
                }

                attachedContext

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.dangerInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("bugs.composer.error")
                }
            }
            .padding(SQSpace.lg)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            GradientButton(kind == .idea ? String(localized: "Envoyer l'idée") : String(localized: "Envoyer"),
                           systemImage: "paperplane.fill", isBusy: isSending) {
                Task { await send() }
            }
            .disabled(!canSend)
            .accessibilityIdentifier("bugs.composer.send")
            .padding(.horizontal, SQSpace.lg)
            .padding(.vertical, SQSpace.sm)
            .background(SQColor.bg)
        }
    }

    private func fieldTitle(_ title: LocalizedStringKey, note: String? = nil) -> some View {
        HStack(spacing: 0) {
            Text(title)
                .font(SQFont.body(13, .bold, relativeTo: .subheadline))
                .foregroundStyle(SQColor.label)
            if let note {
                Text(verbatim: " · \(note)")
                    .font(SQFont.body(13, .medium, relativeTo: .subheadline))
                    .foregroundStyle(SQColor.labelSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func field(_ title: LocalizedStringKey, placeholder: LocalizedStringKey, text: Binding<String>, limit: Int,
                       lines: ClosedRange<Int>, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldTitle(title)
            TextField(placeholder, text: text, axis: .vertical)
                .font(SQType.body)
                .foregroundStyle(SQColor.label)
                .lineLimit(lines)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(minHeight: 48, alignment: .topLeading)
                .sqFieldSurface(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityIdentifier(identifier)
                .onChangeCompat(of: text.wrappedValue) { _, value in
                    if value.count > limit { text.wrappedValue = String(value.prefix(limit)) }
                }
            Text(verbatim: "\(text.wrappedValue.count) / \(limit)")
                .font(SQFont.body(11, .regular, relativeTo: .caption2))
                .monospacedDigit()
                .foregroundStyle(SQColor.labelSecondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityHidden(true)
        }
    }

    private var captures: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            if kind == .bug {
                fieldTitle("Captures", note: "\(images.count) / \(BugReportSubmission.maxImages)")
            } else {
                fieldTitle("Images", note: String(localized: "facultatif, 5 au plus"))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: SQSpace.sm) {
                    ForEach(images) { pending in
                        Image(uiImage: pending.image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 74, height: 74)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(alignment: .topTrailing) {
                                Button {
                                    Haptics.light()
                                    images.removeAll { $0.id == pending.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 20))
                                        .foregroundStyle(.white, .black.opacity(0.55))
                                        .frame(width: 44, height: 44, alignment: .topTrailing)
                                        .contentShape(Rectangle())
                                }
                                .accessibilityLabel("Retirer la capture")
                            }
                    }
                    if images.count < BugReportSubmission.maxImages {
                        PhotosPicker(selection: $pickerItems,
                                     maxSelectionCount: BugReportSubmission.maxImages - images.count,
                                     matching: .images) {
                            Image(systemName: "photo.badge.plus")
                                .font(.system(size: 22, weight: .medium))
                                .foregroundStyle(SQColor.ink2)
                                .frame(width: 74, height: 74)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .strokeBorder(SQColor.dots, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                                }
                        }
                        .accessibilityLabel("Ajouter des captures")
                        .accessibilityIdentifier("bugs.composer.addImages")
                    }
                }
            }
            if let attachmentError {
                Text(attachmentError)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.dangerInk)
            }
        }
    }

    private var moreDetails: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            Button {
                withAnimation(SQMotion.resolve(SQMotion.snappy, UIAccessibility.isReduceMotionEnabled)) { showsMore.toggle() }
            } label: {
                HStack(spacing: SQSpace.sm) {
                    Text("Plus de détails")
                        .font(SQFont.body(15, .semibold, relativeTo: .body))
                        .foregroundStyle(SQColor.label)
                    Text("facultatif")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(SQColor.labelSecondary)
                        .rotationEffect(.degrees(showsMore ? 180 : 0))
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(showsMore ? Text("Ouvert") : Text("Fermé"))
            .accessibilityIdentifier("bugs.composer.more")

            if showsMore {
                field("Étapes pour reproduire", placeholder: "1. Ouvrir la carte · 2. …", text: $steps,
                      limit: BugReportSubmission.stepsLimit, lines: 2...6, identifier: "bugs.composer.steps")
                field("Ce que tu attendais", placeholder: "Ex. La carte s'affiche", text: $expected,
                      limit: BugReportSubmission.expectedLimit, lines: 1...4, identifier: "bugs.composer.expected")
                VStack(alignment: .leading, spacing: 6) {
                    fieldTitle("Gêne")
                    MapSegmented(selection: $severity, options: BugSeverity.allCases.map { ($0, $0.label) },
                                 identifier: "bugs.composer.severity")
                }
            }
        }
    }

    private var attachedContext: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Joint au signalement").sqKicker()
            VStack(alignment: .leading, spacing: SQSpace.sm2) {
                if let device {
                    SQFactRow(label: "Appareil", value: device.model)
                    SQFactRow(label: "Système", value: device.osVersion)
                    SQFactRow(label: "Application", value: device.appVersion)
                    SQFactRow(label: String(localized: "bug.context.connection", defaultValue: "Connexion"), value: device.network)
                }
                Divider()
                Toggle(isOn: $includeSpeedtest) {
                    toggleLabel("Mon dernier speedtest", detail: speedtestSummary)
                }
                .disabled(lastSpeedtest == nil)
                .accessibilityIdentifier("bugs.composer.speedtest")
                Divider()
                Toggle(isOn: $includeLocation) {
                    toggleLabel("Position approximative",
                                detail: approximateLocation == nil
                                    ? String(localized: "Position indisponible pour l'instant")
                                    : String(localized: "À 1 km près, pour un bug lié au lieu"))
                }
                .disabled(approximateLocation == nil && !includeLocation)
                .accessibilityIdentifier("bugs.composer.location")
            }
            .tint(SQColor.brandRed)
            .padding(SQSpace.lg)
            .sqCardBackground()
            Label("Rien d'autre n'est envoyé. L'équipe voit ton pseudo, jamais ta position exacte.", systemImage: "lock")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func toggleLabel(_ title: LocalizedStringKey, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(SQFont.body(15, .semibold, relativeTo: .body))
                .foregroundStyle(SQColor.label)
            Text(verbatim: detail)
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
        }
    }

    private var speedtestSummary: String {
        guard let result = lastSpeedtest else { return String(localized: "Aucun test sur cet iPhone pour l'instant") }
        let speed = result.downloadMbps.formatted(.number.precision(.fractionLength(0)))
        return "\(speed) Mbit/s · \(result.createdAt.formatted(.relative(presentation: .named)))"
    }

    private var approximateLocation: BugReportContext.Location? {
        services.location.cachedLocation().map {
            BugReportContext.Location(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)
        }
    }

    private func success(_ report: BugReport) -> some View {
        VStack(spacing: SQSpace.lg) {
            Spacer(minLength: SQSpace.xl)
            SQIconPastille(systemImage: "checkmark", size: 72, tint: SQColor.success, fill: SQColor.successSoft,
                           font: .system(size: 30, weight: .bold))
            Text("Merci, c'est envoyé")
                .font(SQFont.display(26, .bold, relativeTo: .title))
                .foregroundStyle(SQColor.label)
                .multilineTextAlignment(.center)
                .sqHeader()
            Text("L'équipe te répond ici et par notification. Un bug confirmé te rapporte des points.")
                .font(SQType.callout)
                .foregroundStyle(SQColor.labelSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: SQSpace.xl)
            GradientButton(String(localized: "Voir mon signalement")) {
                onOpen(report)
                dismiss()
            }
            .accessibilityIdentifier("bugs.composer.open")
            GradientButton(String(localized: "Fermer"), style: .secondary) { dismiss() }
                .accessibilityIdentifier("bugs.composer.done")
        }
        .padding(SQSpace.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func processPicked() async {
        let items = pickerItems
        pickerItems = []
        guard !items.isEmpty else { return }
        attachmentError = nil
        for item in items {
            guard images.count < BugReportSubmission.maxImages else { break }
            guard let prepared = await PendingReportImage.prepare(item) else {
                attachmentError = String(localized: "Image illisible.")
                continue
            }
            images.append(prepared)
        }
    }

    private func send() async {
        guard canSend, let device else { return }
        isSending = true
        error = nil
        defer { isSending = false }
        let speedtest = includeSpeedtest ? lastSpeedtest.map {
            BugReportContext.Speedtest(downloadMbps: $0.downloadMbps, uploadMbps: $0.uploadMbps, pingMs: $0.primaryPingMs,
                                       connectionType: $0.connectionType.rawValue, network: $0.networkDisplayName,
                                       measuredAt: ISO8601DateFormatter().string(from: $0.createdAt))
        } : nil
        let submission = BugReportSubmission(
            category: kind == .idea ? .feature : (category ?? .other),
            title: title,
            description: details,
            severity: kind == .bug ? severity : .medium,
            steps: kind == .bug ? steps : nil,
            expectedResult: kind == .bug ? expected : nil,
            images: images.map(\.dataURL),
            device: device,
            speedtest: speedtest,
            location: includeLocation ? approximateLocation : nil
        )
        do {
            let report = try await services.bugReports.submit(submission, submissionID: submissionID)
            Haptics.success()
            onSent(report)
            withAnimation(SQMotion.resolve(SQMotion.snappy, UIAccessibility.isReduceMotionEnabled)) { sent = report }
        } catch {
            if error.isCancellation { return }
            Haptics.error()
            if let apiError = error as? APIError, case .transport = apiError {
                self.error = String(localized: "Pas de connexion. Réessaie quand le réseau revient : ton texte reste ici.")
            } else {
                self.error = error.userFacingMessage
            }
        }
    }
}

// MARK: Page d'un signalement

@MainActor
final class BugReportDetailViewModel: ObservableObject {
    @Published var report: BugReport?
    @Published var comments: [BugComment] = []
    @Published var isLoading = false
    @Published var loadFailed = false
    @Published var errorMessage: String?
    @Published var draft = ""
    @Published var pendingImages: [PendingReportImage] = []
    @Published var pickerItems: [PhotosPickerItem] = []
    @Published var isSending = false
    @Published var isDeleting = false

    let reportId: String
    private let service: BugReportsServicing
    static let maxImages = 3

    init(service: BugReportsServicing, report: BugReport?, reportId: String) {
        self.service = service
        self.report = report
        self.reportId = report?.id ?? reportId
    }

    /// Le serveur exige un texte : une image seule ne part pas.
    var canSend: Bool { !isSending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func load() async {
        isLoading = true
        loadFailed = false
        defer { isLoading = false }
        async let fetchedReport = try? service.report(id: reportId)
        async let fetchedComments = try? service.comments(bugId: reportId)
        if let value = await fetchedReport { report = value }
        if let value = await fetchedComments {
            comments = value.sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
        }
        if Task.isCancelled { return }
        loadFailed = report == nil
    }

    func processPickedItems() async {
        let items = pickerItems
        pickerItems = []
        for item in items where pendingImages.count < Self.maxImages {
            if let prepared = await PendingReportImage.prepare(item) { pendingImages.append(prepared) }
        }
    }

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isSending, !text.isEmpty else { return }
        isSending = true
        errorMessage = nil
        defer { isSending = false }
        do {
            let comment = try await service.addComment(bugId: reportId, content: text, images: pendingImages.map(\.dataURL))
            withAnimation(SQMotion.resolve(SQMotion.bouncy, UIAccessibility.isReduceMotionEnabled)) { comments.append(comment) }
            draft = ""
            pendingImages = []
            Haptics.success()
            // Une réponse rouvre un signalement résolu : le statut affiché suit.
            if report?.status == .resolved, let refreshed = try? await service.report(id: reportId) { report = refreshed }
        } catch {
            errorMessage = String(localized: "Échec de l'envoi. Réessaie.")
            Haptics.error()
        }
    }

    func delete() async -> Bool {
        isDeleting = true
        errorMessage = nil
        defer { isDeleting = false }
        do {
            try await service.delete(bugId: reportId)
            Haptics.success()
            return true
        } catch {
            errorMessage = String(localized: "Suppression impossible. Réessaie.")
            Haptics.error()
            return false
        }
    }
}

/// Un signalement : réponse de l'équipe, description et captures, puis la
/// conversation. Poussée depuis la liste, ou présentée en feuille depuis une
/// notification (`onClose`).
struct BugReportDetailView: View {
    @StateObject private var model: BugReportDetailViewModel
    var onDeleted: ((String) -> Void)?
    var onClose: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var viewerImage: AntennaReportImage?
    @State private var confirmDelete = false

    init(service: BugReportsServicing, report: BugReport? = nil, reportId: String? = nil,
         onClose: (() -> Void)? = nil, onDeleted: ((String) -> Void)? = nil) {
        _model = StateObject(wrappedValue: BugReportDetailViewModel(service: service, report: report,
                                                                    reportId: report?.id ?? reportId ?? ""))
        self.onClose = onClose
        self.onDeleted = onDeleted
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: SQSpace.lg) {
                        topBar
                        if let report = model.report {
                            header(report)
                            if let response = report.adminResponse?.trimmingCharacters(in: .whitespacesAndNewlines),
                               !response.isEmpty {
                                teamReply(response)
                            }
                            if report.status == .resolved, let fix = report.fixVersion, !fix.isEmpty {
                                VStack(spacing: SQSpace.sm2) { SQFactRow(label: "Corrigé dans", value: fix) }
                                    .padding(SQSpace.lg)
                                    .sqCardBackground()
                            }
                            descriptionCard(report)
                            conversation
                        } else if model.isLoading {
                            SQSpinner().tint(SQColor.brandRed).frame(maxWidth: .infinity).padding(.top, SQSpace.xl)
                        } else if model.loadFailed {
                            ErrorStateView(title: "Signalement indisponible",
                                           message: String(localized: "Impossible de charger ce signalement.")) {
                                Task { await model.load() }
                            }
                        }
                    }
                    .padding(.horizontal, SQSpace.lg)
                    .padding(.vertical, SQSpace.sm)
                }
                .onChangeCompat(of: model.comments.count) { _, _ in
                    guard let last = model.comments.last else { return }
                    withAnimation(SQMotion.resolve(SQMotion.snappy, reduceMotion)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.dangerInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, SQSpace.lg)
                    .padding(.vertical, SQSpace.sm)
                    .background(SQColor.dangerSoft)
            }
            if let report = model.report {
                footer(report)
            }
        }
        .sqReadableWidth()
        .signalQuestBackground()
        .navigationTitle(model.report?.title ?? "")
        .toolbar(.hidden, for: .navigationBar)
        .sqKeepsSwipeBack()
        .task { await model.load() }
        .onChangeCompat(of: model.pickerItems) { _, _ in
            Task { await model.processPickedItems() }
        }
        .fullScreenCover(item: $viewerImage) { image in
            AntennaReportImageViewer(image: image)
        }
        .confirmationDialog("Supprimer ce signalement ?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Supprimer", role: .destructive) {
                Task {
                    guard await model.delete() else { return }
                    onDeleted?(model.reportId)
                    close()
                }
            }
        } message: {
            Text("Il disparaît aussi du site, et l'équipe ne pourra plus te répondre.")
        }
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    private var topBar: some View {
        HStack {
            MapChipIconButton(systemImage: onClose == nil ? "chevron.left" : "xmark",
                              label: onClose == nil ? "Retour" : "Fermer", identifier: "bugs.detail.back") { close() }
            Spacer()
            if model.report != nil {
                Menu {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("Supprimer le signalement", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(SQColor.label)
                        .frame(width: 44, height: 44)
                        .sqSurface(SQColor.chip, in: Circle())
                        .contentShape(Circle())
                }
                .disabled(model.isDeleting)
                .accessibilityLabel("Plus d'actions")
                .accessibilityIdentifier("bugs.detail.more")
            }
        }
    }

    private func header(_ report: BugReport) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text(verbatim: report.isIdea ? String(localized: "Idée") : String(localized: "Bug · \(report.category.label)"))
                .sqKicker()
            Text(verbatim: report.title)
                .font(SQFont.display(26, .bold, relativeTo: .title))
                .foregroundStyle(SQColor.label)
                .fixedSize(horizontal: false, vertical: true)
                .sqHeader()
            FlowLayout(spacing: SQSpace.sm) {
                BugStatusPill(status: report.status)
                if !report.isIdea {
                    BugStatusPill(text: report.severity.pillLabel)
                }
            }
            let meta = [report.createdAt?.formatted(.dateTime.day().month(.abbreviated).year()), report.deviceModel,
                        report.appVersion].compactMap { $0 }.filter { !$0.isEmpty }
            if !meta.isEmpty {
                Text(verbatim: meta.joined(separator: " · "))
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }
        }
        .accessibilityIdentifier("bugs.detail.header")
    }

    private func teamReply(_ response: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Réponse de l'équipe", systemImage: "checkmark.seal.fill")
                .font(SQFont.body(12, .semibold, relativeTo: .caption))
                .foregroundStyle(SQColor.accentInk)
            Text(verbatim: response)
                .font(SQType.body)
                .foregroundStyle(SQColor.label)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SQColor.accentSoft, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("bugs.detail.reply")
    }

    private func descriptionCard(_ report: BugReport) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            Text(verbatim: report.description)
                .font(SQType.body)
                .foregroundStyle(SQColor.label)
                .fixedSize(horizontal: false, vertical: true)
            if let steps = report.steps, !steps.isEmpty {
                labelled("Étapes pour reproduire", steps)
            }
            if let expected = report.expectedResult, !expected.isEmpty {
                labelled("Ce que tu attendais", expected)
            }
            let images = report.images.compactMap(AntennaReportImage.parse)
            if !images.isEmpty {
                imageRow(images, side: 74)
            }
        }
        .padding(SQSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sqCardBackground()
    }

    private func labelled(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(SQFont.body(13, .semibold, relativeTo: .subheadline))
                .foregroundStyle(SQColor.labelSecondary)
            Text(verbatim: value)
                .font(SQType.callout)
                .foregroundStyle(SQColor.label)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func imageRow(_ images: [AntennaReportImage], side: CGFloat) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: SQSpace.sm) {
                ForEach(images) { image in
                    Button { viewerImage = image } label: {
                        Group {
                            switch image {
                            case .remote(let url):
                                RemoteImage(url: url, maxDimension: side * 2, contentMode: .fill) { SQColor.surfaceMuted }
                            case .inline(let uiImage):
                                Image(uiImage: uiImage).resizable().scaledToFill()
                            }
                        }
                        .frame(width: side, height: side)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Capture jointe, toucher pour agrandir")
                }
            }
        }
    }

    private var conversation: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            Text("Conversation").sqKicker()
            if model.comments.isEmpty {
                Text("Pas encore de message. L'équipe te répond ici, et tu peux ajouter des précisions.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(model.comments) { comment in
                    bubble(comment).id(comment.id)
                }
            }
        }
    }

    /// Équipe à gauche sur la carte, moi à droite à l'encre.
    private func bubble(_ comment: BugComment) -> some View {
        let isTeam = comment.isAdmin
        return HStack {
            if !isTeam { Spacer(minLength: SQSpace.xxl) }
            VStack(alignment: .leading, spacing: 3) {
                if isTeam {
                    Label("Équipe SignalQuest", systemImage: "checkmark.seal.fill")
                        .font(SQFont.body(11, .bold, relativeTo: .caption2))
                        .foregroundStyle(SQColor.accentInk)
                }
                if !comment.content.isEmpty {
                    Text(verbatim: comment.content)
                        .font(SQType.callout)
                        .foregroundStyle(isTeam ? SQColor.label : SQColor.onInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                let images = comment.images.compactMap(AntennaReportImage.parse)
                if !images.isEmpty { imageRow(images, side: 96) }
                if let date = comment.createdAt {
                    Text(date, format: .dateTime.day().month(.abbreviated).hour().minute())
                        .font(SQFont.body(11, .regular, relativeTo: .caption2))
                        .foregroundStyle(isTeam ? SQColor.labelSecondary : SQColor.onInk)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background {
                if isTeam {
                    UnevenRoundedRectangleCompat(bottomLeading: true)
                        .fill(SQColor.surface)
                        .overlay { UnevenRoundedRectangleCompat(bottomLeading: true).strokeBorder(SQOledPalette.cardStroke, lineWidth: 1) }
                } else {
                    UnevenRoundedRectangleCompat(bottomLeading: false).fill(SQColor.label)
                }
            }
            .accessibilityElement(children: .combine)
            if isTeam { Spacer(minLength: SQSpace.xxl) }
        }
    }

    @ViewBuilder
    private func footer(_ report: BugReport) -> some View {
        if report.status.acceptsReplies {
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                if !model.pendingImages.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: SQSpace.sm) {
                            ForEach(model.pendingImages) { pending in
                                Image(uiImage: pending.image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 56, height: 56)
                                    .clipShape(RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                                    .overlay(alignment: .topTrailing) {
                                        Button { model.pendingImages.removeAll { $0.id == pending.id } } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.system(size: 18))
                                                .foregroundStyle(.white, .black.opacity(0.55))
                                                .frame(width: 44, height: 44, alignment: .topTrailing)
                                                .contentShape(Rectangle())
                                        }
                                        .accessibilityLabel("Retirer la photo")
                                    }
                            }
                        }
                    }
                }
                HStack(spacing: SQSpace.sm2) {
                    PhotosPicker(selection: $model.pickerItems,
                                 maxSelectionCount: BugReportDetailViewModel.maxImages,
                                 matching: .images) {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(SQColor.label)
                            .frame(width: 44, height: 44)
                            .sqSurface(SQColor.chip, in: Circle())
                    }
                    .disabled(model.pendingImages.count >= BugReportDetailViewModel.maxImages)
                    .accessibilityLabel("Ajouter des photos")
                    TextField(report.status == .resolved ? "Le problème revient ? Réponds ici…" : "Écrire une réponse…",
                              text: $model.draft, axis: .vertical)
                        .font(SQType.body)
                        .foregroundStyle(SQColor.label)
                        .lineLimit(1...4)
                        .padding(.horizontal, SQSpace.lg)
                        .padding(.vertical, SQSpace.sm2)
                        .frame(minHeight: 44)
                        .sqFieldSurface(in: RoundedRectangle(cornerRadius: SQRadius.pill, style: .continuous))
                        .accessibilityIdentifier("bugs.detail.reply.field")
                    Button { Task { await model.send() } } label: {
                        Image(systemName: model.isSending ? "ellipsis" : "paperplane.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(SQColor.onInk)
                            .frame(width: 44, height: 44)
                            .background(SQColor.label, in: Circle())
                            .opacity(model.canSend ? 1 : 0.45)
                    }
                    .buttonStyle(SQPressButtonStyle())
                    .disabled(!model.canSend)
                    .accessibilityLabel("Envoyer")
                    .accessibilityIdentifier("bugs.detail.reply.send")
                }
                if report.status == .resolved {
                    Text("Répondre rouvre le signalement.")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .padding(.leading, 44 + SQSpace.sm2)
                }
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.vertical, SQSpace.sm2)
            .background(SQColor.bg)
            .overlay(alignment: .top) { Divider() }
        } else {
            Label("Ce signalement est clos, les réponses sont fermées. Tu peux en ouvrir un nouveau.", systemImage: "lock")
                .font(SQType.callout)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(SQSpace.lg)
                .sqCardBackground()
                .padding(SQSpace.lg)
                .accessibilityIdentifier("bugs.detail.closed")
        }
    }
}

/// Bulle à un coin resserré (celui de l'auteur), compatible iOS 16 :
/// `UnevenRoundedRectangle` n'existe qu'à partir d'iOS 17.
private struct UnevenRoundedRectangleCompat: InsettableShape {
    let bottomLeading: Bool
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let big: CGFloat = 18, small: CGFloat = 6
        let bl = bottomLeading ? small : big, br = bottomLeading ? big : small
        var path = Path()
        path.move(to: CGPoint(x: r.minX + big, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX - big, y: r.minY))
        path.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY + big), radius: big)
        path.addLine(to: CGPoint(x: r.maxX, y: r.maxY - br))
        path.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.maxX - br, y: r.maxY), radius: br)
        path.addLine(to: CGPoint(x: r.minX + bl, y: r.maxY))
        path.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY - bl), radius: bl)
        path.addLine(to: CGPoint(x: r.minX, y: r.minY + big))
        path.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.minX + big, y: r.minY), radius: big)
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> UnevenRoundedRectangleCompat {
        var copy = self
        copy.inset += amount
        return copy
    }
}
