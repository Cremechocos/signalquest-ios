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
            if !error.isCancellation { errorMessage = error.localizedDescription }
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
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }
}

/// Consultation + vote des identifiants radio validés d'un site (eNB/PCI/CellID/gNB).
struct ValidationsSheet: View {
    @StateObject private var model: ValidationsViewModel

    init(siteId: String, operatorName: String?, service: ValidationsServicing) {
        _model = StateObject(wrappedValue: ValidationsViewModel(siteId: siteId, operatorName: operatorName, service: service))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SQSpace.lg) {
                    if let v = model.validations, !v.isEmpty {
                        group("eNB (4G)", "enb", v.enb)
                        group("PCI", "pci", v.pci)
                        group("Cell ID", "cellid", v.cellid)
                        group("gNB (5G)", "gnb", v.gnb)
                    } else if !model.isLoading {
                        EmptyStateView(
                            title: "Aucune validation",
                            message: "Aucune validation pour ce site. Sois le premier à confirmer ses identifiants.",
                            systemImage: "checkmark.seal"
                        )
                    }
                    if let errorMessage = model.errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(SQType.caption).foregroundStyle(SQColor.warning)
                    }
                }
                .padding()
            }
            .background(SQColor.bg.ignoresSafeArea())
            .navigationTitle("Validations")
            .toolbarTitleInlineCompat()
            .overlay { if model.isLoading && model.validations == nil { ProgressView().tint(SQColor.brandRed) } }
            .task { await model.load() }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func group(_ title: String, _ type: String, _ entries: [ValidationEntry]) -> some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                Text(title)
                    .font(SQType.heading)
                    .foregroundStyle(SQColor.label)
                    .padding(.bottom, SQSpace.xs)
                ForEach(entries) { entry in
                    HStack(spacing: SQSpace.sm) {
                        Text(entry.value)
                            .font(SQFont.body(15, .semibold, relativeTo: .subheadline).monospacedDigit())
                            .foregroundStyle(SQColor.label)
                        Spacer()
                        Label("\(entry.validations)", systemImage: "hand.thumbsup.fill")
                            .font(SQFont.body(11.5, .medium, relativeTo: .caption2))
                            .foregroundStyle(SQColor.success)
                        Label("\(entry.rejections)", systemImage: "hand.thumbsdown.fill")
                            .font(SQFont.body(11.5, .medium, relativeTo: .caption2))
                            .foregroundStyle(SQColor.danger)
                        if model.pendingVote == "\(type)-\(entry.value)" {
                            ProgressView().tint(SQColor.brandRed)
                        } else {
                            voteButton("checkmark", tint: SQColor.success, soft: SQColor.successSoft,
                                       label: "Valider \(title) \(entry.value)") {
                                Task { await model.vote(type: type, value: entry.value, action: "validate") }
                            }
                            voteButton("xmark", tint: SQColor.danger, soft: SQColor.dangerSoft,
                                       label: "Rejeter \(title) \(entry.value)") {
                                Task { await model.vote(type: type, value: entry.value, action: "reject") }
                            }
                        }
                    }
                    .padding(.vertical, 3)
                    if entry.id != entries.last?.id {
                        Rectangle()
                            .fill(SQColor.separator)
                            .frame(height: 1)
                    }
                }
            }
            .padding(SQSpace.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
            .sqShadowCard()
        }
    }

    /// Pastille de vote circulaire (teinte douce + icône pleine), zone tactile ≥ 44 pt.
    private func voteButton(_ icon: String, tint: Color, soft: Color, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(soft, in: Circle())
                .padding(3)
                .contentShape(Rectangle())
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityLabel(label)
    }
}
