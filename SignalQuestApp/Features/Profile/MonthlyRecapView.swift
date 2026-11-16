import SwiftUI
import UIKit

/// Accès au Bilan mensuel (D20) : rien ne s'affiche tant que le serveur ne sert pas
/// `recap.monthly` dans `benefits.premium`, et seul un compte Premium confirmé par le
/// serveur le lit. Les liens et la notification ouvrent l'écran quoi qu'il en soit :
/// le serveur répond alors 403 et l'écran montre la carte Premium.
enum MonthlyRecapAccess {
    static let benefitKey = "recap.monthly"

    @MainActor
    static func isOffered(_ store: EntitlementsStore) -> Bool {
        if let variant = AppEnvironment.monthlyRecapQAVariant { return variant != "unserved" }
        return store.serverState.snapshot?.benefits?.premium.contains(benefitKey) == true
    }

    @MainActor
    static func isPremium(_ store: EntitlementsStore) -> Bool {
        if let variant = AppEnvironment.monthlyRecapQAVariant { return variant != "free" }
        return store.confirmedServerTier == .premium
    }
}

// MARK: - Modèle de l'écran

@MainActor
final class MonthlyRecapViewModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case loaded(MonthlyRecap)
        case failed(MonthlyRecapError)
    }

    @Published private(set) var months: [MonthlyRecapMonth] = []
    @Published private(set) var month: String?
    @Published private(set) var phase: Phase = .loading
    @Published private(set) var badgeTitles: [String: String] = [:]
    @Published private(set) var preferences: NotificationPreferences?

    let service: MonthlyRecapServicing
    private let initialMonth: String?
    private let loadBadgeTitles: @Sendable () async -> [String: String]
    private let loadPreferences: @Sendable () async -> NotificationPreferences?
    private let savePreferences: @Sendable (NotificationPreferences) async throws -> NotificationPreferences
    private var started = false
    private var loadToken = UUID()

    init(
        initialMonth: String?,
        service: MonthlyRecapServicing,
        loadBadgeTitles: @escaping @Sendable () async -> [String: String],
        loadPreferences: @escaping @Sendable () async -> NotificationPreferences?,
        savePreferences: @escaping @Sendable (NotificationPreferences) async throws -> NotificationPreferences
    ) {
        self.initialMonth = initialMonth.flatMap { MonthlyRecapLink.isMonth($0) ? $0 : nil }
        self.service = service
        self.loadBadgeTitles = loadBadgeTitles
        self.loadPreferences = loadPreferences
        self.savePreferences = savePreferences
    }

    func start() async {
        guard !started else { return }
        started = true
        async let titles = loadBadgeTitles()
        async let preferences = loadPreferences()
        var listError: MonthlyRecapError?
        do {
            months = try await service.months()
        } catch {
            listError = MonthlyRecapError.from(error)
        }
        if listError == .premiumRequired {
            month = initialMonth
            phase = .failed(.premiumRequired)
        } else if let target = initialMonth ?? months.first(where: \.available)?.month ?? months.first?.month {
            await load(target)
        } else {
            phase = .failed(listError ?? .unavailable)
        }
        badgeTitles = await titles
        self.preferences = await preferences
    }

    func select(_ month: String) async {
        guard month != self.month || phase != .loading else { return }
        await load(month)
    }

    func retry() async {
        if let month {
            await load(month)
        } else {
            started = false
            await start()
        }
    }

    private func load(_ month: String) async {
        let token = UUID()
        loadToken = token
        self.month = month
        phase = .loading
        do {
            let recap = try await service.recap(month: month)
            guard loadToken == token else { return }
            phase = .loaded(recap)
        } catch {
            guard loadToken == token else { return }
            phase = .failed(MonthlyRecapError.from(error))
        }
    }

    /// Mois disponible plus ancien que le mois affiché.
    var olderMonth: String? {
        guard let month else { return nil }
        return months.first { $0.available && $0.month < month }?.month
    }

    /// Mois disponible plus récent que le mois affiché.
    var newerMonth: String? {
        guard let month else { return nil }
        return months.last { $0.available && $0.month > month }?.month
    }

    var recap: MonthlyRecap? {
        if case .loaded(let recap) = phase { return recap }
        return nil
    }

    /// Carte E-mail : seulement quand le compte reçoit le Bilan par e-mail.
    var receivesEmail: Bool { preferences?.notifyMonthlyRecapEmail == true }

    /// Retour des réglages ouverts depuis la carte E-mail : la carte suit le nouveau choix.
    func reloadPreferences() async {
        if let fresh = await loadPreferences() { preferences = fresh }
    }

    /// Nom et profil sur l'image : activé par défaut côté serveur.
    var sharesIdentity: Bool { preferences?.recapShareIdentity ?? true }

    /// Enregistre le choix sur le compte ; `false` si le serveur ne l'a pas pris.
    func setSharesIdentity(_ value: Bool) async -> Bool {
        var patch = NotificationPreferences.empty
        patch.recapShareIdentity = value
        do {
            let saved = try await savePreferences(patch)
            var merged = preferences ?? .empty
            merged.recapShareIdentity = saved.recapShareIdentity ?? value
            preferences = merged
            return true
        } catch {
            return false
        }
    }
}

extension MonthlyRecapViewModel {
    static func live(services: AppServices, initialMonth: String?) -> MonthlyRecapViewModel {
        let gamification = services.gamification
        let users = services.users
        return MonthlyRecapViewModel(
            initialMonth: initialMonth,
            service: services.monthlyRecap,
            loadBadgeTitles: {
                let catalog = (try? await gamification.catalog()) ?? []
                return Dictionary(catalog.compactMap { badge in
                    badge.title.flatMap { $0.isEmpty ? nil : (badge.id, $0) }
                }, uniquingKeysWith: { first, _ in first })
            },
            loadPreferences: { try? await users.notificationPreferences() },
            savePreferences: { try await users.updateNotificationPreferences($0) }
        )
    }
}

// MARK: - Écran

/// Bilan mensuel Premium (maquette validée le 16/11) : récit, grands chiffres, cartes,
/// jours actifs, comparaison avec le mois précédent, et l'image de partage du serveur.
struct MonthlyRecapView: View {
    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var model: MonthlyRecapViewModel
    @State private var showsShare = false
    @State private var showsPaywall = false
    @State private var showsNotificationSettings = false

    init(model: @autoclosure @escaping () -> MonthlyRecapViewModel) {
        _model = StateObject(wrappedValue: model())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.xl) {
                header
                monthPicker
                content
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.sm)
            .padding(.bottom, SQDock.floatingContentInset)
            .sqReadableWidth()
        }
        .toolbar(.hidden, for: .navigationBar)
        .sqKeepsSwipeBack()
        .signalQuestBackground()
        .navigationTitle("Bilan")
        .task {
            await model.start()
            if AppEnvironment.monthlyRecapQAVariant == "share", model.recap != nil { showsShare = true }
        }
        .refreshable { await model.retry() }
        .sheet(isPresented: $showsShare) {
            if let month = model.month {
                MonthlyRecapShareSheet(month: month, model: model)
            }
        }
        .sheet(isPresented: $showsPaywall) {
            NavigationStack {
                PaywallView(store: services.entitlements, entryPoint: .premiumFeature(String(localized: "Bilan mensuel")))
            }
            .presentationDetents([.large])
        }
        .sheet(isPresented: $showsNotificationSettings, onDismiss: { Task { await model.reloadPreferences() } }) {
            NavigationStack {
                NotificationSettingsView(userService: services.users)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("OK") { showsNotificationSettings = false }
                        }
                    }
            }
        }
    }

    // MARK: En-tête

    private var header: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            HStack {
                MapChipIconButton(systemImage: "chevron.left", label: "Retour", identifier: "recap.back") { dismiss() }
                Spacer()
                if model.recap != nil {
                    MapChipIconButton(systemImage: "square.and.arrow.up", label: "Partager l’image",
                                      identifier: "recap.share") { showsShare = true }
                }
            }
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                Text("Bilan mensuel")
                    .sqKicker()
                    .foregroundStyle(SQColor.labelSecondary)
                if let month = model.month {
                    Text(verbatim: MonthlyRecapPresentation.title(for: month))
                        .font(SQFont.display(26, .bold, relativeTo: .largeTitle))
                        .foregroundStyle(SQColor.label)
                        .fixedSize(horizontal: false, vertical: true)
                        .sqHeader()
                        .accessibilityIdentifier("recap.title")
                }
                if let recap = model.recap {
                    let subtitle = presentation(recap).subtitle
                    if !subtitle.isEmpty {
                        Text(verbatim: subtitle)
                            .font(SQType.callout)
                            .foregroundStyle(SQColor.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Choix du mois

    @ViewBuilder
    private var monthPicker: some View {
        if let month = model.month, model.phase != .failed(.premiumRequired) {
            HStack(spacing: SQSpace.sm) {
                arrowButton(older: true, target: model.olderMonth, identifier: "recap.month.previous")
                Spacer(minLength: 0)
                monthMenu(month)
                Spacer(minLength: 0)
                arrowButton(older: false, target: model.newerMonth, identifier: "recap.month.next")
            }
        }
    }

    private func arrowButton(older: Bool, target: String?, identifier: String) -> some View {
        Button {
            guard let target else { return }
            Haptics.selection()
            Task { await model.select(target) }
        } label: {
            Image(systemName: older ? "chevron.left" : "chevron.right")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(target == nil ? SQColor.labelTertiary : SQColor.accentInk)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(target == nil)
        .accessibilityLabel(Text(verbatim: arrowLabel(older: older, target: target)))
        .accessibilityIdentifier(identifier)
    }

    private func arrowLabel(older: Bool, target: String?) -> String {
        guard let target else {
            return older ? String(localized: "Mois précédent") : String(localized: "Mois suivant")
        }
        let name = MonthlyRecapPresentation.monthYear(target)
        return older ? String(localized: "Mois précédent : \(name)") : String(localized: "Mois suivant : \(name)")
    }

    @ViewBuilder
    private func monthMenu(_ month: String) -> some View {
        let label = HStack(spacing: SQSpace.xs2) {
            Text(verbatim: MonthlyRecapPresentation.monthYear(month))
                .font(SQFont.body(15, .bold, relativeTo: .body))
            if !model.months.isEmpty {
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .bold))
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(SQColor.accentInk)
        .padding(.horizontal, SQSpace.lg)
        .frame(minHeight: 44)
        .background(SQColor.accentSoft, in: Capsule())

        if model.months.isEmpty {
            label
        } else {
            Menu {
                ForEach(model.months, id: \.month) { item in
                    Button {
                        Task { await model.select(item.month) }
                    } label: {
                        if item.available {
                            Text(verbatim: MonthlyRecapPresentation.monthYear(item.month))
                        } else {
                            Text(verbatim: MonthlyRecapPresentation.monthYear(item.month) + " · " + String(localized: "Sans activité"))
                        }
                    }
                    .disabled(!item.available)
                }
            } label: {
                label
            }
            .accessibilityLabel(Text(verbatim: String(localized: "Choisir un mois, \(MonthlyRecapPresentation.monthYear(month))")))
            .accessibilityIdentifier("recap.month.menu")
        }
    }

    // MARK: Contenu

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            skeleton
        case .failed(.premiumRequired):
            MonthlyRecapFreeCard { showsPaywall = true }
        case .failed(let error):
            stateCard(error)
        case .loaded(let recap):
            loaded(presentation(recap))
        }
    }

    private func presentation(_ recap: MonthlyRecap) -> MonthlyRecapPresentation {
        MonthlyRecapPresentation(recap: recap, badgeTitles: model.badgeTitles)
    }

    private var skeleton: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            ForEach([0.92, 0.78, 0.6], id: \.self) { width in
                RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous)
                    .fill(SQColor.skeleton)
                    .frame(height: 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .scaleEffect(x: width, y: 1, anchor: .leading)
            }
            RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
                .fill(SQColor.skeleton)
                .frame(height: 96)
        }
        .padding(SQSpace.xl)
        .sqCardBackground()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Chargement"))
    }

    private func stateCard(_ error: MonthlyRecapError) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            if let message = MonthlyRecapPresentation.message(for: error, month: model.month) {
                Text(verbatim: message)
                    .font(SQType.body)
                    .foregroundStyle(SQColor.label)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("recap.state.message")
            }
            if error == .unavailable {
                GradientButton("Réessayer", systemImage: "arrow.clockwise", style: .secondary) {
                    Task { await model.retry() }
                }
                .accessibilityIdentifier("recap.retry")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(SQSpace.lg)
        .sqCardBackground()
    }

    @ViewBuilder
    private func loaded(_ presentation: MonthlyRecapPresentation) -> some View {
        let sentences = presentation.storySentences
        let figures = presentation.figures
        if !sentences.isEmpty || !figures.isEmpty {
            storyCard(sentences: sentences, figures: figures)
        }
        ForEach(presentation.sections) { section in
            sectionView(section)
        }
        if presentation.activeDayCount > 0 {
            activeDays(presentation)
        }
        if let comparison = presentation.comparison {
            sectionView(comparison)
        }
        if model.receivesEmail {
            emailCard
        }
    }

    private func storyCard(sentences: [String], figures: [MonthlyRecapPresentation.Figure]) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.xl) {
            if !sentences.isEmpty {
                Text(verbatim: sentences.joined(separator: " "))
                    .font(SQFont.body(17, .semibold, relativeTo: .body))
                    .foregroundStyle(SQColor.label)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("recap.story")
            }
            if !figures.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: SQSpace.md, alignment: .topLeading),
                                         count: dynamicTypeSize.isAccessibilitySize ? 1 : 2),
                          alignment: .leading, spacing: SQSpace.lg) {
                    ForEach(figures, id: \.self) { figure in
                        VStack(alignment: .leading, spacing: SQSpace.xxs) {
                            Text(verbatim: figure.value)
                                .font(SQFont.display(28, .heavy, relativeTo: .title))
                                .monospacedDigit()
                                .foregroundStyle(SQColor.label)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            Text(verbatim: figure.label)
                                .font(SQType.subhead(.regular))
                                .foregroundStyle(SQColor.labelSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .padding(SQSpace.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sqCardBackground()
    }

    private func sectionView(_ section: MonthlyRecapPresentation.Section) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text(verbatim: section.title)
                .font(SQFont.display(17, .bold, relativeTo: .headline))
                .foregroundStyle(SQColor.label)
                .padding(.horizontal, SQSpace.xs)
                .sqHeader()
            VStack(spacing: 0) {
                ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 {
                        Rectangle().fill(SQColor.separator).frame(height: 1)
                    }
                    MonthlyRecapRowView(row: row)
                }
            }
            .padding(.horizontal, SQSpace.lg)
            .sqCardBackground()
            if let note = section.note {
                Text(verbatim: note)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, SQSpace.xs)
            }
        }
        .accessibilityIdentifier("recap.section.\(section.id)")
    }

    private func activeDays(_ presentation: MonthlyRecapPresentation) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: SQSpace.xs2), count: 7)
        return VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Tes jours actifs")
                .font(SQFont.display(17, .bold, relativeTo: .headline))
                .foregroundStyle(SQColor.label)
                .padding(.horizontal, SQSpace.xs)
                .sqHeader()
            VStack(alignment: .leading, spacing: SQSpace.md) {
                VStack(spacing: SQSpace.xs2) {
                    LazyVGrid(columns: columns, spacing: SQSpace.xs2) {
                        ForEach(Array(presentation.weekdayLetters.enumerated()), id: \.offset) { _, letter in
                            Text(verbatim: letter)
                                .font(SQType.micro)
                                .foregroundStyle(SQColor.labelSecondary)
                        }
                    }
                    LazyVGrid(columns: columns, spacing: SQSpace.xs2) {
                        ForEach(Array(presentation.activeDayGrid.enumerated()), id: \.offset) { _, cell in
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(dayFill(cell))
                                .aspectRatio(1, contentMode: .fit)
                        }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: presentation.activeDaysAccessibilityLabel))
                Text(verbatim: presentation.activeDaysCaption)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(SQSpace.lg)
            .sqCardBackground()
        }
        .accessibilityIdentifier("recap.section.activeDays")
    }

    private func dayFill(_ cell: MonthlyRecapPresentation.DayCell) -> Color {
        guard cell.day != nil else { return .clear }
        switch cell.intensity {
        case 1: return SQColor.label.opacity(0.24)
        case 2: return SQColor.label.opacity(0.52)
        case 3: return SQColor.label
        default: return SQColor.chip
        }
    }

    private var emailCard: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("E-mail")
                .font(SQFont.display(17, .bold, relativeTo: .headline))
                .foregroundStyle(SQColor.label)
                .padding(.horizontal, SQSpace.xs)
                .sqHeader()
            VStack(alignment: .leading, spacing: SQSpace.xxs) {
                Text("Tu reçois ce bilan par e-mail le 1er de chaque mois.")
                    .font(SQType.body)
                    .foregroundStyle(SQColor.label)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Gérer dans les réglages") { showsNotificationSettings = true }
                    .font(SQFont.body(15, .bold, relativeTo: .body))
                    .foregroundStyle(SQColor.accentInk)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("recap.email.settings")
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.md2)
            .padding(.bottom, SQSpace.xs2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .sqCardBackground()
        }
    }
}

/// Une ligne d'une carte du Bilan : libellé à gauche, valeur à droite, détail dessous.
private struct MonthlyRecapRowView: View {
    let row: MonthlyRecapPresentation.Row
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: SQSpace.xxs) {
                    label
                    values(alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: SQSpace.md) {
                    label
                    Spacer(minLength: SQSpace.md)
                    values(alignment: .trailing)
                }
            }
        }
        .padding(.vertical, SQSpace.md)
        .frame(minHeight: 48)
        .accessibilityElement(children: .combine)
    }

    private var label: some View {
        Text(verbatim: row.label)
            .font(SQFont.body(15, .medium, relativeTo: .body))
            .foregroundStyle(SQColor.label)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func values(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: SQSpace.xxs) {
            HStack(spacing: SQSpace.xs2) {
                if let key = row.operatorKey, row.detail == nil || row.id == "topNetwork" {
                    operatorMark(key)
                }
                Text(verbatim: row.value)
                    .font(SQFont.body(15, .bold, relativeTo: .body))
                    .monospacedDigit()
                    .foregroundStyle(SQColor.label)
                    .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
            }
            if let detail = row.detail {
                HStack(spacing: SQSpace.xs2) {
                    if let key = row.operatorKey, row.id != "topNetwork" {
                        operatorMark(key)
                    }
                    Text(verbatim: detail)
                        .font(SQFont.body(13, .medium, relativeTo: .footnote))
                        .foregroundStyle(SQColor.labelSecondary)
                        .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
                }
            }
        }
    }

    private func operatorMark(_ key: String) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .strokeBorder(SQBrand.operatorColors(key).solid, lineWidth: 2)
            .frame(width: 10, height: 10)
            .accessibilityHidden(true)
    }
}

// MARK: - Partage

/// Feuille « Partager l'image » : l'image 1080 × 1350 rendue par le serveur, toujours en
/// clair et sans aucun lieu, et le choix « Afficher mon nom et mon profil », retenu sur le
/// compte. « Partager » ouvre le partage de l'iPhone avec l'image seule.
struct MonthlyRecapShareSheet: View {
    let month: String
    @ObservedObject var model: MonthlyRecapViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showsIdentity = true
    @State private var images: [Bool: Data] = [:]
    @State private var failed = false
    @State private var savingFailed = false
    @State private var shareFile: ShareFile?

    private struct ShareFile: Identifiable {
        let url: URL
        var id: URL { url }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: SQSpace.lg) {
                    preview
                    VStack(alignment: .leading, spacing: SQSpace.sm) {
                        Toggle(isOn: Binding(get: { showsIdentity }, set: { setIdentity($0) })) {
                            Text("Afficher mon nom et mon profil")
                                .font(SQFont.body(15, .semibold, relativeTo: .body))
                                .foregroundStyle(SQColor.label)
                        }
                        .tint(SQColor.brandRed)
                        .frame(minHeight: 56)
                        .padding(.horizontal, SQSpace.lg)
                        .sqCardBackground()
                        .accessibilityIdentifier("recap.share.identity")
                        Text("Coupé, l’image perd ton nom, ton badge Premium, l’adresse de ton profil et ta bannière. Ton choix est retenu sur ton compte.")
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, SQSpace.xs)
                        if savingFailed {
                            SQInlineError(message: String(localized: "Ton choix n’a pas pu être enregistré. Réessaie."))
                        }
                    }
                    GradientButton("Partager", systemImage: "square.and.arrow.up") { share() }
                        .disabled(images[showsIdentity] == nil)
                        .accessibilityIdentifier("recap.share.send")
                }
                .padding(.horizontal, SQSpace.lg)
                .padding(.vertical, SQSpace.md)
                .sqReadableWidth(560)
            }
            .signalQuestBackground()
            .navigationTitle("Partager l’image")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .task {
            showsIdentity = model.sharesIdentity
            await loadImage()
        }
        .sheet(item: $shareFile) { file in
            ShareSheet(items: [file.url])
        }
    }

    @ViewBuilder
    private var preview: some View {
        let frame = RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
        Group {
            if let data = images[showsIdentity], let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .accessibilityLabel(Text("Aperçu de l’image du bilan"))
            } else if failed {
                VStack(spacing: SQSpace.md) {
                    Text("L’image n’a pas pu être préparée.")
                        .font(SQType.callout)
                        .foregroundStyle(SQColor.label)
                        .multilineTextAlignment(.center)
                    Button("Réessayer") { Task { await loadImage() } }
                        .font(SQFont.body(15, .bold, relativeTo: .body))
                        .foregroundStyle(SQColor.accentInk)
                        .frame(minHeight: 44)
                }
                .padding(SQSpace.lg)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(SQColor.chip)
            } else {
                SQColor.skeleton
                    .overlay(ProgressView())
                    .accessibilityLabel(Text("Chargement"))
            }
        }
        .aspectRatio(1080.0 / 1350.0, contentMode: .fit)
        .frame(maxWidth: 264)
        .clipShape(frame)
        .overlay(frame.strokeBorder(SQColor.separator, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
        .frame(maxWidth: .infinity)
    }

    private var options: MonthlyRecapImageOptions {
        MonthlyRecapImageOptions(
            language: AccountLocaleSync.appLocale,
            formal: SQAddress.appIsFrench && SQAddress.isFormal,
            imperial: SQUnits.current == .imperial,
            showIdentity: showsIdentity
        )
    }

    private func loadImage() async {
        let identity = showsIdentity
        guard images[identity] == nil else { return }
        failed = false
        do {
            let data = try await model.service.image(month: month, options: options)
            guard UIImage(data: data) != nil else { throw MonthlyRecapError.unavailable }
            images[identity] = data
        } catch {
            if identity == showsIdentity { failed = true }
        }
    }

    private func setIdentity(_ value: Bool) {
        let previous = showsIdentity
        showsIdentity = value
        savingFailed = false
        Haptics.selection()
        Task {
            await loadImage()
            if await !model.setSharesIdentity(value), showsIdentity == value {
                showsIdentity = previous
                savingFailed = true
            }
        }
    }

    private func share() {
        guard let data = images[showsIdentity] else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SignalQuest-\(month).png")
        do {
            try data.write(to: url, options: [.atomic])
            shareFile = ShareFile(url: url)
        } catch {
            failed = true
        }
    }
}

// MARK: - Entrées du Profil

/// Entrée du Bilan dans le Profil : rangée sous les tuiles pour un compte Premium (le
/// dernier mois clos qui a un Bilan), carte « Ton mois, raconté » pour un compte gratuit,
/// rien tant que l'avantage n'est pas servi.
enum MonthlyRecapEntryState: Equatable {
    case hidden
    case free
    case premium(latestMonth: String)
}

/// Lit l'accès et la liste des mois ; posé en fond pour que son `task` tourne même sans entrée.
struct MonthlyRecapEntryLoader: View {
    @ObservedObject var store: EntitlementsStore
    let service: MonthlyRecapServicing
    @Binding var state: MonthlyRecapEntryState

    var body: some View {
        Color.clear
            .accessibilityHidden(true)
            .task(id: key) { await load() }
    }

    private var key: String {
        "\(MonthlyRecapAccess.isOffered(store))-\(MonthlyRecapAccess.isPremium(store))"
    }

    private func load() async {
        guard MonthlyRecapAccess.isOffered(store) else {
            state = .hidden
            return
        }
        guard MonthlyRecapAccess.isPremium(store) else {
            state = .free
            return
        }
        if AppEnvironment.monthlyRecapQAVariant != nil {
            state = .premium(latestMonth: "2026-10")
            return
        }
        do {
            let months = try await service.months()
            state = months.first(where: \.available).map { .premium(latestMonth: $0.month) } ?? .hidden
        } catch MonthlyRecapError.premiumRequired {
            state = .free
        } catch {
            // Hors ligne : l'entrée déjà montrée reste.
        }
    }
}

struct MonthlyRecapProfileRow: View {
    let month: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: SQSpace.md) {
                ProfileMenuIcon(systemImage: "calendar", tint: SQColor.accentInk, fill: SQColor.accentSoft)
                VStack(alignment: .leading, spacing: SQSpace.xxs) {
                    Text("Bilan mensuel")
                        .font(SQFont.body(15, .bold, relativeTo: .subheadline))
                        .foregroundStyle(SQColor.label)
                    Text(verbatim: MonthlyRecapPresentation.monthYear(month))
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.ink2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(SQColor.labelTertiary)
                    .accessibilityHidden(true)
            }
            .padding(SQSpace.md)
            .frame(minHeight: 44)
            .sqCardBackground(cornerRadius: SQRadius.lg)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Bilan mensuel"))
        .accessibilityValue(Text(verbatim: MonthlyRecapPresentation.monthYear(month)))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("profile.recap")
    }
}

/// « Ton mois, raconté » : l'offre, pour un compte gratuit ou un Premium terminé.
struct MonthlyRecapFreeCard: View {
    let discover: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm2) {
            HStack(spacing: SQSpace.sm) {
                Text("Ton mois, raconté")
                    .font(SQFont.display(16, .heavy, relativeTo: .headline))
                    .foregroundStyle(SQColor.label)
                    .fixedSize(horizontal: false, vertical: true)
                    .sqHeader()
                Text("Premium")
                    .font(SQType.chip)
                    .foregroundStyle(SQColor.accentInk)
                    .padding(.horizontal, SQSpace.sm)
                    .padding(.vertical, 3)
                    .background(SQColor.accentSoft, in: Capsule())
            }
            Text("Chaque 1er du mois, un bilan de tes mesures et de tes contributions, à lire, à recevoir par e-mail et à partager.")
                .font(SQType.callout)
                .foregroundStyle(SQColor.label)
                .fixedSize(horizontal: false, vertical: true)
            GradientButton("Découvrir Premium", action: discover)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityIdentifier("recap.discoverPremium")
        }
        .padding(SQSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sqCardBackground()
        .accessibilityIdentifier("recap.freeCard")
    }
}
