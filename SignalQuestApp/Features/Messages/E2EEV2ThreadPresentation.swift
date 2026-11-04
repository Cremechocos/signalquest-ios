import Foundation

/// Ce que le fil montre d'une conversation v2 (§4.2, §4.3, §5) : les messages
/// du magasin v2 sous la forme commune `MessageItem`, et les avis à poser dans
/// le fil. Rien ici ne touche au réseau ni aux clés : la relève et la
/// vérification sont faites avant, par la messagerie v2.
struct E2EEV2ThreadPresentation: Equatable {
    enum Notice: Equatable {
        /// Un membre a un nouveau numéro de sécurité : rien ne lui est envoyé
        /// tant que l'utilisateur ne l'a pas vu (§2.4). L'avis mène à son numéro.
        case identityChanged(userId: String, name: String?)
        /// Le paquet de confiance d'un membre est refusé (liste en recul,
        /// lacune, signature invalide) : rien ne lui est envoyé non plus.
        case identityUnverified(userId: String, name: String?)
        /// Deux versions d'un même message : aucune n'est affichée (§4.2).
        case equivocation(count: Int)
        /// Des messages d'un membre n'ont pas été reçus (§4.3).
        case missing(senderName: String?, count: Int)
        /// Messages d'une version plus récente de l'app (§5.2).
        case unsupported(count: Int)
        /// L'appareil n'a pas encore la clé de l'époque courante (§3.2).
        case waitingForEpoch
        /// Un manifeste cite un appareil que le journal des appareils refuse
        /// (E2EE-AUTO §7.1) : la conversation passe à une nouvelle clé sans lui.
        case deviceRefused(userId: String, name: String?)
        /// Une clé de la conversation n'a pas pu être vérifiée (époque non
        /// marquée après une époque marquée, §7.2) : elle est remplacée.
        case keyUnverified
        /// Un appareil a été ajouté chez un membre (E2EE-AUTO §3.5), dans les 7 derniers jours.
        case devicesChanged(userId: String, name: String?)
        /// Le journal des appareils d'un membre a un maillon sans entrée (E2EE-AUTO
        /// §3.5 point 5) : rien ne lui est envoyé, l'avis mène au signalement.
        case logMismatch(userId: String, name: String?)

        var text: String {
            switch self {
            case .identityChanged(_, let name?):
                return String(localized: "\(name) a un nouveau numéro de sécurité. Rien ne lui est envoyé tant que tu ne l’as pas vu.")
            case .identityChanged(_, nil):
                return String(localized: "Un membre a un nouveau numéro de sécurité. Rien ne lui est envoyé tant que tu ne l’as pas vu.")
            case .identityUnverified(_, let name?):
                return String(localized: "Le chiffrement avec \(name) n’a pas pu être vérifié : rien ne lui est envoyé pour l’instant. Réessaie plus tard.")
            case .identityUnverified(_, nil):
                return String(localized: "Le chiffrement avec un membre n’a pas pu être vérifié : rien ne lui est envoyé pour l’instant. Réessaie plus tard.")
            case .equivocation:
                return String(localized: "Un message est arrivé en deux versions différentes : aucune n’est affichée.")
            case .missing(let name?, _):
                return String(localized: "Des messages envoyés par \(name) n’ont pas été reçus.")
            case .missing(nil, _):
                return String(localized: "Des messages n’ont pas été reçus.")
            case .unsupported:
                return String(localized: "Un message demande une version plus récente de SignalQuest.")
            case .waitingForEpoch:
                return String(localized: "En attente de la clé de cette conversation chiffrée.")
            case .deviceRefused(_, let name?):
                return String(localized: "Un appareil de \(name) ne figure pas tel quel dans le journal des appareils : la conversation passe à une nouvelle clé sans lui.")
            case .deviceRefused(_, nil):
                return String(localized: "Un appareil d’un membre ne figure pas tel quel dans le journal des appareils : la conversation passe à une nouvelle clé sans lui.")
            case .keyUnverified:
                return String(localized: "Une clé de cette conversation n’a pas pu être vérifiée : elle est remplacée par une nouvelle.")
            case .devicesChanged(_, let name?):
                return String(localized: "Les appareils de \(name) ont changé.")
            case .devicesChanged(_, nil):
                return String(localized: "Les appareils d’un membre ont changé.")
            case .logMismatch(_, let name?):
                return String(localized: "Le journal des appareils de \(name) ne correspond pas : rien ne lui est envoyé.")
            case .logMismatch(_, nil):
                return String(localized: "Le journal des appareils d’un membre ne correspond pas : rien ne lui est envoyé.")
            }
        }
    }

    let messages: [MessageItem]
    let notices: [Notice]
    /// Enveloppe du dernier message d'un autre membre : de quoi accuser « distribué »
    /// depuis le fil (U05), sans toucher à `MessageItem` dont l'identifiant est le `messageRef`.
    var lastIncomingEnvelopeId: String? = nil
    /// Identifiants de requête des messages déjà acceptés : une bulle locale « non envoyé »
    /// qui y figure est déjà partie (B02).
    var clientRequestIds: Set<String> = []
    /// Des messages plus anciens existent dans le magasin local mais ne sont pas présentés.
    var hasOlder: Bool = false
    /// Tous les appareils des membres lisent les réactions chiffrées (D.16) :
    /// sinon ni bouton ni double tap, jamais de repli en clair.
    var reactionsAvailable = false
    /// Messages v1 importés (E2EE-AUTO §8), par identifiant de `MessageItem`.
    var imports: [String: ImportLabel] = [:]
    /// Anciens messages v1 ou en clair (E2EE-AUTO §8) : leur mention, par identifiant.
    var legacyCaptions: [String: String] = [:]
    /// Messages v1 qu'un import vérifié cite : l'importeur ne les renvoie pas.
    var importedV1Ids: Set<String> = []
    /// Pièces chiffrées (E2EE-AUTO §7.7) par `blobId` : manifestes de la pièce et de sa miniature.
    var media: [String: E2EEAutoMediaRef] = [:]
    /// Enveloppe des messages qui citent des blobs, par identifiant : de quoi purger après un `DELETE` (§7.4).
    var blobEnvelopes: [String: String] = [:]
    /// Sondages chiffrés (§7.7) par identifiant de message, décomptés sur l'appareil.
    var polls: [String: MessagePoll] = [:]
    /// Publications partagées chiffrées (§7.7, `CARD` `POST`) par identifiant de message.
    var cards: [String: E2EEAutoContentR17.PostCard] = [:]

    /// Mentions d'un message importé, sous sa bulle.
    struct ImportLabel: Equatable {
        /// « importé par <nom> (<plateforme>) ».
        let importedBy: String
        /// Pièces de la source qui ne sont pas venues avec l'import.
        let missingAttachments: Bool
        /// Premier message du bloc « historique importé ».
        let startsBlock: Bool
        /// Sa source diffère de la lecture v1 de cet appareil (§8).
        var contested = false
    }
}

/// Taille de la fenêtre du fil v2 : les derniers messages d'abord, puis des pages de même taille.
enum E2EEV2ThreadWindow {
    static let pageSize = 200
}

enum E2EEV2ThreadPresenter {
    /// Durée de la ligne « les appareils de X ont changé ».
    static let deviceChangeWindowMs: Int64 = 7 * 24 * 3_600_000

    /// `members` : nom et avatar par utilisateur ; `deviceOwners` : l'utilisateur
    /// de chaque appareil certifié, pour nommer qui a des messages manquants ;
    /// `refusals` : les membres dont l'annuaire n'a pas cru l'identité, en tête
    /// des avis puisque l'envoi les attend.
    static func present(
        _ result: E2EEV2MessagesV2,
        conversationId: String,
        members: [String: MessageUser],
        deviceOwners: [String: String],
        refusals: [String: E2EEV2IdentityVerification.Failure] = [:],
        ownUserId: String? = nil,
        limit: Int? = nil,
        legacy: [MessageItem] = [],
        legacyReadings: [String: String] = [:],
        isGroup: Bool = false,
        groupAdmins: (Int) -> Set<String>? = { _ in nil },
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) -> E2EEV2ThreadPresentation {
        // Les imports forment un bloc placé avant tout message non importé (E2EE-AUTO §8).
        let recent = result.snapshot.messages.filter { $0.historyImport == nil }
        let ordered = importBlock(result.snapshot.messages) + recent
        // Le magasin garde jusqu'à des milliers de messages : seuls les derniers deviennent des
        // `MessageItem`, les précédents se présentent par pages (P03).
        let shown = limit.map { Array(ordered.suffix($0)) } ?? ordered
        let importRefs = Dictionary(
            result.snapshot.messages.compactMap { stored in stored.historyImport?.source.map { ($0.messageId, stored.messageRef) } },
            uniquingKeysWith: { first, _ in first }
        )
        // Import contesté : la lecture v1 de cet appareil en diffère (§8).
        let importedHashes = Dictionary(
            result.snapshot.messages.compactMap { stored in
                stored.historyImport?.source.flatMap { source in
                    (try? E2EEV2HistoryMigrationContract.sourceHash(source)).map { (source.messageId, $0) }
                }
            },
            uniquingKeysWith: { first, _ in first }
        )
        let localHashes = Dictionary(
            legacy.compactMap { item in
                legacyReadings[item.id]
                    .flatMap { E2EEAutoHistoryImporter.source(item, text: $0, conversationId: conversationId) }
                    .flatMap { source in (try? E2EEV2HistoryMigrationContract.sourceHash(source)).map { (item.id, $0) } }
            },
            uniquingKeysWith: { first, _ in first }
        )
        let contested = E2EEAutoHistoryImporter.contested(local: localHashes, imported: importedHashes)
        // Les anciens messages, entre le bloc et les messages v2, seulement quand
        // la fenêtre remonte jusqu'à eux.
        let old = shown.count >= recent.count
            ? E2EEAutoLegacyHistory.present(legacy, importRefs: importRefs, readings: legacyReadings, contested: contested)
            : (messages: [], captions: [:])
        // Le fil se trie par date : le bloc reste avant le premier message non importé.
        let legacyStartMs = old.messages.compactMap(\.createdAt).map { Int64(($0.timeIntervalSince1970 * 1_000).rounded(.down)) }.min()
        let blockEndMs = min(recent.map(\.serverTimeMs).min() ?? .max, legacyStartMs ?? .max) - 1
        var imports: [String: E2EEV2ThreadPresentation.ImportLabel] = [:]
        var media: [String: E2EEAutoMediaRef] = [:]
        var blobEnvelopes: [String: String] = [:]
        var polls: [String: MessagePoll] = [:]
        var cards: [String: E2EEAutoContentR17.PostCard] = [:]
        let messages = old.messages + shown.map { stored -> MessageItem in
            if let record = stored.historyImport {
                imports[stored.messageRef] = importLabel(
                    record, importer: members[stored.senderUserId], startsBlock: stored.messageRef == ordered.first?.messageRef
                )
                imports[stored.messageRef]?.contested = record.source.map { contested.contains($0.messageId) } ?? false
                return importedItem(
                    stored, record: record, conversationId: conversationId, members: members,
                    importRefs: importRefs, blockEndMs: blockEndMs
                )
            }
            // Révision 17 : chaque pièce devient une pièce jointe dont l'adresse désigne son blob.
            let body = stored.deleted ? nil : E2EEV2MessageStoreV2.r17Body(stored)
            if let body, !body.blobIds.isEmpty { blobEnvelopes[stored.messageRef] = stored.envelopeId }
            if let body, case .poll = body {
                polls[stored.messageRef] = poll(
                    body, stored: stored, events: result.snapshot.pollEvents[stored.messageRef] ?? [],
                    ownUserId: ownUserId, isGroup: isGroup, groupAdmins: groupAdmins, nowMs: nowMs
                )
            }
            if let body, case .card(let card) = body { cards[stored.messageRef] = card }
            let attachments = body.map { E2EEAutoMediaRef.attachments(of: $0, into: &media) } ?? []
            return MessageItem(
                id: stored.messageRef,
                conversationId: conversationId,
                senderId: stored.senderUserId,
                kind: E2EEV2MessageStoreV2.displayedKinds.contains(stored.kind) ? stored.kind : "TEXT",
                content: stored.deleted ? nil : stored.text,
                e2eeVersion: 2,
                e2eeIvB64: nil,
                e2eeCiphertextB64: nil,
                e2eeAadB64: nil,
                metadata: nil,
                // L'heure du serveur ordonne et date le fil ; l'heure signée
                // de l'émetteur ne sert qu'à l'expiration (§5.4).
                createdAt: date(stored.serverTimeMs),
                editedAt: stored.deleted ? nil : stored.editedAtMs.map(date),
                deletedAt: stored.deleted ? date(stored.editedAtMs ?? stored.serverTimeMs) : nil,
                expiresAt: stored.expiresAtMs.map(date),
                replyToId: stored.replyToRef,
                threadReplyCount: nil,
                sender: members[stored.senderUserId],
                attachments: attachments,
                reactions: result.snapshot.reactions[stored.messageRef]?.map {
                    MessageReaction(emoji: $0.emoji, userId: $0.userId)
                } ?? []
            )
        }
        var notices: [E2EEV2ThreadPresentation.Notice] = refusals.keys.sorted().map { userId in
            let name = members[userId]?.displayName
            switch refusals[userId] {
            case .uikChanged?: return .identityChanged(userId: userId, name: name)
            case .logEntryMissing?: return .logMismatch(userId: userId, name: name)
            default: return .identityUnverified(userId: userId, name: name)
            }
        }
        // Une ligne par appareil refusé, la plus récente gardée.
        var refusedDevices = Set<String>()
        for alert in result.securityAlerts.reversed() {
            if alert.code == "UNMARKED_EPOCH" {
                if !notices.contains(.keyUnverified) { notices.append(.keyUnverified) }
            } else if refusedDevices.insert(alert.userId + "\n" + alert.deviceId).inserted {
                notices.append(.deviceRefused(userId: alert.userId, name: members[alert.userId]?.displayName))
            }
        }
        for change in result.deviceChanges.reversed()
        where change.userId != ownUserId && nowMs - change.atMs < deviceChangeWindowMs {
            notices.append(.devicesChanged(userId: change.userId, name: members[change.userId]?.displayName))
        }
        if result.waitingForEpoch { notices.append(.waitingForEpoch) }
        if !result.snapshot.equivocalRefs.isEmpty {
            notices.append(.equivocation(count: result.snapshot.equivocalRefs.count))
        }
        // Un avis par membre, pas par appareil : ses appareils s'additionnent.
        var missingByUser: [String?: Int] = [:]
        for (deviceId, count) in result.missingByDevice where count > 0 {
            missingByUser[deviceOwners[deviceId], default: 0] += count
        }
        for (userId, count) in missingByUser.sorted(by: { ($0.key ?? "") < ($1.key ?? "") }) {
            notices.append(.missing(senderName: userId.flatMap { members[$0]?.displayName }, count: count))
        }
        if !result.unsupported.isEmpty { notices.append(.unsupported(count: result.unsupported.count)) }
        // Un import ne déplace aucun marqueur (E2EE-AUTO §8) : il n'est pas accusé « distribué ».
        let lastIncoming = ownUserId.flatMap { own in
            result.snapshot.messages.last { $0.senderUserId != own && !$0.deleted && $0.historyImport == nil }?.envelopeId
        }
        return E2EEV2ThreadPresentation(
            messages: messages, notices: notices,
            lastIncomingEnvelopeId: lastIncoming,
            clientRequestIds: Set(result.snapshot.messages.map(\.clientRequestId)),
            hasOlder: shown.count < result.snapshot.messages.count,
            imports: imports,
            legacyCaptions: old.captions,
            importedV1Ids: Set(importRefs.keys),
            media: media,
            blobEnvelopes: blobEnvelopes,
            polls: polls,
            cards: cards
        )
    }

    /// Sondage chiffré dans la forme de la bulle commune. Une clôture compte si elle vient
    /// de l'auteur, ou d'un administrateur du groupe à l'époque de la clôture ; une
    /// conversation à deux n'a pas d'administrateur. `pollId` est la référence du message.
    static func poll(
        _ body: E2EEAutoContentR17.Body, stored: E2EEV2MessageStoreV2.Stored, events: [E2EEV2MessageStoreV2.Stored],
        ownUserId: String?, isGroup: Bool, groupAdmins: (Int) -> Set<String>?, nowMs: Int64
    ) -> MessagePoll? {
        guard case .poll(let question, let options, let multipleChoice, let closesAt) = body else { return nil }
        let closesAtMs = closesAt.flatMap(E2EEAutoContentR17.isoMs)
        let pollEvents: [E2EEAutoContentR17.PollEvent] = events.compactMap { event in
            switch E2EEV2MessageStoreV2.r17Body(event) {
            case .pollVote(_, let optionIds)?:
                return .vote(senderId: event.senderUserId, sequence: event.sequence, serverTimeMs: event.serverTimeMs, optionIds: optionIds)
            case .pollClose?:
                let isAdmin = isGroup ? groupAdmins(event.epochNumber).map { $0.contains(event.senderUserId) } : false
                return .close(senderId: event.senderUserId, sequence: event.sequence, serverTimeMs: event.serverTimeMs, senderIsAdmin: isAdmin)
            default:
                return nil
            }
        }
        let tally = E2EEAutoContentR17.tally(
            authorId: stored.senderUserId, optionIds: options.map(\.id), multipleChoice: multipleChoice,
            closesAtMs: closesAtMs, events: pollEvents, nowServerMs: nowMs
        )
        let counts = Dictionary(tally.counts.map { ($0.id, $0.count) }, uniquingKeysWith: { first, _ in first })
        let closedAt: Date? = tally.closedBySequence.flatMap { sequence in
            events.first { $0.sequence == sequence }.map { date($0.serverTimeMs) }
        } ?? (tally.closed ? closesAtMs.map(date) : nil)
        return MessagePoll(
            pollId: stored.messageRef, question: question,
            options: options.map { PollOption(id: $0.id, text: $0.label, count: counts[$0.id] ?? 0) },
            multiSelect: multipleChoice, createdById: stored.senderUserId, closedAt: closedAt,
            endsAt: closesAtMs.map(date), totalVotes: tally.votes.count,
            votesByMe: ownUserId.flatMap { tally.votes[$0] } ?? []
        )
    }

    /// Les imports, triés par date de la source puis identifiant v1 ; les
    /// illisibles à la suite, dans l'ordre du serveur.
    private static func importBlock(_ stored: [E2EEV2MessageStoreV2.Stored]) -> [E2EEV2MessageStoreV2.Stored] {
        let imports = stored.filter { $0.historyImport != nil }
        let readable = imports.filter { $0.historyImport?.source != nil }.sorted { lhs, rhs in
            let (l, r) = (lhs.historyImport!.source!, rhs.historyImport!.source!)
            let (ld, rd) = (E2EEV2HistoryMigrationContract.date(l.createdAt), E2EEV2HistoryMigrationContract.date(r.createdAt))
            return ld == rd ? l.messageId < r.messageId : (ld ?? .distantPast) < (rd ?? .distantPast)
        }
        return readable + imports.filter { $0.historyImport?.source == nil }
    }

    /// Un import sous la forme commune : sous le nom du compte de la source,
    /// jamais son identifiant brut ; à sa date d'origine, gardée avant le
    /// premier message non importé.
    private static func importedItem(
        _ stored: E2EEV2MessageStoreV2.Stored,
        record: E2EEAutoHistoryImport.Record,
        conversationId: String,
        members: [String: MessageUser],
        importRefs: [String: String],
        blockEndMs: Int64
    ) -> MessageItem {
        let dateMs = min(blockEndMs, stored.serverTimeMs)
        guard let source = record.source else {
            return MessageItem(
                id: stored.messageRef, conversationId: conversationId, senderId: stored.senderUserId, kind: "TEXT",
                content: String(localized: "message importé illisible"), e2eeVersion: 2, e2eeIvB64: nil,
                e2eeCiphertextB64: nil, e2eeAadB64: nil, metadata: nil, createdAt: date(dateMs), editedAt: nil,
                deletedAt: nil, expiresAt: nil, replyToId: nil, threadReplyCount: nil,
                sender: members[stored.senderUserId], attachments: [], reactions: []
            )
        }
        let created = E2EEV2HistoryMigrationContract.date(source.createdAt).map { min($0, date(blockEndMs)) } ?? date(dateMs)
        // Une pièce sans texte n'a plus rien à montrer que sa mention.
        let attachmentOnly = source.kind == "ATTACHMENT"
        let content = attachmentOnly && source.content.isEmpty
            ? String(localized: "pièce jointe non importée") : source.content
        return MessageItem(
            id: stored.messageRef, conversationId: conversationId, senderId: source.senderId,
            kind: attachmentOnly ? "TEXT" : source.kind, content: content, e2eeVersion: 2, e2eeIvB64: nil,
            e2eeCiphertextB64: nil, e2eeAadB64: nil, metadata: attachmentOnly ? nil : source.metadata, createdAt: created,
            editedAt: source.editedAt.flatMap(E2EEV2HistoryMigrationContract.date), deletedAt: nil, expiresAt: nil,
            replyToId: source.replyToId.flatMap { importRefs[$0] }, threadReplyCount: nil,
            sender: members[source.senderId]
                ?? MessageUser(id: source.senderId, name: String(localized: "ancien membre"), email: "", avatarUrl: nil),
            attachments: [], reactions: []
        )
    }

    private static func importLabel(
        _ record: E2EEAutoHistoryImport.Record, importer: MessageUser?, startsBlock: Bool
    ) -> E2EEV2ThreadPresentation.ImportLabel {
        let name = importer.map(\.displayName).flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "ancien membre")
        let platform: String
        switch record.importerPlatform {
        case "ios"?: platform = "iOS"
        case "android"?: platform = "Android"
        case "web"?: platform = "Web"
        default: platform = String(localized: "plateforme inconnue")
        }
        let content = record.source?.content ?? ""
        return .init(
            importedBy: String(localized: "importé par \(name) (\(platform))"),
            // Une pièce seule l'a déjà dit dans sa bulle.
            missingAttachments: record.missingAttachments > 0 && !(record.source?.kind == "ATTACHMENT" && content.isEmpty),
            startsBlock: startsBlock
        )
    }

    private static func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }
}
