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

    @State private var preferences: SentinellePreferences?
    @State private var webhookDraft = ""
    @State private var isSaving = false
    @State private var isTesting = false
    @State private var verdict: SentinelleWebhookTest?
    @State private var loadFailed = false

    var body: some View {
        NavigationStack {
            Group {
                if let preferences {
                    form(preferences)
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

                Button(webhookDraft.trimmingCharacters(in: .whitespaces).isEmpty
                       ? "Retirer le webhook" : "Enregistrer") {
                    let value = webhookDraft.trimmingCharacters(in: .whitespaces)
                    verdict = nil
                    save(SentinellePreferencesPatch(webhookUrl: .some(value.isEmpty ? nil : value)))
                }
                .disabled(isSaving || webhookDraft.trimmingCharacters(in: .whitespaces) == (current.webhookUrl ?? ""))

                if current.webhookUrl != nil {
                    Button(isTesting ? "Envoi…" : "Envoyer un message d’essai") {
                        Task { await test() }
                    }
                    .disabled(isTesting)
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
            preferences = response.preferences
            webhookDraft = response.preferences.webhookUrl ?? ""
            loadFailed = false
        } catch {
            loadFailed = true
        }
    }

    private func save(_ changes: SentinellePreferencesPatch) {
        Task {
            isSaving = true
            defer { isSaving = false }
            // On relit après écriture plutôt que de supposer : c'est le serveur
            // qui valide, et une URL refusée ne doit pas rester à l'écran comme
            // si elle avait été acceptée.
            try? await service.savePreferences(changes)
            await load()
        }
    }

    private func test() async {
        isTesting = true
        defer { isTesting = false }
        verdict = try? await service.testWebhook()
        if verdict == nil {
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
