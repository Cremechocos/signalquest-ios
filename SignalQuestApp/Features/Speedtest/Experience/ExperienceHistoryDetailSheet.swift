import SwiftUI

/// Fiche d'un test d'expérience de l'historique : chargée du téléphone ou du serveur, puis
/// rendue comme le résultat d'un test qu'on vient de lancer, avec le même détail par test.
struct ExperienceHistoryDetailSheet: View {
    let item: ExperienceHistoryItem
    let load: (ExperienceHistoryItem) async throws -> ExperienceHistoryEntryDetail

    @State private var detail: ExperienceHistoryEntryDetail?
    @State private var errorMessage: String?
    @State private var openedTest: ExperienceTestKind?
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
        .task { await loadDetail() }
    }

    private func summary(_ detail: ExperienceHistoryEntryDetail) -> some View {
        let tests = ExperienceMethod.order.filter { detail.result.tests.state(of: $0) != nil }
        return VStack(alignment: .leading, spacing: SQSpace.md) {
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                Text("Test d’expérience")
                    .font(SQType.title)
                    .foregroundStyle(SQColor.label)
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: detail.result.measuredAt.formatted(date: .long, time: .shortened))
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

            VStack(spacing: 0) {
                ForEach(tests, id: \.self) { test in
                    row(test, detail: detail)
                    if test != tests.last { Divider().padding(.leading, SQSpace.cardPadding) }
                }
            }
            .sqCardBackground()

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

    /// La note servie fait foi ; celle du téléphone seulement pour un test pas encore confirmé.
    private func scores(_ detail: ExperienceHistoryEntryDetail) -> ExperienceScores {
        item.highlights.scores ?? ExperienceScores(detail.result.tests)
    }

    private func line(_ test: ExperienceTestKind, detail: ExperienceHistoryEntryDetail) -> ExperienceResultText.Line {
        var line = ExperienceResultText.line(test, in: detail.result.tests, failure: detail.failures[test])
        line.score = scores(detail).score(for: test)
        return line
    }

    @ViewBuilder
    private func row(_ test: ExperienceTestKind, detail: ExperienceHistoryEntryDetail) -> some View {
        let line = line(test, detail: detail)
        if detail.result.tests.state(of: test) != .notTested {
            Button {
                Haptics.selection()
                openedTest = test
            } label: {
                ExperienceResultRowContent(test: test, line: line, chevron: true)
            }
            .buttonStyle(SQPressButtonStyle())
            .accessibilityHint(Text("Ouvre le détail du test"))
            .accessibilityIdentifier("experience.history.detail.\(test.rawValue)")
        } else {
            ExperienceResultRowContent(test: test, line: line, chevron: false)
                .accessibilityIdentifier("experience.history.detail.\(test.rawValue)")
        }
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
