import SwiftUI

/// Formulaire d'émission d'un signalement sur une antenne, présenté depuis la
/// fiche antenne (`AntennaDetailSheet`). Calqué sur `ReportSheet` (Form natif,
/// fond crème) pour rester cohérent avec le reste de l'app.
struct AntennaReportSheet: View {
    let siteId: String
    let siteLabel: String
    /// Azimuts connus du site (degrés arrondis) proposés comme « secteur concerné ».
    let availableSectors: [Int]
    let service: AntennaReportsServicing

    @Environment(\.dismiss) private var dismiss

    @State private var reportType: AntennaReportType = .other
    @State private var reason: String = ""
    @State private var currentValue: String = ""
    @State private var suggestedValue: String = ""
    @State private var sector: Int?
    @State private var isBusy = false
    @State private var error: String?
    @State private var duplicateMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(selection: $reportType) {
                        ForEach(AntennaReportType.allCases) { type in
                            Label(type.label, systemImage: type.systemImage).tag(type)
                        }
                    } label: {
                        Label("Type de problème", systemImage: "exclamationmark.triangle")
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text("Que veux-tu signaler ?")
                } footer: {
                    Text("Site \(siteLabel). Ton signalement est envoyé à l'équipe de modération, qui pourra te répondre.")
                        .font(SQType.caption)
                }
                .listRowBackground(SQColor.surface)

                if reportType.suggestsValues {
                    Section("Correction proposée (optionnel)") {
                        TextField("Valeur actuelle affichée", text: $currentValue, axis: .vertical)
                            .lineLimit(1...3)
                        TextField("Valeur correcte selon toi", text: $suggestedValue, axis: .vertical)
                            .lineLimit(1...3)
                    }
                    .foregroundStyle(SQColor.label)
                    .listRowBackground(SQColor.surface)
                }

                if !availableSectors.isEmpty {
                    Section("Secteur concerné (optionnel)") {
                        Picker(selection: $sector) {
                            Text("Non précisé").tag(Int?.none)
                            ForEach(availableSectors, id: \.self) { deg in
                                Text("Secteur \(deg)°").tag(Int?.some(deg))
                            }
                        } label: {
                            Label("Secteur", systemImage: "safari")
                        }
                        .pickerStyle(.menu)
                    }
                    .foregroundStyle(SQColor.label)
                    .listRowBackground(SQColor.surface)
                }

                Section("Précisions (optionnel)") {
                    TextField("Décris ce qui ne va pas", text: $reason, axis: .vertical)
                        .lineLimit(3...6)
                }
                .foregroundStyle(SQColor.label)
                .listRowBackground(SQColor.surface)

                if let duplicateMessage {
                    Section {
                        Label(duplicateMessage, systemImage: "checkmark.circle")
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.success)
                    }
                    .listRowBackground(SQColor.successSoft)
                }

                if let error {
                    Section { Text(error).foregroundStyle(SQColor.danger) }
                        .listRowBackground(SQColor.dangerSoft)
                }

                Section {
                    Button {
                        Task { await send() }
                    } label: {
                        HStack {
                            if isBusy {
                                ProgressView().tint(SQColor.brandRed)
                            } else {
                                Text("Envoyer le signalement")
                                    .font(SQType.button)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(SQColor.brandRed)
                    }
                    .disabled(isBusy)
                    .listRowBackground(SQColor.accentSoft)
                }
            }
            .scrollContentBackground(.hidden)
            .signalQuestBackground()
            .navigationTitle("Signaler un problème")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(duplicateMessage == nil ? "Annuler" : "Fermer") { dismiss() }
                        .tint(SQColor.brandRed)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func send() async {
        isBusy = true
        error = nil
        duplicateMessage = nil
        defer { isBusy = false }
        do {
            let result = try await service.submit(
                siteId: siteId,
                reportType: reportType,
                currentValue: currentValue,
                suggestedValue: suggestedValue,
                reason: reason,
                sector: sector
            )
            Haptics.success()
            if result.duplicate == true {
                // Déjà signalé ce type pour ce site (HTTP 200) : on le dit sans
                // fermer, pour que l'utilisateur sache que c'est bien pris en compte.
                duplicateMessage = result.message ?? "Tu avais déjà signalé ce problème pour ce site. Merci !"
            } else {
                dismiss()
            }
        } catch {
            if error.isCancellation { return }
            self.error = error.localizedDescription
            Haptics.error()
        }
    }
}
