import SwiftUI

@MainActor
final class ZoneAlertSettingsModel: ObservableObject {
    @Published private(set) var settings: ZoneAlertSettings?
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let service: ZoneAlertService
    /// Dernier état confirmé par le serveur : base du retour arrière.
    private var confirmed: ZoneAlertSettings?
    /// Les envois partent l'un après l'autre, dans l'ordre des gestes.
    private var sendChain: Task<Void, Never>?
    private var latestToken: [String: Int] = [:]
    private var tokenCounter = 0
    private var pendingCount = 0

    init(service: ZoneAlertService) {
        self.service = service
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            settings = try await service.settings()
            confirmed = settings
            errorMessage = nil
        } catch {
            if !error.isCancellation { errorMessage = error.userFacingMessage }
        }
    }

    /// Enregistré au geste, comme les autres notifications : le réglage change
    /// tout de suite et revient si le serveur refuse. Pour une même clé (pas
    /// rapides du stepper), seule la dernière valeur est envoyée.
    func apply(_ change: ZoneAlertChange) async {
        guard let current = settings else { return }
        var optimistic = current
        optimistic.preferences = change.applied(to: current.preferences)
        settings = optimistic
        if confirmed == nil { confirmed = current }
        tokenCounter += 1
        let token = tokenCounter
        let key = change.serverKey
        latestToken[key] = token
        pendingCount += 1
        let previous = sendChain
        let task = Task { [weak self] in
            await previous?.value
            await self?.send(change, key: key, token: token)
        }
        sendChain = task
        await task.value
    }

    private func send(_ change: ZoneAlertChange, key: String, token: Int) async {
        defer { pendingCount -= 1 }
        // Une valeur plus récente pour la même clé attend : celle-ci est périmée.
        guard latestToken[key] == token, let base = confirmed else { return }
        let isLast = pendingCount == 1
        do {
            let result = try await service.apply(change, to: base)
            confirmed = result
            if isLast { settings = result }
            errorMessage = nil
        } catch {
            if isLast { settings = confirmed }
            if !error.isCancellation { errorMessage = error.userFacingMessage }
        }
    }
}

private extension ZoneAlertChange {
    /// Clé serveur visée : deux changements de même clé s'écrasent.
    var serverKey: String {
        switch self {
        case .notifyAntennaDown: return "notifyAntennaDown"
        case .notifyDegraded: return "notifyDegraded"
        case .radius: return "radius"
        case .maxPerDay: return "maxPerDay"
        case .watchedOperators: return "watchedOperators"
        case .quietHours, .quietHoursOff: return "quietHours"
        }
    }
}

/// Pannes près de mes lieux (plan 3, vague 2) : ce qui déclenche une alerte,
/// à quelle distance d'un lieu, pour quels opérateurs, et quand se taire.
struct ZoneAlertSettingsView: View {
    @StateObject private var model: ZoneAlertSettingsModel
    @EnvironmentObject private var services: AppServices

    init(service: ZoneAlertService) {
        _model = StateObject(wrappedValue: ZoneAlertSettingsModel(service: service))
    }

    var body: some View {
        List {
            if let settings = model.settings {
                content(settings)
            } else if model.isLoading {
                SQSpinner()
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }
            if let error = model.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(SQColor.dangerInk)
                        .accessibilityIdentifier("zoneAlerts.error")
                    if model.settings == nil {
                        Button("Réessayer") { Task { await model.load() } }
                            .foregroundStyle(SQColor.accentInk)
                            .accessibilityIdentifier("zoneAlerts.retry")
                    }
                }
                .listRowBackground(SQColor.dangerSoft)
            }
        }
        .scrollContentBackground(.hidden)
        .sqReadableWidth()
        .signalQuestBackground()
        .navigationTitle("Pannes près de mes lieux")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.load() }
        .task { if model.settings == nil { await model.load() } }
    }

    @ViewBuilder
    private func content(_ settings: ZoneAlertSettings) -> some View {
        let preferences = settings.preferences
        Section {
            toggle("Une panne", isOn: preferences.notifyAntennaDown, id: "zoneAlerts.down") { .notifyAntennaDown($0) }
            toggle("Un réseau dégradé", isOn: preferences.notifyDegraded, id: "zoneAlerts.degraded") { .notifyDegraded($0) }
        } header: {
            Text("Me prévenir pour")
        } footer: {
            Text("Quand la communauté signale un problème près d’un de tes lieux. Chaque réglage s’enregistre dès que tu le changes.")
        }
        .modifier(SettingsSectionStyle())

        Section {
            Picker("Distance d’un lieu", selection: Binding(
                get: { preferences.notificationRadiusMeters },
                set: { meters in Task { await model.apply(.radius(meters)) } }
            )) {
                ForEach(settings.capabilities.notificationRadiusOptionsMeters, id: \.self) { meters in
                    Text(verbatim: SQUnits.distance(meters: Double(meters))).tag(meters)
                }
            }
            .accessibilityIdentifier("zoneAlerts.radius")
            NavigationLink {
                PrivacySettingsView(service: services.privacy)
            } label: {
                Label("Mes lieux", systemImage: "mappin.and.ellipse")
            }
            .accessibilityIdentifier("zoneAlerts.places")
        } header: {
            Text("Autour de mes lieux")
        } footer: {
            Text("Tes lieux sont les zones de Confidentialité.")
        }
        .modifier(SettingsSectionStyle())

        Section {
            ForEach(settings.capabilities.supportedOperators, id: \.self) { key in
                operatorRow(key, watched: preferences.watchedOperators)
            }
        } header: {
            Text("Opérateurs")
        } footer: {
            Text("Aucun opérateur coché : toutes les pannes. Deux au plus.")
        }
        .modifier(SettingsSectionStyle())

        Section {
            Toggle("Heures calmes", isOn: Binding(
                get: { preferences.quietHoursStart != nil },
                set: { on in Task { await model.apply(on ? .quietHours(start: 22, end: 7) : .quietHoursOff) } }
            ))
            .frame(minHeight: 44)
            .accessibilityIdentifier("zoneAlerts.quietHours")
            if let start = preferences.quietHoursStart, let end = preferences.quietHoursEnd {
                hourPicker("De", hour: start, id: "zoneAlerts.quietFrom") { .quietHours(start: $0, end: end) }
                hourPicker("À", hour: end, id: "zoneAlerts.quietTo") { .quietHours(start: start, end: $0) }
            }
            Stepper(value: Binding(
                get: { preferences.maxNotificationsPerDay },
                set: { count in Task { await model.apply(.maxPerDay(count)) } }
            ), in: ZoneAlertPreferences.maxPerDayRange) {
                Text("Maximum par jour : \(preferences.maxNotificationsPerDay)")
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier("zoneAlerts.maxPerDay")
        } header: {
            Text("Moments calmes")
        }
        .modifier(SettingsSectionStyle())
    }

    private func toggle(_ title: LocalizedStringKey, isOn: Bool, id: String, change: @escaping (Bool) -> ZoneAlertChange) -> some View {
        Toggle(title, isOn: Binding(get: { isOn }, set: { value in Task { await model.apply(change(value)) } }))
            .frame(minHeight: 44)
            .accessibilityIdentifier(id)
    }

    private func operatorRow(_ key: String, watched: [String]) -> some View {
        let isWatched = watched.contains(key)
        let isFull = watched.count >= ZoneAlertPreferences.maxWatchedOperators
        return Button {
            let updated = isWatched ? watched.filter { $0 != key } : watched + [key]
            Task { await model.apply(.watchedOperators(updated)) }
        } label: {
            HStack {
                Text(verbatim: SentinelleListOrder.displayOperator(key))
                    .foregroundStyle(SQColor.label)
                Spacer()
                if isWatched {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(SQColor.accentInk)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Deux déjà cochés : les autres attendent qu'on en décoche un.
        .disabled(!isWatched && isFull)
        .accessibilityAddTraits(isWatched ? .isSelected : [])
        .accessibilityIdentifier("zoneAlerts.operator.\(key)")
    }

    private func hourPicker(_ title: LocalizedStringKey, hour: Int, id: String, change: @escaping (Int) -> ZoneAlertChange) -> some View {
        Picker(title, selection: Binding(get: { hour }, set: { value in Task { await model.apply(change(value)) } })) {
            ForEach(0..<24, id: \.self) { value in
                Text(verbatim: Self.hourLabel(value)).tag(value)
            }
        }
        .frame(minHeight: 44)
        .accessibilityIdentifier(id)
    }

    /// « 22 h » en français, « 10 PM » en anglais.
    nonisolated static func hourLabel(_ hour: Int, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let date = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: hour)) ?? Date()
        return date.formatted(.dateTime.hour().locale(locale))
    }
}

/// Fond et couleurs des sections, comme l'écran Notifications.
private struct SettingsSectionStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .tint(SQColor.brandRed)
            .foregroundStyle(SQColor.label)
            .listRowBackground(SQColor.surface)
    }
}
