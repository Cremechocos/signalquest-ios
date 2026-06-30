import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var session: AuthSessionViewModel
    let user: AuthUser
    @State private var showEdit = false
    @State private var stats: UserStats?
    @State private var statsError: String?

    var body: some View {
        ScrollView {
            VStack(spacing: SQSpace.xl) {
                profileHeader
                    .sqFadeUp()
                if let stats {
                    statsRow(stats)
                        .sqFadeUp()
                } else if let statsError {
                    ErrorStateView(title: "Stats indisponibles", message: statsError)
                        .sqFadeUp()
                }

                GradientButton("Éditer le profil", systemImage: "person.crop.circle", style: .secondary) {
                    showEdit = true
                }
                .sqFadeUp()

                VStack(spacing: 0) {
                    NavigationLink {
                        GamificationView(service: services.gamification)
                    } label: {
                        menuRow(title: "Récompenses", icon: "rosette")
                    }
                    menuSeparator
                    NavigationLink {
                        LeaderboardsView(service: services.leaderboards)
                    } label: {
                        menuRow(title: "Classement", icon: "trophy")
                    }
                    menuSeparator
                    NavigationLink {
                        FriendsListView(service: services.friends)
                    } label: {
                        menuRow(title: "Amis", icon: "person.2.fill")
                    }
                    menuSeparator
                    NavigationLink {
                        PhotosView(service: services.photos)
                    } label: {
                        menuRow(title: "Photos", icon: "photo.stack")
                    }
                    menuSeparator
                    NavigationLink {
                        SessionsListView(service: services.sessions)
                    } label: {
                        menuRow(title: "Mes sessions / Logs", icon: "point.topleft.down.curvedto.point.bottomright.up")
                    }
                    menuSeparator
                    NavigationLink {
                        MyMeasurementsView(service: services.sessions)
                    } label: {
                        menuRow(title: "Mes mesures", icon: "mappin.and.ellipse")
                    }
                    menuSeparator
                    NavigationLink {
                        MyIdentificationsView(service: services.identify)
                    } label: {
                        menuRow(title: "Mes identifications", icon: "checkmark.seal")
                    }
                    menuSeparator
                    NavigationLink {
                        ANFRMapView(service: services.anfr)
                    } label: {
                        menuRow(title: "Carte ANFR", icon: "antenna.radiowaves.left.and.right")
                    }
                    menuSeparator
                    NavigationLink {
                        ANFRStatsView(service: services.anfr)
                    } label: {
                        menuRow(title: "Statistiques ANFR", icon: "chart.bar.xaxis")
                    }
                    menuSeparator
                    NavigationLink {
                        NotificationsCenterView(service: services.notifications)
                    } label: {
                        menuRow(title: "Notifications", icon: "bell.fill")
                    }
                    menuSeparator
                    NavigationLink {
                        CallHistoryView(service: services.calls)
                    } label: {
                        menuRow(title: "Appels", icon: "phone.circle")
                    }
                    menuSeparator
                    NavigationLink {
                        PrivacySettingsView(service: services.privacy)
                    } label: {
                        menuRow(title: "Confidentialité", icon: "hand.raised.fill")
                    }
                    menuSeparator
                    NavigationLink {
                        SettingsView(userService: services.users, authService: services.auth)
                    } label: {
                        menuRow(title: "Réglages", icon: "gearshape.fill")
                    }
                }
                .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
                        .stroke(SQColor.separator, lineWidth: 1.5)
                }
                .sqFadeUp()

                Button(role: .destructive) {
                    Task { await session.logout() }
                } label: {
                    Label("Déconnexion", systemImage: "rectangle.portrait.and.arrow.right")
                        .font(SQType.heading)
                        .foregroundStyle(SQColor.danger)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, SQSpace.md + 2)
                        .background(SQColor.danger.opacity(0.10), in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
                }
                .buttonStyle(.plain)
                .sqFadeUp()
            }
            .padding(SQSpace.lg)
            .padding(.bottom, SQSpace.huge + SQSpace.huge)
        }
        .navigationTitle("Profil")
        .toolbarTitleInlineCompat()
        .signalQuestBackground()
        .sheet(isPresented: $showEdit) {
            EditProfileView(user: user)
        }
        .task { await loadStats() }
        .refreshable { await loadStats() }
    }

    private var profileHeader: some View {
        VStack(spacing: SQSpace.md) {
            Text("Mon profil")
                .sqKicker()
            SQAvatar(url: user.avatarUrl, name: user.displayName, size: 84)
                .padding(5)
                .overlay {
                    Circle().stroke(SQColor.brandRed, lineWidth: 3)
                }
                .accessibilityHidden(true)
            Text(user.displayName)
                .font(SQType.display)
                .foregroundStyle(SQColor.label)
                .multilineTextAlignment(.center)
            Text(user.handle.flatMap { $0.isEmpty ? nil : "@\($0)" } ?? "Ajoute un nom d’utilisateur")
                .font(SQType.subhead)
                .foregroundStyle((user.handle?.isEmpty ?? true) ? SQColor.labelTertiary : SQColor.labelSecondary)
            if user.twoFactorEnabled == true {
                SQEditorialTag(text: "2FA", color: SQColor.success)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func statsRow(_ stats: UserStats) -> some View {
        HStack(spacing: 0) {
            statCell(label: "Points", value: stats.totalPoints.map(String.init) ?? "—")
            statDivider
            statCell(label: "Tests", value: stats.totalSpeedtests.map(String.init) ?? "—")
            statDivider
            statCell(label: "Niveau", value: stats.level.map(String.init) ?? "—")
            if let validations = stats.totalValidations {
                statDivider
                statCell(label: "Valid.", value: String(validations))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, SQSpace.md)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
                .stroke(SQColor.separator, lineWidth: 1.5)
        }
    }

    private func statCell(label: String, value: String) -> some View {
        VStack(spacing: SQSpace.xs) {
            Text(value)
                .font(SQFont.display(22, .bold))
                .monospacedDigit()
                .foregroundStyle(SQColor.label)
                .contentTransition(.numericText())
            Text(label)
                .font(SQType.micro)
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(SQColor.labelSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var statDivider: some View {
        Rectangle()
            .fill(SQColor.separator)
            .frame(width: 1.5, height: 36)
    }

    private func loadStats() async {
        do {
            stats = try await services.users.stats()
        } catch {
            statsError = error.localizedDescription
        }
    }

    private var menuSeparator: some View {
        Rectangle()
            .fill(SQColor.separator)
            .frame(height: 1)
            .padding(.leading, SQSpace.md + 2 + 30 + SQSpace.md)
    }

    private func menuRow(title: String, icon: String) -> some View {
        HStack(spacing: SQSpace.md) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(SQColor.brandRed)
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
            Text(title)
                .font(SQFont.archivo(17, .medium, relativeTo: .body))
                .foregroundStyle(SQColor.label)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(SQColor.labelTertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, SQSpace.md + 2)
        .padding(.vertical, SQSpace.md)
        .contentShape(Rectangle())
    }
}
