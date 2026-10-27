import SwiftUI

/// Historique du Speedtest avec les tests d'expérience : « Tous · Speedtests · Expérience »,
/// comme Android. Sans test d'expérience, rien ne change : la liste des speedtests seule.
/// « Speedtests » garde sa mise en page (« Tes tests », « Sur ton compte ») ; « Tous » mêle les
/// deux par date, sans jamais montrer de trou entre deux pages (`UnifiedHistory`).
struct UnifiedHistorySection<Speedtests: View>: View {
    @ObservedObject var experience: ExperienceHistoryModel
    @Binding var kind: HistoryKind
    let local: [SpeedtestRunResult]
    let pendingIds: Set<UUID>
    let account: [SocialShareableSpeedtest]
    let accountOnly: [SocialShareableSpeedtest]
    let accountHasMore: Bool
    let loadingMoreAccount: Bool
    let openLocal: (SpeedtestRunResult) -> Void
    let openAccount: (SocialShareableSpeedtest) -> Void
    let loadMoreAccount: () async -> Void
    let loadDetail: (ExperienceHistoryItem) async throws -> ExperienceHistoryEntryDetail
    @ViewBuilder let speedtests: () -> Speedtests

    @State private var openedExperience: ExperienceHistoryItem?
    @State private var loadingMore = false

    var body: some View {
        let source = experience.source
        Group {
            if source.items.isEmpty {
                speedtests()
            } else {
                VStack(alignment: .leading, spacing: SQSpace.md) {
                    HistoryKindPicker(kind: $kind)
                    switch kind {
                    case .speedtests: speedtests()
                    case .experience: experienceList(source)
                    case .all: allList(source)
                    }
                }
            }
        }
        .sheet(item: $openedExperience) { item in
            ExperienceHistoryDetailSheet(item: item, load: loadDetail)
        }
    }

    // MARK: Listes

    private func allList(_ source: ExperienceHistorySource) -> some View {
        let entries = UnifiedHistory.allEntries(
            local: local, account: account, accountOnly: accountOnly,
            accountHasMore: accountHasMore, experience: source
        )
        let toLoad = UnifiedHistory.sourcesToLoad(account: account, accountHasMore: accountHasMore, experience: source)
        return VStack(alignment: .leading, spacing: SQSpace.sm) {
            if entries.isEmpty {
                loadingRow
            } else {
                card(entries)
            }
            failureNotice
            if toLoad.account || toLoad.experience {
                moreButton {
                    if toLoad.account { await loadMoreAccount() }
                    if toLoad.experience { await experience.loadMore() }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("history.all")
    }

    private func experienceList(_ source: ExperienceHistorySource) -> some View {
        let items = source.visibleItems
        return VStack(alignment: .leading, spacing: SQSpace.sm) {
            if items.isEmpty {
                loadingRow
            } else {
                card(items.map(HistoryEntry.experience))
            }
            failureNotice
            if source.hasMore {
                moreButton { await experience.loadMore() }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("history.experience")
    }

    private func card(_ entries: [HistoryEntry]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                if index > 0 {
                    Rectangle()
                        .fill(SQColor.separator)
                        .frame(height: 1)
                        .padding(.leading, SQSpace.cardPadding)
                }
                row(entry)
            }
        }
        .padding(.vertical, 2)
        .sqCardBackground()
    }

    @ViewBuilder
    private func row(_ entry: HistoryEntry) -> some View {
        Button {
            Haptics.selection()
            switch entry {
            case .local(let result): openLocal(result)
            case .account(let test): openAccount(test)
            case .experience(let item): openedExperience = item
            }
        } label: {
            switch entry {
            case .local(let result): SpeedtestHistoryRow(result: result, isPending: pendingIds.contains(result.id))
            case .account(let test): AccountSpeedtestRow(test: test)
            case .experience(let item): ExperienceHistoryRow(item: item)
            }
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityHint("Voir le détail du test")
        .accessibilityIdentifier("history.row.\(entry.id)")
    }

    // MARK: États

    /// Première page pas encore arrivée : rien n'est sûr à montrer, on le dit.
    private var loadingRow: some View {
        HStack(spacing: SQSpace.sm) {
            if experience.loading { ProgressView() }
            Text(experience.loading ? "Chargement des tests" : "Aucun test")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 58)
        .sqCardBackground()
    }

    /// Une page du compte a échoué : ce qui est montré peut être incomplet.
    @ViewBuilder
    private var failureNotice: some View {
        if experience.loadFailed {
            HStack(alignment: .firstTextBaseline, spacing: SQSpace.sm) {
                Text(experience.remoteUnavailable
                     ? "Tests d’expérience du compte injoignables : seuls ceux de cet appareil sont affichés."
                     : "La suite des tests d’expérience n’a pas pu être chargée.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Réessayer") {
                    Haptics.selection()
                    Task {
                        if experience.remoteUnavailable { await experience.refresh() } else { await experience.loadMore() }
                    }
                }
                .font(SQFont.body(14, .bold))
                .foregroundStyle(SQColor.accentInk)
                .frame(minHeight: 44)
                .accessibilityIdentifier("history.retry")
            }
            .padding(.horizontal, SQSpace.xs)
        }
    }

    private func moreButton(_ action: @escaping () async -> Void) -> some View {
        Button {
            guard !loadingMore else { return }
            Task {
                loadingMore = true
                await action()
                loadingMore = false
            }
        } label: {
            HStack(spacing: SQSpace.sm) {
                if loadingMore || loadingMoreAccount { ProgressView() }
                Text("Voir plus de tests")
                    .font(SQFont.body(15, .semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(SQPressButtonStyle())
        .foregroundStyle(SQColor.accentInk)
        .disabled(loadingMore || loadingMoreAccount)
        .accessibilityIdentifier("history.more")
    }
}

/// « Tous · Speedtests · Expérience » : même capsule que le choix Débit / Expérience, sans icône.
/// Aux tailles d'accessibilité, les trois choix s'empilent plutôt que de se couper.
private struct HistoryKindPicker: View {
    @Binding var kind: HistoryKind
    @Namespace private var thumb
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        layout {
            ForEach(HistoryKind.allCases, id: \.self) { value in
                segment(value)
            }
        }
        .padding(SQSpace.xxs)
        .background(SQColor.segTrack, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("history.kind")
    }

    private func segment(_ value: HistoryKind) -> some View {
        let isSelected = kind == value
        return Button {
            guard !isSelected else { return }
            Haptics.selection()
            withAnimation(reduceMotion ? nil : SQMotion.snappy) { kind = value }
        } label: {
            Text(LocalizedStringKey(value.title))
                .font(SQFont.body(14, .semibold, relativeTo: .subheadline))
                .foregroundStyle(isSelected ? SQColor.label : SQColor.labelSecondary)
                .lineLimit(1)
                .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.7)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(SQColor.segThumb)
                            .shadow(color: SQColor.shadowSoft, radius: 4, y: 1)
                            .matchedGeometryEffect(id: "thumb", in: thumb)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("history.kind.\(value.rawValue)")
    }
}
