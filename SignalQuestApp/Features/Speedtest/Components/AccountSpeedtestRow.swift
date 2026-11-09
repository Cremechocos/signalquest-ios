import SwiftUI

/// Un test du compte absent de ce téléphone (UI-12) : date, réception, latence,
/// réseau. La fiche se charge au toucher (`AccountSpeedtestDetailSheet`) : la
/// liste n'en reçoit qu'un résumé.
struct AccountSpeedtestRow: View {
    let test: SocialShareableSpeedtest

    var body: some View {
        HStack(spacing: SQSpace.md) {
            Image(systemName: "icloud")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(SQColor.ink2)
                .frame(width: 34, height: 34)
                .background(SQColor.chip, in: RoundedRectangle(cornerRadius: SQRadius.iconTile, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: titleLine)
                    .font(SQFont.body(15, .bold))
                    .monospacedDigit()
                    .foregroundStyle(SQColor.label)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("speedtest.account.title")
                if !subtitleLine.isEmpty {
                    Text(verbatim: subtitleLine)
                        .font(SQFont.body(12.5))
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("speedtest.account.subtitle")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SQColor.labelTertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, SQSpace.cardPadding)
        .padding(.vertical, SQSpace.sm2)
        .frame(minHeight: 58)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// « 10 juil. · 388 Mbit/s · 21 ms »
    var titleLine: String {
        var parts: [String] = []
        if let date = test.displayedDate {
            parts.append(date.formatted(.dateTime.day().month(.abbreviated)))
        }
        if let download = test.downloadAverageMbps, download.isFinite, download > 0 {
            parts.append(SQUnits.throughput(mbps: download))
        } else {
            parts.append("—")
        }
        if let ping = test.ping, ping.isFinite, ping >= 0 {
            parts.append(SQUnits.milliseconds(ping))
        }
        return parts.joined(separator: " · ")
    }

    /// « 5G · Orange » : le nom complet de l'opérateur, pas la clé « ORANGE » du serveur.
    var subtitleLine: String {
        let raw = test.mobileOperator?.trimmingCharacters(in: .whitespacesAndNewlines)
        let operatorName = raw.flatMap { SQBrand.operatorName($0) } ?? raw
        return [TechAccent.shortLabel(for: test.networkType), operatorName]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: " · ")
    }
}

/// Fiche d'un test du compte fait ailleurs : chargée depuis le serveur, puis
/// rendue comme un test de ce téléphone. Sans réglage de visibilité : celui-ci
/// suit un test local par son identifiant client, que ce test n'a pas ici.
struct AccountSpeedtestDetailSheet: View {
    let testId: String
    let load: @Sendable (String) async throws -> SpeedtestDetail
    @State private var result: SpeedtestRunResult?
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                HStack {
                    MapChipIconButton(systemImage: "xmark", label: "Fermer", identifier: "speedtest.accountDetail.close") {
                        dismiss()
                    }
                    Spacer()
                }
                .padding(.horizontal, SQSpace.lg)
                .padding(.top, SQSpace.lg)
                if let result {
                    SpeedtestDetailContent(result: result, onDismiss: { dismiss() })
                        .padding(.bottom, SQSpace.xl)
                } else if let errorMessage {
                    SQNotice(message: errorMessage, tone: .warning)
                        .padding(SQSpace.lg)
                } else {
                    ProgressView()
                        .padding(SQSpace.xl)
                        .accessibilityLabel("Chargement du test")
                }
            }
            .sqReadableWidth()
        }
        .signalQuestBackground()
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task { await loadDetail() }
    }

    private func loadDetail() async {
        do {
            result = SpeedtestAccountHistory.runResult(from: try await load(testId))
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = String(localized: "Le détail de ce test n’a pas pu être chargé. \(error.userFacingMessage)")
        }
    }
}
