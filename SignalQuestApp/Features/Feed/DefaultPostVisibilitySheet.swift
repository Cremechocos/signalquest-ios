import SwiftUI

/// Choix de l'audience par défaut des nouveaux posts (PRIVACY-DPV v1).
///
/// - `.firstChoice` : la page du fil, ouverte seulement quand le serveur dit
///   « à demander » (§6). Rien n'est présélectionné ; la croix enregistre
///   « Privé » en un seul geste, et le glissement vers le bas est bloqué.
/// - `.settings` : depuis Réglages › Confidentialité ou le composer, avec le
///   réglage actuel présélectionné ; la croix ne fait que fermer.
///
/// Dans les deux cas, la case « Appliquer aussi… » est décochée à chaque
/// ouverture (§7) et rien n'est gardé localement tant que le serveur n'a pas
/// accepté.
struct DefaultPostVisibilitySheet: View {
    enum Mode: Equatable {
        case firstChoice
        case settings(current: DefaultPostVisibility)
    }

    let mode: Mode
    var onSaved: (DefaultPostVisibility) -> Void = { _ in }
    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    @State private var selection: DefaultPostVisibility?
    @State private var applyToExistingPosts = Self.applyToExistingPostsByDefault
    @State private var isSaving = false
    @State private var errorMessage: String?
    /// Compte présent à l'ouverture : une réponse arrivée après un changement de
    /// compte n'enregistre rien.
    @State private var owner = LocalAccountScope.sessionSnapshot()

    /// Décochée par défaut, et à chaque ouverture (§7).
    static let applyToExistingPostsByDefault = false

    init(mode: Mode, onSaved: @escaping (DefaultPostVisibility) -> Void = { _ in }) {
        self.mode = mode
        self.onSaved = onSaved
        if case .settings(let current) = mode { _selection = State(initialValue: current) }
    }

    private var isFirstChoice: Bool { mode == .firstChoice }

    private var canValidate: Bool {
        guard let selection, !isSaving else { return false }
        if case .settings(let current) = mode {
            return selection != current || showsApplyOption && applyToExistingPosts
        }
        return true
    }

    private var showsApplyOption: Bool { selection?.allowsApplyingToExistingPosts ?? true }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SQSpace.lg) {
                    VStack(alignment: .leading, spacing: SQSpace.sm) {
                        // Deux `Text` : un ternaire de littéraux donnerait une `String`, jamais traduite.
                        (isFirstChoice ? Text("Qui voit tes prochaines publications ?") : Text("Audience par défaut"))
                            .font(isFirstChoice ? SQType.display : SQType.title)
                            .foregroundStyle(SQColor.label)
                            .accessibilityAddTraits(.isHeader)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Ce choix s’applique à tes nouvelles publications : celles que tu écris et celles que SignalQuest crée pour toi, comme tes speedtests ou tes badges.")
                            .font(SQType.body)
                            .foregroundStyle(SQColor.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(spacing: SQSpace.sm) {
                        ForEach(DefaultPostVisibility.allCases) { value in
                            option(value)
                        }
                    }

                    if showsApplyOption {
                        Toggle(isOn: $applyToExistingPosts) {
                            Text("Appliquer aussi à mes publications déjà en ligne")
                                .font(SQType.body)
                                .foregroundStyle(SQColor.label)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .toggleStyle(SQCheckboxToggleStyle())
                        .disabled(isSaving)
                        .accessibilityIdentifier("dpv.applyExisting")
                    }

                    VStack(alignment: .leading, spacing: SQSpace.sm) {
                        note(DefaultPostVisibilityText.text("note.privateZone"), systemImage: "location.slash")
                        note((selection ?? .friends).existingPostsNote(applying: showsApplyOption && applyToExistingPosts),
                             systemImage: "clock.arrow.circlepath")
                            .accessibilityIdentifier("dpv.existingNote")
                    }

                    if let errorMessage {
                        SQNotice(message: errorMessage, systemImage: "exclamationmark.triangle", tone: .danger)
                            .accessibilityIdentifier("dpv.error")
                    }

                    if isFirstChoice {
                        // Toujours visible : la fermeture tient en un seul geste, sans
                        // boîte de confirmation (§6).
                        Text(verbatim: DefaultPostVisibilityText.text("choice.closeNote"))
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("dpv.closeNote")
                    }

                    GradientButton(String(localized: "Valider"), style: .accent) {
                        guard let selection else { return }
                        Task { await save(selection, applying: showsApplyOption && applyToExistingPosts) }
                    }
                    .disabled(!canValidate)
                    .overlay { if isSaving { SQSpinner() } }
                    .accessibilityIdentifier("dpv.validate")
                }
                .padding(.horizontal, SQSpace.xl)
                .padding(.vertical, SQSpace.lg)
                .sqReadableWidth()
            }
            .background(SQColor.bg.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { close() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .disabled(isSaving)
                    .accessibilityLabel(isFirstChoice ? Text("Fermer sans choisir") : Text("Fermer"))
                    .accessibilityIdentifier("dpv.close")
                }
            }
        }
        .interactiveDismissDisabled(isFirstChoice || isSaving)
    }

    private func option(_ value: DefaultPostVisibility) -> some View {
        let isSelected = selection == value
        return Button {
            selection = value
            errorMessage = nil
        } label: {
            HStack(alignment: .top, spacing: SQSpace.md) {
                Image(systemName: value.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isSelected ? SQColor.onAccent : SQColor.accentInk)
                    .frame(width: 34, height: 34)
                    .background(isSelected ? SQColor.brandRed : SQColor.accentSoft,
                                in: RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous))
                VStack(alignment: .leading, spacing: SQSpace.xxs) {
                    Text(verbatim: value.label)
                        .font(SQFont.body(17, .semibold, relativeTo: .body))
                        .foregroundStyle(SQColor.label)
                    Text(value.choiceDetail)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(isSelected ? SQColor.brandRed : SQColor.labelTertiary)
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(SQSpace.md)
            .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous)
                .strokeBorder(isSelected ? SQColor.brandRed : .clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isSaving)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: value.label))
        .accessibilityValue(Text(value.choiceDetail))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("dpv.option.\(value.rawValue)")
    }

    private func note(_ text: String, systemImage: String) -> some View {
        Label {
            Text(verbatim: text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage).accessibilityHidden(true)
        }
        .font(SQType.caption)
        .foregroundStyle(SQColor.labelSecondary)
    }

    private func close() {
        // Fermer la page de choix vaut « Privé » : exactement ce corps, sans la case
        // (§6). Un échec n'écrit rien : la page reviendra au prochain lancement.
        guard isFirstChoice else { dismiss(); return }
        Task {
            await save(.privateOnly, applying: false, dismissOnFailure: true)
        }
    }

    private func save(_ value: DefaultPostVisibility, applying: Bool, dismissOnFailure: Bool = false) async {
        guard let owner, LocalAccountScope.sessionSnapshot() == owner else { dismiss(); return }
        isSaving = true; errorMessage = nil
        defer { isSaving = false }
        do {
            _ = try await services.privacy.scoped(to: owner)
                .setDefaultPostVisibility(value, applyToExistingPosts: applying)
            guard LocalAccountScope.sessionSnapshot() == owner else { dismiss(); return }
            Haptics.success()
            onSaved(value)
            dismiss()
        } catch {
            guard !error.isCancellation else { return }
            if dismissOnFailure { dismiss(); return }
            // La page reste ouverte avec le choix et la case : le membre renvoie
            // lui-même, jamais de relance automatique (§7).
            errorMessage = DefaultPostVisibilityText.failureMessage(error)
            Haptics.error()
        }
    }
}

extension DefaultPostVisibility {
    /// Ce que chaque choix veut dire, sous son nom.
    var choiceDetail: String {
        switch self {
        case .auto: String(localized: "Selon le type : sites, photos et pannes en public, le reste pour tes amis.")
        case .publicWorld: String(localized: "Tout le monde peut les voir.")
        case .friends: String(localized: "Seulement tes amis.")
        case .privateOnly: String(localized: "Toi seul.")
        }
    }
}

/// Case à cocher : un interrupteur dirait « activé », alors que c'est une
/// action ponctuelle qui accompagne la validation.
private struct SQCheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(alignment: .top, spacing: SQSpace.sm) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 22))
                    .foregroundStyle(configuration.isOn ? SQColor.brandRed : SQColor.labelTertiary)
                configuration.label
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(configuration.isOn ? [.isButton, .isSelected] : .isButton)
    }
}
