import SwiftUI

// MARK: - ViewModel

@MainActor
final class ANFRSiteDetailViewModel: ObservableObject {
    @Published var history: ANFRSiteHistory?
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let service: ANFRServicing
    init(service: ANFRServicing) { self.service = service }

    func load(supId: String) async {
        if AppEnvironment.usesDemoData {
            history = ANFRDemoData.siteHistory
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            history = try await service.siteHistory(supId: supId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Sheet

struct ANFRSiteDetailSheet: View {
    let site: ANFRMapSite
    @StateObject private var model: ANFRSiteDetailViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    init(site: ANFRMapSite, service: ANFRServicing) {
        self.site = site
        _model = StateObject(wrappedValue: ANFRSiteDetailViewModel(service: service))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SQSpace.lg) {
                    header
                    currentAntennasCard
                    timelineSection
                }
                .padding(SQSpace.lg)
                .padding(.bottom, SQSpace.huge)
            }
            .signalQuestBackground()
            .navigationTitle("Support \(site.supId)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fermer") { dismiss() }
                        .font(SQType.button)
                        .foregroundStyle(SQColor.brandRed)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackgroundCompat(SQColor.bg)
        .task { await model.load(supId: site.supId) }
        .onAppear {
            withAnimation(reduceMotion ? nil : SQMotion.standard.delay(0.05)) { appeared = true }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Site ANFR").sqKicker()
            Text(site.city.isEmpty ? "Support \(site.supId)" : site.city.capitalized)
                .font(SQType.title)
                .foregroundStyle(SQColor.label)
            HStack(spacing: SQSpace.xs + 2) {
                Image(systemName: "mappin.circle.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(SQColor.brandRed)
                Text(String(format: "%.5f, %.5f", site.latitude, site.longitude))
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }
            // Pastilles opérateurs + générations présents.
            HStack(spacing: SQSpace.xs + 2) {
                ForEach(site.operators) { op in
                    SQEditorialTag(text: op.label, color: op.color)
                }
                if let gen = site.highestGeneration {
                    SQEditorialTag(text: gen.label, color: gen.color)
                }
            }
            .padding(.top, SQSpace.xs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Current antennas

    private var currentAntennasCard: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            sectionTitle("Antennes au relevé", systemImage: "antenna.radiowaves.left.and.right")
            ForEach(site.antennas) { antenna in
                HStack(spacing: SQSpace.sm) {
                    Circle()
                        .fill((antenna.operator?.color) ?? SQColor.labelSecondary)
                        .frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(antenna.system.isEmpty ? (antenna.operator?.label ?? "Antenne") : antenna.system)
                            .font(SQFont.archivo(14, .semibold))
                            .foregroundStyle(SQColor.label)
                        Text(antenna.statut)
                            .font(SQType.micro)
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                    Spacer()
                    if let gen = antenna.generationEnum {
                        SQEditorialTag(text: gen.label, color: gen.color)
                    }
                    modTypeBadge(antenna.modType)
                }
                .padding(.vertical, SQSpace.sm)
                .padding(.horizontal, SQSpace.md)
                .background(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
            }
            if site.antennas.isEmpty {
                Text("Aucune antenne au relevé courant.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }
        }
        .padding(SQSpace.lg)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous)
                .stroke(SQColor.separator, lineWidth: 1.5)
        }
    }

    // MARK: Timeline

    @ViewBuilder
    private var timelineSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            sectionTitle("Historique des modifications", systemImage: "clock.arrow.circlepath")

            if model.isLoading {
                HStack(spacing: SQSpace.sm) {
                    ProgressView().tint(SQColor.brandRed)
                    Text("Chargement de l'historique…")
                        .font(SQType.subhead)
                        .foregroundStyle(SQColor.labelSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, SQSpace.md)
            } else if let history = model.history, !history.entries.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(history.entries.enumerated()), id: \.element.id) { index, entry in
                        ANFRTimelineRow(
                            entry: entry,
                            isFirst: index == 0,
                            isLast: index == history.entries.count - 1
                        )
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 10)
                        .animation(
                            reduceMotion ? nil : SQMotion.standard.delay(Double(index) * 0.05),
                            value: appeared
                        )
                    }
                }
            } else if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.warning)
            } else {
                Text("Aucune modification archivée pour ce support.")
                    .font(SQType.subhead)
                    .foregroundStyle(SQColor.labelSecondary)
            }
        }
        .padding(SQSpace.lg)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous)
                .stroke(SQColor.separator, lineWidth: 1.5)
        }
    }

    // MARK: Helpers

    private func sectionTitle(_ title: String, systemImage: String) -> some View {
        HStack(spacing: SQSpace.sm) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(SQColor.brandRed)
            Text(title)
                .font(SQType.heading)
                .foregroundStyle(SQColor.label)
        }
    }

    private func modTypeBadge(_ type: ANFRModType) -> some View {
        Image(systemName: type.glyph)
            .font(.system(size: 11, weight: .black))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(type.color, in: Circle())
    }
}

// MARK: - Timeline row

private struct ANFRTimelineRow: View {
    let entry: ANFRSiteHistoryEntry
    let isFirst: Bool
    let isLast: Bool

    private var dominantModType: ANFRModType {
        entry.modTypeEnums.max { $0.priority < $1.priority } ?? .added
    }

    var body: some View {
        HStack(alignment: .top, spacing: SQSpace.md) {
            // Rail + nœud
            VStack(spacing: 0) {
                Rectangle()
                    .fill(isFirst ? Color.clear : SQColor.separator)
                    .frame(width: 2, height: 10)
                Circle()
                    .fill(dominantModType.color)
                    .frame(width: 14, height: 14)
                    .overlay { Circle().stroke(SQColor.surface, lineWidth: 2) }
                Rectangle()
                    .fill(isLast ? Color.clear : SQColor.separator)
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: 14)

            // Contenu daté
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                HStack(spacing: SQSpace.sm) {
                    Text(prettyDate(entry.archiveDate))
                        .font(SQFont.archivo(14, .bold))
                        .foregroundStyle(SQColor.label)
                    if entry.isCurrentSnapshot {
                        Text("Actuel")
                            .font(SQType.micro)
                            .foregroundStyle(SQColor.brandRed)
                            .padding(.horizontal, SQSpace.sm)
                            .padding(.vertical, 2)
                            .background(SQColor.brandRed.opacity(0.12), in: Capsule())
                    }
                    Spacer()
                }
                ForEach(entry.changes) { change in
                    HStack(spacing: SQSpace.sm) {
                        Image(systemName: change.modType.glyph)
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(.white)
                            .frame(width: 18, height: 18)
                            .background(change.modType.color, in: Circle())
                        VStack(alignment: .leading, spacing: 1) {
                            Text(changeText(change))
                                .font(SQFont.archivo(13, .semibold))
                                .foregroundStyle(SQColor.label)
                                .lineLimit(2)
                            Text(change.modType.label)
                                .font(SQType.micro)
                                .foregroundStyle(change.modType.color)
                        }
                        Spacer()
                        if let gen = change.generationEnum {
                            Text(gen.label)
                                .font(SQType.micro)
                                .foregroundStyle(gen.color)
                        }
                    }
                }
            }
            .padding(.bottom, SQSpace.lg)
        }
    }

    private func changeText(_ change: ANFRSiteHistoryChange) -> String {
        let op = change.operator?.label ?? change.operatorRaw.capitalized
        let tech = change.technology.isEmpty ? "" : " · \(change.technology)"
        return "\(op)\(tech)"
    }

    private func prettyDate(_ raw: String) -> String {
        ANFRDateParser.date(from: raw)?.formatted(.dateTime.day().month(.wide).year()) ?? raw
    }
}
