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
                        Text("Aucune validation pour ce site. Sois le premier à confirmer ses identifiants.")
                            .font(.subheadline)
                            .foregroundStyle(SQColor.labelSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, SQSpace.xxl)
                    }
                    if let errorMessage = model.errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(SQColor.warning)
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
                    .font(SQFont.archivo(12, .semibold))
                    .tracking(0.4)
                    .textCase(.uppercase)
                    .foregroundStyle(SQColor.labelSecondary)
                ForEach(entries) { entry in
                    HStack(spacing: SQSpace.sm) {
                        Text(entry.value)
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(SQColor.label)
                        Spacer()
                        Label("\(entry.validations)", systemImage: "hand.thumbsup.fill")
                            .font(.caption2).foregroundStyle(SQColor.brandGreen)
                        Label("\(entry.rejections)", systemImage: "hand.thumbsdown.fill")
                            .font(.caption2).foregroundStyle(SQColor.danger)
                        if model.pendingVote == "\(type)-\(entry.value)" {
                            ProgressView()
                        } else {
                            Button { Task { await model.vote(type: type, value: entry.value, action: "validate") } } label: {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(SQColor.brandGreen)
                            }
                            Button { Task { await model.vote(type: type, value: entry.value, action: "reject") } } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(SQColor.danger)
                            }
                        }
                    }
                    .padding(.vertical, 5)
                }
            }
            .padding(SQSpace.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SQColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}
