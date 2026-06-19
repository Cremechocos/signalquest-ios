import SwiftUI

@MainActor
final class SessionDetailViewModel: ObservableObject {
    @Published var detail: CoverageSessionDetail?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var identifyingId: String?
    @Published var identifyResult: String?

    let session: CoverageSession

    init(session: CoverageSession) { self.session = session }

    func load(service: SessionsServicing) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            detail = try await service.sessionDetail(id: session.id)
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
        }
    }

    /// Identifie une antenne non confirmée : croise les identifiants radio d'un
    /// point représentatif de la session avec le référentiel (backend).
    func identify(_ antenna: ServingAntenna, service: IdentifyServicing, location: LocationService) async {
        identifyingId = antenna.id
        identifyResult = nil
        defer { identifyingId = nil }
        // Point porteur des mêmes identifiants que l'antenne, sinon premier point radio.
        let sample = detail?.points.first { p in
            (antenna.enb != nil && p.enb == antenna.enb) || (antenna.gnb != nil && p.gnb == antenna.gnb)
        } ?? detail?.points.first { $0.enb != nil || $0.gnb != nil || $0.pci != nil }
        let coord = await location.currentLocation(timeoutSeconds: 5)?.coordinate ?? antenna.coordinate
        do {
            let result = try await service.identify(
                siteId: antenna.siteId,
                enb: sample?.enb ?? antenna.enb,
                gnb: sample?.gnb ?? antenna.gnb,
                pci: sample?.pci ?? antenna.pci,
                cellId: sample?.cellId ?? antenna.cellId,
                operatorName: antenna.operatorName, mcc: nil, mnc: nil,
                lat: coord.latitude, lng: coord.longitude
            )
            identifyResult = result.success ? "Site identifié ✓" : (result.message ?? "Identification non confirmée")
            Haptics.success()
        } catch {
            identifyResult = "Échec : \(error.localizedDescription)"
            Haptics.error()
        }
    }
}

struct SessionDetailView: View {
    @EnvironmentObject private var services: AppServices
    @StateObject private var model: SessionDetailViewModel
    @State private var validationTarget: ValidationTarget?
    @State private var pendingIdentify: ServingAntenna?

    struct ValidationTarget: Identifiable {
        let id = UUID()
        let siteId: String
        let operatorName: String?
    }

    init(session: CoverageSession) {
        _model = StateObject(wrappedValue: SessionDetailViewModel(session: session))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                statsCard
                if !model.session.operators.isEmpty || !model.session.technologies.isEmpty {
                    chipsRow
                }
                traceSection
                if let antennas = model.detail?.servingAntennas, !antennas.isEmpty {
                    servingAntennasSection(antennas)
                } else if model.detail != nil && !model.isLoading {
                    emptyAntennasHint
                }
                if let result = model.identifyResult {
                    Label(result, systemImage: "checkmark.seal")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(SQColor.brandGreen)
                }
                if let errorMessage = model.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(SQColor.warning)
                }
            }
            .padding()
        }
        .background(SQColor.bg.ignoresSafeArea())
        .navigationTitle(model.session.name ?? (model.session.isDriveTest ? "Drive-test" : "Couverture"))
        .toolbarTitleInlineCompat()
        .overlay {
            if model.isLoading && model.detail == nil { ProgressView().tint(SQColor.brandRed) }
        }
        .task { await model.load(service: services.sessions) }
        .sheet(item: $validationTarget) { target in
            ValidationsSheet(siteId: target.siteId, operatorName: target.operatorName, service: services.validations)
        }
        .confirmationDialog(
            "Confirmer cette antenne ?",
            isPresented: Binding(get: { pendingIdentify != nil }, set: { if !$0 { pendingIdentify = nil } }),
            presenting: pendingIdentify
        ) { antenna in
            Button("Valider cette antenne", role: .none) {
                Task {
                    await model.identify(antenna, service: services.identify, location: services.location)
                    pendingIdentify = nil
                }
            }
            Button("Annuler", role: .cancel) { pendingIdentify = nil }
        } message: { antenna in
            Text("Cette antenne est indiquée comme \(Self.statusLabel(antenna)). Confirme uniquement si tu l'as sélectionnée comme antenne réelle.")
        }
    }

    // MARK: Stats

    private var statsCard: some View {
        let s = model.session
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: SQSpace.sm), count: 2), spacing: SQSpace.sm) {
            statTile("Points", s.totalPoints.map { "\($0)" } ?? "—", "mappin.and.ellipse")
            statTile("Distance", s.distanceKm.map(Self.formatKm) ?? "—", "ruler")
            statTile("RSRP moyen", s.avgSignalStrength.map { "\(Int($0)) dBm" } ?? "—", "antenna.radiowaves.left.and.right")
            statTile(s.isDriveTest ? "Durée" : "Date",
                     s.isDriveTest ? (s.durationLabel ?? "—")
                                   : (s.startTime.map { $0.formatted(.dateTime.day().month().year()) } ?? "—"),
                     s.isDriveTest ? "clock" : "calendar")
        }
    }

    private func statTile(_ label: String, _ value: String, _ icon: String) -> some View {
        HStack(spacing: SQSpace.sm) {
            Image(systemName: icon)
                .foregroundStyle(SQColor.brandOrange)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.caption2).foregroundStyle(SQColor.labelSecondary)
                Text(value).font(.subheadline.weight(.semibold)).foregroundStyle(SQColor.label).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(SQSpace.sm + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: Operators + technologies chips

    private var chipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: SQSpace.sm) {
                ForEach(model.session.operators) { op in
                    HStack(spacing: 5) {
                        Circle().fill(Self.operatorColor(op.colorHex)).frame(width: 8, height: 8)
                        Text(op.label).font(.caption.weight(.semibold))
                        if let count = op.count { Text("\(count)").font(.caption2).foregroundStyle(SQColor.labelSecondary) }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(SQColor.surface, in: Capsule())
                    .overlay(Capsule().stroke(Self.operatorColor(op.colorHex).opacity(0.35), lineWidth: 1))
                }
                ForEach(model.session.technologies, id: \.self) { tech in
                    Text(tech)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(SQColor.brandBlue.opacity(0.15), in: Capsule())
                        .foregroundStyle(SQColor.brandBlue)
                }
            }
        }
    }

    // MARK: Trace

    @ViewBuilder
    private var traceSection: some View {
        if let detail = model.detail, !(detail.points.isEmpty && detail.servingAntennas.isEmpty) {
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                SessionTraceMapView(points: detail.points,
                                    antennas: detail.servingAntennas,
                                    drawPath: model.session.isDriveTest)
                    .frame(height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous)
                            .stroke(SQColor.separator, lineWidth: 1)
                    }
                if !detail.points.isEmpty {
                    rsrpLegend
                }
            }
        } else if model.detail != nil && !model.isLoading {
            Text("Aucun point géolocalisé pour cette session.")
                .font(.footnote)
                .foregroundStyle(SQColor.labelSecondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, SQSpace.lg)
        }
    }

    private var rsrpLegend: some View {
        HStack(spacing: SQSpace.sm) {
            legendDot(0x10B981, "Excellent")
            legendDot(0x84CC16, "Bon")
            legendDot(0xF59E0B, "Moyen")
            legendDot(0xF97316, "Faible")
            legendDot(0xEF4444, "Mauvais")
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(SQColor.labelSecondary)
        .frame(maxWidth: .infinity)
    }

    private func legendDot(_ hex: UInt32, _ label: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(Color(hex: hex)).frame(width: 7, height: 7)
            Text(label)
        }
    }

    // MARK: Serving antennas

    private func servingAntennasSection(_ antennas: [ServingAntenna]) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Antennes desservantes")
                .font(SQFont.archivo(12, .semibold))
                .tracking(0.4)
                .textCase(.uppercase)
                .foregroundStyle(SQColor.labelSecondary)
            ForEach(antennas) { antenna in
                antennaRow(antenna)
                if antenna.id != antennas.last?.id { Divider().overlay(SQColor.separator) }
            }
        }
        .padding(SQSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func antennaRow(_ antenna: ServingAntenna) -> some View {
        HStack(spacing: SQSpace.sm) {
            Circle().fill(Self.statusColor(antenna.status)).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(antenna.operatorName ?? antenna.displayName ?? "Antenne")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SQColor.label)
                    .lineLimit(1)
                Text(Self.statusLabel(antenna))
                    .font(.caption2)
                    .foregroundStyle(SQColor.labelSecondary)
                    .lineLimit(1)
                if let commune = antenna.commune, !commune.isEmpty {
                    Text(commune).font(.caption2).foregroundStyle(SQColor.labelSecondary).lineLimit(1)
                }
            }
            Spacer()
            if antenna.isUnconfirmed && (antenna.siteId != nil || antenna.enb != nil || antenna.gnb != nil) {
                Button {
                    pendingIdentify = antenna
                } label: {
                    if model.identifyingId == antenna.id {
                        ProgressView()
                    } else {
                        Text("Valider").font(.caption.weight(.bold))
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(SQColor.brandOrange)
                .disabled(model.identifyingId != nil)
            }
            if antenna.siteId != nil {
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(SQColor.labelSecondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let siteId = antenna.siteId {
                validationTarget = ValidationTarget(siteId: siteId, operatorName: antenna.operatorName)
            }
        }
        .padding(.vertical, 6)
    }

    private var emptyAntennasHint: some View {
        Label("Aucune antenne desservante résolue pour cette session.", systemImage: "antenna.radiowaves.left.and.right.slash")
            .font(.footnote)
            .foregroundStyle(SQColor.labelSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(SQSpace.md)
            .background(SQColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: Helpers

    static func formatKm(_ km: Double) -> String {
        if km < 1 { return "\(Int((km * 1000).rounded())) m" }
        return String(format: "%.1f km", km)
    }

    static func statusColor(_ s: ServingStatus) -> Color {
        switch s {
        case .identified: return SQColor.brandGreen
        case .hypothesis: return SQColor.brandOrange
        case .proximity, .unknown: return SQColor.labelSecondary
        }
    }

    static func statusLabel(_ a: ServingAntenna) -> String {
        var parts: [String] = [a.status.label]
        if a.status == .hypothesis || a.status == .proximity, let conf = a.confidenceFR {
            parts.append("confiance \(conf)")
        }
        if let d = a.distanceKm, d > 0 { parts.append("à \(formatKm(d))") }
        return parts.joined(separator: " · ")
    }

    static func operatorColor(_ hex: String?) -> Color {
        guard let hex else { return SQColor.brandBlue }
        let cleaned = hex.replacingOccurrences(of: "#", with: "")
        guard let value = UInt32(cleaned, radix: 16) else { return SQColor.brandBlue }
        return Color(hex: value)
    }
}
