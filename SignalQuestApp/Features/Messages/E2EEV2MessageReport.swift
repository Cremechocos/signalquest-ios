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

    /// §11 : l'utilisateur sait, avant d'envoyer, ce que l'équipe de
    /// modération pourra lire.
    static var notice: String {
        String(localized: "Conversation chiffrée : le message signalé, tel que tu le vois, et ses versions précédentes dans la limite de taille d’un signalement sont envoyés à l’équipe de modération, déchiffrés sur ton appareil et chiffrés pour elle seule. Elle pourra les lire. Ni le reste de la conversation ni sa clé ne sont transmis.")
    }

    enum Failure: LocalizedError, Equatable {
        /// Aucune clé de modération épinglée dans cette version de l'app.
        case unavailable
        /// Message dont la charge exacte n'est plus gardée (supprimé par son
        /// auteur, éphémère expiré, en équivoque) : rien de vérifiable à transmettre.
        case notReportable
        /// Les versions affichées des messages choisis ne tiennent pas dans un
        /// rapport (50 éléments, 512 Kio) : en choisir moins (D.10).
        case tooLarge
        /// Quota de signalements du jour atteint (`E2EE_REPORT_QUOTA`, §16).
        case dailyLimit
        case failed

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return String(localized: "Le signalement d’un message chiffré n’est pas encore disponible dans cette version de l’app.")
            case .notReportable:
                return String(localized: "Ce message ne peut pas être signalé : il n’est plus gardé sur cet appareil.")
            case .tooLarge:
                return String(localized: "Ce signalement est trop volumineux : choisis moins de messages.")
            case .dailyLimit:
                return String(localized: "Tu as atteint la limite de signalements pour aujourd’hui. Réessaie demain.")
            case .failed:
                return String(localized: "Impossible d’envoyer le signalement. Réessaie.")
            }
        }
    }

    /// Signale `refs`, des messages gardés par cet appareil dans cette
    /// conversation. La version affichée de chacun part toujours : un message
    /// n'est jamais insignalable parce qu'il a été trop modifié. Leur histoire
    /// suit, la plus utile d'abord, tant que le rapport tient (50 éléments,
    /// 512 Kio). Tous les messages choisis partent, ou aucun.
    static func send(
        refs: [String],
        reason: ReportReason,
        conversationId: String,
        ownerScopeId: String,
        store: E2EEV2MessageStoreV2,
        sender: E2EEV2ReportSenderV2,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) async throws {
        var seen = Set<String>()
        let unique = refs.filter { seen.insert($0).inserted }
        guard !unique.isEmpty else { throw Failure.notReportable }
        guard unique.count <= E2EEV2ReportSenderV2.maxMessages else { throw Failure.tooLarge }
        let groups: [String: E2EEV2MessageStoreV2.ReportGroup]
        do {
            groups = try store.reportGroups(unique, conversationId: conversationId, ownerScopeId: ownerScopeId, nowMs: nowMs)
        } catch {
            throw Failure.failed
        }
        let chosen = unique.compactMap { groups[$0] }
        guard chosen.count == unique.count else { throw Failure.notReportable }
        let displayed = chosen.map(\.displayed)
        // L'histoire, couche par couche : les originaux, puis les éditions
        // intermédiaires de la plus récente à la plus ancienne.
        let depth = chosen.map(\.history.count).max() ?? 0
        var history = (0..<depth).flatMap { level in chosen.compactMap { level < $0.history.count ? $0.history[level] : nil } }
        history = Array(history.prefix(E2EEV2ReportSenderV2.maxMessages - displayed.count))
        while true {
            switch await sender.report(
                displayed + history, reason: wireReason(reason), conversationId: conversationId,
                expectedOwnerScopeId: ownerScopeId
            ) {
            case .sent:
                return
            case .unavailable:
                throw Failure.unavailable
            case .tooLarge:
                // Rien n'est parti : une version ancienne de moins, sinon trop de messages choisis.
                guard !history.isEmpty else { throw Failure.tooLarge }
                history.removeLast()
            case .failure(let failure) where failure.statusCode == 429 && failure.code == "E2EE_REPORT_QUOTA":
                throw Failure.dailyLimit
            case .failure:
                throw Failure.failed
            }
        }
    }
}

/// Démonstration de la feuille de signalement v2 (`--qa-e2ee-report`, envoi
/// accepté ; `--qa-e2ee-report-unavailable`, sans clé de modération ;
/// `--qa-e2ee-report-comment`, témoin avec le champ libre des autres
/// signalements). Après l'envoi, elle montre le motif et le commentaire reçus.
struct E2EEV2MessageReportQAScreen: View {
    #if DEBUG && targetEnvironment(simulator)
    @State private var showsSheet = true
    @State private var received: String?
    private let available = !ProcessInfo.processInfo.arguments.contains("--qa-e2ee-report-unavailable")
    private let allowsComment = ProcessInfo.processInfo.arguments.contains("--qa-e2ee-report-comment")
    #endif

    var body: some View {
        #if DEBUG && targetEnvironment(simulator)
        NavigationStack {
            VStack(spacing: SQSpace.lg) {
                Button("Signaler le message") { showsSheet = true }
                    .accessibilityIdentifier("report.qa.open")
                    .frame(minHeight: 44)
                if let received {
                    Text(verbatim: received)
                        .accessibilityIdentifier("report.qa.sent")
                }
            }
            .navigationTitle("Signalement v2 QA")
        }
        .sheet(isPresented: $showsSheet) {
            ReportSheet(reasons: E2EEV2MessageReport.reasons, notice: E2EEV2MessageReport.notice, allowsComment: allowsComment) { reason, comment in
                guard available else { throw E2EEV2MessageReport.Failure.unavailable }
                received = "\(E2EEV2MessageReport.wireReason(reason)) · \(comment ?? "-")"
            }
        }
        #else
        EmptyView()
        #endif
    }
}
