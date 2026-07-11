import SwiftUI

@MainActor
final class CallHistoryViewModel: ObservableObject {
    @Published var calls: [CallSession] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let service: CallsServicing
    init(service: CallsServicing) { self.service = service }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            calls = try await service.history()
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
        }
    }
}

struct CallHistoryView: View {
    @StateObject private var model: CallHistoryViewModel
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
                            Text(call.participants?.joined(separator: ", ") ?? "Conversation")
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
                            .accessibilityHidden(true)
                    }
                    .listRowBackground(SQColor.surface)
                    .accessibilityElement(children: .combine)
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
