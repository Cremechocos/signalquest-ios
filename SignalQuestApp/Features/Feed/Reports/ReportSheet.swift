import SwiftUI

struct ReportSheet: View {
    private let reasons: [ReportReason]
    private let notice: String?
    private let submit: @MainActor (ReportReason, String?) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var reason: ReportReason
    @State private var note: String = ""
    @State private var isBusy = false
    @State private var error: String?

    init(target: ReportTarget, service: ReportsServicing) {
        self.init(reasons: ReportReason.allCases) { reason, comment in
            try await service.report(target, reason: reason, comment: comment)
        }
    }

    /// Signalement hors `/api/social/reports` (messages) : l'appelant fournit
    /// l'envoi, les motifs proposés et, au besoin, ce qu'il faut savoir avant.
    init(
        reasons: [ReportReason],
        notice: String? = nil,
        submit: @escaping @MainActor (ReportReason, String?) async throws -> Void
    ) {
        self.reasons = reasons
        self.notice = notice
        self.submit = submit
        _reason = State(initialValue: reasons.first ?? .spam)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let notice {
                    Section {
                        Label(notice, systemImage: "lock")
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                }
                Section("Motif") {
                    Picker("Raison", selection: $reason) {
                        ForEach(reasons) { value in
                            Text(value.label).tag(value)
                        }
                    }
                    .pickerStyle(.inline)
                    // La section « Motif » nomme déjà la liste ; VoiceOver garde
                    // le libellé.
                    .labelsHidden()
                }
                Section("Précisions (optionnel)") {
                    TextField("Décris ce qui te pose problème", text: $note, axis: .vertical)
                        .lineLimit(3...6)
                }
                if let error {
                    Section { Text(error).foregroundStyle(SQColor.danger) }
                }
                Section {
                    Button(role: .destructive) {
                        Task { await send() }
                    } label: {
                        HStack {
                            if isBusy {
                                ProgressView().tint(SQColor.danger)
                            } else {
                                Text("Envoyer le signalement")
                                    .font(SQType.button)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(SQColor.dangerInk)
                    }
                    .disabled(isBusy)
                    .listRowBackground(SQColor.dangerSoft)
                }
            }
            .scrollContentBackground(.hidden)
            .signalQuestBackground()
            .navigationTitle("Signaler")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Annuler") { dismiss() }
                        .tint(SQColor.brandRed)
                }
            }
        }
    }

    private func send() async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await submit(reason, note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : note)
            Haptics.success()
            dismiss()
        } catch {
            self.error = error.userFacingMessage
            Haptics.error()
        }
    }
}
