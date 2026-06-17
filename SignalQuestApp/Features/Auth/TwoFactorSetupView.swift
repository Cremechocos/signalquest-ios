import SwiftUI
import CoreImage.CIFilterBuiltins

@MainActor
final class TwoFactorSetupViewModel: ObservableObject {
    @Published var setup: TwoFactorSetupResponse?
    @Published var code: String = ""
    @Published var isBusy = false
    @Published var errorMessage: String?
    @Published var didEnable = false

    private let service: AuthServicing

    init(service: AuthServicing) {
        self.service = service
    }

    func load() async {
        isBusy = true
        defer { isBusy = false }
        do {
            setup = try await service.setup2FA()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func confirm() async {
        guard let secret = setup?.secret else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await service.confirm2FA(secret: secret, code: code.trimmingCharacters(in: .whitespaces))
            didEnable = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct TwoFactorSetupView: View {
    @StateObject private var model: TwoFactorSetupViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var appeared = false

    init(service: AuthServicing) {
        _model = StateObject(wrappedValue: TwoFactorSetupViewModel(service: service))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.xl + 2) {
                header
                    .sqAuthAppear(appeared)
                if let setup = model.setup {
                    VStack(alignment: .center, spacing: SQSpace.md + 2) {
                        if let url = setup.uri, let image = qrCode(for: url) {
                            Image(uiImage: image)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 220, height: 220)
                                .padding(SQSpace.sm)
                                .background(Color.white, in: RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous))
                                .accessibilityLabel("QR code de configuration 2FA")
                        }
                        Text("Secret manuel").sqKicker()
                        Text(setup.secret)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(SQColor.label)
                            .padding(.horizontal, SQSpace.md).padding(.vertical, SQSpace.sm)
                            .background(SQColor.fill, in: RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous))
                            .contextMenu {
                                Button("Copier") { UIPasteboard.general.string = setup.secret }
                            }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(SQSpace.xl)
                    .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
                            .stroke(SQColor.label, lineWidth: 2)
                    }
                    .sqAuthAppear(appeared, delay: 0.08)

                    VStack(alignment: .leading, spacing: SQSpace.md) {
                        Text("Saisis un code généré")
                            .font(SQType.heading)
                            .foregroundStyle(SQColor.label)
                        TextField("Code TOTP à 6 chiffres", text: $model.code)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                            .font(SQFont.display(28, .black))
                            .multilineTextAlignment(.center)
                            .textFieldStyle(SQTextFieldStyle())
                        GradientButton("Activer la 2FA", systemImage: "lock.shield.fill", isBusy: model.isBusy) {
                            Task {
                                await model.confirm()
                                if model.didEnable {
                                    Haptics.success()
                                    dismiss()
                                }
                            }
                        }
                        if let error = model.errorMessage {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(SQColor.danger)
                        }
                    }
                    .padding(SQSpace.xl)
                    .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
                            .stroke(SQColor.separator, lineWidth: 1.5)
                    }
                    .sqAuthAppear(appeared, delay: 0.14)
                } else {
                    VStack(spacing: SQSpace.sm + 2) {
                        ProgressView().tint(SQColor.brandRed)
                        Text("Génération du secret 2FA…")
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(SQSpace.xl)
                    .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
                            .stroke(SQColor.separator, lineWidth: 1.5)
                    }
                    .sqAuthAppear(appeared, delay: 0.08)
                }
            }
            .padding(SQSpace.xl)
        }
        .background { SQAuthHalo() }
        .signalQuestHeroBackground()
        .onAppear { appeared = true }
        .task { if model.setup == nil { await model.load() } }
        .navigationTitle("Activer la 2FA")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            Image(systemName: "lock.shield")
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(SQColor.brandRed, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                Text("Sécurité").sqKicker()
                Text("Double authentification")
                    .font(SQType.display)
                    .foregroundStyle(SQColor.label)
            }
            Text("Scanne le QR avec Authy, Google Authenticator ou 1Password puis valide avec un code généré.")
                .font(SQType.body)
                .foregroundStyle(SQColor.labelSecondary)
        }
        .padding(.top, SQSpace.xxl)
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
}
