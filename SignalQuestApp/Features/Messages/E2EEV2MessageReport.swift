import Foundation
import SwiftUI

/// Signalement d'un message d'une conversation v2 (§11) : les motifs, ce que
/// l'utilisateur doit savoir avant l'envoi, et ce qu'il voit selon le
/// résultat. L'envoi lui-même, en deux parties, est dans `E2EEV2ReportSenderV2`.
enum E2EEV2MessageReport {
    /// Motifs proposés pour un message, alignés sur le web.
    static let reasons: [ReportReason] = ReportReason.messageReasons

    /// Motif tel qu'il part dans la partie en clair (D.10).
    static func wireReason(_ reason: ReportReason) -> String {
        switch reason {
        case .spam: return "SPAM"
        case .harassment: return "HARASSMENT"
        case .illegal: return "ILLEGAL"
        case .privacy, .misleading, .other: return "OTHER"
        }
    }

    /// §11 : l'utilisateur sait, avant d'envoyer, que le message signalé sera
    /// lisible par l'équipe de modération.
    static var notice: String {
        String(localized: "Conversation chiffrée : le message signalé, déchiffré sur ton appareil, est envoyé à l’équipe de modération, chiffré pour elle seule. Elle pourra le lire et vérifier qu’il vient bien de son auteur. Ni le reste de la conversation ni sa clé ne sont transmis.")
    }

    static var sentMessage: String {
        String(localized: "Signalement envoyé. Merci, l’équipe de modération va l’examiner.")
    }

    enum Failure: LocalizedError, Equatable {
        /// Aucune clé de modération épinglée dans cette version de l'app.
        case unavailable
        /// Message envoyé par soi, ou dont la charge exacte n'est plus gardée
        /// (effacé, éphémère expiré) : rien de vérifiable à transmettre.
        case notReportable
        case failed

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return String(localized: "Le signalement d’un message chiffré n’est pas encore disponible dans cette version de l’app.")
            case .notReportable:
                return String(localized: "Ce message ne peut pas être signalé : il n’est plus gardé sur cet appareil.")
            case .failed:
                return String(localized: "Impossible d’envoyer le signalement. Réessaie.")
            }
        }
    }

    /// Signale `refs`, des messages reçus par cet appareil dans cette
    /// conversation. Tous doivent pouvoir partir : un signalement ne perd
    /// jamais en silence une partie de ce que l'utilisateur a choisi.
    static func send(
        refs: [String],
        reason: ReportReason,
        conversationId: String,
        ownerScopeId: String,
        store: E2EEV2MessageStoreV2,
        sender: E2EEV2ReportSenderV2
    ) async throws {
        let messages = (try? store.reportable(refs, conversationId: conversationId, ownerScopeId: ownerScopeId)) ?? []
        guard !refs.isEmpty, messages.count == refs.count else { throw Failure.notReportable }
        switch await sender.report(
            messages, reason: wireReason(reason), conversationId: conversationId, expectedOwnerScopeId: ownerScopeId
        ) {
        case .sent: return
        case .unavailable: throw Failure.unavailable
        case .failure: throw Failure.failed
        }
    }
}

/// Démonstration de la feuille de signalement v2 (`--qa-e2ee-report`, envoi
/// accepté ; `--qa-e2ee-report-unavailable`, sans clé de modération).
struct E2EEV2MessageReportQAScreen: View {
    #if DEBUG && targetEnvironment(simulator)
    @State private var showsSheet = true
    @State private var sent = false
    private let available = !ProcessInfo.processInfo.arguments.contains("--qa-e2ee-report-unavailable")
    #endif

    var body: some View {
        #if DEBUG && targetEnvironment(simulator)
        NavigationStack {
            VStack(spacing: SQSpace.lg) {
                Button("Signaler le message") { showsSheet = true }
                    .accessibilityIdentifier("report.qa.open")
                    .frame(minHeight: 44)
                if sent {
                    Text(E2EEV2MessageReport.sentMessage)
                        .accessibilityIdentifier("report.qa.sent")
                }
            }
            .navigationTitle("Signalement v2 QA")
        }
        .sheet(isPresented: $showsSheet) {
            ReportSheet(reasons: E2EEV2MessageReport.reasons, notice: E2EEV2MessageReport.notice, allowsComment: false) { _, _ in
                guard available else { throw E2EEV2MessageReport.Failure.unavailable }
                sent = true
            }
        }
        #else
        EmptyView()
        #endif
    }
}
