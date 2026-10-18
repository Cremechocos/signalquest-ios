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
            if !error.isCancellation && calls.isEmpty { errorMessage = error.userFacingMessage }
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
        errorMessage = nil
        do {
            try await service.clearHistory()
            calls = []
            page = 1
            hasMore = false
        } catch {
            errorMessage = error.userFacingMessage
        }
    }

    /// Supprime un appel de MON historique (optimiste, rollback si le serveur échoue).
    func deleteEntry(_ call: CallSession) async {
        let previous = calls
        errorMessage = nil
        calls.removeAll { $0.id == call.id }
        do {
            try await service.deleteEntry(callId: call.id)
        } catch {
            calls = previous
            errorMessage = error.userFacingMessage
        }
    }
}

struct CallHistoryView: View {
    @StateObject private var model: CallHistoryViewModel
    @State private var confirmingClear = false
    @EnvironmentObject private var router: AppRouter
    init(service: CallsServicing) {
        _model = StateObject(wrappedValue: CallHistoryViewModel(service: service))
    }

    var body: some View {
        List {
            SQSettingsHeader(title: "Appels", backIdentifier: "calls.back")
                .overlay(alignment: .topTrailing) {
                    if !model.calls.isEmpty {
                        MapChipIconButton(systemImage: "trash", label: "Effacer l'historique", identifier: "calls.clear") {
                            confirmingClear = true
                        }
                    }
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: SQSpace.sm, leading: SQSpace.lg, bottom: SQSpace.sm, trailing: SQSpace.lg))

            Group {
                if model.isLoading && model.calls.isEmpty {
                    SQSpinner().tint(SQColor.brandRed).frame(maxWidth: .infinity)
                } else if let error = model.errorMessage, model.calls.isEmpty {
                    ErrorStateView(title: "Appels indisponibles", message: error) { Task { await model.load() } }
                } else if model.calls.isEmpty {
                    EmptyStateView(title: "Aucun appel", message: "Tes appels apparaîtront ici.", systemImage: "phone.badge.waveform")
                        .frame(maxWidth: .infinity)
                }
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            // Groupés par jour, chaque jour sur sa carte.
            ForEach(daySections, id: \.day) { section in
                Text(verbatim: section.title)
                    .sqKicker()
                    .accessibilityAddTraits(.isHeader)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: SQSpace.md, leading: SQSpace.lg + SQSpace.xs, bottom: SQSpace.xs, trailing: SQSpace.lg))
                ForEach(Array(section.calls.enumerated()), id: \.element.id) { index, call in
                    callRow(call, isFirst: index == 0)
                        .listRowBackground(
                            MessagesCardSegment(top: index == 0, bottom: index == section.calls.count - 1)
                                .fill(SQColor.surface)
                                .overlay {
                                    MessagesCardSegment(top: index == 0, bottom: index == section.calls.count - 1)
                                        .strokeBorder(SQOledPalette.cardStroke, lineWidth: 1)
                                }
                                .padding(.horizontal, SQSpace.lg)
                        )
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: SQSpace.lg, bottom: 0, trailing: SQSpace.lg))
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
                        // Le geste ouvre la conversation, sans lancer d'appel : son bouton
                        // d'appel applique les règles (chiffrement, groupe, réseau) ; la
                        // ligne ne menait nulle part (SOC-44).
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            if let conversationId = call.conversationId {
                                Button {
                                    router.route(toConversation: conversationId)
                                } label: {
                                    Label("Ouvrir la conversation", systemImage: "bubble.left.fill")
                                }
                                .tint(SQColor.success)
                            }
                        }
                        .contextMenu {
                            if let conversationId = call.conversationId {
                                Button {
                                    router.route(toCallBack: conversationId, video: call.mode == "video")
                                } label: {
                                    Label("Rappeler", systemImage: "phone.arrow.up.right")
                                }
                            }
                        }
                }
            }
            if model.isLoadingMore {
                SQSpinner()
                    .tint(SQColor.brandRed)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .sqReadableWidth()
        .signalQuestBackground()
        // Échec d'une suppression ou de « Tout effacer » : la rangée revient, on dit pourquoi.
        .actionErrorBar(model.calls.isEmpty ? nil : model.errorMessage)
        .navigationTitle("Appels")
        .toolbar(.hidden, for: .navigationBar)
        .sqKeepsSwipeBack()
        .task { await model.load() }
        .refreshable { await model.load() }
        .confirmationDialog("Effacer tout l'historique d'appels ?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Tout effacer", role: .destructive) { Task { await model.clearHistory() } }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Ton historique sera effacé pour toi. Tes correspondants gardent le leur.")
        }
    }

    private struct DaySection {
        let day: Date
        let title: String
        let calls: [CallSession]
    }

    /// Les appels par jour, dans l'ordre du serveur (le plus récent d'abord).
    private var daySections: [DaySection] {
        let calendar = Calendar.current
        var sections: [DaySection] = []
        for call in model.calls {
            let day = call.createdAt.map { calendar.startOfDay(for: $0) } ?? .distantPast
            if let last = sections.last, last.day == day {
                sections[sections.count - 1] = DaySection(day: day, title: last.title, calls: last.calls + [call])
            } else {
                sections.append(DaySection(day: day, title: dayTitle(day, calendar: calendar), calls: [call]))
            }
        }
        return sections
    }

    private func dayTitle(_ day: Date, calendar: Calendar) -> String {
        if day == .distantPast { return String(localized: "Plus anciens") }
        if calendar.isDateInToday(day) { return String(localized: "Aujourd’hui") }
        if calendar.isDateInYesterday(day) { return String(localized: "Hier") }
        let text = day.formatted(.dateTime.weekday(.wide).day().month(.wide))
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// Avatar, nom (rouge si manqué), issue et durée, heure, puis un rond pour
    /// rappeler depuis la conversation.
    private func callRow(_ call: CallSession, isFirst: Bool) -> some View {
        let style = directionStyle(call)
        let name = call.displayName ?? call.participants?.joined(separator: ", ") ?? String(localized: "Conversation")
        let status = [statusLabel(call.status), durationText(call)].compactMap { $0 }.joined(separator: " · ")
        return VStack(spacing: 0) {
            if !isFirst { Divider().padding(.leading, 52) }
            HStack(spacing: SQSpace.md) {
                SQAvatar(url: nil, name: name, size: 40)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(SQType.body(.semibold))
                        .foregroundStyle(style.isMissed ? SQColor.dangerInk : SQColor.label)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Image(systemName: style.icon)
                            .font(.system(size: 10, weight: .bold))
                            .accessibilityHidden(true)
                        Text(verbatim: status)
                    }
                    .font(SQType.caption)
                    .foregroundStyle(style.isMissed ? SQColor.dangerInk : SQColor.labelSecondary)
                    // Le mode (audio/vidéo) n'existait que via une icône masquée :
                    // on l'expose à VoiceOver (fusionné dans la ligne, CALL-HIST-C).
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(call.mode == "video" ? "Appel vidéo" : "Appel audio") + Text(verbatim: ", \(status)"))
                }
                Spacer(minLength: SQSpace.sm)
                if let date = call.createdAt {
                    Text(date, format: .dateTime.hour().minute())
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .monospacedDigit()
                }
                if let conversationId = call.conversationId {
                    // Lance l'appel pour de vrai : la conversation s'ouvre et applique
                    // ses règles (chiffrement, participants) avant de composer.
                    Button {
                        router.route(toCallBack: conversationId, video: call.mode == "video")
                    } label: {
                        Image(systemName: call.mode == "video" ? "video.fill" : "phone.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(SQColor.label)
                            .frame(width: 36, height: 36)
                            .background(SQColor.chip, in: Circle())
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(call.mode == "video" ? Text("Rappeler en vidéo") : Text("Rappeler"))
                }
            }
            .padding(.vertical, SQSpace.sm)
            .accessibilityElement(children: .combine)
        }
        .padding(.leading, SQSpace.md)
        .padding(.trailing, SQSpace.xs)
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
        case "ended": return String(localized: "Terminé")
        case "missed": return String(localized: "Manqué")
        case "rejected": return String(localized: "Refusé")
        case "accepted", "answered": return String(localized: "Accepté")
        case "ringing": return String(localized: "Sonnerie")
        case "pending": return String(localized: "En attente")
        case "cancelled", "canceled": return String(localized: "Annulé")
        case "active": return String(localized: "En cours")
        // Statut inconnu : rien plutôt que le mot brut du serveur (SOC-44).
        default: return "—"
        }
    }

    private func durationText(_ call: CallSession) -> String? {
        guard let duration = call.talkDuration else { return nil }
        let seconds = Int(duration)
        guard seconds > 0 else { return nil }
        return Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
    }
}
