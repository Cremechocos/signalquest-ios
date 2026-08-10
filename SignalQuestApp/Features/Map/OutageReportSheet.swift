import CoreLocation
import SwiftUI

/// Feuille de signalement d'une panne.
///
/// L'ordre suit la question qu'on se pose vraiment sur place : « qu'est-ce qui ne marche pas »,
/// puis « quoi précisément », puis « où je suis ». Demander la position en premier — le réflexe
/// technique, puisque c'est elle qui conditionne l'envoi — ferait passer une formalité avant le
/// constat. Même ordre que sur Android, à dessein.
struct OutageReportSheet: View {
    let siteId: String
    let siteLabel: String
    let marketCode: String
    let operatorKey: String
    let siteLatitude: Double?
    let siteLongitude: Double?
    let service: CommunityOutageServicing
    /// Appelé après un envoi réussi, pour que la fiche recharge ses pannes.
    var onSubmitted: ((OutageWriteResponse) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var services: AppServices

    @State private var severity: OutageSeverity = .down
    @State private var affectsData = true
    @State private var affectsVoice = false
    @State private var affectsSms = false
    @State private var submitting = false
    @State private var errorMessage: String?
    @State private var distanceMeters: Int?
    @State private var accuracyMeters: Int?

    /// « Quelque chose ne marche pas, mais rien de précis » n'est pas exploitable par la communauté.
    private var canSubmit: Bool {
        !submitting && (affectsData || affectsVoice || affectsSms)
    }

    private var tint: Color { OutageTint.of(severity) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SQSpace.md) {
                    header
                    whatSection
                    servicesSection
                    positionSection
                    if let errorMessage {
                        Text(errorMessage)
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.danger)
                    }
                    submitButton
                    Text("Votre signalement est visible tout de suite. Il devient « confirmé » quand deux autres personnes constatent la même chose.")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                }
                .padding(SQSpace.lg)
            }
            .background(SQColor.bg)
            .navigationTitle("Signaler un problème")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
            }
        }
        .task { await measureDistance() }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: SQSpace.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(siteLabel)
                    .font(SQFont.body(14, .semibold))
                    .foregroundStyle(SQColor.label)
                Text(operatorKey)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(SQSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
    }

    private var whatSection: some View {
        module("Que constatez-vous ?") {
            VStack(spacing: SQSpace.sm) {
                severityOption(
                    .down,
                    title: "Plus rien",
                    detail: "Rien ne passe : ni Internet, ni appels, ni SMS",
                    accent: OutageTint.down
                )
                severityOption(
                    .degraded,
                    title: "Dégradé",
                    detail: "Ça passe moins bien que d'habitude",
                    accent: OutageTint.degraded
                )
            }
        }
    }

    private var servicesSection: some View {
        module("Services touchés") {
            HStack(spacing: SQSpace.sm) {
                serviceChip("Internet", isOn: $affectsData)
                serviceChip("Voix", isOn: $affectsVoice)
                serviceChip("SMS", isOn: $affectsSms)
            }
        }
    }

    /// La position est DITE, pas demandée.
    ///
    /// L'éligibilité se joue côté serveur ; on annonce simplement ce qu'il verra, pour qu'un
    /// refus ne soit jamais une surprise. Position inconnue ne bloque pas : la branche
    /// « historique récent » peut encore faire passer le signalement.
    private var positionSection: some View {
        HStack(spacing: SQSpace.sm) {
            Image(systemName: "location.fill")
                .font(.caption)
                .foregroundStyle(SQColor.labelSecondary)
            Text(positionLabel)
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
            Spacer(minLength: 0)
        }
        .padding(SQSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SQColor.fill, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
    }

    private var positionLabel: String {
        guard let distanceMeters else {
            return "Position inconnue — le signalement partira si vous avez déjà relevé du signal ici."
        }
        guard let accuracyMeters else { return "Vous êtes à \(distanceMeters) m du site." }
        return "Vous êtes à \(distanceMeters) m du site, à \(accuracyMeters) m près."
    }

    private var submitButton: some View {
        Button {
            Task { await submit() }
        } label: {
            HStack {
                Spacer()
                if submitting {
                    ProgressView().tint(.white)
                } else {
                    Text("Signaler la panne")
                        .font(SQFont.body(15, .semibold))
                        .foregroundStyle(.white)
                }
                Spacer()
            }
            .frame(minHeight: 50)
            .background(
                canSubmit ? tint : SQColor.fill,
                in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(!canSubmit)
    }

    // MARK: - Fragments

    private func module<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text(title)
                .font(SQFont.body(12.5, .semibold))
                .foregroundStyle(SQColor.labelSecondary)
            content()
        }
        .padding(SQSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
    }

    private func severityOption(
        _ value: OutageSeverity,
        title: String,
        detail: String,
        accent: Color
    ) -> some View {
        let selected = severity == value
        return Button {
            severity = value
            // « Plus rien » dit littéralement que RIEN ne passe : redemander lesquels des trois
            // services sont touchés serait reposer une question déjà répondue. Les cases restent
            // modifiables, on ne fait que pré-remplir l'évidence.
            if value == .down {
                affectsData = true
                affectsVoice = true
                affectsSms = true
            }
        } label: {
            HStack(spacing: SQSpace.sm) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? accent : SQColor.labelTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(SQFont.body(14, .semibold))
                        .foregroundStyle(SQColor.label)
                    Text(detail)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(SQSpace.sm)
            .background(
                selected ? accent.opacity(0.12) : SQColor.fill,
                in: RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func serviceChip(_ label: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Text(label)
                .font(SQFont.body(13, isOn.wrappedValue ? .semibold : .medium))
                .foregroundStyle(isOn.wrappedValue ? tint : SQColor.labelSecondary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(
                    isOn.wrappedValue ? tint.opacity(0.13) : SQColor.fill,
                    in: RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn.wrappedValue ? [.isSelected] : [])
    }

    // MARK: - Actions

    /// Annonce la distance que le serveur vérifiera, sans jamais bloquer dessus.
    private func measureDistance() async {
        guard
            let siteLatitude, let siteLongitude,
            let here = services.location.lastLocation
        else { return }
        let site = CLLocation(latitude: siteLatitude, longitude: siteLongitude)
        distanceMeters = Int(here.distance(from: site))
        if here.horizontalAccuracy > 0 { accuracyMeters = Int(here.horizontalAccuracy) }
    }

    private func submit() async {
        submitting = true
        errorMessage = nil
        let here = services.location.lastLocation
        do {
            let response = try await service.report(
                OutageReportRequest(
                    targetKind: "anfr",
                    targetId: siteId,
                    marketCode: marketCode,
                    operatorKey: operatorKey,
                    severity: severity.rawValue,
                    affectsData: affectsData,
                    affectsVoice: affectsVoice,
                    affectsSms: affectsSms,
                    latitude: here?.coordinate.latitude,
                    longitude: here?.coordinate.longitude,
                    accuracyMeters: here.flatMap { $0.horizontalAccuracy > 0 ? $0.horizontalAccuracy : nil }
                )
            )
            submitting = false
            onSubmitted?(response)
            dismiss()
        } catch {
            submitting = false
            // Message du serveur, déjà rédigé en français — affiché tel quel.
            errorMessage = error.localizedDescription
        }
    }
}
