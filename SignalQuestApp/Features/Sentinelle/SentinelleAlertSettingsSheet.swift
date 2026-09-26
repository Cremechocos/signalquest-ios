import SwiftUI

/// Réglages d'alerte et webhook.
///
/// Le bouton d'essai est la raison d'être de cet écran : un webhook mal formé
/// échouait EN SILENCE — Discord refuse un corps sans `content` ni `embeds` et
/// répond 400, mais ce refus se perdait dans les journaux du serveur. On affiche
/// donc le code HTTP réel du destinataire, pas un « c'est fait ».
struct SentinelleAlertSettingsSheet: View {
    let service: SentinellePreferencesServicing

    @Environment(\.dismiss) private var dismiss

    @State private var edits: SentinellePreferenceEditQueue?
    @State private var webhookDraft = ""
    @State private var isSaving = false
    @State private var isTesting = false
    @State private var verdict: SentinelleWebhookTest?
    @State private var loadFailed = false
    @State private var saveError: String?
    @State private var validationError: String?

    var body: some View {
        NavigationStack {
            Group {
                if let edits {
                    form(edits.draft)
                } else if loadFailed {
                    ErrorStateView(title: "Réglages indisponibles", message: "Réessayez dans un instant.") {
                        Task { await load() }
                    }
                    .padding(SQSpace.lg)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Alertes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                #if DEBUG && targetEnvironment(simulator)
                if AppEnvironment.showsSentinelleAlertSettingsQA {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Actualiser QA") { Task { await load() } }
                            .accessibilityIdentifier("sentinelle.qa.refresh")
                    }
                }
                #endif
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Terminé") { dismiss() }.tint(SQColor.brandRed)
                }
            }
        }
        .task { await load() }
    }

    /// Seuils proposés, identiques au web et à Android. 5 s en tête : c'est le
    /// plancher que la sonde sait tenir, sa boucle tournant toutes les 5 s.
    private static let thresholds = [5, 30, 120, 300, 900]

    @ViewBuilder
    private func form(_ current: SentinellePreferences) -> some View {
        Form {
            if isSaving {
                Section { ProgressView("Enregistrement en cours") }
            }
            if let message = validationError ?? saveError {
                Section {
                    Text(message)
                        .foregroundStyle(SQColor.dangerInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("sentinelle.save.error")
                    if saveError != nil, edits?.next != nil {
                        Button("Réessayer") { Task { await flush() } }
                            .frame(minHeight: 44)
                            .disabled(isSaving)
                            .accessibilityIdentifier("sentinelle.save.retry")
                    }
                }
            }
            Section {
                Toggle("Me prévenir en cas de coupure", isOn: Binding(
                    get: { current.notifyDown },
                    set: { value in save(SentinellePreferencesPatch(notifyDown: value)) }
                ))
                .accessibilityIdentifier("sentinelle.notifyDown")
                // Le seuil n'était qu'AFFICHÉ en pied de section, alors que le
                // patch le supporte, que l'API l'accepte depuis 5 s et que le web
                // le règle. Il compte plus qu'il n'y paraît : un redémarrage de
                // box dure vingt à quarante secondes, donc au seuil d'une minute
                // l'événement le plus courant ne déclenche jamais rien.
                if current.notifyDown {
                    Picker("Seuil de coupure", selection: Binding(
                        get: { current.downThresholdSec },
                        set: { value in save(SentinellePreferencesPatch(downThresholdSec: value)) }
                    )) {
                        ForEach(Self.thresholds, id: \.self) { seconds in
                            Text(formatSeconds(seconds)).tag(seconds)
                        }
                    }
                }
                Toggle("Me prévenir au rétablissement", isOn: Binding(
                    get: { current.notifyUp },
                    set: { value in save(SentinellePreferencesPatch(notifyUp: value)) }
                ))
                .accessibilityIdentifier("sentinelle.notifyUp")
            } header: {
                Text("Notifications")
            } footer: {
                Text("Une coupure plus courte que ce seuil est enregistrée dans l’historique "
                     + "sans déclencher d’alerte.")
            }

            Section {
                TextField("https://discord.com/api/webhooks/…", text: $webhookDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(SQFont.body(14))
                    .accessibilityIdentifier("sentinelle.webhook.input")
                    .onChangeCompat(of: webhookDraft) { _, _ in
                        validationError = nil
                        verdict = nil
                    }

                Button(webhookDraft.trimmingCharacters(in: .whitespaces).isEmpty
                       ? "Retirer le webhook" : "Enregistrer") {
                    let value = webhookDraft.trimmingCharacters(in: .whitespaces)
                    guard value.isEmpty || Self.validWebhookURL(value) else {
                        validationError = String(localized: "Adresse de webhook invalide. Utilise une URL http(s) complète.")
                        return
                    }
                    verdict = nil
                    save(SentinellePreferencesPatch(webhookUrl: .some(value.isEmpty ? nil : value)))
                }
                .disabled(webhookDraft.trimmingCharacters(in: .whitespaces) == (current.webhookUrl ?? ""))
                .accessibilityIdentifier("sentinelle.webhook.save")

                if edits?.confirmed.webhookUrl != nil {
                    let canTest = edits?.canTestWebhook(webhookDraft, isSaving: isSaving) == true
                    Button(isTesting ? "Envoi…" : "Envoyer un message d’essai") {
                        Task { await test() }
                    }
                    .disabled(isTesting || !canTest)
                    .accessibilityIdentifier("sentinelle.webhook.test")
                    if !canTest {
                        Text("Enregistre l’adresse avant de tester le webhook.")
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                }

                if let verdict {
                    // Le verdict reste DANS la section, sous le champ : on le lit
                    // pendant qu'on corrige l'URL juste au-dessus.
                    Text(verdict.message)
                        .font(SQFont.body(12))
                        .foregroundStyle(verdict.ok ? SQColor.labelSecondary : SQColor.danger)
                        .accessibilityIdentifier("sentinelle.webhook.verdict")
                }
            } header: {
                Text("Webhook")
            } footer: {
                Text("Discord, Slack et ntfy sont reconnus à leur adresse et reçoivent leur format. "
                     + "Les autres destinataires reçoivent un appel signé.")
            }
        }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            let response = try await service.preferences()
            if var current = edits {
                current.refresh(response.preferences)
                edits = current
            } else {
                edits = SentinellePreferenceEditQueue(response.preferences)
                webhookDraft = response.preferences.webhookUrl ?? ""
            }
            loadFailed = false
        } catch {
            loadFailed = true
        }
    }

    private func save(_ changes: SentinellePreferencesPatch) {
        guard var current = edits else { return }
        current.enqueue(changes)
        edits = current
        saveError = nil
        Task { await flush() }
    }

    private func flush() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        while let changes = edits?.next {
            do {
                let response = try await service.savePreferences(changes)
                guard var current = edits else { return }
                let submittedURL = current.draft.webhookUrl ?? ""
                current.acknowledge(response.preferences)
                edits = current
                if current.next == nil,
                   webhookDraft.trimmingCharacters(in: .whitespaces) == submittedURL {
                    webhookDraft = response.preferences.webhookUrl ?? ""
                }
                saveError = nil
            } catch {
                // La tête de file et tous les choix suivants restent visibles.
                saveError = String(localized: "Enregistrement non confirmé. Vérifie les valeurs et réessaie.")
                return
            }
        }
    }

    static func validWebhookURL(_ value: String) -> Bool {
        guard value.count <= 500, !value.contains(where: { $0.isWhitespace }),
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty else { return false }
        return true
    }

    private func test() async {
        guard let savedURL = edits?.confirmed.webhookUrl,
              edits?.canTestWebhook(webhookDraft, isSaving: isSaving) == true else { return }
        isTesting = true
        defer { isTesting = false }
        do {
            let response = try await service.testWebhook()
            guard edits?.confirmed.webhookUrl == savedURL,
                  edits?.canTestWebhook(webhookDraft, isSaving: isSaving) == true else { return }
            verdict = response
        } catch {
            guard edits?.confirmed.webhookUrl == savedURL,
                  edits?.canTestWebhook(webhookDraft, isSaving: isSaving) == true else { return }
            verdict = SentinelleWebhookTest(
                ok: false, status: nil, destination: nil,
                message: String(localized: "L’essai n’a pas pu être lancé.")
            )
        }
    }

    private func formatSeconds(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) s" }
        let minutes = seconds / 60
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h"
    }
}

/// Un reçu PATCH fait autorité ; les choix faits pendant son trajet restent en
/// file et s'appliquent au reçu suivant. Un GET ne détruit jamais cette file.
struct SentinellePreferenceEditQueue {
    private(set) var confirmed: SentinellePreferences
    private(set) var draft: SentinellePreferences
    private var pending: [SentinellePreferencesPatch] = []

    init(_ initial: SentinellePreferences) {
        confirmed = initial
        draft = initial
    }

    var next: SentinellePreferencesPatch? { pending.first }

    func canTestWebhook(_ entered: String, isSaving: Bool) -> Bool {
        guard !isSaving, pending.isEmpty,
              let saved = confirmed.webhookUrl else { return false }
        return entered.trimmingCharacters(in: .whitespaces) == saved
    }

    mutating func enqueue(_ changes: SentinellePreferencesPatch) {
        pending.append(changes)
        draft = Self.applying(changes, to: draft)
    }

    mutating func acknowledge(_ saved: SentinellePreferences) {
        if !pending.isEmpty { pending.removeFirst() }
        refresh(saved)
    }

    mutating func refresh(_ saved: SentinellePreferences) {
        confirmed = saved
        draft = pending.reduce(saved) { Self.applying($1, to: $0) }
    }

    private static func applying(_ changes: SentinellePreferencesPatch, to value: SentinellePreferences) -> SentinellePreferences {
        SentinellePreferences(
            notifyDown: changes.notifyDown ?? value.notifyDown,
            notifyUp: changes.notifyUp ?? value.notifyUp,
            downThresholdSec: changes.downThresholdSec ?? value.downThresholdSec,
            webhookUrl: changes.webhookUrl ?? value.webhookUrl
        )
    }
}

#if DEBUG && targetEnvironment(simulator)
/// Banc isolé : mêmes vues et modèle de file, sans compte ni destinataire réel.
actor SentinelleAlertPreferencesQAFixture: SentinellePreferencesServicing {
    private var saved = SentinellePreferences(
        notifyDown: true, notifyUp: false, downThresholdSec: 30,
        webhookUrl: nil
    )
    private let rejectionStatus: Int
    private var remainingRejections: Int

    init(rejectNextPatch status: Int) {
        rejectionStatus = status
        remainingRejections = status == 503 ? 2 : 1
    }

    func preferences() async throws -> SentinellePreferencesResponse {
        SentinellePreferencesResponse(preferences: saved)
    }

    func savePreferences(_ changes: SentinellePreferencesPatch) async throws -> SentinellePreferencesResponse {
        try await Task.sleep(nanoseconds: 600_000_000)
        if remainingRejections > 0 {
            remainingRejections -= 1
            throw APIError.http(status: rejectionStatus, code: nil, message: "QA refusal", requestId: nil, retryAfter: nil)
        }
        saved = SentinellePreferences(
            notifyDown: changes.notifyDown ?? saved.notifyDown,
            notifyUp: changes.notifyUp ?? saved.notifyUp,
            downThresholdSec: changes.downThresholdSec ?? saved.downThresholdSec,
            webhookUrl: changes.webhookUrl ?? saved.webhookUrl
        )
        return SentinellePreferencesResponse(preferences: saved)
    }

    func testWebhook() async throws -> SentinelleWebhookTest {
        SentinelleWebhookTest(
            ok: false, status: 400, destination: "synthetic",
            message: "Webhook synthétique refusé · HTTP 400"
        )
    }
}
#endif

struct SentinelleAlertSettingsQAScreen: View {
    #if DEBUG && targetEnvironment(simulator)
    @State private var fixture: SentinelleAlertPreferencesQAFixture
    @State private var showsSettings = true

    init() {
        let status = Int(ProcessInfo.processInfo.environment["SQ_QA_SENTINELLE_PATCH_STATUS"] ?? "400") ?? 400
        _fixture = State(initialValue: SentinelleAlertPreferencesQAFixture(rejectNextPatch: status))
    }
    #endif

    var body: some View {
        #if DEBUG && targetEnvironment(simulator)
        NavigationStack {
            Button("Ouvrir les réglages d’alerte") { showsSettings = true }
                .accessibilityIdentifier("sentinelle.qa.open")
                .frame(minHeight: 44)
                .navigationTitle("Sentinelle QA")
        }
        .sheet(isPresented: $showsSettings) {
            SentinelleAlertSettingsSheet(service: fixture)
        }
        #else
        EmptyView()
        #endif
    }
}
