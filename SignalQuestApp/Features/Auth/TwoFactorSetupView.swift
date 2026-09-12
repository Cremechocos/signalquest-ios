import SwiftUI
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers

struct TwoFactorSetupView: View {
    @StateObject private var model: TwoFactorSetupViewModel
    @EnvironmentObject private var session: AuthSessionViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var qrImage: UIImage?
    @State private var copiedSecretChangeCount: Int?
    @FocusState private var codeFocused: Bool

    init(service: TwoFactorEnrollmentServicing,
         acknowledge: @escaping @MainActor () throws -> Void,
         refreshProfile: @escaping @MainActor () async throws -> Void) {
        _model = StateObject(wrappedValue: TwoFactorSetupViewModel(service: service,
            acknowledge: acknowledge, refreshProfile: refreshProfile))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.xl) {
                header
                if model.needsProfileRefresh {
                    confirmation
                } else if let setup = model.setup {
                    enrollment(setup)
                    verification
                } else if model.phase == .loading || model.phase == .idle {
                    VStack(alignment: .leading, spacing: SQSpace.md) {
                        ProgressView("Préparation de la configuration…")
                            .tint(SQColor.accent)
                        Text("Le secret sera disponible ici pour ton application d’authentification.")
                            .font(SQType.subhead)
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                    .accessibilityIdentifier("two-factor.setup.loading")
                }

                if let message = model.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(SQType.subhead)
                        .foregroundStyle(SQColor.dangerInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(SQSpace.lg)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(SQColor.dangerSoft, in: RoundedRectangle(cornerRadius: SQRadius.xl))
                        .accessibilityIdentifier("two-factor.setup.error")
                }

                if model.phase == .loadFailed || model.phase == .needsNewSetup {
                    GradientButton(model.phase == .needsNewSetup ? "Générer un nouveau QR code" : "Réessayer",
                        systemImage: "arrow.clockwise") { Task { await model.load() } }
                        .accessibilityIdentifier("two-factor.setup.retry")
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(SQSpace.xl)
        }
        .scrollDismissesKeyboard(.interactively)
        .signalQuestBackground()
        .background(AppSensitiveContentMarker())
        .navigationTitle("Activer la 2FA")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Fermer") { close() }
                    .disabled(model.phase == .confirming)
                    .accessibilityIdentifier("two-factor.setup.close")
            }
        }
        .interactiveDismissDisabled(model.phase == .confirming)
        .task { if model.phase == .idle { await model.load() } }
        .task(id: model.qrCodeURI) {
            let uri = model.qrCodeURI
            let rendered = uri.flatMap(qrCode)
            guard uri == model.qrCodeURI, model.isCurrent else { qrImage = nil; return }
            qrImage = rendered
        }
        .onChangeCompat(of: session.state) { _, _ in model.sessionDidChange() }
        .onReceive(NotificationCenter.default.publisher(for: E2EEV2NotificationContextEvents.refresh).receive(on: RunLoop.main)) { _ in
            model.sessionDidChange()
        }
        .onChangeCompat(of: model.phase) { _, phase in
            if phase != .ready && phase != .confirming {
                qrImage = nil
                clearCopiedSecret()
            }
            if phase == .sessionChanged { codeFocused = false }
        }
        .onChangeCompat(of: model.didEnable) { _, enabled in
            if enabled { codeFocused = false; Haptics.success() }
        }
        .onDisappear { clearCopiedSecret(); qrImage = nil; model.close() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            Image(systemName: "lock.shield")
                .font(.title3.weight(.semibold))
                .foregroundStyle(SQColor.accentInk)
                .frame(width: 46, height: 46)
                .background(SQColor.accentSoft, in: Circle())
                .accessibilityHidden(true)
            Text("Double authentification")
                .font(SQType.title)
                .foregroundStyle(SQColor.label)
            if !model.needsProfileRefresh && model.phase != .sessionChanged {
                Text("Ajoute SignalQuest à ton application d’authentification, puis saisis le code qu’elle affiche.")
                    .font(SQType.body)
                    .foregroundStyle(SQColor.labelSecondary)
            }
        }
    }

    private func enrollment(_ setup: TwoFactorSetupResponse) -> some View {
        VStack(alignment: .center, spacing: SQSpace.md) {
            if let image = qrImage {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 220)
                    .padding(SQSpace.sm)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: SQRadius.control))
                    .accessibilityLabel("QR code de configuration 2FA")
                    .privacySensitive()
            }
            Text("Secret manuel")
                .font(SQType.subhead)
                .foregroundStyle(SQColor.labelSecondary)
            Text(setup.secret)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(SQColor.label)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .privacySensitive()
                .accessibilityIdentifier("two-factor.setup.secret")
            Button { copySecret(setup.secret) } label: {
                Label("Copier le secret", systemImage: "doc.on.doc")
                    .font(SQType.button)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.bordered)
            .tint(SQColor.accent)
            .disabled(model.phase == .confirming)
            Text("Secret sensible — copie effacée du presse-papier après 1 min.")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(SQSpace.lg)
        .sqSoftCard()
    }

    private var verification: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            Text("Code de vérification")
                .font(SQType.heading)
                .foregroundStyle(SQColor.label)
            TextField("Code TOTP à 6 chiffres", text: $model.code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(SQFont.body(24, .semibold))
                .multilineTextAlignment(.center)
                .textFieldStyle(SQTextFieldStyle())
                .focused($codeFocused)
                .disabled(model.isBusy)
                .privacySensitive()
                .accessibilityIdentifier("two-factor.setup.code")
                .onChangeCompat(of: model.code) { _, value in
                    let filtered = String(value.unicodeScalars.filter { (48...57).contains($0.value) }.prefix(6).map(Character.init))
                    if value != filtered { model.code = filtered }
                }
            GradientButton("Activer la 2FA", systemImage: "lock.shield.fill", isBusy: model.phase == .confirming) {
                codeFocused = false
                Task { await model.confirm() }
            }
            .disabled(!model.canConfirm)
            .accessibilityIdentifier("two-factor.setup.confirm")
        }
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            Label(model.didEnable ? String(localized: "La double authentification est activée.")
                : String(localized: "La double authentification est déjà active."), systemImage: "checkmark.shield.fill")
                .font(SQType.heading)
                .foregroundStyle(SQColor.success)
                .accessibilityIdentifier("two-factor.setup.enabled")
            if model.phase == .refreshingProfile {
                ProgressView("Actualisation du compte…").tint(SQColor.accent)
            } else if model.phase == .profileRefreshFailed {
                Text("Ton compte reste protégé. Seule l’actualisation de son affichage doit être réessayée.")
                    .font(SQType.body)
                    .foregroundStyle(SQColor.labelSecondary)
                GradientButton("Actualiser le compte", systemImage: "arrow.clockwise") {
                    Task { await model.retryProfile() }
                }
                .accessibilityIdentifier("two-factor.setup.refresh-profile")
            }
            GradientButton("Terminer", systemImage: "checkmark", style: .secondary) { close() }
                .accessibilityIdentifier("two-factor.setup.done")
        }
        .padding(SQSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SQColor.successSoft, in: RoundedRectangle(cornerRadius: SQRadius.xl))
    }

    private func close() {
        clearCopiedSecret()
        qrImage = nil
        model.close()
        dismiss()
    }

    private func qrCode(for value: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.setValue(Data(value.utf8), forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    private func copySecret(_ secret: String) {
        guard model.isCurrent, model.setup?.secret == secret else { return }
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: secret]], options: [
            .localOnly: true, .expirationDate: Date().addingTimeInterval(60),
        ])
        copiedSecretChangeCount = UIPasteboard.general.changeCount
        Haptics.success()
    }

    private func clearCopiedSecret() {
        // Only clear the copy made by this sheet; never read or erase a newer
        // clipboard item copied elsewhere by the user.
        if let count = copiedSecretChangeCount, UIPasteboard.general.changeCount == count {
            UIPasteboard.general.items = []
        }
        copiedSecretChangeCount = nil
    }
}
