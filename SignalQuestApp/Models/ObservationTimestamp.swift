import Foundation

/// Les dates de capture gardent les millisecondes. La stratégie JSON historique
/// de l'app arrondit à la seconde ; elle reste inchangée pour les autres contrats.
enum ObservationTimestamp {
    static func string(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
