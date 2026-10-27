import CryptoKit
import Foundation

/// E2EE-AUTO §8 : lecture d'un message v1 importé (`HISTORY_IMPORT`). Le
/// serveur garde le premier import venu sans lire le contenu : rien n'en est
/// cru avant ces contrôles, et l'expéditeur d'origine n'est qu'une affirmation
/// de l'importeur.
enum E2EEAutoHistoryImport {
    /// Ce que le lecteur retient d'un import, gardé avec le message.
    struct Record: Codable, Equatable, Sendable {
        /// Source vérifiée ; nil : « message importé illisible ».
        let source: E2EEV2LegacyMessageSource?
        /// Pièces de la source sans manifeste dans l'import : « pièce jointe non importée ».
        let missingAttachments: Int
        /// Plateforme de l'appareil importeur, lue dans le journal à la réception.
        let importerPlatform: String?
    }

    /// Contrôles du lecteur, dans l'ordre du contrat : condensat, octets égaux
    /// à la recanonicalisation de la source analysée, conversation courante,
    /// message v1 servi par `importedFromMessageId`, puis blobs de l'enveloppe
    /// égaux aux pièces citées (révision 16). Un échec rend nil.
    static func verify(
        _ body: E2EEV2HistoryImportBody,
        conversationId: String,
        importedFromMessageId: String?,
        encryptedBlobIds: [String]
    ) -> E2EEV2LegacyMessageSource? {
        guard let importedFromMessageId,
              let bytes = Data(base64Encoded: body.sourceB64),
              bytes.count <= E2EEV2HistoryMigrationContract.maxClearBytes,
              hex(Data(SHA256.hash(data: bytes))) == body.sourceHash,
              let source = try? JSONDecoder().decode(E2EEV2LegacyMessageSource.self, from: bytes),
              (try? E2EEV2HistoryMigrationContract.canonicalSource(source)) == bytes,
              source.conversationId == conversationId,
              source.messageId == importedFromMessageId,
              encryptedBlobIds == body.attachments.map(\.blobId) else { return nil }
        return source
    }

    /// Ce que le magasin garde d'un message reçu : rien pour un message
    /// ordinaire ; pour un import, ou un message servi comme tel sans en être
    /// un, sa lecture vérifiée ou « illisible ».
    static func record(
        payload: E2EEV2ContentPayloadV2,
        conversationId: String,
        importedFromMessageId: String?,
        encryptedBlobIds: [String],
        importerPlatform: String?
    ) -> Record? {
        guard case .historyImport(let body) = payload.body else {
            return importedFromMessageId == nil
                ? nil
                : Record(source: nil, missingAttachments: 0, importerPlatform: importerPlatform)
        }
        let source = verify(
            body, conversationId: conversationId, importedFromMessageId: importedFromMessageId,
            encryptedBlobIds: encryptedBlobIds
        )
        let sourceAttachments = source.map(E2EEV2HistoryMigrationContract.attachmentCount) ?? 0
        return Record(
            source: source, missingAttachments: max(0, sourceAttachments - body.attachments.count),
            importerPlatform: importerPlatform
        )
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
