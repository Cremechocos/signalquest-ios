import SwiftUI

@MainActor
final class CallHistoryViewModel: ObservableObject {
    @Published var calls: [CallSession] = []
    @Published var isLoading = false
    @Published var isLoadingMore = false
    @Published var errorMessage: String?

    private let service: CallsServicing
    private let pageSize = 20
    private var page = 1
    private var hasMore = true
    init(service: CallsServicing) { self.service = service }

    func load() async {
        // Stale-while-revalidate : afficher immédiatement la dernière liste connue
        // (cache disque) pour ne plus bloquer sur un spinner plein écran à chaque
        // visite, puis rafraîchir en arrière-plan.
        if calls.isEmpty {
            let cached = await service.cachedHistory()
            if !cached.isEmpty { calls = cached }
        }
        isLoading = calls.isEmpty
        defer { isLoading = false }
        errorMessage = nil
        do {
            let fresh = try await service.history(page: 1, limit: pageSize)
            calls = fresh
            page = 1
            hasMore = fresh.count >= pageSize
        } catch {
            // Ne montrer l'erreur que si on n'a rien à afficher (sinon on garde le cache).
            if !error.isCancellation && calls.isEmpty { errorMessage = error.localizedDescription }
        }
    }

    func loadMore() async {
        guard hasMore, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let next = try await service.history(page: page + 1, limit: pageSize)
            guard !next.isEmpty else { hasMore = false; return }
            let existing = Set(calls.map(\.id))
            calls.append(contentsOf: next.filter { !existing.contains($0.id) })
            page += 1
            hasMore = next.count >= pageSize
        } catch {
            // Silencieux : on conserve la liste déjà affichée.
        }
    }

    /// Efface tout l'historique (masquage « pour moi » côté serveur + cache local vidé).
    func clearHistory() async {
        do {
            try await service.clearHistory()
            calls = []
            page = 1
            hasMore = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Supprime un appel de MON historique (optimiste, rollback si le serveur échoue).
    func deleteEntry(_ call: CallSession) async {
        let previous = calls
        calls.removeAll { $0.id == call.id }
        do {
            try await service.deleteEntry(callId: call.id)
        } catch {
            calls = previous
            errorMessage = error.localizedDescription
        }
    }
}

struct CallHistoryView: View {
    @StateObject private var model: CallHistoryViewModel
    @State private var confirmingClear = false
    init(service: CallsServicing) {
        _model = StateObject(wrappedValue: CallHistoryViewModel(service: service))
    }

    var body: some View {
        List {
            Section {
                if model.isLoading && model.calls.isEmpty {
                    ProgressView().tint(SQColor.brandRed).frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                } else if let error = model.errorMessage, model.calls.isEmpty {
                    ErrorStateView(title: "Appels indisponibles", message: error) { Task { await model.load() } }
                        .listRowBackground(Color.clear)
                } else if model.calls.isEmpty {
                    EmptyStateView(title: "Aucun appel", message: "Tes appels apparaîtront ici.", systemImage: "phone.badge.waveform")
                        .listRowBackground(Color.clear)
                }
                ForEach(model.calls) { call in
                    let style = directionStyle(call)
                    HStack(spacing: SQSpace.md) {
                        Image(systemName: style.icon)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(style.color)
                            .frame(width: 38, height: 38)
                            .background(style.soft, in: Circle())
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(call.displayName ?? call.participants?.joined(separator: ", ") ?? "Conversation")
                                .font(SQFont.body(15, .medium))
                                .foregroundStyle(style.isMissed ? SQColor.danger : SQColor.label)
                            if let date = call.createdAt {
                                Text(date, format: .dateTime.day().month(.abbreviated).hour().minute())
                                    .font(SQType.caption)
                                    .foregroundStyle(SQColor.labelSecondary)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(statusLabel(call.status))
                                .font(SQType.caption)
                                .foregroundStyle(style.isMissed ? SQColor.danger : SQColor.labelSecondary)
                            if let duration = durationText(call) {
                                Text(duration)
                                    .font(SQType.micro)
                                    .monospacedDigit()
                                    .foregroundStyle(SQColor.labelTertiary)
                            }
                        }
                        Image(systemName: call.mode == "video" ? "video.fill" : "phone.fill")
                            .font(.caption)
                            .foregroundStyle(SQColor.labelTertiary)
                            // Le mode (audio/vidéo) n'existait que via cette icône masquée :
                            // on l'expose à VoiceOver (fusionné dans la ligne, CALL-HIST-C).
                            .accessibilityLabel(call.mode == "video" ? "Appel vidéo" : "Appel audio")
                    }
                    .listRowBackground(SQColor.surface)
                    .accessibilityElement(children: .combine)
                    .onAppear {
                        // Défilement infini : charge la page suivante à l'apparition
                        // de la dernière ligne.
                        if call.id == model.calls.last?.id {
                            Task { await model.loadMore() }
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            Task { await model.deleteEntry(call) }
                        } label: {
                            Label("Supprimer", systemImage: "trash")
                        }
                    }
                }
                if model.isLoadingMore {
                    ProgressView()
                        .tint(SQColor.brandRed)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
            } header: {
                Text("Journal")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }
        }
        .scrollContentBackground(.hidden)
        .signalQuestBackground()
        .navigationTitle("Appels")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .refreshable { await model.load() }
        .toolbar {
            if !model.calls.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) { confirmingClear = true } label: {
                        Image(systemName: "trash")
                    }
                    .tint(SQColor.brandRed)
                    .accessibilityLabel("Effacer l'historique")
                }
            }
        }
        .confirmationDialog("Effacer tout l'historique d'appels ?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Tout effacer", role: .destructive) { Task { await model.clearHistory() } }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Ton historique sera effacé pour toi. Tes correspondants gardent le leur.")
        }
    }

    /// Icône + couleur selon l'ISSUE de l'appel (pas la direction : aucun champ
    /// entrant/sortant fiable côté backend — CALL-HIST-07). Manqué/refusé en danger,
    /// terminé en succès, en cours/sonnerie en brique. La pastille reprend la
    /// teinte douce assortie (DA Crème).
    private func directionStyle(_ call: CallSession) -> (icon: String, color: Color, soft: Color, isMissed: Bool) {
        switch call.status {
        case "missed", "rejected":
            return ("phone.down.fill", SQColor.danger, SQColor.dangerSoft, true)
        case "ended", "accepted":
            return ("phone.fill", SQColor.success, SQColor.successSoft, false)
        default:
            return ("phone.fill", SQColor.brandRed, SQColor.accentSoft, false)
        }
    }

    /// Libellé FR du statut d'appel (l'app est 100 % francophone — CALL-HIST-06).
    private func statusLabel(_ status: String?) -> String {
        switch status {
        case "ended": return "Terminé"
        case "missed": return "Manqué"
        case "rejected": return "Refusé"
        case "accepted", "answered": return "Accepté"
        case "ringing": return "Sonnerie"
        case "pending": return "En attente"
        case "cancelled", "canceled": return "Annulé"
        case .some(let other) where !other.isEmpty: return other.capitalized
        default: return "—"
        }
    }

    private func durationText(_ call: CallSession) -> String? {
        guard let start = call.createdAt, let end = call.endedAt else { return nil }
        let seconds = Int(end.timeIntervalSince(start))
        guard seconds > 0 else { return nil }
        return Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond))
    }
}
