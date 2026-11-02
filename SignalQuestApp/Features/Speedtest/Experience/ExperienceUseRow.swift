import SwiftUI

/// Un usage d'un test d'expérience prêt à afficher (`presentation-v1`) : ses phrases, sa
/// valeur clé et sa note, et le test dont le détail s'ouvre au toucher.
struct ExperienceUseItem: Identifiable, Equatable {
    let use: ExperiencePresentation.Use
    let presentation: ExperiencePresentation.UsePresentation
    /// Phrase locale d'un échec juste après le test (serveur occupé ou redirigé), à la place
    /// de « Échec de la mesure » ; jamais rendue depuis un test relu.
    let localFailure: ExperiencePresentation.Text?
    /// Le premier test lancé de l'usage, celui que le toucher ouvre ; nil s'il n'a rien produit.
    let detailTest: ExperienceTestKind?

    var id: String { use.rawValue }

    var lines: [ExperiencePresentation.Text] { localFailure.map { [$0] } ?? presentation.lines }

    /// Les usages dont un test a un état, dans l'ordre du contrat ; `only` restreint aux tests choisis.
    static func items(
        _ result: ExperienceTestsResult,
        methodology: String? = nil,
        failures: [ExperienceTestKind: ExperienceFailureCause] = [:],
        only selected: Set<ExperienceTestKind>? = nil
    ) -> [ExperienceUseItem] {
        let uses = ExperiencePresentation.uses(tests: ExperienceSubmission.tests(result),
                                               methodology: methodology ?? ExperienceMethod.methodology)
        return ExperiencePresentation.Use.allCases.compactMap { use in
            let tests = use.tests.filter { selected?.contains($0) ?? (result.state(of: $0) != nil) }
            guard !tests.isEmpty, let presentation = uses[use] else { return nil }
            let local: ExperiencePresentation.Text? = presentation.state != "failed" ? nil
                : tests.lazy.compactMap { test -> ExperiencePresentation.Text? in
                    switch failures[test] {
                    case .serverBusy?: ExperiencePresentation.Text(key: "experience.local.failed_server_busy")
                    case .routeChanged?: ExperiencePresentation.Text(key: "experience.local.failed_server_redirected")
                    default: nil
                    }
                }.first
            let detail = tests.first { (result.state(of: $0) ?? .notTested) != .notTested }
            return ExperienceUseItem(use: use, presentation: presentation, localFailure: local, detailTest: detail)
        }
    }
}

extension ExperiencePresentation.Use {
    /// Titre de la ligne, comme sur la note globale et l'image de partage.
    var title: String {
        switch self {
        case .video: String(localized: "Vidéo")
        case .webPage: String(localized: "Web")
        case .gameAndCalls: String(localized: "Jeu et appels")
        case .upload: String(localized: "Envoi")
        }
    }
}

/// Une ligne du résultat par usage : son titre, une phrase (deux pour la vidéo : l'échelle
/// puis le lecteur adaptatif), sa valeur clé, et sa note en chiffre seul. Partagée par le
/// résultat, la fiche d'un test de l'historique et le détail d'un post.
struct ExperienceUseRowContent: View {
    let item: ExperienceUseItem
    let chevron: Bool
    private let language = ExperienceShareLanguage.current

    var body: some View {
        HStack(alignment: .top, spacing: SQSpace.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: item.use.title)
                    .font(SQFont.body(10, .bold, relativeTo: .caption))
                    .tracking(10 * 0.12)
                    .textCase(.uppercase)
                    .foregroundStyle(SQColor.labelSecondary)
                ForEach(Array(item.lines.enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line.rendered(language))
                        .font(SQFont.body(15, .semibold, relativeTo: .body))
                        .foregroundStyle(SQColor.label)
                }
                if let keyValue = item.presentation.keyValue {
                    Text(verbatim: keyValue.rendered(language))
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            if let score = item.presentation.score {
                VStack(spacing: 0) {
                    Text(verbatim: "\(score)")
                        .font(SQFont.display(24, .heavy, relativeTo: .title2))
                        .foregroundStyle(SQColor.label)
                        .monospacedDigit()
                    Text(verbatim: "/100")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Note \(score) sur 100"))
            }
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SQColor.labelTertiary)
                    .padding(.top, 2)
                    .accessibilityHidden(true)
            }
        }
        .padding(SQSpace.cardPadding)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// La carte des usages : une ligne par usage, chacune ouvre le détail de son premier test.
struct ExperienceUseList: View {
    let items: [ExperienceUseItem]
    /// Préfixe des identifiants d'accessibilité, suivi du nom de l'usage.
    let identifier: String
    let open: (ExperienceTestKind) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                row(item)
                if item.id != items.last?.id { Divider().padding(.leading, SQSpace.cardPadding) }
            }
        }
        .sqCardBackground()
    }

    @ViewBuilder
    private func row(_ item: ExperienceUseItem) -> some View {
        if let test = item.detailTest {
            Button {
                Haptics.selection()
                open(test)
            } label: {
                ExperienceUseRowContent(item: item, chevron: true)
            }
            .buttonStyle(SQPressButtonStyle())
            .accessibilityHint(Text("Ouvre le détail du test"))
            .accessibilityIdentifier("\(identifier).\(item.use.rawValue)")
        } else {
            ExperienceUseRowContent(item: item, chevron: false)
                .accessibilityIdentifier("\(identifier).\(item.use.rawValue)")
        }
    }
}
