import SwiftUI
import MapKit
import CoreLocation

/// Pose un site à partir de cellules observées.
///
/// Les cellules apportent l'identité radio — eNB, PCI, TAC, bande, PLMN — mais
/// leur position n'est qu'un centroïde de mesures. L'écran part donc de ce
/// centroïde, le donne comme point de départ, et laisse déplacer la carte
/// jusqu'au pylône réel. C'est le seul apport que la machine ne peut pas
/// fournir : quelqu'un qui l'a vu.
struct CreateSiteFromCellsView: View {
    let cells: [AndroidCommunitySiteMarker]
    let operatorLabel: (String) -> String
    let service: CustomSitesServicing
    /// Appelé après création réussie, pour rafraîchir la carte.
    let onCreated: () -> Void

    @State private var name = ""
    @State private var type = "PYLONE"
    @State private var note = ""
    @State private var region: MKCoordinateRegion
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var pendingMessage: String?
    @State private var isQueued = false
    @Environment(\.dismiss) private var dismiss

    /// Types acceptés par le backend (`ALLOWED_TYPES`). Envoyer autre chose fait
    /// échouer la création en 400.
    private static let types: [(value: String, label: String)] = [
        ("PYLONE", String(localized: "Pylône")),
        ("TOIT", String(localized: "Toit-terrasse")),
        ("CHATEAU_EAU", String(localized: "Château d'eau")),
        ("INFRASTRUCTURE", String(localized: "Infrastructure")),
        ("LIEU_PUBLIC", String(localized: "Lieu public")),
        ("AUTRE", String(localized: "Autre"))
    ]

    init(
        cells: [AndroidCommunitySiteMarker],
        operatorLabel: @escaping (String) -> String,
        service: CustomSitesServicing,
        onCreated: @escaping () -> Void
    ) {
        self.cells = cells
        self.operatorLabel = operatorLabel
        self.service = service
        self.onCreated = onCreated
        // Centroïde des cellules retenues : le meilleur point de départ dont on
        // dispose, même s'il n'est pas le bon.
        let lat = cells.map(\.lat).reduce(0, +) / Double(max(cells.count, 1))
        let lng = cells.map(\.lng).reduce(0, +) / Double(max(cells.count, 1))
        _region = State(initialValue: MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: lat, longitude: lng),
            span: MKCoordinateSpan(latitudeDelta: 0.004, longitudeDelta: 0.004)
        ))
    }

    private var draft: CustomSiteDraft {
        CustomSiteDraft.fromObservedCells(
            cells,
            latitude: region.center.latitude,
            longitude: region.center.longitude,
            name: name,
            type: type,
            description: note.isEmpty ? nil : note
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SQSpace.lg) {
                    positionPicker
                    field(String(localized: "Nom du site"), text: $name, placeholder: "Pylône rue des Lilas")
                    typePicker
                    field(String(localized: "Note (facultatif)"), text: $note, placeholder: "Ce qui aide à le reconnaître")
                    radioSummary
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(SQType.subhead)
                            .foregroundStyle(SQColor.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let pendingMessage {
                        Label(pendingMessage, systemImage: "clock.arrow.circlepath")
                            .font(SQType.subhead)
                            .foregroundStyle(SQColor.success)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    submitButton
                }
                .padding(SQSpace.lg)
            }
            .signalQuestBackground()
            .navigationTitle("Nouveau site")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(isQueued ? "Fermer" : "Annuler") { dismiss() }
                        .tint(SQColor.labelSecondary)
                }
            }
        }
    }

    /// Carte + réticule fixe : on déplace la CARTE sous la croix, pas un
    /// marqueur sur la carte. Le doigt ne masque donc jamais le point visé.
    private var positionPicker: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Où est l'antenne ?").sqKicker()
            ZStack {
                Map(coordinateRegion: $region)
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
                Image(systemName: "plus.viewfinder")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(SQColor.brandRed)
                    .shadow(color: .black.opacity(0.25), radius: 3)
                    .allowsHitTesting(false)
            }
            Text("Déplace la carte pour viser le pylône. Le point de départ est la moyenne des mesures, pas l'antenne.")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(String(format: "%.5f, %.5f", region.center.latitude, region.center.longitude))
                .font(SQFont.body(12.5, .semibold).monospacedDigit())
                .foregroundStyle(SQColor.labelTertiary)
        }
    }

    private var typePicker: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Type de support").sqKicker()
            Picker("Type de support", selection: $type) {
                ForEach(Self.types, id: \.value) { entry in
                    Text(entry.label).tag(entry.value)
                }
            }
            .pickerStyle(.menu)
            .tint(SQColor.brandRed)
        }
    }

    /// Ce que le site reprendra des cellules : l'utilisateur doit voir ce qu'il
    /// signe, d'autant qu'il n'a pas saisi ces valeurs lui-même.
    private var radioSummary: some View {
        let radios = draft.normalized().operatorRadios
        return VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Identifiants repris").sqKicker()
            VStack(alignment: .leading, spacing: 0) {
                ForEach(radios, id: \.operator) { radio in
                    HStack(alignment: .top) {
                        Text(operatorLabel(radio.operator))
                            .font(SQFont.body(14, .semibold))
                            .foregroundStyle(SQColor.label)
                        Spacer()
                        Text([
                            radio.enb.map { "eNB \($0)" },
                            radio.gnb.map { "gNB \($0)" },
                            radio.pci.map { "PCI \($0)" },
                            radio.band.map { "B\($0)" }
                        ].compactMap { $0 }.joined(separator: " · "))
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                            .multilineTextAlignment(.trailing)
                    }
                    .padding(.horizontal, SQSpace.md)
                    .padding(.vertical, SQSpace.sm + 1)
                    Divider().overlay(SQColor.separator).padding(.leading, SQSpace.md)
                }
            }
            .padding(.vertical, SQSpace.xs)
            .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
            .sqShadowCard()
        }
    }

    private var submitButton: some View {
        Button {
            Task { await submit() }
        } label: {
            HStack(spacing: SQSpace.sm) {
                if isSubmitting { ProgressView().tint(SQColor.onAccent) }
                Text(isSubmitting ? "Création…" : isQueued ? "En attente d'envoi" : "Créer le site")
                    .font(SQFont.body(15, .semibold))
            }
            .foregroundStyle(SQColor.onAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, SQSpace.md)
            .background(
                draft.isValid && !isSubmitting && !isQueued ? SQColor.brandRed : SQColor.labelTertiary,
                in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
            )
        }
        .buttonStyle(SQPressButtonStyle())
        .disabled(!draft.isValid || isSubmitting || isQueued)
    }

    private func submit() async {
        guard draft.isValid, !isSubmitting, !isQueued else { return }
        isSubmitting = true
        errorMessage = nil
        pendingMessage = nil
        defer { isSubmitting = false }
        do {
            let result = try await service.create(draft)
            Haptics.success()
            if result.isPending {
                isQueued = true
                pendingMessage = String(localized: "Proposition enregistrée. Elle sera envoyée automatiquement dès que la connexion le permettra.")
            } else {
                onCreated()
                dismiss()
            }
        } catch {
            Haptics.error()
            errorMessage = error.localizedDescription
        }
    }

    @ViewBuilder
    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text(LocalizedStringKey(label)).sqKicker()
            TextField(placeholder, text: text)
                .font(SQFont.body(15))
                .foregroundStyle(SQColor.label)
                .padding(.horizontal, SQSpace.md)
                .padding(.vertical, SQSpace.sm + 2)
                .background(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        }
    }
}
