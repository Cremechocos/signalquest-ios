import Foundation
import SwiftUI

/// Photo instantanée des seuls prérequis qu'iOS permet d'observer sans inventer
/// un état de SIM, d'itinérance ou de mode avion. Les valeurs indisponibles restent
/// `nil` et ne deviennent jamais un faux blocage.
struct DriveTestPreflightSnapshot: Equatable {
    enum LocationAuthorization: Equatable {
        case authorized
        case notDetermined
        case denied
    }

    let locationAuthorization: LocationAuthorization
    let locationAgeSeconds: TimeInterval?
    let horizontalAccuracyMeters: Double?
    let availableStorageBytes: Int64?
    let batteryPercent: Int?
    let isCharging: Bool
    let isOnline: Bool
    let connection: NetworkConnectionKind
    let isConstrained: Bool
    let recordsCoverage: Bool
    let runsSpeedtest: Bool
}

struct DriveTestPreflightIssue: Identifiable, Equatable {
    enum ID: String, Equatable {
        case locationPermission
        case gpsFix
        case storage
        case battery
        case connectivity
        case wifi
        case constrainedNetwork
    }

    enum Severity: Equatable {
        case warning
        case blocking
    }

    enum Action: Equatable {
        case none
        case requestLocation
        case openSettings
    }

    let id: ID
    let severity: Severity
    let action: Action
    let value: Int?
}

struct DriveTestPreflightReport: Identifiable, Equatable {
    let issues: [DriveTestPreflightIssue]

    var id: String { issues.map { $0.id.rawValue }.joined(separator: "|") }
    var isBlocked: Bool { issues.contains { $0.severity == .blocking } }
    var isReady: Bool { issues.isEmpty }
}

enum DriveTestPreflightPolicy {
    private static let staleLocationAge: TimeInterval = 60
    private static let inaccurateLocationMeters = 200.0
    private static let storageWarningBytes: Int64 = 200 * 1_000_000
    private static let storageBlockingBytes: Int64 = 100 * 1_000_000
    private static let batteryWarningPercent = 20

    static func evaluate(_ snapshot: DriveTestPreflightSnapshot) -> DriveTestPreflightReport {
        var issues: [DriveTestPreflightIssue] = []

        switch snapshot.locationAuthorization {
        case .authorized:
            let locationIsMissing = snapshot.locationAgeSeconds == nil
            let locationIsStale = snapshot.locationAgeSeconds.map { $0 > staleLocationAge } ?? false
            let locationIsInaccurate = snapshot.horizontalAccuracyMeters.map {
                $0 < 0 || $0 > inaccurateLocationMeters
            } ?? false
            if locationIsMissing || locationIsStale || locationIsInaccurate {
                issues.append(
                    DriveTestPreflightIssue(
                        id: .gpsFix,
                        severity: .warning,
                        action: .none,
                        value: snapshot.locationAgeSeconds.map { Int(max(0, $0).rounded()) }
                    )
                )
            }
        case .notDetermined:
            issues.append(
                DriveTestPreflightIssue(
                    id: .locationPermission,
                    severity: .blocking,
                    action: .requestLocation,
                    value: nil
                )
            )
        case .denied:
            issues.append(
                DriveTestPreflightIssue(
                    id: .locationPermission,
                    severity: .blocking,
                    action: .openSettings,
                    value: nil
                )
            )
        }

        if let bytes = snapshot.availableStorageBytes, bytes < storageWarningBytes {
            issues.append(
                DriveTestPreflightIssue(
                    id: .storage,
                    severity: bytes < storageBlockingBytes ? .blocking : .warning,
                    action: .none,
                    value: Int(max(0, bytes) / 1_000_000)
                )
            )
        }

        if !snapshot.isCharging,
           let batteryPercent = snapshot.batteryPercent,
           batteryPercent < batteryWarningPercent {
            // Une batterie faible augmente le risque d'interruption, mais elle
            // n'empêche pas techniquement l'enregistrement : avertissement seulement.
            issues.append(
                DriveTestPreflightIssue(
                    id: .battery,
                    severity: .warning,
                    action: .none,
                    value: max(0, batteryPercent)
                )
            )
        }

        if !snapshot.isOnline, snapshot.runsSpeedtest {
            issues.append(
                DriveTestPreflightIssue(
                    id: .connectivity,
                    severity: snapshot.recordsCoverage ? .warning : .blocking,
                    action: .none,
                    value: nil
                )
            )
        } else if snapshot.connection == .wifi, snapshot.runsSpeedtest {
            issues.append(
                DriveTestPreflightIssue(
                    id: .wifi,
                    severity: .warning,
                    action: .none,
                    value: nil
                )
            )
        }

        if snapshot.isConstrained, snapshot.runsSpeedtest {
            issues.append(
                DriveTestPreflightIssue(
                    id: .constrainedNetwork,
                    severity: .warning,
                    action: .none,
                    value: nil
                )
            )
        }

        return DriveTestPreflightReport(issues: issues)
    }
}

/// Feuille compacte : elle n'existe que lorsqu'une action ou une décision est
/// nécessaire. Les permissions accordées, la SIM lisible, le stockage suffisant
/// et tous les autres contrôles positifs n'y apparaissent jamais.
struct DriveTestPreflightSheet: View {
    @Environment(\.dismiss) private var dismiss

    let report: DriveTestPreflightReport
    let onDismiss: () -> Void
    let onStartAnyway: () -> Void
    let onAction: (DriveTestPreflightIssue.Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.lg) {
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                Text(report.isBlocked ? "Enregistrement impossible" : "Avant de démarrer")
                    .font(SQFont.display(24, .bold))
                    .foregroundStyle(SQColor.label)
                    .accessibilityAddTraits(.isHeader)
                Text(
                    report.isBlocked
                    ? "Corrige le point bloquant ci-dessous."
                    : "Seuls les points susceptibles d'affecter cette session sont affichés."
                )
                .font(SQFont.body(14))
                .foregroundStyle(SQColor.labelSecondary)
            }

            ScrollView {
                VStack(spacing: SQSpace.sm) {
                    ForEach(report.issues) { issue in
                        issueRow(issue)
                    }
                }
            }

            HStack(spacing: SQSpace.sm) {
                Button("Fermer", role: .cancel) { close() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                if !report.isBlocked {
                    Button("Démarrer quand même") {
                        dismiss()
                        onStartAnyway()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SQColor.brandRed)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(SQSpace.lg)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func issueRow(_ issue: DriveTestPreflightIssue) -> some View {
        HStack(alignment: .top, spacing: SQSpace.sm + 2) {
            Image(systemName: icon(for: issue))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(color(for: issue))
                .frame(width: 38, height: 38)
                .background(color(for: issue).opacity(0.14), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title(for: issue))
                    .font(SQFont.body(14.5, .semibold))
                    .foregroundStyle(SQColor.label)
                Text(detail(for: issue))
                    .font(SQFont.body(12.5))
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if issue.action != .none {
                    Button(actionTitle(for: issue.action)) {
                        dismiss()
                        onAction(issue.action)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .padding(.top, 3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(SQSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func title(for issue: DriveTestPreflightIssue) -> String {
        switch issue.id {
        case .locationPermission:
            return issue.action == .requestLocation
                ? String(localized: "Autoriser la localisation")
                : String(localized: "Localisation désactivée")
        case .gpsFix: return String(localized: "Position GPS en cours d'acquisition")
        case .storage: return String(localized: "Espace de stockage faible")
        case .battery: return String(localized: "Batterie faible")
        case .connectivity: return String(localized: "Connexion indisponible")
        case .wifi: return String(localized: "WiFi détecté")
        case .constrainedNetwork: return String(localized: "Mode données faibles actif")
        }
    }

    private func detail(for issue: DriveTestPreflightIssue) -> String {
        switch issue.id {
        case .locationPermission:
            return issue.action == .requestLocation
                ? String(localized: "La position est nécessaire pour tracer et géolocaliser la session.")
                : String(localized: "Active la localisation dans les Réglages pour enregistrer le trajet.")
        case .gpsFix:
            return String(localized: "La position est absente, trop ancienne ou trop imprécise. Elle sera acquise au démarrage.")
        case .storage:
            let megabytes = issue.value ?? 0
            return issue.severity == .blocking
                ? String(localized: "Il ne reste que \(megabytes) Mo. Libère de l'espace avant d'enregistrer.")
                : String(localized: "Il ne reste que \(megabytes) Mo. Une longue session peut être interrompue.")
        case .battery:
            return String(localized: "Batterie à \(issue.value ?? 0) %. Branche le téléphone pour une longue session.")
        case .connectivity:
            return issue.severity == .blocking
                ? String(localized: "Le speedtest continu nécessite une connexion réseau.")
                : String(localized: "La couverture restera enregistrée localement ; les speedtests attendront le retour du réseau.")
        case .wifi:
            return String(localized: "Les speedtests resteront en pause et reprendront automatiquement en cellulaire.")
        case .constrainedNetwork:
            return String(localized: "iOS peut limiter les transferts nécessaires aux speedtests.")
        }
    }

    private func icon(for issue: DriveTestPreflightIssue) -> String {
        switch issue.id {
        case .locationPermission: return "location.slash.fill"
        case .gpsFix: return "location.circle.fill"
        case .storage: return "internaldrive.fill"
        case .battery: return "battery.25percent"
        case .connectivity: return "wifi.slash"
        case .wifi: return "wifi"
        case .constrainedNetwork: return "tortoise.fill"
        }
    }

    private func color(for issue: DriveTestPreflightIssue) -> Color {
        issue.severity == .blocking ? SQColor.danger : SQColor.warning
    }

    private func actionTitle(for action: DriveTestPreflightIssue.Action) -> String {
        switch action {
        case .none: return ""
        case .requestLocation: return String(localized: "Autoriser")
        case .openSettings: return String(localized: "Ouvrir les Réglages")
        }
    }

    private func close() {
        dismiss()
        onDismiss()
    }
}
