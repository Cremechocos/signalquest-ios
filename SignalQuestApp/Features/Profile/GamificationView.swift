import SwiftUI

@MainActor
final class GamificationViewModel: ObservableObject {
    @Published var profile: GamificationProfile?
    @Published var events: [GamificationEvent] = []
    @Published var catalog: [GamificationBadge] = []
    @Published var errorMessage: String?

    private let service: GamificationServicing
    init(service: GamificationServicing) { self.service = service }

    func load() async {
        do {
            async let p = service.profile()
            async let e = service.events()
            async let c = service.catalog()
            profile = try await p
            events = try await e
            // Catalogue tolérant : un échec ici ne masque pas profil/activité.
            catalog = (try? await c) ?? []
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct GamificationView: View {
    @StateObject private var model: GamificationViewModel
    init(service: GamificationServicing) {
        _model = StateObject(wrappedValue: GamificationViewModel(service: service))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                levelCard
                    .sqFadeUp()
                if !badgeList.isEmpty { badgesGrid.sqFadeUp() }
                if !lockedBadges.isEmpty { questsSection.sqFadeUp() }
                if !model.events.isEmpty { eventsList.sqFadeUp() }
                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(SQColor.warning)
                }
            }
            .padding(18)
        }
        .signalQuestBackground()
        .navigationTitle("Récompenses")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .refreshable { await model.load() }
    }

    private var levelCard: some View {
        VStack(alignment: .leading, spacing: SQSpace.md + 2) {
            Text("Progression").sqKicker()
            HStack(alignment: .firstTextBaseline) {
                Text("Niveau \(model.profile?.level ?? 0)")
                    .font(SQType.title)
                    .foregroundStyle(SQColor.label)
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: SQSpace.xs) {
                    Text("\(model.profile?.points ?? 0)")
                        .font(SQFont.display(30, .black))
                        .monospacedDigit()
                        .foregroundStyle(SQColor.brandRed)
                        .contentTransition(.numericText())
                    Text("pts")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                }
            }
            xpBar
            Text("\(model.profile?.consecutiveDays ?? 0) jours consécutifs")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
        }
        .padding(SQSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
                .stroke(SQColor.label, lineWidth: 2)
        }
    }

    private var xpBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(SQColor.fill)
                if xpProgress > 0 {
                    Capsule()
                        .fill(SQGradient.signal)
                        .frame(width: max(8, proxy.size.width * xpProgress))
                }
            }
        }
        .frame(height: 8)
        .accessibilityElement()
        .accessibilityLabel("Progression vers le niveau suivant")
        .accessibilityValue("\(Int(xpProgress * 100)) %")
    }

    private var badgesGrid: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm + 2) {
            Text("Badges").font(SQType.title).foregroundStyle(SQColor.label)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: SQSpace.md), count: 3), spacing: SQSpace.md) {
                ForEach(badgeList) { badge in
                    badgeTile(badge)
                }
            }
        }
    }

    private var badgeList: [GamificationBadge] { model.profile?.badges ?? [] }

    /// Badges du catalogue pas encore débloqués = « quêtes » à accomplir (F6),
    /// branchées sur le même système de badges/points que la progression.
    private var lockedBadges: [GamificationBadge] {
        let earned = Set(badgeList.map(\.id))
        return model.catalog.filter { !earned.contains($0.id) }
    }

    private var questsSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm + 2) {
            Text("Quêtes à débloquer").font(SQType.title).foregroundStyle(SQColor.label)
            ForEach(lockedBadges) { badge in
                HStack(spacing: SQSpace.md) {
                    Group {
                        if let icon = badge.icon {
                            Text(icon).font(.title3)
                        } else {
                            Image(systemName: "lock.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(SQColor.labelSecondary)
                        }
                    }
                    .frame(width: 32, height: 32)
                    .background(SQColor.fill, in: Circle())
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(badge.title ?? "Badge")
                            .font(SQType.subhead)
                            .foregroundStyle(SQColor.label)
                        if let desc = badge.description {
                            Text(desc)
                                .font(SQType.caption)
                                .foregroundStyle(SQColor.labelSecondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer()
                }
                .padding(SQSpace.md - 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
                        .stroke(SQColor.separator, lineWidth: 1.5)
                }
                .opacity(0.75)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Quête : \(badge.title ?? "Badge")")
                .accessibilityValue(badge.description ?? "À débloquer")
            }
        }
    }

    private func badgeTile(_ badge: GamificationBadge) -> some View {
        VStack(spacing: SQSpace.sm) {
            RemoteImage(url: badge.iconUrl, maxDimension: 52, contentMode: .fit) {
                if let icon = badge.icon {
                    Text(icon)
                        .font(.largeTitle)
                } else {
                    Image(systemName: "rosette")
                        .font(.title)
                        .foregroundStyle(SQColor.brandRed)
                }
            }
            .frame(width: 52, height: 52)
            .accessibilityHidden(true)
            Text(badge.title ?? "Badge")
                .font(SQType.micro)
                .multilineTextAlignment(.center)
                .foregroundStyle(SQColor.label)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity)
        .padding(SQSpace.md - 2)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
                .stroke(SQColor.separator, lineWidth: 1.5)
        }
    }

    private var eventsList: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm + 2) {
            Text("Activité").font(SQType.title).foregroundStyle(SQColor.label)
            ForEach(model.events) { event in
                HStack(spacing: SQSpace.md) {
                    Image(systemName: "sparkles")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(SQColor.brandRed)
                        .frame(width: 32, height: 32)
                        .background(SQColor.brandRed.opacity(0.12), in: Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.kind ?? "Événement")
                            .font(SQType.subhead)
                            .foregroundStyle(SQColor.label)
                        if let date = event.createdAt {
                            Text(date, format: .relative(presentation: .named))
                                .font(SQType.caption)
                                .foregroundStyle(SQColor.labelSecondary)
                        }
                    }
                    Spacer()
                    if let delta = event.pointsDelta {
                        Text("\(delta > 0 ? "+" : "")\(delta) pts")
                            .font(SQFont.archivo(13, .bold, relativeTo: .footnote))
                            .monospacedDigit()
                            .foregroundStyle(delta >= 0 ? SQColor.success : SQColor.danger)
                    }
                }
                .padding(SQSpace.md - 2)
                .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
                        .stroke(SQColor.separator, lineWidth: 1.5)
                }
            }
        }
    }

    private var xpProgress: Double {
        guard let points = model.profile?.points, let next = model.profile?.xpToNextLevel, next > 0 else { return 0 }
        let inLevel = Double(points % next)
        return min(1, inLevel / Double(next))
    }
}
