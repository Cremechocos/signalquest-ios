import SwiftUI

/// Réglages d'alerte et webhook.
///
/// Le bouton d'essai est la raison d'être de cet écran : un webhook mal formé
/// échouait EN SILENCE — Discord refuse un corps sans `content` ni `embeds` et
/// répond 400, mais ce refus se perdait dans les journaux du serveur. On affiche
/// donc le code HTTP réel du destinataire, pas un « c'est fait ».
struct SentinelleAlertSettingsSheet: View {
    let service: SentinelleServicing

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
                    if saveError != nil, edits?.next != nil {
                        Button("Réessayer") { Task { await flush() } }
                            .frame(minHeight: 44)
                            .disabled(isSaving)
                    }
                }
            }
            Section {
                Toggle("Me prévenir en cas de coupure", isOn: Binding(
                    get: { current.notifyDown },
                    set: { value in save(SentinellePreferencesPatch(notifyDown: value)) }
                ))
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
                    .onChangeCompat(of: webhookDraft) { _, _ in
                        validationError = nil
                        verdict = nil
                    }

                Button(webhookDraft.trimmingCharacters(in: .whitespaces).isEmpty
                       ? "Retirer le webhook" : "Enregistrer") {
                    let value = webhookDraft.trimmingCharacters(in: .whitespaces)
                    guard value.isEmpty || Self.validWebhookURL(value) else {
                        validationError = "Adresse de webhook invalide. Utilise une URL http(s) complète."
                        return
                    }
                    verdict = nil
                    save(SentinellePreferencesPatch(webhookUrl: .some(value.isEmpty ? nil : value)))
                }
                .disabled(webhookDraft.trimmingCharacters(in: .whitespaces) == (current.webhookUrl ?? ""))

                if edits?.confirmed.webhookUrl != nil {
                    let canTest = edits?.canTestWebhook(webhookDraft, isSaving: isSaving) == true
                    Button(isTesting ? "Envoi…" : "Envoyer un message d’essai") {
                        Task { await test() }
                    }
                    .disabled(isTesting || !canTest)
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
                }
            } header: {
                Text("Webhook")
            } footer: {
                Text("Discord, Slack et ntfy sont reconnus à leur adresse et reçoivent leur format. "
                     + "Les autres destinataires reçoivent un appel signé.")
            }
        }
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
                saveError = "Enregistrement non confirmé. Vérifie les valeurs et réessaie."
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
                message: "L’essai n’a pas pu être lancé."
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
