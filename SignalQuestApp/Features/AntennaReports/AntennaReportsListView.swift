import SwiftUI

@MainActor
final class AntennaReportsListViewModel: ObservableObject {
    @Published var reports: [AntennaReport] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let service: AntennaReportsServicing
    init(service: AntennaReportsServicing) { self.service = service }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            reports = try await service.myReports()
                .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        } catch {
            if error.isCancellation { return }
            errorMessage = error.localizedDescription
        }
    }
}

/// « Mes signalements d'antenne » : liste des signalements émis + statut, chaque
/// ligne ouvre le fil de discussion avec la modération.
struct AntennaReportsListView: View {
    @StateObject private var model: AntennaReportsListViewModel
    private let service: AntennaReportsServicing

    init(service: AntennaReportsServicing) {
        self.service = service
        _model = StateObject(wrappedValue: AntennaReportsListViewModel(service: service))
    }

    var body: some View {
        List {
            if let error = model.errorMessage, model.reports.isEmpty {
                Section {
                    ErrorStateView(title: "Signalements indisponibles", message: error) {
                        Task { await model.load() }
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            } else if !model.isLoading, model.reports.isEmpty {
                Section {
                    EmptyStateView(
                        title: "Aucun signalement",
                        message: "Depuis la fiche d'une antenne, touche « Signaler un problème » pour aider à corriger les données.",
                        systemImage: "exclamationmark.bubble"
                    )
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            } else {
                Section {
                    ForEach(model.reports) { report in
                        NavigationLink {
                            AntennaReportThreadView(service: service, report: report)
                        } label: {
                            reportRow(report)
                        }
                        .buttonStyle(SQPressButtonStyle())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 5, leading: SQSpace.lg, bottom: 5, trailing: SQSpace.lg))
                    }
                } header: {
                    Text("Mes signalements")
                        .font(SQType.subhead)
                        .foregroundStyle(SQColor.labelSecondary)
                        .textCase(nil)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .sqReadableWidth()
        .signalQuestBackground()
        .navigationTitle("Signalements d'antenne")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .refreshable { await model.load() }
    }

    private func reportRow(_ report: AntennaReport) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            HStack(alignment: .top, spacing: SQSpace.md) {
                Image(systemName: report.reportType.systemImage)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(SQColor.brandRed)
                    .frame(width: 38, height: 38)
                    .background(SQColor.accentSoft, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(report.reportType.label)
                        .font(SQType.heading)
                        .foregroundStyle(SQColor.label)
                    Text("Site \(report.siteId)")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                    if let date = report.createdAt {
                        Text(date, format: .relative(presentation: .named))
                            .font(SQFont.body(11.5, relativeTo: .caption2))
                            .foregroundStyle(SQColor.labelTertiary)
                    }
                }
                Spacer(minLength: 0)
                AntennaReportStatusChip(status: report.status)
            }
            if let reason = report.reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
                Text(reason)
                    .font(SQType.body)
                    .foregroundStyle(SQColor.labelSecondary)
                    .lineLimit(2)
            }
            if (report.confirmCount ?? 0) > 0 || (report.disputeCount ?? 0) > 0 || report.communityConfirmed == true {
                HStack(spacing: SQSpace.md) {
                    if report.communityConfirmed == true {
                        Label("Confirmé par la communauté", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(SQColor.success)
                    }
                    if let confirm = report.confirmCount, confirm > 0 {
                        Label("\(confirm)", systemImage: "hand.thumbsup")
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                    if let dispute = report.disputeCount, dispute > 0 {
                        Label("\(dispute)", systemImage: "hand.thumbsdown")
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                }
                .font(SQType.caption)
            }
        }
        .padding(SQSpace.md + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        .sqShadowSoft()
        .contentShape(Rectangle())
    }
}
