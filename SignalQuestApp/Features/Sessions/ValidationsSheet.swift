import SwiftUI

@MainActor
final class ValidationsViewModel: ObservableObject {
    @Published var validations: SiteValidations?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var pendingVote: String?

    let siteId: String
    let operatorName: String?
    private let service: ValidationsServicing

    init(siteId: String, operatorName: String?, service: ValidationsServicing) {
        self.siteId = siteId
        self.operatorName = operatorName
        self.service = service
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            validations = try await service.validations(siteId: siteId)
        } catch {
            if !error.isCancellation { errorMessage = error.userFacingMessage }
        }
    }

    func vote(type: String, value: String, action: String) async {
        pendingVote = "\(type)-\(value)"
        defer { pendingVote = nil }
        do {
            try await service.vote(siteId: siteId, type: type, value: value, operatorName: operatorName, tech: nil, action: action)
            Haptics.success()
            await load()
        } catch {
            errorMessage = error.userFacingMessage
            Haptics.error()
        }
    }
}

/// Consultation + vote des identifiants radio validés d'un site (eNB/PCI/CellID/gNB).
struct ValidationsSheet: View {
    @StateObject private var model: ValidationsViewModel
    @Environment(\.dismiss) private var dismiss

    init(siteId: String, operatorName: String?, service: ValidationsServicing) {
        _model = StateObject(wrappedValue: ValidationsViewModel(siteId: siteId, operatorName: operatorName, service: service))
    }

    /// « Site 0381234 · Orange ».
    private var subtitle: String {
        var parts = [String(localized: "Site \(model.siteId)")]
        if let op = model.operatorName, !op.isEmpty { parts.append(op) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                header
                if let v = model.validations, !v.isEmpty {
                    group("eNB (4G)", short: "eNB", "enb", v.enb)
                    group("PCI", short: "PCI", "pci", v.pci)
                    group("Cell ID", short: "Cell ID", "cellid", v.cellid)
                    group("gNB (5G)", short: "gNB", "gnb", v.gnb)
                } else if !model.isLoading {
                    EmptyStateView(
                        title: "Aucune validation",
                        message: "Aucune validation pour ce site. Sois le premier à confirmer ses identifiants.",
                        systemImage: "checkmark.seal"
                    )
                }
                if let errorMessage = model.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(SQType.caption).foregroundStyle(OutageTint.degradedInk)
                }
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.lg)
            .padding(.bottom, SQSpace.xxl)
        }
        .background(SQColor.bg.ignoresSafeArea())
        .overlay { if model.isLoading && model.validations == nil { SQSpinner().tint(SQColor.brandRed) } }
        .task { await model.load() }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: SQSpace.sm2) {
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                Text("Validations")
                    .font(SQFont.display(24, .bold, relativeTo: .title))
                    .foregroundStyle(SQColor.label)
                    .sqHeader()
                Text(verbatim: subtitle)
                    .font(SQFont.body(13, relativeTo: .footnote))
                    .foregroundStyle(SQColor.labelSecondary)
                    .monospacedDigit()
                Text("Confirme les identifiants que tu as relevés, conteste ceux qui te semblent faux.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
            MapChipIconButton(systemImage: "xmark", label: "Fermer", identifier: "validations.close") { dismiss() }
        }
    }

    @ViewBuilder
    private func group(_ title: String, short: String, _ type: String, _ entries: [ValidationEntry]) -> some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                Text(LocalizedStringKey(title))
                    .font(SQType.heading)
                    .foregroundStyle(SQColor.label)
                    .sqHeader()
                    .padding(.horizontal, SQSpace.xs)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(entries) { entry in
                        row(entry, short: short, type: type)
                        if entry.id != entries.last?.id {
                            Rectangle()
                                .fill(SQColor.separator)
                                .frame(height: 1)
                        }
                    }
                }
                .padding(.horizontal, SQSpace.lg)
                .padding(.vertical, SQSpace.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .sqCardBackground()
            }
        }
    }

    /// « 261 », « 6 pour · 1 contre », puis les deux votes ; sa propre proposition ne se conteste pas.
    private func row(_ entry: ValidationEntry, short: String, type: String) -> some View {
        HStack(spacing: SQSpace.sm) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: SQSpace.sm) {
                    Text(verbatim: entry.value)
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .foregroundStyle(SQColor.label)
                        .sqSingleLine()
                    if entry.isMine {
                        Text("ta proposition")
                            .font(SQFont.body(11, .bold, relativeTo: .caption2))
                            .foregroundStyle(SQColor.accentInk)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(SQColor.accentSoft, in: Capsule(style: .continuous))
                    }
                }
                Text("\(entry.validations) pour · \(entry.rejections) contre")
                    .font(SQFont.body(12, relativeTo: .caption2))
                    .foregroundStyle(SQColor.labelSecondary)
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: SQSpace.sm)
            if model.pendingVote == "\(type)-\(entry.value)" {
                SQSpinner().tint(SQColor.brandRed).frame(width: 44, height: 44)
            } else {
                voteButton("hand.thumbsup.fill", tint: SQColor.success, soft: SQColor.successSoft,
                           label: String(localized: "Confirmer l’identifiant \(short) \(entry.value)")) {
                    Task { await model.vote(type: type, value: entry.value, action: "validate") }
                }
                // Le serveur refuse le rejet de sa propre identification.
                if !entry.isMine {
                    voteButton("hand.thumbsdown.fill", tint: SQColor.dangerInk, soft: SQColor.dangerSoft,
                               label: String(localized: "Contester l’identifiant \(short) \(entry.value)")) {
                        Task { await model.vote(type: type, value: entry.value, action: "reject") }
                    }
                }
            }
        }
        .padding(.vertical, SQSpace.sm)
    }

    /// Bouton de vote rond de 44 pt, teinte douce et pouce plein.
    private func voteButton(_ icon: String, tint: Color, soft: Color, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(soft, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(SQPressButtonStyle())
        .disabled(model.pendingVote != nil)
        .accessibilityLabel(label)
    }
}
