import SwiftUI
import UniformTypeIdentifiers

/// Fenêtre des codes de secours (contrat 2FA r3.3, §4 et §8), montrée une seule fois, à
/// l'activation ou à la régénération. Elle se ferme librement ; sans « J'ai noté mes codes », la
/// rubrique Sécurité invite à en refaire (règle A, repère tenu par l'appelant).
struct TwoFactorBackupCodesPanel: View {
    let batch: TwoFactorBackupCodeBatch
    let onSaved: () -> Void
    @State private var copiedChangeCount: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            Text("Tes codes de secours")
                .font(SQType.heading)
                .sqHeader()
                .foregroundStyle(SQColor.label)
            Text("Garde ces codes en lieu sûr. Chacun ne sert qu’une fois.")
                .font(SQType.body)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: SQSpace.sm)], spacing: SQSpace.sm) {
                ForEach(Array(batch.codes.enumerated()), id: \.offset) { _, code in
                    Text(verbatim: code)
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .foregroundStyle(SQColor.label)
                        .speechSpellsOutCharacters()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
                                .strokeBorder(SQColor.separator, lineWidth: 1)
                        }
                        .privacySensitive()
                }
            }
            .accessibilityIdentifier("two-factor.backup-codes.list")
            GradientButton(String(localized: "Copier les codes"), systemImage: "doc.on.doc", style: .secondary) { copy() }
                .accessibilityIdentifier("two-factor.backup-codes.copy")
            GradientButton(String(localized: "J’ai noté mes codes"), systemImage: "checkmark") { onSaved() }
                .accessibilityIdentifier("two-factor.backup-codes.saved")
        }
        .padding(SQSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sqSoftCard()
        .background(AppSensitiveContentMarker())
        .onDisappear(perform: clearCopy)
    }

    private func copy() {
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: batch.codes.joined(separator: "\n")]], options: [
            .localOnly: true, .expirationDate: Date().addingTimeInterval(120),
        ])
        copiedChangeCount = UIPasteboard.general.changeCount
        Haptics.success()
    }

    /// N'efface que la copie faite ici, jamais un contenu copié ensuite ailleurs.
    private func clearCopy() {
        if let count = copiedChangeCount, UIPasteboard.general.changeCount == count {
            UIPasteboard.general.items = []
        }
        copiedChangeCount = nil
    }
}

/// Champ de preuve du second facteur : le code de l'application (6 chiffres) ou un code de secours,
/// tel que tapé.
struct TwoFactorProofField: View {
    @Binding var text: String
    let usesBackupCode: Bool
    let isDisabled: Bool
    var focused: FocusState<Bool>.Binding
    let onSubmit: () -> Void

    var body: some View {
        Group {
            if usesBackupCode {
                TextField("Code de secours", text: $text,
                          prompt: Text(verbatim: "XXXXX-XXXXX").foregroundColor(SQColor.labelSecondary))
                    .textInputAutocapitalization(.characters)
                    .keyboardType(.asciiCapable)
                    .accessibilityLabel("Code de secours")
            } else {
                TextField("Code à 6 chiffres de ton app d’authentification", text: $text,
                          prompt: SQFormPrompt.text("123 456"))
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .accessibilityLabel("Code à 6 chiffres de ton app d’authentification")
            }
        }
        .autocorrectionDisabled()
        .font(SQFont.body(20, .semibold))
        .multilineTextAlignment(.center)
        .textFieldStyle(SQTextFieldStyle())
        .focused(focused)
        .submitLabel(.go)
        .onSubmit(onSubmit)
        .disabled(isDisabled)
        .privacySensitive()
        .accessibilityIdentifier("two-factor.proof.field")
        .onChangeCompat(of: text) { _, value in
            let filtered = usesBackupCode ? String(value.prefix(TwoFactorBackupCodes.inputMax))
                : String(value.unicodeScalars.filter { (48...57).contains($0.value) }.prefix(6).map(Character.init))
            if value != filtered { text = filtered }
        }
    }
}

/// Désactivation de la 2FA ou régénération des codes de secours : même preuve, le code de
/// l'application ou un code de secours (contrat 2FA r3, §4). Une régénération réussie montre le
/// nouveau lot dans la même feuille.
struct TwoFactorProofSheet: View {
    enum Purpose: Equatable { case disable, regenerate }

    let purpose: Purpose
    let operation: any TwoFactorSecondFactorOperations
    /// Lot actuel, qu'une relecture ne prendra jamais pour le nouveau (règle A).
    let previousGeneratedAt: String?
    let onDisabled: @MainActor () throws -> Void
    let onCodesChanged: @MainActor () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var usesBackupCode = false
    @State private var isBusy = false
    @State private var errorMessage: String?
    @State private var batch: TwoFactorBackupCodeBatch?
    @FocusState private var fieldFocused: Bool

    private var proof: TwoFactorProof { usesBackupCode ? .backup(text) : .app(text) }
    private var markers: TwoFactorBackupCodesMarkerStore { .live(userID: operation.scope.userID) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.xl) {
                if let batch {
                    TwoFactorBackupCodesPanel(batch: batch) {
                        markers.save(nil)
                        onCodesChanged()
                        dismiss()
                    }
                } else {
                    form
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(SQSpace.xl)
        }
        .scrollDismissesKeyboard(.interactively)
        .signalQuestBackground()
        .background(AppSensitiveContentMarker())
        .navigationTitle(purpose == .disable ? String(localized: "Désactiver la 2FA ?") : String(localized: "Générer de nouveaux codes"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(batch == nil ? LocalizedStringKey("Annuler") : LocalizedStringKey("Fermer")) { dismiss() }
                    .disabled(isBusy)
                    .accessibilityIdentifier("two-factor.proof.close")
            }
        }
        .interactiveDismissDisabled(isBusy)
        .onAppear { fieldFocused = true }
        .onDisappear { text = ""; batch = nil }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: SQSpace.lg) {
            SQIconPastille(systemImage: purpose == .disable ? "lock.open" : "key", size: 46,
                           tint: purpose == .disable ? SQColor.dangerInk : SQColor.accentInk,
                           font: Font.title3.weight(.semibold))
            if purpose == .regenerate {
                Text("Les anciens codes ne fonctionneront plus.")
                    .font(SQType.body)
                    .foregroundStyle(SQColor.label)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !usesBackupCode {
                Text("Saisis un code de ton application d'authentification pour confirmer la désactivation.")
                    .font(SQType.body)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TwoFactorProofField(text: $text, usesBackupCode: usesBackupCode, isDisabled: isBusy,
                                focused: $fieldFocused, onSubmit: submit)
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(SQType.subhead)
                    .foregroundStyle(SQColor.dangerInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("two-factor.proof.error")
                    .sqAnnounce(errorMessage)
            }
            GradientButton(purpose == .disable ? String(localized: "Désactiver") : String(localized: "Générer de nouveaux codes"),
                           isBusy: isBusy, style: purpose == .disable ? .destructiveFill : .primary, action: submit)
                .disabled(!TwoFactorEnrollmentService.isReady(proof))
                .accessibilityIdentifier("two-factor.proof.submit")
            Button {
                errorMessage = nil
                text = ""
                usesBackupCode.toggle()
                fieldFocused = true
            } label: {
                Text(usesBackupCode ? LocalizedStringKey("Utiliser le code de l’application")
                     : LocalizedStringKey("Utiliser un code de secours"))
                    .font(SQType.caption(.bold))
                    .foregroundStyle(SQColor.accentInk)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .disabled(isBusy)
            .accessibilityIdentifier("two-factor.proof.switch")
        }
    }

    private func submit() {
        let proof = proof, operation = operation
        guard !isBusy, TwoFactorEnrollmentService.isReady(proof) else { return }
        fieldFocused = false
        isBusy = true
        errorMessage = nil
        Task { @MainActor in
            defer { isBusy = false }
            do {
                switch purpose {
                case .disable:
                    try await operation.disable(proof: proof)
                    // 2FA coupée : plus de lot, donc plus rien à confirmer.
                    markers.save(nil)
                    onCodesChanged()
                    try onDisabled()
                    dismiss()
                case .regenerate:
                    let created = try await TwoFactorBackupCodes.createTracked(
                        previous: previousGeneratedAt, markers: markers,
                        create: { try await operation.regenerateBackupCodes(proof: proof) },
                        readStatus: { try await operation.backupCodeStatus() })
                    onCodesChanged()
                    text = ""
                    batch = created
                }
            } catch {
                guard operation.isCurrent() else { dismiss(); return }
                text = ""
                errorMessage = error.userFacingMessage
            }
        }
    }
}

/// Règle B (contrat 2FA r3.3) : après une connexion par le DERNIER code de secours, le texte
/// « dernier code » et un accès à la rubrique Sécurité, une fois.
struct LastBackupCodeNoticeModifier: ViewModifier {
    @Binding var isPresented: Bool
    let openSecurity: () -> Void

    func body(content: Content) -> some View {
        content.alert(Text("Tu as utilisé ton dernier code de secours. Génère-en de nouveaux."), isPresented: $isPresented) {
            Button("Générer de nouveaux codes") {
                isPresented = false
                openSecurity()
            }
            Button("Fermer", role: .cancel) { isPresented = false }
        }
    }
}
