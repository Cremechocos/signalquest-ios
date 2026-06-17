import SwiftUI

@MainActor
final class LeaderboardsViewModel: ObservableObject {
    @Published var result: LeaderboardResult = .empty
    @Published var period = "week"
    @Published var scope = "global"
    @Published var category = "download"
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let service: LeaderboardServicing

    init(service: LeaderboardServicing) {
        self.service = service
    }

    func load() async {
        if AppEnvironment.usesDemoData {
            result = .demo
            errorMessage = nil
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            result = try await service.leaderboard(period: period, scope: scope, category: category)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct LeaderboardsView: View {
    @StateObject private var model: LeaderboardsViewModel

    init(service: LeaderboardServicing = LeaderboardService(api: APIClient())) {
        _model = StateObject(wrappedValue: LeaderboardsViewModel(service: service))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                filters
                if model.isLoading {
                    ProgressView()
                        .tint(SQColor.brandRed)
                        .frame(maxWidth: .infinity)
                }
                podium
                    .padding(.vertical, 10)
                    .sqFadeUp()
                if let myRank = model.result.myRank {
                    myRankCard(myRank)
                        .sqFadeUp()
                }
                VStack(spacing: SQSpace.sm + 2) {
                    ForEach(model.result.entries) { entry in
                        entryRow(entry)
                            .sqFadeUp()
                    }
                }
                if let error = model.errorMessage {
                    ErrorStateView(title: "Classement indisponible", message: error)
                }
            }
            .padding(16)
            .padding(.bottom, 96)
        }
        .navigationTitle("Classement")
        .toolbarTitleInlineCompat()
        .signalQuestBackground()
        .task {
            await model.load()
        }
    }

    // MARK: Podium top 3

    private var podium: some View {
        HStack(alignment: .bottom, spacing: SQSpace.md) {
            ForEach(podiumEntries, id: \.rank) { entry in
                podiumColumn(entry)
            }
        }
    }

    /// Ordre visuel 2 — 1 — 3, le premier au centre.
    private var podiumEntries: [LeaderboardEntry] {
        let top = Array(model.result.entries.prefix(3))
        let order = [2: 0, 1: 1, 3: 2]
        return top.sorted { (order[$0.rank] ?? $0.rank) < (order[$1.rank] ?? $1.rank) }
    }

    private func podiumColumn(_ entry: LeaderboardEntry) -> some View {
        let isFirst = entry.rank == 1
        return VStack(spacing: SQSpace.sm) {
            SQAvatar(url: entry.user.avatarUrl, name: entry.user.displayName, size: isFirst ? 76 : 56)
                .padding(isFirst ? 5 : 4)
                .overlay {
                    if isFirst {
                        Circle().stroke(SQGradient.signal, lineWidth: 3)
                    } else {
                        Circle().stroke(SQColor.separator, lineWidth: 1.5)
                    }
                }
                .accessibilityHidden(true)
            Text(medal(for: entry.rank))
                .font(isFirst ? .title2 : .title3)
            Text(entry.user.displayName)
                .font(SQType.micro)
                .foregroundStyle(SQColor.label)
                .lineLimit(1)
            Text("\(Int(entry.value)) \(entry.unit)")
                .font(SQFont.archivo(13, .bold, relativeTo: .footnote))
                .monospacedDigit()
                .foregroundStyle(isFirst ? SQColor.brandRed : SQColor.labelSecondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func medal(for rank: Int) -> String {
        switch rank {
        case 1: return "🥇"
        case 2: return "🥈"
        case 3: return "🥉"
        default: return ""
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: SQSpace.xs) {
            Text("Communauté").sqKicker()
            SQSectionHeader("Classement")
        }
    }

    private var filters: some View {
        VStack(spacing: 10) {
            Picker("Période", selection: $model.period) {
                Text("Semaine").tag("week")
                Text("Mois").tag("month")
                Text("Tout").tag("all")
            }
            Picker("Scope", selection: $model.scope) {
                Text("Global").tag("global")
                Text("Amis").tag("friends")
            }
            Picker("Catégorie", selection: $model.category) {
                Text("Download").tag("download")
                Text("Upload").tag("upload")
                Text("Sessions").tag("sessions")
            }
        }
        .pickerStyle(.segmented)
        .onChangeCompat(of: model.period) { _, _ in Task { await model.load() } }
        .onChangeCompat(of: model.scope) { _, _ in Task { await model.load() } }
        .onChangeCompat(of: model.category) { _, _ in Task { await model.load() } }
    }

    private func myRankCard(_ rank: LeaderboardMyRank) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Mon rang").sqKicker()
                    .accessibilityLabel("Mon rang")
                    .accessibilityIdentifier("Mon rang")
                Text("#\(rank.rank) sur \(rank.total)")
                    .font(SQFont.display(20, .bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            Spacer()
            if let entry = rank.entry {
                Text("\(Int(entry.value)) \(entry.unit)")
                    .font(SQFont.archivo(17, .bold, relativeTo: .headline))
                    .monospacedDigit()
                    .foregroundStyle(SQColor.brandRed)
            }
        }
        .foregroundStyle(SQColor.label)
        .padding(SQSpace.lg)
        .frame(maxWidth: .infinity)
        .background(SQColor.brandRed.opacity(0.08), in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
                .stroke(SQColor.brandRed, lineWidth: 2)
        }
    }

    private func entryRow(_ entry: LeaderboardEntry) -> some View {
        let isMe = model.result.myRank?.rank == entry.rank
        let shape = RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
        return HStack(spacing: 12) {
            Text("#\(entry.rank)")
                .font(SQFont.display(17, .bold))
                .monospacedDigit()
                .foregroundStyle(isMe ? SQColor.brandRed : SQColor.labelSecondary)
                .frame(width: 44, alignment: .leading)
            SQAvatar(url: entry.user.avatarUrl, name: entry.user.displayName, size: 42)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SQSpace.xs + 2) {
                Text(entry.user.displayName)
                    .font(SQType.heading)
                HStack(spacing: SQSpace.xs + 2) {
                    if let city = entry.city { SQEditorialTag(text: city, color: SQColor.label) }
                    if let tech = entry.tech { SQEditorialTag(text: tech, color: SQBrand.techColor(tech)) }
                    if entry.isProbablyIOS { SQEditorialTag(text: "iOS", color: SQColor.brandRed) }
                }
            }
            Spacer()
            Text("\(Int(entry.value)) \(entry.unit)")
                .font(SQFont.archivo(17, .bold, relativeTo: .headline))
                .monospacedDigit()
                .foregroundStyle(isMe ? SQColor.brandRed : SQColor.label)
        }
        .foregroundStyle(SQColor.label)
        .padding(.horizontal, SQSpace.md + 2)
        .padding(.vertical, SQSpace.md)
        .background(isMe ? AnyShapeStyle(SQColor.brandRed.opacity(0.08)) : AnyShapeStyle(SQColor.surface), in: shape)
        .overlay {
            shape.stroke(isMe ? SQColor.brandRed : SQColor.separator, lineWidth: isMe ? 2 : 1.5)
        }
    }
}

extension LeaderboardResult {
    static var empty: LeaderboardResult {
        LeaderboardResult(
            category: "download",
            period: "week",
            scope: "global",
            entries: [],
            myRank: nil,
            generatedAt: nil,
            requestId: nil
        )
    }

    static var demo: LeaderboardResult {
        let author1 = SocialFeedAuthor(id: "u1", name: "Camille", handle: "camille", avatarUrl: nil, isFriend: true, isFollowing: true, liveRadio: nil)
        let author2 = SocialFeedAuthor(id: "u2", name: "Nora", handle: "nora", avatarUrl: nil, isFriend: false, isFollowing: true, liveRadio: nil)
        let author3 = SocialFeedAuthor(id: "u3", name: "Alex", handle: "alex", avatarUrl: nil, isFriend: false, isFollowing: false, liveRadio: nil)
        let entries = [
            LeaderboardEntry(rank: 1, user: author1, value: 712, unit: "Mbps", detail: "Android radio", tech: "5G", operator: "SignalQuest", city: "Paris", capturedAt: Date()),
            LeaderboardEntry(rank: 2, user: author2, value: 548, unit: "Mbps", detail: "iOS speedtest", tech: nil, operator: "SignalQuest", city: "Lyon", capturedAt: Date()),
            LeaderboardEntry(rank: 3, user: author3, value: 402, unit: "Mbps", detail: "iPhone", tech: nil, operator: "SignalQuest", city: "Marseille", capturedAt: Date())
        ]
        return LeaderboardResult(
            category: "download",
            period: "week",
            scope: "global",
            entries: entries,
            myRank: LeaderboardMyRank(rank: 42, total: 1204, entry: nil),
            generatedAt: Date(),
            requestId: "demo"
        )
    }
}
