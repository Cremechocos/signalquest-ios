import SwiftUI

@MainActor
final class AntennaReportsListViewModel: ObservableObject {
    @Published var reports: [AntennaReport] = []
    @Published var isLoading = false
    /// Un premier chargement a abouti ou échoué : avant, la liste n'est ni vide ni remplie.
    @Published private(set) var hasLoaded = false
    @Published var errorMessage: String?

    private let service: AntennaReportsServicing
    init(service: AntennaReportsServicing) { self.service = service }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer {
            isLoading = false
            hasLoaded = true
        }
        do {
            reports = try await service.myReports()
                .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        } catch {
            if error.isCancellation { return }
            errorMessage = error.userFacingMessage
        }
    }
}

/// « Mes signalements d'antenne » : liste des signalements émis + statut, chaque
/// ligne ouvre le fil de discussion avec la modération.
struct AntennaReportsListView: View {
    @StateObject private var model: AntennaReportsListViewModel
    @Environment(\.dismiss) private var dismiss
    private let service: AntennaReportsServicing

    init(service: AntennaReportsServicing) {
        self.service = service
        _model = StateObject(wrappedValue: AntennaReportsListViewModel(service: service))
    }

    var body: some View {
        List {
            Section {
                header
                    .listRowInsets(EdgeInsets(top: SQSpace.sm, leading: 0, bottom: SQSpace.xs, trailing: 0))
                    .listRowBackground(Color.clear)
            }
            .listRowSeparator(.hidden)

            if let error = model.errorMessage, model.reports.isEmpty {
                Section {
                    ErrorStateView(title: "Signalements indisponibles", message: error) {
                        Task { await model.load() }
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            } else if !model.hasLoaded, model.reports.isEmpty {
                Section {
                    SQSpinner()
                        .tint(SQColor.brandRed)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, SQSpace.xl)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            } else if !model.isLoading, model.reports.isEmpty {
                Section {
                    EmptyStateView(
                        title: "Aucun signalement",
                        message: "Ouvre la fiche d'une antenne sur la carte et touche « Signaler une erreur sur ce site » pour aider à corriger les données.",
                        systemImage: "exclamationmark.bubble"
                    )
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            } else {
                // Un rafraîchissement raté garde la liste affichée : on le dit au-dessus.
                if let error = model.errorMessage {
                    Section {
                        SQInlineError(message: error)
                            .listRowBackground(Color.clear)
                    }
                }
                Section {
                    ForEach(model.reports) { report in
                        NavigationLink {
                            AntennaReportThreadView(service: service, report: report)
                        } label: {
                            reportRow(report)
                        }
                        .listRowBackground(SQColor.surface)
                        .listRowSeparatorTint(SQColor.separator)
                        .accessibilityIdentifier("antennaReports.row.\(report.id)")
                    }
                } header: {
                    Text("Les plus récents d’abord. Pour signaler, ouvre la fiche d’une antenne sur la carte.")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .textCase(nil)
                }
            }
        }
        .listStyle(.insetGrouped)
        .modifier(CompactListMargins())
        .scrollContentBackground(.hidden)
        .sqReadableWidth()
        .signalQuestBackground()
        .navigationTitle("Signalements d'antenne")
        .toolbar(.hidden, for: .navigationBar)
        // Barre masquée : le balayage retour est rétabli, comme sur les autres écrans Halo.
        .sqKeepsSwipeBack()
        .task { await model.load() }
        .refreshable { await model.load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            MapChipIconButton(systemImage: "chevron.left", label: "Retour", identifier: "antennaReports.back") { dismiss() }
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                Text("Signalements d'antenne")
                    .font(SQFont.display(28, .bold, relativeTo: .largeTitle))
                    .foregroundStyle(SQColor.label)
                    .sqHeader()
                    .accessibilityIdentifier("antennaReports.title")
                Text("Les erreurs que tu as signalées sur une fiche d’antenne, et les réponses de l’équipe.")
                    .font(SQType.callout)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func reportRow(_ report: AntennaReport) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.xs2) {
            HStack(alignment: .top, spacing: SQSpace.sm2) {
                SQIconPastille(systemImage: report.reportType.systemImage, size: 38, font: .system(size: 15, weight: .medium))
                VStack(alignment: .leading, spacing: 2) {
                    Text(report.reportType.label)
                        .font(SQFont.body(15, .semibold, relativeTo: .headline))
                        .foregroundStyle(SQColor.label)
                    siteLine(report)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                AntennaReportStatusChip(status: report.status)
            }
            Group {
                if let reason = report.reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
                    Text(reason)
                        .font(SQType.subhead(.regular))
                        .foregroundStyle(SQColor.labelSecondary)
                        .lineLimit(2)
                }
                if (report.confirmCount ?? 0) > 0 || (report.disputeCount ?? 0) > 0 || report.communityConfirmed == true {
                    // Icône et texte côte à côte : un `Label` prendrait ici le style
                    // des listes, avec une colonne d'icône très large.
                    HStack(spacing: SQSpace.md) {
                        if report.communityConfirmed == true {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.seal.fill")
                                Text("Confirmé par la communauté")
                            }
                            .foregroundStyle(OutageTint.resolvedInk)
                            .accessibilityElement(children: .combine)
                        }
                        if let confirm = report.confirmCount, confirm > 0 {
                            HStack(spacing: 3) {
                                Image(systemName: "hand.thumbsup")
                                Text("\(confirm)").monospacedDigit()
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(Text("\(confirm) confirmations"))
                        }
                        if let dispute = report.disputeCount, dispute > 0 {
                            HStack(spacing: 3) {
                                Image(systemName: "hand.thumbsdown")
                                Text("\(dispute)").monospacedDigit()
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(Text("\(dispute) contestations"))
                        }
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                }
            }
            // Aligné sous le titre, après la tuile d'icône.
            .padding(.leading, 38 + SQSpace.sm2)
        }
        .padding(.vertical, SQSpace.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// « Site 0381234 · il y a 2 jours » : l'identifiant en chiffres tabulaires.
    private func siteLine(_ report: AntennaReport) -> Text {
        let site = Text("Site \(report.siteId)").monospacedDigit()
        guard let date = report.createdAt else { return site }
        return site + Text(verbatim: " · ") + Text(date, format: .relative(presentation: .named))
    }
}
