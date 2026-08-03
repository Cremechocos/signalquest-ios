import SwiftUI

/// Fiche d'un site pointé à la main par un membre.
///
/// Ces sites sont la seule antenne visible dans les pays sans open data : la
/// fiche doit donc tenir debout sans ANFR — pas de secteurs, pas d'azimuts, pas
/// de hauteur de support. Ce qu'elle a de plus qu'une fiche officielle, c'est
/// l'auteur et le statut de confirmation ; ce qu'elle a en moins, elle le dit
/// plutôt que d'afficher des lignes vides.
///
/// Même squelette que `PlannedDetailSheet` / `OutageDetailSheet`.
struct CustomSiteDetailSheet: View {
    let site: AndroidCustomSiteMarker
    let accent: Color

    private var radio: AndroidCustomSiteRadio? {
        guard let radio = site.radio, !radio.isEmpty else { return nil }
        return radio
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                SQSheetHandle()
                header
                statusBanner
                if let url = site.primaryPhotoUrl.flatMap(URL.init(string:)) { photo(url) }
                if let description = site.description, !description.isEmpty { descriptionCard(description) }
                if radio != nil { radioSection }
                infoSection
                provenanceNote
            }
            .padding()
        }
        .presentationDetents([.height(460), .medium, .large])
        .presentationBackgroundCompat(SQColor.bg)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: SQSpace.md) {
            Image(systemName: "mappin.and.ellipse")
                .font(.title2.weight(.semibold))
                .foregroundStyle(SQColor.onAccent)
                .frame(width: 46, height: 46)
                .background(accent, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(site.name ?? site.typeLabel ?? String(localized: "Site ajouté"))
                    .font(SQFont.display(20, .bold))
                    .foregroundStyle(SQColor.label)
                if let typeLabel = site.typeLabel {
                    Text(typeLabel)
                        .font(SQFont.body(14.5, .semibold))
                        .foregroundStyle(SQColor.labelSecondary)
                }
                if let author = site.createdByDisplayName {
                    Text("Ajouté par \(author)")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                }
            }
            Spacer()
        }
    }

    /// « Confirmé » ≠ « vu par un robot » : le backend ne compte que les
    /// identifications non automatiques. Un site en attente n'est pas douteux,
    /// il n'a simplement encore été confirmé par personne sur le terrain.
    private var statusBanner: some View {
        HStack(spacing: SQSpace.sm) {
            Image(systemName: site.isValidated ? "checkmark.seal.fill" : "clock.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(site.isValidated ? SQColor.success : SQColor.warning)
            Text(site.isValidated
                 ? "Confirmé sur le terrain par au moins un membre"
                 : "Pas encore confirmé sur le terrain")
                .font(SQType.subhead)
                .foregroundStyle(SQColor.label)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(SQSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            (site.isValidated ? SQColor.success : SQColor.warning).opacity(0.12),
            in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
        )
    }

    private func photo(_ url: URL) -> some View {
        RemoteImage(url: url, maxDimension: 380, contentMode: .fill) {
            RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous)
                .fill(SQColor.surfaceMuted)
        }
        .frame(height: 190)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if site.photoCount > 1 {
                    Text("\(site.photoCount) photos")
                        .font(SQFont.body(12, .semibold))
                        .foregroundStyle(SQColor.onAccent)
                        .padding(.horizontal, SQSpace.sm)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.55), in: Capsule(style: .continuous))
                        .padding(SQSpace.sm)
                }
            }
    }

    private func descriptionCard(_ text: String) -> some View {
        Text(text)
            .font(SQType.subhead)
            .foregroundStyle(SQColor.label)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(SQSpace.md)
            .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
            .sqShadowCard()
    }

    private var radioSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Identifiants radio")
                .font(SQType.heading)
                .foregroundStyle(SQColor.label)
            VStack(alignment: .leading, spacing: 0) {
                infoRow("Opérateur", radio?.operatorName)
                infoRow("Technologie", radio?.technology)
                infoRow("PLMN", radio?.plmn)
                infoRow("eNB", radio?.enb)
                infoRow("gNB", radio?.gnb)
                infoRow("CI", radio?.cellId)
                infoRow("PCI", radio?.pci.map(String.init))
                infoRow("TAC", radio?.tac)
                infoRow("EARFCN", radio?.earfcn.map(String.init))
                infoRow("NR-ARFCN", radio?.nrarfcn.map(String.init))
                infoRow("Bande", radio?.band.map { "B\($0)" })
            }
            .padding(.vertical, SQSpace.xs)
            .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
            .sqShadowCard()
        }
    }

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            infoRow("Type de support", site.typeLabel)
            infoRow("Ajouté par", site.createdByDisplayName)
            infoRow("Ajouté le", site.createdAt.map { SignalFormatters.date($0) })
            infoRow("Photos", site.photoCount > 0 ? "\(site.photoCount)" : nil)
            infoRow("Coordonnées", String(format: "%.5f, %.5f", site.lat, site.lng))
        }
        .padding(.vertical, SQSpace.xs)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
        .sqShadowCard()
    }

    /// La fiche officielle affiche hauteur, secteurs et azimuts ; ici il n'y en a
    /// pas, et l'expliquer vaut mieux que laisser croire à un chargement raté.
    private var provenanceNote: some View {
        Text("Site relevé par un membre : sa position et ses identifiants viennent du terrain, pas d'un registre officiel. Hauteur, secteurs et azimuts ne sont donc pas connus.")
            .font(SQType.caption)
            .foregroundStyle(SQColor.labelSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func infoRow(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .top) {
                Text(LocalizedStringKey(label))
                    .font(SQType.subhead)
                    .foregroundStyle(SQColor.labelSecondary)
                Spacer()
                Text(value)
                    .font(SQFont.body(14, .semibold))
                    .foregroundStyle(SQColor.label)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.horizontal, SQSpace.md)
            .padding(.vertical, SQSpace.sm + 1)
            Divider().overlay(SQColor.separator).padding(.leading, SQSpace.md)
        }
    }
}
