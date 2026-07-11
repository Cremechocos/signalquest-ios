import SwiftUI

struct ReportSheet: View {
    let targetType: String
    let targetId: String
    let service: ReportsServicing
    @Environment(\.dismiss) private var dismiss
    @State private var reason: ReportReason = .spam
    @State private var note: String = ""
    @State private var isBusy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Motif") {
                    Picker("Raison", selection: $reason) {
                        ForEach(ReportReason.allCases) { value in
                            Text(value.label).tag(value)
                        }
                    }
                    .pickerStyle(.inline)
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
                        .foregroundStyle(SQColor.danger)
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
            try await service.report(
                targetType: targetType,
                targetId: targetId,
                reason: reason,
                comment: note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : note
            )
            Haptics.success()
            dismiss()
        } catch {
            self.error = error.localizedDescription
            Haptics.error()
        }
    }
}
