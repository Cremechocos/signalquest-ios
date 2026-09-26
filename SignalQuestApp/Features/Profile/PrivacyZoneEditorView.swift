import SwiftUI
import MapKit

struct PrivacyZoneEditorRoute: Identifiable {
    let zone: PrivacyZone?
    var id: String { zone?.id ?? "new" }
}

struct PrivacyZoneEditorView: View {
    @ObservedObject var model: PrivacySettingsViewModel
    let original: PrivacyZone?
    let location: LocationService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var draft: PrivacyZoneDraft
    @State private var locating = false
    @State private var locationError: String?
    @State private var showDeleteConfirmation = false
    @State private var locationRequest = PrivacyZoneEditorRequest()
    @State private var mutationRequest = PrivacyZoneEditorRequest()

    init(model: PrivacySettingsViewModel, zone: PrivacyZone?, location: LocationService) {
        self.model = model
        original = zone
        self.location = location
        _draft = State(initialValue: PrivacyZoneDraft(zone: zone))
    }

    private var isBusy: Bool { model.zoneBusyId != nil }
    private var canSave: Bool {
        model.isSessionCurrent && !isBusy && !locating && (try? draft.validate()) != nil
            && (original == nil || draft != PrivacyZoneDraft(zone: original))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Nom de la zone", text: draftBinding(for: \.name))
                        .textInputAutocapitalization(.words)
                        .accessibilityIdentifier("privacy-zone.name")
                    Picker("Type de lieu", selection: draftBinding(for: \.type)) {
                        ForEach(PrivacyZoneType.allCases) { type in Text(type.label).tag(type) }
                    }
                } header: { Text("Lieu") }
                .listRowBackground(SQColor.surface)

                Section {
                    PrivacyZoneMapPicker(draft: draft) { coordinate in
                        invalidateLocationRequest()
                        draft.select(latitude: coordinate.latitude, longitude: coordinate.longitude)
                    }
                    .frame(height: 260)
                    .listRowInsets(EdgeInsets())
                    .accessibilityLabel("Carte de la zone privée")
                    Button {
                        useCurrentLocation()
                    } label: {
                        HStack {
                            Label("Utiliser ma position", systemImage: "location.fill")
                            if locating { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(locating)
                    if let locationError { Text(locationError).font(SQType.caption).foregroundStyle(SQColor.dangerInk) }
                    DisclosureGroup("Saisir les coordonnées") {
                        TextField("Latitude", text: draftBinding(for: \.latitudeText))
                            .keyboardType(.numbersAndPunctuation)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Longitude", text: draftBinding(for: \.longitudeText))
                            .keyboardType(.numbersAndPunctuation)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    HStack {
                        Text("Rayon")
                        Spacer()
                        Text(SQUnits.radius(meters: draft.radius)).monospacedDigit()
                    }
                    Slider(value: Binding(
                        get: { draft.radius.isFinite ? min(PrivacyZoneDraft.maximumRadius, max(PrivacyZoneDraft.minimumRadius, draft.radius)) : PrivacyZoneDraft.minimumRadius },
                        set: { value in
                            invalidateLocationRequest()
                            draft.radius = value
                        }
                    ), in: PrivacyZoneDraft.minimumRadius...PrivacyZoneDraft.maximumRadius, step: 100)
                        .accessibilityLabel("Rayon de la zone")
                        .accessibilityValue(SQUnits.radius(meters: draft.radius))
                    if !draft.radius.isFinite || !(PrivacyZoneDraft.minimumRadius...PrivacyZoneDraft.maximumRadius).contains(draft.radius) {
                        Text(PrivacyZoneDraft.ValidationError.radius.localizedDescription)
                            .font(SQType.caption).foregroundStyle(SQColor.dangerInk)
                    }
                } header: { Text("Position et rayon") }
                footer: { Text("Touche la carte pour choisir le centre. Le cercle montre la zone à protéger ; vérifie sa position avant d’enregistrer.") }
                .listRowBackground(SQColor.surface)

                Section {
                    Toggle("Protéger les nouveaux speedtests", isOn: draftBinding(for: \.hideSpeedtestsOnMap))
                    if original != nil {
                        Toggle("Zone active", isOn: draftBinding(for: \.isActive))
                    }
                    if !draft.isActive {
                        Label("La protection est en pause tant que la zone est inactive.", systemImage: "pause.circle")
                            .font(SQType.caption).foregroundStyle(SQColor.labelSecondary)
                    }
                } header: { Text("Protection") }
                footer: { Text("Une zone active avec le masquage activé protège les nouveaux speedtests réalisés dans son rayon. La création d’une zone ne masque pas rétroactivement les mesures déjà publiées.") }
                .listRowBackground(SQColor.surface)

                if let error = model.zoneMutationError ?? (model.isSessionCurrent ? nil : model.errorMessage) {
                    Section { Text(error).foregroundStyle(SQColor.dangerInk) }
                        .listRowBackground(SQColor.dangerSoft)
                }
                if original != nil {
                    Section {
                        Button("Supprimer cette zone", role: .destructive) { showDeleteConfirmation = true }
                    }
                    .listRowBackground(SQColor.surface)
                }
            }
            .disabled(isBusy || !model.isSessionCurrent)
            .tint(SQColor.brandRed)
            .scrollContentBackground(.hidden)
            .signalQuestBackground()
            .navigationTitle(original == nil ? Text("Nouvelle zone privée") : Text("Modifier la zone"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { closeRequests(); dismiss() }.disabled(isBusy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        guard !isBusy, model.isSessionCurrent, canSave else { return }
                        mutationRequest.start(
                            operation: { await model.saveZone(draft, original: original) },
                            isSessionCurrent: { model.isSessionCurrent },
                            apply: { saved in if saved { closeRequests(); dismiss() } }
                        )
                    } label: {
                        if isBusy { ProgressView() } else { Text("Enregistrer") }
                    }
                    .disabled(!canSave)
                }
            }
            .interactiveDismissDisabled(isBusy)
            .confirmationDialog("Supprimer cette zone privée ?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
                Button("Supprimer", role: .destructive) {
                    guard !isBusy, model.isSessionCurrent, let original else { return }
                    mutationRequest.start(
                        operation: { await model.deleteZone(original) },
                        isSessionCurrent: { model.isSessionCurrent },
                        apply: { deleted in if deleted { closeRequests(); dismiss() } }
                    )
                }
            } message: {
                Text("Elle sera supprimée de ton compte sur iOS, Android et le web. Les nouveaux speedtests ne seront plus protégés par cette zone.")
            }
        }
        .onAppear { updateRequestPresentation() }
        .onDisappear { closeRequests() }
        .onChangeCompat(of: scenePhase) { _, _ in updateRequestPresentation() }
        .onChangeCompat(of: model.isSessionCurrent) { _, current in
            if !current { closeRequests() }
        }
    }

    private func draftBinding<Value>(for keyPath: WritableKeyPath<PrivacyZoneDraft, Value>) -> Binding<Value> {
        Binding(get: { draft[keyPath: keyPath] }, set: { value in
            invalidateLocationRequest()
            draft[keyPath: keyPath] = value
        })
    }

    private func invalidateLocationRequest() {
        locationRequest.invalidate()
        locating = false
        locationError = nil
    }

    private func updateRequestPresentation() {
        guard model.isSessionCurrent else { closeRequests(); return }
        switch scenePhase {
        case .background:
            locationRequest.close()
            locating = false
            locationError = nil
            mutationRequest.suspendDelivery()
        case .active:
            locationRequest.open()
            mutationRequest.open()
            mutationRequest.resumeDelivery()
        case .inactive:
            // Le dialogue de permission GPS suspend l'interaction sans fermer
            // l'éditeur. Conserver le GPS et les mutations pendant ce dialogue.
            break
        @unknown default:
            break
        }
    }

    private func closeRequests() {
        locationRequest.close()
        mutationRequest.close()
        locating = false
        locationError = nil
    }

    private func useCurrentLocation() {
        guard !locating, model.isSessionCurrent else { return }
        locationError = nil
        locating = locationRequest.start(
            operation: { () async -> (latitude: Double, longitude: Double)? in
                guard let fix = await location.currentLocation(),
                      abs(fix.timestamp.timeIntervalSinceNow) <= 60, fix.horizontalAccuracy >= 0,
                      CLLocationCoordinate2DIsValid(fix.coordinate) else { return nil }
                return (fix.coordinate.latitude, fix.coordinate.longitude)
            },
            isSessionCurrent: { model.isSessionCurrent },
            apply: { coordinate in
                locating = false
                guard let coordinate else {
                    locationError = String(localized: "Position récente indisponible. Choisis le centre sur la carte ou saisis ses coordonnées.")
                    return
                }
                draft.select(latitude: coordinate.latitude, longitude: coordinate.longitude)
            }
        ) != nil
    }
}

/// MKMapView garantit le cercle et la sélection précise dès iOS 16.
private struct PrivacyZoneMapPicker: UIViewRepresentable {
    let draft: PrivacyZoneDraft
    let onPick: (CLLocationCoordinate2D) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.showsUserLocation = false
        map.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 20, longitude: 0),
            span: MKCoordinateSpan(latitudeDelta: 100, longitudeDelta: 180)), animated: false)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pick(_:)))
        tap.cancelsTouchesInView = false
        map.addGestureRecognizer(tap)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.onPick = onPick
        map.isUserInteractionEnabled = context.environment.isEnabled
        guard draft.hasValidCoordinate, let lat = draft.latitude, let lon = draft.longitude,
              draft.radius.isFinite, draft.radius > 0 else {
            map.removeAnnotations(map.annotations); map.removeOverlays(map.overlays)
            context.coordinator.geometry = nil
            return
        }
        let geometry = [lat, lon, draft.radius]
        guard context.coordinator.geometry != geometry else { return }
        context.coordinator.geometry = geometry
        let center = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        map.removeAnnotations(map.annotations); map.removeOverlays(map.overlays)
        let pin = MKPointAnnotation(); pin.coordinate = center
        map.addAnnotation(pin)
        map.addOverlay(MKCircle(center: center, radius: draft.radius))
        map.setRegion(MKCoordinateRegion(center: center, latitudinalMeters: max(800, draft.radius * 3),
            longitudinalMeters: max(800, draft.radius * 3)), animated: false)
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        var onPick: (CLLocationCoordinate2D) -> Void
        var geometry: [Double]?
        init(onPick: @escaping (CLLocationCoordinate2D) -> Void) { self.onPick = onPick }
        @objc func pick(_ gesture: UITapGestureRecognizer) {
            guard let map = gesture.view as? MKMapView, gesture.state == .ended else { return }
            onPick(map.convert(gesture.location(in: map), toCoordinateFrom: map))
        }
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let circle = overlay as? MKCircle else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKCircleRenderer(circle: circle)
            renderer.strokeColor = UIColor(SQColor.brandRed)
            renderer.fillColor = UIColor(SQColor.brandRed).withAlphaComponent(0.15)
            renderer.lineWidth = 2
            return renderer
        }
    }
}
