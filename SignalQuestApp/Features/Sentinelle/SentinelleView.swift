import SwiftUI

/// Sentinelle — consultation de l'état des connexions surveillées.
///
/// Écran de lecture seule : la sonde est côté serveur. La configuration fine
/// (seuils d'alerte, heures calmes, webhook) reste sur le web ; en mobilité, la
/// seule question qui compte est « est-ce que ma box est tombée, et depuis
/// quand ? ».
struct SentinelleView: View {
    let service: SentinelleServicing

    @State private var targets: [SentinelleTarget] = []
    @State private var incidentsByTarget: [String: [SentinelleIncident]] = [:]
    @State private var isLoading = true
    @State private var accessDenied = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if accessDenied {
                message(
                    title: "Réservé aux membres Premium",
                    body: "Sentinelle surveille votre connexion en continu : disponibilité, latence, "
                        + "perte de paquets et historique daté de chaque coupure."
                )
            } else if let errorMessage {
                message(title: "Chargement impossible", body: errorMessage)
            } else if targets.isEmpty {
                message(
                    title: "Aucune cible surveillée",
                    body: "Ajoutez l’adresse publique de votre box depuis le site pour suivre sa disponibilité."
                )
            } else {
                List {
                    ForEach(targets) { target in
                        Section {
                            targetRow(target)
                            ForEach(incidentsByTarget[target.id]?.prefix(3).map { $0 } ?? []) { incident in
                                incidentRow(incident)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Sentinelle")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func targetRow(_ target: SentinelleTarget) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(statusColor(target.status)).frame(width: 10, height: 10)
                Text(target.label).font(.headline)
            }
            Text(statusLabel(target.status))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(target.displayAddress)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            if target.suspendedReason != nil {
                Text("Surveillance suspendue : l’adresse a changé de réseau. Vérifiez depuis le site qu’elle vous appartient toujours.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.top, 4)
            }
        }
        .padding(.vertical, 4)
    }

    private func incidentRow(_ incident: SentinelleIncident) -> some View {
        HStack {
            Text(shortDate(incident.startedAt) + causeSuffix(incident))
                .font(.caption)
            Spacer()
            Text(incident.endedAt == nil ? "en cours" : formatDuration(incident.durationSec))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    private func message(title: String, body: String) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.headline)
            Text(body)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        do {
            let response = try await service.targets()
            targets = response.targets
            // Détail chargé uniquement pour les cibles affichées.
            var collected: [String: [SentinelleIncident]] = [:]
            for target in response.targets {
                collected[target.id] = (try? await service.detail(targetId: target.id))?.incidents ?? []
            }
            incidentsByTarget = collected
        } catch is SentinelleAccessDenied {
            accessDenied = true
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "up": return Color(red: 0.25, green: 0.61, blue: 0.43)
        case "down": return Color(red: 0.76, green: 0.25, blue: 0.24)
        case "degraded": return Color(red: 0.79, green: 0.60, blue: 0.18)
        default: return .secondary
        }
    }

    private func statusLabel(_ status: String) -> String {
        switch status {
        case "up": return "En ligne"
        case "down": return "Hors ligne"
        case "degraded": return "Connexion dégradée"
        default: return "En attente de mesure"
        }
    }

    private func causeSuffix(_ incident: SentinelleIncident) -> String {
        switch incident.cause {
        case "local": return " · chez vous"
        case "isp": return " · chez votre opérateur"
        case "transit": return " · sur le trajet"
        default:
            let others = incident.correlatedUsers ?? 0
            return others > 0 ? " · \(others) autres touchés" : ""
        }
    }

    /// Les dates arrivent en ISO 8601 ; on n'affiche que le jour et l'heure.
    private func shortDate(_ iso: String) -> String {
        let parts = iso.split(separator: "T")
        guard parts.count == 2 else { return iso }
        let date = parts[0].split(separator: "-")
        guard date.count == 3 else { return iso }
        return "\(date[2])/\(date[1]) \(parts[1].prefix(5))"
    }

    private func formatDuration(_ seconds: Int?) -> String {
        guard let seconds else { return "—" }
        if seconds < 60 { return "\(seconds) s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(String(format: "%02d", minutes % 60))"
    }
}
