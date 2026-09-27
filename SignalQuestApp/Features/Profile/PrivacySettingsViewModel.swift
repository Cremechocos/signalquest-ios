import Foundation
import Combine

@MainActor
final class PrivacySettingsViewModel: ObservableObject {
    @Published var shareLiveLocationWithFriends = false
    @Published var shareRadioDataWithFriends = false
    @Published var shareSessionsWithFriends = false
    @Published var sharePhotosOnFriendMap = false
    @Published var liveShareMode: LiveShareMode = LiveShareModeStore.load()
    @Published var lastSeenVisibility: LastSeenVisibility = .none
    @Published var messageRequestPolicy: MessageRequestPolicy = .friendsOnly
    @Published private(set) var isLoadingPrivacy = false
    @Published private(set) var isLoadingPreferences = false
    @Published private(set) var isLoadingZones = false
    @Published private(set) var isSaving = false
    @Published private(set) var isSavingPreferences = false
    @Published private(set) var loaded = false
    @Published private(set) var preferencesLoaded = false
    @Published private(set) var zonesLoaded = false
    @Published private(set) var privacyError: String?
    @Published private(set) var preferencesError: String?
    @Published private(set) var zonesError: String?
    @Published private(set) var zoneMutationError: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var savedConfirmation = false
    @Published private(set) var preferences = UserPreferences()
    @Published private(set) var zones: [PrivacyZone] = []
    @Published private(set) var zoneBusyId: String?
    weak var unitsStore: SQUnitsStore?

    var canSavePrivacy: Bool {
        isSessionCurrent && loaded && !isLoadingPrivacy && !isSaving && hasPrivacyChanges
    }

    var isLoading: Bool { isLoadingPrivacy || isLoadingPreferences || isLoadingZones }
    var declaredZones: [PrivacyZone] { zones.filter { !$0.isAutoDetected } }
    var detectedZones: [PrivacyZone] { zones.filter(\.isAutoDetected) }
    var hiddenDetectedCount: Int { detectedZones.filter { $0.isActive && $0.hideSpeedtestsOnMap }.count }
    var isSessionCurrent: Bool { owner != nil && sessionSnapshot() == owner }

    private let service: PrivacyServicing
    private let sessionSnapshot: () -> LocalAccountSession?
    private let owner: LocalAccountSession?
    private var privacyBaseline: SocialPrivacy?
    private var privacyLoadID = UUID()
    private var preferencesLoadID = UUID()
    private var zonesLoadID = UUID()
    private var invalidated = false

    init(service: PrivacyServicing, sessionSnapshot: @escaping () -> LocalAccountSession? = LocalAccountScope.sessionSnapshot) {
        self.sessionSnapshot = sessionSnapshot
        owner = sessionSnapshot()
        self.service = owner.map { service.scoped(to: $0) } ?? service
    }

    func load() async {
        async let privacy: Void = loadPrivacy()
        async let preferences: Void = loadPreferences()
        async let zones: Void = loadZones()
        _ = await (privacy, preferences, zones)
    }

    func sessionDidChange() { _ = checkSession() }

    func loadPrivacy() async {
        guard checkSession(), !isSaving else { return }
        // Une actualisation ne remplace pas un brouillon encore non enregistré.
        if loaded && hasPrivacyChanges { return }
        let ticket = UUID(); privacyLoadID = ticket
        isLoadingPrivacy = true; privacyError = nil
        defer { if privacyLoadID == ticket { isLoadingPrivacy = false } }
        do {
            let value = try await service.get()
            guard checkSession(), privacyLoadID == ticket else { return }
            apply(value); privacyBaseline = value; loaded = true
        } catch {
            guard checkSession(), privacyLoadID == ticket, !error.isCancellation else { return }
            privacyError = error.localizedDescription
        }
    }

    func loadPreferences() async {
        guard checkSession(), !isSavingPreferences else { return }
        let ticket = UUID(); preferencesLoadID = ticket
        isLoadingPreferences = true; preferencesError = nil
        defer { if preferencesLoadID == ticket { isLoadingPreferences = false } }
        do {
            let value = try await service.preferences()
            guard checkSession(), preferencesLoadID == ticket else { return }
            preferences = value; preferencesLoaded = true
            unitsStore?.apply(value.unitsSystem)
        } catch {
            guard checkSession(), preferencesLoadID == ticket, !error.isCancellation else { return }
            preferencesError = error.localizedDescription
        }
    }

    func loadZones() async {
        guard checkSession(), zoneBusyId == nil else { return }
        let ticket = UUID(); zonesLoadID = ticket
        isLoadingZones = true; zonesError = nil
        defer { if zonesLoadID == ticket { isLoadingZones = false } }
        do {
            let value = try await service.zones()
            guard checkSession(), zonesLoadID == ticket else { return }
            zones = value; zonesLoaded = true
        } catch {
            guard checkSession(), zonesLoadID == ticket, !error.isCancellation else { return }
            zonesError = error.localizedDescription
        }
    }

    func setUnits(_ system: SQUnitsSystem) async {
        guard system != preferences.unitsSystem else { return }
        await updatePreferences(UserPreferencesPatch(unitsSystem: system))
    }

    func setShowHandleOnLeaderboard(_ value: Bool) async {
        guard value != preferences.showHandleOnLeaderboard else { return }
        await updatePreferences(UserPreferencesPatch(showHandleOnLeaderboard: value))
    }

    func setShowHypothesisSystem(_ value: Bool) async {
        guard value != preferences.showHypothesisSystem else { return }
        await updatePreferences(UserPreferencesPatch(showHypothesisSystem: value))
    }

    private func updatePreferences(_ patch: UserPreferencesPatch) async {
        guard checkSession(), preferencesLoaded, !isLoadingPreferences, !isSavingPreferences else { return }
        isSavingPreferences = true; errorMessage = nil
        defer { isSavingPreferences = false }
        do {
            let value = try await service.updatePreferences(patch)
            guard checkSession() else { return }
            preferences = value
            preferencesError = nil
            unitsStore?.apply(value.unitsSystem)
            Haptics.success()
        } catch {
            guard checkSession(), !error.isCancellation else { return }
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }

    func setZoneHidden(_ zone: PrivacyZone, hidden: Bool) async {
        guard beginZoneMutation(id: zone.id) else { return }
        defer { zoneBusyId = nil }
        do {
            // Activer la protection d'une suggestion/zone en pause la confirme
            // explicitement. La désactivation ne touche pas ses autres usages.
            let value = try await service.updateZone(UpdatePrivacyZoneRequest(id: zone.id,
                isActive: hidden && !zone.isActive ? true : nil, hideSpeedtestsOnMap: hidden))
            guard checkSession() else { return }
            replaceZone(value)
            Haptics.success()
        } catch { handleZoneMutationError(error) }
    }

    func saveZone(_ draft: PrivacyZoneDraft, original: PrivacyZone?) async -> Bool {
        guard beginZoneMutation(id: original?.id) else { return false }
        defer { zoneBusyId = nil }
        do {
            try draft.validate()
            let value: PrivacyZone
            if let original {
                value = try await service.updateZone(draft.updateRequest(original: original))
            } else {
                value = try await service.createZone(draft.createRequest())
            }
            guard checkSession() else { return false }
            replaceZone(value)
            Haptics.success()
            return true
        } catch { handleZoneMutationError(error); return false }
    }

    func deleteZone(_ zone: PrivacyZone) async -> Bool {
        guard beginZoneMutation(id: zone.id) else { return false }
        defer { zoneBusyId = nil }
        do {
            try await service.deleteZone(id: zone.id)
            guard checkSession() else { return false }
            zones.removeAll { $0.id == zone.id }
            Haptics.success()
            return true
        } catch { handleZoneMutationError(error); return false }
    }

    private func beginZoneMutation(id: String?) -> Bool {
        guard checkSession(), zonesLoaded, !isLoadingZones, zoneBusyId == nil else { return false }
        if let id, !zones.contains(where: { $0.id == id }) {
            zoneMutationError = String(localized: "Cette zone n’est plus disponible. Actualise la liste.")
            return false
        }
        zoneBusyId = id ?? "new"
        zoneMutationError = nil
        return true
    }

    private func replaceZone(_ zone: PrivacyZone) {
        if let index = zones.firstIndex(where: { $0.id == zone.id }) { zones[index] = zone }
        else { zones.append(zone) }
        zonesError = nil
    }

    private func handleMutationError(_ error: Error) {
        guard checkSession(), !error.isCancellation else { return }
        errorMessage = error.localizedDescription
        Haptics.error()
    }

    private func handleZoneMutationError(_ error: Error) {
        guard checkSession(), !error.isCancellation else { return }
        zoneMutationError = error.localizedDescription
        Haptics.error()
    }

    @discardableResult
    func save() async -> Bool {
        savedConfirmation = false
        guard checkSession(), canSavePrivacy, let baseline = privacyBaseline else { return false }
        isSaving = true; errorMessage = nil
        defer { isSaving = false }
        let sent = currentPrivacy
        let patch = UpdatePrivacyRequest(
            shareLiveLocationWithFriends: sent.shareLiveLocationWithFriends == baseline.shareLiveLocationWithFriends ? nil : sent.shareLiveLocationWithFriends,
            shareRadioDataWithFriends: sent.shareRadioDataWithFriends == baseline.shareRadioDataWithFriends ? nil : sent.shareRadioDataWithFriends,
            shareSessionsWithFriends: sent.shareSessionsWithFriends == baseline.shareSessionsWithFriends ? nil : sent.shareSessionsWithFriends,
            sharePhotosOnFriendMap: sent.sharePhotosOnFriendMap == baseline.sharePhotosOnFriendMap ? nil : sent.sharePhotosOnFriendMap,
            lastSeenVisibility: sent.lastSeenVisibility == baseline.lastSeenVisibility ? nil : sent.lastSeenVisibility,
            messageRequestPolicy: sent.messageRequestPolicy == baseline.messageRequestPolicy ? nil : sent.messageRequestPolicy)
        do {
            // Seul un reçu serveur frais peut autoriser la propagation locale.
            // Le baseline pourrait avoir été révoqué depuis un autre client.
            let value = try await service.update(patch)
            guard checkSession() else { return false }
            // Une nouvelle saisie effectuée pendant le réseau reste un brouillon.
            if currentPrivacy == sent { apply(value) }
            privacyBaseline = value
            savedConfirmation = !hasPrivacyChanges
            Haptics.success()
            return savedConfirmation
        } catch { handleMutationError(error); return false }
    }

    private var currentPrivacy: SocialPrivacy {
        SocialPrivacy(shareLiveLocationWithFriends: shareLiveLocationWithFriends,
            shareRadioDataWithFriends: shareRadioDataWithFriends, shareSessionsWithFriends: shareSessionsWithFriends,
            sharePhotosOnFriendMap: sharePhotosOnFriendMap, shareExactMeasurements: true,
            lastSeenVisibility: lastSeenVisibility, messageRequestPolicy: messageRequestPolicy)
    }

    private var hasPrivacyChanges: Bool {
        guard let baseline = privacyBaseline else { return false }
        return currentPrivacy.shareLiveLocationWithFriends != baseline.shareLiveLocationWithFriends
            || currentPrivacy.shareRadioDataWithFriends != baseline.shareRadioDataWithFriends
            || currentPrivacy.shareSessionsWithFriends != baseline.shareSessionsWithFriends
            || currentPrivacy.sharePhotosOnFriendMap != baseline.sharePhotosOnFriendMap
            || currentPrivacy.lastSeenVisibility != baseline.lastSeenVisibility
            || currentPrivacy.messageRequestPolicy != baseline.messageRequestPolicy
    }

    private func apply(_ p: SocialPrivacy) {
        shareLiveLocationWithFriends = p.shareLiveLocationWithFriends
        shareRadioDataWithFriends = p.shareRadioDataWithFriends
        shareSessionsWithFriends = p.shareSessionsWithFriends
        sharePhotosOnFriendMap = p.sharePhotosOnFriendMap
        lastSeenVisibility = p.lastSeenVisibility
        messageRequestPolicy = p.messageRequestPolicy
    }

    private func checkSession() -> Bool {
        guard !Task.isCancelled else { return false }
        guard isSessionCurrent else {
            if !invalidated {
                invalidated = true
                privacyLoadID = UUID(); preferencesLoadID = UUID(); zonesLoadID = UUID()
                isLoadingPrivacy = false; isLoadingPreferences = false; isLoadingZones = false
                loaded = false; preferencesLoaded = false; zonesLoaded = false
                zones = []; preferences = UserPreferences(); privacyBaseline = nil
                shareLiveLocationWithFriends = false; shareRadioDataWithFriends = false
                shareSessionsWithFriends = false; sharePhotosOnFriendMap = false
                lastSeenVisibility = .none; messageRequestPolicy = .friendsOnly
                errorMessage = String(localized: "La session a changé. Rouvre les réglages de confidentialité.")
            }
            return false
        }
        return true
    }
}
