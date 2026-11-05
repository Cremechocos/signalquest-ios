import SwiftUI

/// Fiche d'un test d'expérience de l'historique : chargée du téléphone ou du serveur, puis
/// rendue comme le résultat d'un test qu'on vient de lancer, avec le même détail par test.
struct ExperienceHistoryDetailSheet: View {
    let item: ExperienceHistoryItem
    let load: (ExperienceHistoryItem) async throws -> ExperienceHistoryEntryDetail

    @State private var detail: ExperienceHistoryEntryDetail?
    @State private var errorMessage: String?
    @State private var openedTest: ExperienceTestKind?
    @State private var shareInput: ExperienceShareInput?
    @Environment(\.dismiss) private var dismiss

    private static let topAnchor = "experience.history.detail.top"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: SQSpace.md) {
                    HStack {
                        MapChipIconButton(systemImage: "xmark", label: "Fermer", identifier: "experience.history.detail.close") {
                            dismiss()
                        }
                        Spacer()
                        if let detail, openedTest == nil,
                           ExperienceTestKind.allCases.contains(where: { detail.result.tests.state(of: $0) == .measured }) {
                            MapChipIconButton(systemImage: "square.and.arrow.up", label: "Partager",
                                              identifier: "experience.history.detail.share") {
                                shareInput = ExperienceShareInput(
                                    tests: ExperienceSubmission.tests(detail.result.tests), scores: scores(detail),
                                    measuredAt: detail.result.measuredAt, connectionType: detail.result.network.connectionType,
                                    technology: detail.result.network.technology, operatorKey: detail.result.network.operatorKey
                                )
                            }
                        }
                    }
                    .id(Self.topAnchor)
                    if let detail {
                        if let openedTest {
                            ExperienceDetailView(
                                tests: detail.result.tests, failure: detail.failures[openedTest],
                                usage: detail.usage[openedTest], test: openedTest,
                                back: { self.openedTest = nil }
                            )
                        } else {
                            summary(detail)
                        }
                    } else if let errorMessage {
                        SQNotice(message: errorMessage, tone: .warning)
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(SQSpace.xl)
                            .accessibilityLabel("Chargement du test")
                    }
                }
                .padding(SQSpace.lg)
                .sqReadableWidth()
            }
            .onChangeCompat(of: openedTest) { _, _ in proxy.scrollTo(Self.topAnchor, anchor: .top) }
        }
        .signalQuestBackground()
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("experience.history.detail")
        .sheet(item: $shareInput) { ExperienceSharePreviewSheet(input: $0) }
        .task { await loadDetail() }
    }

    private func summary(_ detail: ExperienceHistoryEntryDetail) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                Text("Test d’expérience")
                    .font(SQType.title)
                    .foregroundStyle(SQColor.label)
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: detail.result.measuredAt.sqFormatted(date: .long))
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                if let network = item.networkLine {
                    Text(verbatim: network)
                        .font(SQFont.body(12.5, .semibold, relativeTo: .footnote))
                        .foregroundStyle(SQColor.chipInk)
                        .padding(.horizontal, SQSpace.sm2)
                        .padding(.vertical, SQSpace.xs)
                        .background(SQColor.chip, in: Capsule(style: .continuous))
                        .padding(.top, SQSpace.xxs)
                }
            }

            let scores = scores(detail)
            if !scores.isEmpty {
                ExperienceOverallScoreCard(scores: scores)
            }

            ExperienceUseList(
                items: ExperienceUseItem.items(detail.result.tests, failures: detail.failures),
                identifier: "experience.history.detail",
                open: { openedTest = $0 }
            )

            if let usageLine = usageLine(detail.result) {
                Text(verbatim: usageLine)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            Label {
                Text(verbatim: keptLine)
            } icon: {
                Image(systemName: "checkmark.circle")
            }
            .font(SQType.caption)
            .foregroundStyle(SQColor.labelSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("experience.history.detail.kept")
        }
    }

    /// La note se recalcule depuis les tests (`presentation-v1`) : le plafond du jeu par son
    /// verdict s'applique à la lecture, aux anciens tests comme aux nouveaux, et les lignes
    /// affichent la même note.
    private func scores(_ detail: ExperienceHistoryEntryDetail) -> ExperienceScores {
        ExperienceScores(detail.result.tests)
    }

    /// « Données utilisées : 81,9 Mo · durée 34 s », seulement avec ce que le test a gardé.
    private func usageLine(_ result: ExperienceStoredResult) -> String? {
        switch (result.bytesUsed, result.durationMs) {
        case let (bytes?, duration?):
            String(localized: "Données utilisées : \(ExperienceResultText.megabytes(bytes)) · durée \(ExperienceResultText.duration(seconds: Int(duration / 1_000)))")
        case let (bytes?, nil):
            String(localized: "Données utilisées : \(ExperienceResultText.megabytes(bytes))")
        default:
            nil
        }
    }

    private var keptLine: String {
        switch item.delivery {
        case .pending: String(localized: "Enregistré · envoi au compte en attente")
        case .localOnly: String(localized: "Enregistré sur cet appareil, sans compte")
        case .rejected: String(localized: "Gardé sur cet appareil seulement")
        case .synced, nil: String(localized: "Enregistré sur ton compte")
        }
    }

    private func loadDetail() async {
        do {
            detail = try await load(item)
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = String(localized: "Le détail de ce test n’a pas pu être chargé. \(error.userFacingMessage)")
        }
    }
}
