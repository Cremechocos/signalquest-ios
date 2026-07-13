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
                        .font(SQFont.body(13, .semibold, relativeTo: .footnote))
                        .foregroundStyle(SQColor.success)
                }
                if let errorMessage = model.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(SQType.caption)
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
                    // SESS-DETAIL-BUG-01 : rafraîchir la liste pour repasser l'antenne identifiée en vert.
                    await model.load(service: services.sessions)
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
        return GlassCard {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: SQSpace.sm), count: 2), spacing: SQSpace.sm) {
                statTile("Points", s.totalPoints.map { "\($0)" } ?? "—", "mappin.and.ellipse")
                statTile("Distance", s.distanceKm.map(Self.formatKm) ?? "—", "ruler")
                statTile("RSRP moyen", s.avgSignalStrength.map { "\(Int($0)) dBm" } ?? "—", "antenna.radiowaves.left.and.right")
                statTile(s.isDriveTest ? "Durée" : "Date",
                         s.isDriveTest ? (s.durationLabel ?? "—")
                                       : (s.startTime.map { $0.formatted(.dateTime.day().month().year()) } ?? "—"),
                         s.isDriveTest ? "clock" : "calendar")
            }
        }
    }

    private func statTile(_ label: String, _ value: String, _ icon: String) -> some View {
        HStack(spacing: SQSpace.sm) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(SQColor.brandRed)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(SQFont.body(11, relativeTo: .caption2)).foregroundStyle(SQColor.labelSecondary)
                Text(value)
                    .font(SQFont.display(15, .bold, relativeTo: .subheadline))
                    .foregroundStyle(SQColor.label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            Spacer(minLength: 0)
        }
        .padding(SQSpace.sm + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }

    // MARK: Operators + technologies chips

    private var chipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: SQSpace.sm) {
                ForEach(model.session.operators) { op in
                    HStack(spacing: 5) {
                        Circle().fill(Self.operatorColor(op.colorHex)).frame(width: 8, height: 8)
                        Text(op.label).font(SQFont.body(13, .semibold, relativeTo: .caption))
                        if let count = op.count {
                            Text("\(count)")
                                .font(SQFont.body(11.5, relativeTo: .caption2))
                                .foregroundStyle(SQColor.labelSecondary)
                        }
                    }
                    .foregroundStyle(SQColor.label)
                    .padding(.horizontal, SQSpace.md).padding(.vertical, 7)
                    .background(SQColor.surface, in: Capsule(style: .continuous))
                    .sqShadowSoft()
                }
                ForEach(model.session.technologies, id: \.self) { tech in
                    TechBadge(text: tech, color: SQBrand.techColor(tech))
                }
            }
            .padding(.vertical, SQSpace.xs)
        }
    }

    // MARK: Trace

    @ViewBuilder
    private var traceSection: some View {
        if let detail = model.detail, !(detail.points.isEmpty && detail.servingAntennas.isEmpty) {
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                SessionTraceMapView(points: detail.points,
                                    antennas: detail.servingAntennas,
                                    drawPath: model.session.isDriveTest,
                                    coloring: model.session.isIosCoverage ? .generation : .rsrp)
                    .frame(height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
                    .sqShadowCard()
                if !detail.points.isEmpty {
                    // Couverture iOS = génération seule (pas de RSRP) → légende génération.
                    if model.session.isIosCoverage {
                        generationLegend
                    } else {
                        rsrpLegend
                    }
                }
            }
        } else if model.detail != nil && !model.isLoading {
            Text("Aucun point géolocalisé pour cette session.")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, SQSpace.lg)
        }
    }

    /// Légende RSRP — couleurs dérivées de `SessionRSRPColor` (celles des points
    /// de la carte) pour garantir la correspondance légende ↔ tracé.
    private var rsrpLegend: some View {
        HStack(spacing: SQSpace.sm) {
            legendDot(SessionRSRPColor.ui(-70), "Excellent")
            legendDot(SessionRSRPColor.ui(-85), "Bon")
            legendDot(SessionRSRPColor.ui(-95), "Moyen")
            legendDot(SessionRSRPColor.ui(-105), "Faible")
            legendDot(SessionRSRPColor.ui(-115), "Mauvais")
        }
        .font(SQFont.body(11, .medium, relativeTo: .caption2))
        .foregroundStyle(SQColor.labelSecondary)
        .frame(maxWidth: .infinity)
    }

    /// Légende GÉNÉRATION (couverture iOS) — couleurs de `SessionGenerationColor`,
    /// identiques aux points de la carte (correspondance légende ↔ tracé).
    private var generationLegend: some View {
        HStack(spacing: SQSpace.sm) {
            legendDot(SessionGenerationColor.ui("5G"), "5G")
            legendDot(SessionGenerationColor.ui("4G"), "4G")
            legendDot(SessionGenerationColor.ui("3G"), "3G")
            legendDot(SessionGenerationColor.ui("2G"), "2G")
            legendDot(SessionGenerationColor.ui(nil), "Aucun")
        }
        .font(SQFont.body(11, .medium, relativeTo: .caption2))
        .foregroundStyle(SQColor.labelSecondary)
        .frame(maxWidth: .infinity)
    }

    private func legendDot(_ color: UIColor, _ label: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(Color(uiColor: color)).frame(width: 7, height: 7)
            Text(label)
        }
    }

    // MARK: Serving antennas

    private func servingAntennasSection(_ antennas: [ServingAntenna]) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Antennes desservantes")
                .font(SQType.heading)
                .foregroundStyle(SQColor.label)
                .padding(.bottom, SQSpace.xs)
            ForEach(antennas) { antenna in
                antennaRow(antenna)
                if antenna.id != antennas.last?.id {
                    Rectangle()
                        .fill(SQColor.separator)
                        .frame(height: 1)
                        .padding(.leading, SQSpace.lg + 2)
                }
            }
        }
        .padding(SQSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
        .sqShadowCard()
    }

    private func antennaRow(_ antenna: ServingAntenna) -> some View {
        HStack(spacing: SQSpace.sm) {
            Circle().fill(Self.statusColor(antenna.status)).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(antenna.operatorName ?? antenna.displayName ?? "Antenne")
                    .font(SQFont.body(15, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(SQColor.label)
                    .lineLimit(1)
                Text(Self.statusLabel(antenna))
                    .font(SQFont.body(11.5, relativeTo: .caption2))
                    .foregroundStyle(SQColor.labelSecondary)
                    .lineLimit(1)
                if let commune = antenna.commune, !commune.isEmpty {
                    Text(commune)
                        .font(SQFont.body(11.5, relativeTo: .caption2))
                        .foregroundStyle(SQColor.labelSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if antenna.isUnconfirmed && (antenna.siteId != nil || antenna.enb != nil || antenna.gnb != nil) {
                Button {
                    pendingIdentify = antenna
                } label: {
                    Group {
                        if model.identifyingId == antenna.id {
                            ProgressView().tint(SQColor.onAccent)
                        } else {
                            Text("Valider").font(SQFont.body(13, .semibold, relativeTo: .caption))
                        }
                    }
                    .foregroundStyle(SQColor.onAccent)
                    .padding(.horizontal, SQSpace.md + 2)
                    .frame(minHeight: 34)
                    .background(SQColor.brandRed, in: Capsule(style: .continuous))
                    // Capsule visuelle 34 pt, zone tactile étendue à ≥ 44 pt.
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(SQPressButtonStyle())
                .disabled(model.identifyingId != nil)
                .accessibilityLabel("Valider l'antenne \(antenna.operatorName ?? antenna.displayName ?? "")")
            }
            if antenna.siteId != nil {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(SQColor.labelTertiary)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let siteId = antenna.siteId {
                validationTarget = ValidationTarget(siteId: siteId, operatorName: antenna.operatorName)
            }
        }
        .padding(.vertical, SQSpace.sm)
    }

    private var emptyAntennasHint: some View {
        Label("Aucune antenne desservante résolue pour cette session.", systemImage: "antenna.radiowaves.left.and.right.slash")
            .font(SQType.caption)
            .foregroundStyle(SQColor.labelSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(SQSpace.md)
            .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
            .sqShadowSoft()
    }

    // MARK: Helpers

    static func formatKm(_ km: Double) -> String {
        if km < 1 { return "\(Int((km * 1000).rounded())) m" }
        return String(format: "%.1f km", km)
    }

    static func statusColor(_ s: ServingStatus) -> Color {
        switch s {
        case .identified: return SQColor.success
        case .hypothesis: return SQColor.warning
        case .proximity, .unknown: return SQColor.labelSecondary
        }
    }

    static func statusLabel(_ a: ServingAntenna) -> String {
        var parts: [String] = [a.status.label]
        // SESS-DETAIL-TELECOM-01 : la confiance n'a de sens que pour une hypothèse scorée ;
        // pour une antenne de proximité, la distance suffit à exprimer l'incertitude.
        if a.status == .hypothesis, let conf = a.confidenceFR {
            parts.append("confiance \(conf)")
        }
        if let d = a.distanceKm, d > 0 { parts.append("à \(formatKm(d))") }
        return parts.joined(separator: " · ")
    }

    /// Couleur d'opérateur fournie par le backend (donnée, pas décor) ;
    /// repli neutre si absente ou illisible.
    static func operatorColor(_ hex: String?) -> Color {
        guard let hex else { return SQColor.labelSecondary }
        let cleaned = hex.replacingOccurrences(of: "#", with: "")
        guard let value = UInt32(cleaned, radix: 16) else { return SQColor.labelSecondary }
        return Color(hex: value)
    }
}
