import SwiftUI
import MapKit

/// Carte MapKit rétro-compatible iOS 16 : utilise l'API `Map(coordinateRegion:)`
/// (iOS 14→18) au lieu de `Map(position:)` + `MapCameraPosition` (iOS 17+). Pour
/// nos aperçus/pickers d'antennes, le rendu est équivalent et fonctionne sur
/// iOS 16 comme sur iOS 18/26. Les avertissements de dépréciation iOS 17+ sont
/// volontairement concentrés ici (un seul endroit).
struct SQRegionMap<Item: Identifiable, Content: MapAnnotationProtocol>: View {
    @Binding var region: MKCoordinateRegion
    let items: [Item]
    let annotationContent: (Item) -> Content

    init(region: Binding<MKCoordinateRegion>, items: [Item], annotationContent: @escaping (Item) -> Content) {
        self._region = region
        self.items = items
        self.annotationContent = annotationContent
    }

    var body: some View {
        Map(coordinateRegion: $region, interactionModes: .all, annotationItems: items, annotationContent: annotationContent)
    }
}

/// Épingle Identifiable minimale pour les aperçus à un seul point.
struct SQMapPin: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
}
