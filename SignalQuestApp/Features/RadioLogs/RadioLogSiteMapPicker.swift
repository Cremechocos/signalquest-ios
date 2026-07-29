import CoreLocation
import MapKit
import SwiftUI

private typealias M = RadioLogsMetrics
private typealias P = RadioLogsPalette

/// « Choisir une autre antenne sur la carte ».
///
/// Les propositions du serveur couvrent le cas courant, pas tous les cas : un
/// site relevé depuis une position bruitée, une antenne récente absente des
/// validations, un relevé fait en mouvement. Cet écran ouvre le choix à
/// n'importe quelle antenne du référentiel, en demandant confirmation — parce
/// qu'une identification manuelle engage la base communautaire.
struct RadioLogSiteMapPicker: View {
    let site: RadioLogSite
    @ObservedObject var picker: RadioLogIdentifyPicker
    let antennas: AntennasServicing
    @Environment(\.dismiss) private var dismiss

    @State private var region: MKCoordinateRegion
    @State private var visible: [AntennaSite] = []
    @State private var selected: AntennaSite?
    @State private var isLoading = false
    @State private var loadError: String?
    /// Clé de la zone déjà chargée, arrondie : évite de recharger à chaque
    /// micro-déplacement de la carte.
    @State private var loadedKey: String?
    @State private var showsAllOperators = false
    @State private var showsConfirmation = false
    /// Renseigné une fois l'écriture acceptée par le serveur.
    let onIdentified: (String) -> Void

    init(
        site: RadioLogSite,
        picker: RadioLogIdentifyPicker,
        antennas: AntennasServicing,
        onIdentified: @escaping (String) -> Void
    ) {
        self.site = site
        self.picker = picker
        self.antennas = antennas
        self.onIdentified = onIdentified
        _region = State(
            initialValue: MKCoordinateRegion(
                center: CLLocationCoordinate2D(
                    latitude: site.latitude ?? 46.6,
                    longitude: site.longitude ?? 2.5
                ),
                span: MKCoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.03)
            )
        )
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                map
                overlayCard
            }
            .background(SQColor.bg.ignoresSafeArea())
            .navigationTitle("Choisir l'antenne")
            .toolbarTitleInlineCompat()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Toggle("Tous les opérateurs", isOn: $showsAllOperators)
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityLabel("Filtrer les antennes")
                }
            }
            .task(id: regionKey) { await loadIfNeeded() }
            .onChange(of: showsAllOperators) { _ in
                loadedKey = nil
                Task { await loadIfNeeded() }
            }
            .alert("Identifier ce site ?", isPresented: $showsConfirmation) {
                Button("Annuler", role: .cancel) {}
                Button("Identifier") { Task { await confirm() } }
            } message: {
                Text(confirmationMessage)
            }
        }
    }

    // MARK: Carte

    private var map: some View {
        SQRegionMap(region: $region, items: pins) { pin in
            MapAnnotation(coordinate: pin.coordinate) {
                Button {
                    if pin.isOrigin { return }
                    selected = pin.antenna
                    Haptics.selection()
                } label: {
                    Image(systemName: pin.isOrigin ? "dot.scope" : "antenna.radiowaves.left.and.right")
                        .font(.system(size: pin.isOrigin ? 18 : 14, weight: .bold))
                        .foregroundStyle(pin.isSelected ? P.onAccent : (pin.isOrigin ? P.ink : P.accentInk))
                        .padding(pin.isSelected ? 9 : 6)
                        .background(
                            pin.isSelected ? AnyShapeStyle(P.accent) : AnyShapeStyle(P.card),
                            in: Circle()
                        )
                        .sqShadowSoft()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(pin.isOrigin ? "Position des relevés" : "Antenne \(pin.antenna?.siteId ?? "")")
            }
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private struct PickerPin: Identifiable {
        let id: String
        let coordinate: CLLocationCoordinate2D
        let isOrigin: Bool
        let isSelected: Bool
        let antenna: AntennaSite?
    }

    private var pins: [PickerPin] {
        var pins: [PickerPin] = []
        if let latitude = site.latitude, let longitude = site.longitude {
            pins.append(
                PickerPin(
                    id: "origin",
                    coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                    isOrigin: true,
                    isSelected: false,
                    antenna: nil
                )
            )
        }
        for antenna in visible {
            guard let latitude = antenna.latitude, let longitude = antenna.longitude else { continue }
            pins.append(
                PickerPin(
                    id: antenna.id,
                    coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                    isOrigin: false,
                    isSelected: selected?.id == antenna.id,
                    antenna: antenna
                )
            )
        }
        return pins
    }

    // MARK: Carte d'information et action

    private var overlayCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: SQSpace.sm) {
                Text(site.nodeLabel)
                    .font(.sqTechnical(M.siteIdSize, .semibold))
                    .foregroundStyle(P.ink)
                RadioLogTechBadge(label: site.techLabel)
                Spacer(minLength: 0)
                if isLoading { ProgressView().controlSize(.small) }
            }

            if let selected {
                Text("Site \(selected.siteId ?? selected.id)")
                    .font(.sqTechnical(13, .semibold))
                    .foregroundStyle(P.ink)
                    .padding(.top, M.siteNameTop)
                if let address = selected.address, !address.isEmpty {
                    Text(address)
                        .font(SQFont.body(M.siteNameSize))
                        .foregroundStyle(P.muted)
                        .lineLimit(2)
                        .padding(.top, 1)
                }
                if let meta = selectedMeta {
                    Text(meta)
                        .font(SQFont.body(M.siteMetaSize))
                        .monospacedDigit()
                        .foregroundStyle(P.muted)
                        .padding(.top, M.siteMetaTop)
                }
            } else {
                Text(visible.isEmpty && !isLoading
                     ? "Aucune antenne dans cette zone. Déplace la carte."
                     : "Touche une antenne sur la carte pour la choisir.")
                    .font(SQFont.body(M.siteMetaSize))
                    .foregroundStyle(P.muted)
                    .padding(.top, M.siteMetaTop)
            }

            if let loadError {
                Text(loadError)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.warning)
                    .padding(.top, M.siteMetaTop)
            }

            HStack(spacing: M.ctaGap) {
                RadioLogActionButton(label: picker.isSubmitting ? "…" : "Identifier ici") {
                    showsConfirmation = true
                }
                .disabled(selected == nil || picker.isSubmitting)
                .opacity(selected == nil ? 0.5 : 1)
                RadioLogActionButton(label: "Annuler", ghost: true) { dismiss() }
            }
            .padding(.top, M.ctaTop)
        }
        .padding(.horizontal, M.cardPaddingH)
        .padding(.vertical, M.cardPaddingV)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(P.card, in: RoundedRectangle(cornerRadius: M.cardRadius, style: .continuous))
        .sqShadowCard()
        .padding(SQSpace.md)
    }

    private var selectedMeta: String? {
        guard let selected else { return nil }
        var parts: [String] = []
        if let latitude = selected.latitude, let longitude = selected.longitude,
           let originLat = site.latitude, let originLng = site.longitude {
            let distance = CLLocation(latitude: originLat, longitude: originLng)
                .distance(from: CLLocation(latitude: latitude, longitude: longitude))
            parts.append(distance >= 1000
                ? String(format: "à %.1f km", distance / 1000)
                : "à \(Int(distance.rounded())) m")
        }
        let operators = selected.operators.filter { $0.uppercased() != "ALL" }
        if !operators.isEmpty { parts.append(operators.joined(separator: ", ")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var confirmationMessage: String {
        let siteId = selected.map { $0.siteId ?? $0.id } ?? "?"
        let place = selected?.address.flatMap { $0.isEmpty ? nil : $0 }
        let base = "\(site.nodeLabel) sera identifié sur le site \(siteId)"
        let located = place.map { "\(base) — \($0)" } ?? base
        return "\(located).\n\nCette identification est publique et attribuée à ton compte. Tu pourras la retirer depuis « Mes identifications »."
    }

    // MARK: Chargement

    /// Zone arrondie au centième de degré (~1 km) : la carte bouge en continu,
    /// pas la donnée. Sans cet arrondi, chaque image de l'animation de panoramique
    /// relancerait une requête.
    private var regionKey: String {
        String(
            format: "%.2f|%.2f|%.2f|%@",
            region.center.latitude,
            region.center.longitude,
            region.span.latitudeDelta,
            showsAllOperators ? "all" : "op"
        )
    }

    private func loadIfNeeded() async {
        let key = regionKey
        guard loadedKey != key else { return }
        // Au-delà, la requête ramènerait des milliers d'antennes pour rien : on
        // demande plutôt de zoomer, plus honnête qu'une carte qui rame.
        guard region.span.latitudeDelta < 0.5 else {
            visible = []
            loadError = String(localized: "Zoome pour afficher les antennes.")
            return
        }
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        let market = RadioLogOperatorResolver.marketCode(forOperator: site.operatorName, mcc: site.mcc) ?? "FR"
        let bbox = BoundingBox(
            north: region.center.latitude + region.span.latitudeDelta / 2,
            south: region.center.latitude - region.span.latitudeDelta / 2,
            east: region.center.longitude + region.span.longitudeDelta / 2,
            west: region.center.longitude - region.span.longitudeDelta / 2
        )
        do {
            var merged: [AntennaSite] = []
            var seen = Set<String>()
            // Éventail EXPLICITE, une requête par opérateur.
            //
            // ⚠️ Ne PAS passer `operatorName: "ALL"` : en France, `AntennasService`
            // le développe en `["SFR", "BOUYGUES", "ALL"]` — Orange et Free en sont
            // absents. C'est cohérent pour la carte, où « ALL » désigne les sites
            // mutualisés et où l'utilisateur a son propre filtre opérateur ; ici ça
            // masquerait silencieusement la moitié du référentiel, sur un journal
            // qui est à 40 % Orange.
            for operatorKey in queriedOperatorKeys(market: market) {
                let batch = try await antennas.list(
                    bbox: bbox, market: market, operatorName: operatorKey, technologies: []
                )
                for antenna in batch where antenna.hasValidCoordinate {
                    if seen.insert(antenna.siteId ?? antenna.id).inserted { merged.append(antenna) }
                }
            }
            visible = merged
            loadedKey = key
            if visible.isEmpty {
                loadError = String(localized: "Aucune antenne connue dans cette zone.")
            }
        } catch {
            if !error.isCancellation { loadError = error.localizedDescription }
        }
    }

    /// Opérateurs à interroger : celui du relevé, ou les quatre nationaux quand
    /// l'utilisateur ouvre le choix. Hors France, on s'en remet au marché.
    private func queriedOperatorKeys(market: String) -> [String] {
        guard showsAllOperators else {
            return [RadioLogOperatorResolver.operatorKey(forOperator: site.operatorName) ?? "ALL"]
        }
        return market.uppercased() == "FR"
            ? ["ORANGE", "SFR", "BOUYGUES", "FREE"]
            : ["ALL"]
    }

    @MainActor
    private func confirm() async {
        guard let selected else { return }
        picker.addManualChoice(selected, origin: site)
        guard let siteId = await picker.submit(site: site) else { return }
        // On se referme AVANT de prévenir : l'appelant peut avancer dans sa file
        // ou changer d'écran, et le faire pendant que la feuille est encore là
        // donnerait une transition qui se marche dessus.
        dismiss()
        onIdentified(siteId)
    }
}
