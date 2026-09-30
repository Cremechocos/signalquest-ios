import SwiftUI

/// Actions du clavier de l'iPad (menu « Actions ») et de la palette ⌘K (plan 3,
/// vague 1). Elles passent par le routeur de la fenêtre au premier plan, comme
/// les raccourcis ⌘1…⌘5 des onglets.
enum SQKeyboardAction: String, CaseIterable, Identifiable {
    case runTest, driveTest, newMessage, newPost, searchMap
    case home, map, speed, community, profile

    var id: String { rawValue }

    /// Celles du menu « Actions » ; les onglets ont déjà leur menu « Aller à ».
    static let menu: [SQKeyboardAction] = [.runTest, .driveTest, .newMessage, .newPost, .searchMap]

    var title: String {
        switch self {
        case .runTest: return String(localized: "Lancer un test")
        case .driveTest: return String(localized: "Drive Test")
        case .newMessage: return String(localized: "Nouveau message")
        case .newPost: return String(localized: "Nouvelle publication")
        case .searchMap: return String(localized: "Rechercher sur la carte")
        case .home: return String(localized: "Accueil")
        case .map: return String(localized: "Carte")
        case .speed: return String(localized: "Tester")
        case .community: return String(localized: "Communauté")
        case .profile: return String(localized: "Profil")
        }
    }

    var symbol: String {
        switch self {
        case .runTest: return "speedometer"
        case .driveTest: return "location.north.line.fill"
        case .newMessage: return "square.and.pencil"
        case .newPost: return "plus.bubble"
        case .searchMap: return "magnifyingglass"
        case .home: return "house"
        case .map: return "map"
        case .speed: return "gauge.with.dots.needle.67percent"
        case .community: return "person.2"
        case .profile: return "person.crop.circle"
        }
    }

    var shortcut: KeyboardShortcut {
        switch self {
        case .runTest: return KeyboardShortcut("r", modifiers: .command)
        case .driveTest: return KeyboardShortcut("d", modifiers: [.command, .shift])
        case .newMessage: return KeyboardShortcut("n", modifiers: .command)
        case .newPost: return KeyboardShortcut("n", modifiers: [.command, .shift])
        case .searchMap: return KeyboardShortcut("f", modifiers: .command)
        case .home: return KeyboardShortcut("1", modifiers: .command)
        case .map: return KeyboardShortcut("2", modifiers: .command)
        case .speed: return KeyboardShortcut("3", modifiers: .command)
        case .community: return KeyboardShortcut("4", modifiers: .command)
        case .profile: return KeyboardShortcut("5", modifiers: .command)
        }
    }

    @MainActor
    func perform(on router: AppRouter) {
        switch self {
        case .runTest: router.requestSpeedtestStart()
        case .driveTest: router.requestDriveTest()
        case .newMessage:
            router.route(toConversation: nil)
            router.openNewConversation = true
        case .newPost:
            router.selectedTab = .community
            router.openPostComposer = true
        case .searchMap:
            router.selectedTab = .map
            router.focusMapSearch = true
        case .home: router.selectedTab = .home
        case .map: router.selectedTab = .map
        case .speed: router.selectedTab = .speed
        case .community: router.selectedTab = .community
        case .profile: router.selectedTab = .profile
        }
    }

    /// Filtre de la palette : sur le titre dans la langue de l'app, sans tenir
    /// compte des accents ni de la casse.
    static func matching(_ query: String) -> [SQKeyboardAction] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return allCases }
        return allCases.filter { $0.title.localizedStandardContains(trimmed) }
    }
}

/// Palette ⌘K : on tape quelques lettres, Entrée lance la première action.
struct SQCommandPalette: View {
    let onChoose: (SQKeyboardAction) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var fieldFocused: Bool

    private var matches: [SQKeyboardAction] { SQKeyboardAction.matching(query) }

    var body: some View {
        NavigationStack {
            List {
                if matches.isEmpty {
                    Text("Aucune action")
                        .foregroundStyle(SQColor.labelSecondary)
                } else {
                    ForEach(matches) { action in
                        Button { onChoose(action) } label: {
                            HStack(spacing: SQSpace.md) {
                                Label(action.title, systemImage: action.symbol)
                                    .foregroundStyle(SQColor.label)
                                Spacer(minLength: SQSpace.sm)
                                Text(verbatim: Self.hint(action.shortcut))
                                    .font(SQType.caption)
                                    .foregroundStyle(SQColor.labelSecondary)
                                    .accessibilityHidden(true)
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .accessibilityIdentifier("palette.action.\(action.rawValue)")
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                // Champ nu plutôt que `SQSearchField` : le focus doit s'y poser
                // à l'ouverture, pour taper sans toucher l'écran.
                HStack(spacing: SQSpace.sm) {
                    Image(systemName: "magnifyingglass")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(SQColor.labelSecondary)
                        .accessibilityHidden(true)
                    TextField("Rechercher une action", text: $query)
                        .font(SQType.body)
                        .foregroundStyle(SQColor.label)
                        .focused($fieldFocused)
                        .submitLabel(.go)
                        .autocorrectionDisabled()
                        .onSubmit { if let first = matches.first { onChoose(first) } }
                        .accessibilityIdentifier("palette.field")
                }
                .padding(.horizontal, SQSpace.lg)
                .frame(minHeight: 44)
                .background(SQColor.surfaceMuted, in: Capsule(style: .continuous))
                .padding(.horizontal, SQSpace.lg)
                .padding(.vertical, SQSpace.sm)
                .background(SQColor.bg)
            }
            .navigationTitle("Actions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .onAppear { fieldFocused = true }
    }

    /// « ⌘⇧N » : les symboles que l'iPad affiche dans ses propres menus.
    static func hint(_ shortcut: KeyboardShortcut) -> String {
        var text = ""
        if shortcut.modifiers.contains(.control) { text += "⌃" }
        if shortcut.modifiers.contains(.option) { text += "⌥" }
        if shortcut.modifiers.contains(.shift) { text += "⇧" }
        if shortcut.modifiers.contains(.command) { text += "⌘" }
        return text + String(shortcut.key.character).uppercased()
    }
}
