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
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                header
                positionPicker
                field(String(localized: "Nom du site"), text: $name, placeholder: String(localized: "Pylône rue des Lilas"))
                typePicker
                field(String(localized: "Note (facultatif)"), text: $note, placeholder: String(localized: "Ce qui aide à le reconnaître"))
                radioSummary
                if let errorMessage {
                    SQNotice(message: errorMessage, tone: .danger)
                }
                if let pendingMessage {
                    SQNotice(message: pendingMessage, systemImage: "clock.arrow.circlepath", tone: .success)
                }
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.lg)
            .padding(.bottom, SQSpace.xl)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(SQColor.bg.ignoresSafeArea())
        // Le bouton reste en bas, au-dessus du clavier : on le valide sans
        // avoir à fermer la saisie ni à redescendre.
        .safeAreaInset(edge: .bottom) {
            submitButton
                .padding(.horizontal, SQSpace.lg)
                .padding(.top, SQSpace.sm)
                .padding(.bottom, SQSpace.sm)
                .background(SQColor.bg.ignoresSafeArea())
        }
        .sqSheet(background: SQColor.bg)
    }

    private var header: some View {
        HStack(spacing: SQSpace.sm) {
            Button(isQueued ? "Fermer" : "Annuler") { dismiss() }
                .font(SQType.body(.semibold))
                .foregroundStyle(SQColor.labelSecondary)
                .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                .accessibilityIdentifier("createSite.cancel")
            Text("Nouveau site")
                .font(SQType.heading)
                .foregroundStyle(SQColor.label)
                .frame(maxWidth: .infinity)
                .sqHeader()
            // Contrepoids du bouton de gauche, pour centrer le titre.
            Button(isQueued ? "Fermer" : "Annuler") {}
                .font(SQType.body(.semibold))
                .frame(minWidth: 44, minHeight: 44)
                .hidden()
                .accessibilityHidden(true)
        }
    }

    /// Carte + réticule fixe : on déplace la CARTE sous la croix, pas un
    /// marqueur sur la carte. Le doigt ne masque donc jamais le point visé.
    private var positionPicker: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Où est l'antenne ?").sqKicker()
            ZStack {
                Map(coordinateRegion: $region)
                    .frame(height: 190)
                    .clipShape(RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
                Image(systemName: "plus.viewfinder")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(SQColor.brandRed)
                    .shadow(color: .black.opacity(0.25), radius: 3)
                    .allowsHitTesting(false)
            }
            (Text("Déplace la carte pour viser le pylône. Le point de départ est la moyenne des mesures, pas l'antenne.")
                + Text(verbatim: " · ")
                + Text(verbatim: String(format: "%.5f, %.5f", region.center.latitude, region.center.longitude))
                    .font(SQFont.body(12, .semibold).monospacedDigit()))
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Pastilles plutôt qu'un menu : les six types se lisent d'un coup d'œil.
    private var typePicker: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Type de support")
                .font(SQType.callout(.bold))
                .foregroundStyle(SQColor.label)
            FlowLayout(spacing: SQSpace.xs2) {
                ForEach(Self.types, id: \.value) { entry in
                    SQChip(label: entry.label, isSelected: type == entry.value) { type = entry.value }
                }
            }
        }
    }

    /// Ce que le site reprendra des cellules : l'utilisateur doit voir ce qu'il
    /// signe, d'autant qu'il n'a pas saisi ces valeurs lui-même.
    private var radioSummary: some View {
        let radios = draft.normalized().operatorRadios
        return VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Identifiants repris").sqKicker()
            VStack(spacing: 0) {
                ForEach(radios, id: \.operator) { radio in
                    HStack(spacing: SQSpace.sm) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(SQBrand.operatorColor(operatorLabel(radio.operator)))
                            .frame(width: 4, height: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(operatorLabel(radio.operator))
                                .font(SQType.callout(.semibold))
                                .foregroundStyle(SQColor.label)
                            let identifiers = [
                                radio.enb.map { "eNB \($0)" },
                                radio.gnb.map { "gNB \($0)" },
                                radio.pci.map { "PCI \($0)" },
                                radio.band.map { SQUnits.band($0, technology: radio.technology ?? (radio.gnb != nil ? "NR" : nil)) }
                            ].compactMap { $0 }.joined(separator: " · ")
                            if !identifiers.isEmpty {
                                Text(identifiers)
                                    .font(SQType.caption.monospacedDigit())
                                    .foregroundStyle(SQColor.labelSecondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if let tech = radio.technology, !tech.isEmpty {
                            MapTechTag(technology: tech, label: tech)
                        }
                    }
                    .frame(minHeight: 46)
                    if radio.operator != radios.last?.operator {
                        Divider().overlay(SQColor.separator)
                    }
                }
            }
            .padding(.horizontal, SQSpace.md)
            .padding(.vertical, SQSpace.xs)
            .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        }
    }

    private var canSubmit: Bool { draft.isValid && !isSubmitting && !isQueued }

    private var submitButton: some View {
        GradientButton(
            isQueued ? String(localized: "En attente d'envoi") : String(localized: "Créer le site"),
            systemImage: isQueued ? "clock.arrow.circlepath" : nil,
            isBusy: isSubmitting
        ) {
            Task { await submit() }
        }
        .disabled(!canSubmit)
        .accessibilityIdentifier("createSite.submit")
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
            errorMessage = error.userFacingMessage
        }
    }

    @ViewBuilder
    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text(LocalizedStringKey(label))
                .font(SQType.callout(.bold))
                .foregroundStyle(SQColor.label)
            TextField(placeholder, text: text)
                .font(SQFont.body(15))
                .foregroundStyle(SQColor.label)
                .padding(.horizontal, SQSpace.md)
                .padding(.vertical, SQSpace.sm2)
                .sqFieldSurface(in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        }
    }
}
