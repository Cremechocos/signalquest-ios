import SwiftUI
import MapKit

/// Fiche d'un site canadien de la carte des modifications (ISED-STATS v1, §10) : ce
/// qui a changé, émetteur par émetteur, sans historique ANFR. Un émetteur encore
/// présent ouvre sa ligne de licence ; un émetteur retiré n'en a plus.
struct ISEDSiteChangesSheet: View {
    let site: ANFRMapSite
    let changes: ISEDSiteChanges
    let service: ANFRServicing
    /// Bilan d'une comparaison de plusieurs extraits, plutôt que d'un seul mois.
    let isComparison: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var copiedCoordinates = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SQSpace.lg) {
                    header
                    actionsRow
                    changesCard
                }
                .padding(SQSpace.lg)
                .padding(.bottom, SQSpace.huge)
            }
            .signalQuestBackground()
            .navigationTitle(site.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fermer") { dismiss() }
                        .font(SQType.button)
                        .foregroundStyle(SQColor.accentInk)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackgroundCompat(SQColor.bg)
        .presentationBackgroundInteractionCompat()
    }

    // MARK: En-tête

    private var header: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text(site.displayName)
                .font(SQType.title)
                .sqHeader()
                .foregroundStyle(SQColor.label)
            Group {
                if let province = changes.province, !province.isEmpty {
                    Text("Site ISED · \(province)")
                } else {
                    Text("Site ISED")
                }
            }
            .font(SQType.caption)
            .foregroundStyle(SQColor.labelSecondary)
            HStack(spacing: SQSpace.xs2) {
                Image(systemName: "mappin.circle.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(SQColor.brandRed)
                    .accessibilityHidden(true)
                Text(ANFRSiteDetailSheet.coordinateText(site))
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Latitude \(ANFRSiteDetailSheet.decimal(site.latitude)), longitude \(ANFRSiteDetailSheet.decimal(site.longitude))"))
            ANFRFlowLayout(spacing: SQSpace.xs2) {
                ForEach(site.mapOperators) { op in
                    SQEditorialTag(text: op.label, color: op.color)
                }
            }
            .padding(.top, SQSpace.xs)
            // Les autres titulaires sont regroupés : la fiche dit lequel.
            if let holder = changes.holderName, !holder.isEmpty {
                Text("Titulaire : \(holder)")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Actions

    private var actionsRow: some View {
        ANFRFlowLayout(spacing: SQSpace.sm) {
            Button {
                Haptics.light()
                let item = MKMapItem(placemark: MKPlacemark(coordinate: site.coordinate))
                item.name = site.displayName
                item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
            } label: {
                actionLabel("Itinéraire", systemImage: "arrow.triangle.turn.up.right.diamond")
            }
            .buttonStyle(.plain)

            Button {
                Haptics.light()
                UIPasteboard.general.string = ANFRSiteDetailSheet.posixCoordinates(site)
                copiedCoordinates = true
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    copiedCoordinates = false
                }
            } label: {
                actionLabel(copiedCoordinates ? "Coordonnées copiées" : "Copier les coordonnées",
                            systemImage: copiedCoordinates ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func actionLabel(_ title: LocalizedStringKey, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(SQType.subhead(.semibold))
            .foregroundStyle(SQColor.accentInk)
            .padding(.horizontal, SQSpace.md)
            .frame(minHeight: 44)
            .background(SQColor.accentSoft, in: Capsule(style: .continuous))
            .contentShape(Capsule(style: .continuous))
    }

    // MARK: Changements

    private var changesCard: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            Label(isComparison ? "Changements sur la période" : "Changements de ce mois",
                  systemImage: "antenna.radiowaves.left.and.right")
                .font(SQType.heading)
                .foregroundStyle(SQColor.label)
                .sqHeader()
            Text("Un émetteur est une technologie dans une famille de bande. Un changement de puissance seule n’est pas compté.")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(ANFRMapMarket.ca.modTypes) { type in
                let items = changes.items.filter { $0.type == type }
                if !items.isEmpty {
                    VStack(alignment: .leading, spacing: SQSpace.xs) {
                        HStack(spacing: SQSpace.sm) {
                            Image(systemName: type.glyph(in: .ca))
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(type.color)
                                .frame(width: 22, height: 22)
                                .background(type.color.opacity(0.14), in: Circle())
                                .accessibilityHidden(true)
                            Text(type.label(in: .ca))
                                .font(SQType.callout(.semibold))
                                .foregroundStyle(SQColor.label)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isHeader)
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            itemRow(item)
                        }
                    }
                }
            }
        }
        .padding(SQSpace.lg)
        .sqCardBackground()
    }

    @ViewBuilder
    private func itemRow(_ item: ISEDChangeItem) -> some View {
        if let siteKey = item.siteKey {
            NavigationLink {
                ISEDLicenceView(recordId: siteKey, service: service)
            } label: {
                itemLabel(item, opensLicence: true)
            }
            .buttonStyle(SQPressButtonStyle())
            .accessibilityHint("Ouvre la ligne de licence ISED")
        } else {
            itemLabel(item, opensLicence: false)
        }
    }

    private func itemLabel(_ item: ISEDChangeItem, opensLicence: Bool) -> some View {
        HStack(spacing: SQSpace.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(SQType.callout(.semibold))
                    .foregroundStyle(SQColor.label)
                let detail = [operatorName(item.operatorKey), item.whatLabel].compactMap { $0 }.joined(separator: " · ")
                if !detail.isEmpty {
                    Text(detail)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if opensLicence {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SQColor.labelTertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, SQSpace.sm)
        .padding(.horizontal, SQSpace.md)
        .frame(minHeight: 44)
        .sqSurface(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func operatorName(_ key: String) -> String? {
        guard !key.isEmpty else { return nil }
        return ANFRStatsOperator.canada.first { $0.key == key }?.label ?? key
    }
}

/// Une ligne de licence ISED : titulaire, autorisation, fréquences, puissance, hauteur.
struct ISEDLicenceView: View {
    let recordId: String
    let service: ANFRServicing
    @State private var record: ISEDSiteRecord?
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                if let record {
                    content(record)
                } else if let errorMessage {
                    VStack(alignment: .leading, spacing: SQSpace.md) {
                        Text(errorMessage)
                            .font(SQType.body)
                            .foregroundStyle(SQColor.label)
                            .fixedSize(horizontal: false, vertical: true)
                        GradientButton("Réessayer", systemImage: "arrow.clockwise", style: .secondary) {
                            Task { await load() }
                        }
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, SQSpace.xl)
                }
            }
            .padding(SQSpace.lg)
            .padding(.bottom, SQSpace.huge)
        }
        .signalQuestBackground()
        .navigationTitle("Licence ISED")
        .navigationBarTitleDisplayMode(.inline)
        .task { if record == nil { await load() } }
    }

    private func load() async {
        errorMessage = nil
        do {
            record = try await service.isedSite(recordId: recordId)
        } catch {
            if !error.isCancellation { errorMessage = error.userFacingMessage }
        }
    }

    @ViewBuilder
    private func content(_ record: ISEDSiteRecord) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            if let holder = record.licenceeName, !holder.isEmpty {
                Text(holder)
                    .font(SQType.title)
                    .foregroundStyle(SQColor.label)
                    .sqHeader()
            }
            if let number = record.authorisationNumber, !number.isEmpty {
                Text("Autorisation \(number)")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .textSelection(.enabled)
            }
        }
        if !record.frequencies.isEmpty {
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                Text("Fréquences")
                    .font(SQType.heading)
                    .foregroundStyle(SQColor.label)
                    .sqHeader()
                ForEach(record.frequencies, id: \.self) { frequency in
                    Text(Self.frequencyText(frequency))
                        .font(SQType.callout)
                        .foregroundStyle(SQColor.label)
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(.horizontal, SQSpace.md)
                        .sqSurface(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                }
            }
            .padding(SQSpace.lg)
            .sqCardBackground()
        }
        let facts = Self.facts(record)
        if !facts.isEmpty {
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                ForEach(facts, id: \.0) { fact in
                    HStack {
                        Text(fact.0)
                            .foregroundStyle(SQColor.labelSecondary)
                        Spacer()
                        Text(fact.1)
                            .foregroundStyle(SQColor.label)
                            .monospacedDigit()
                    }
                    .font(SQType.callout)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(SQSpace.lg)
            .sqCardBackground()
        }
    }

    /// « 3 505 MHz · 10 MHz · LTE B42 » : centre, largeur, technologie et bande publiées.
    static func frequencyText(_ frequency: ISEDSiteRecord.Frequency) -> String {
        let mhz = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...1))
        var parts: [String] = []
        if let center = frequency.centerFrequencyMhz { parts.append("\(center.formatted(mhz)) MHz") }
        if let width = frequency.bandwidthMhz { parts.append(String(localized: "\(width.formatted(mhz)) MHz de large")) }
        if let label = frequency.bandLabel ?? frequency.technology, !label.isEmpty { parts.append(label) }
        return parts.joined(separator: " · ")
    }

    private static func facts(_ record: ISEDSiteRecord) -> [(String, String)] {
        var facts: [(String, String)] = []
        let oneDecimal = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...1))
        if let power = record.transmitPowerDbm {
            facts.append((String(localized: "Puissance d’émission"), "\(power.formatted(oneDecimal)) dBm"))
        }
        if let height = record.antennaStructureHeightM {
            facts.append((String(localized: "Hauteur de la structure"), "\(height.formatted(oneDecimal)) m"))
        }
        return facts
    }
}
