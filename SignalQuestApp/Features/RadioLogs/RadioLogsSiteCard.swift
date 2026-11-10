import SwiftUI

private typealias M = RadioLogsMetrics
private typealias P = RadioLogsPalette

// MARK: - Briques

/// `.tech` — la génération, en pastille neutre collée à l'identifiant.
struct RadioLogTechBadge: View {
    let label: String

    var body: some View {
        Text(label)
            .font(SQFont.body(M.techSize, .heavy))
            .tracking(M.techTracking)
            .foregroundStyle(P.chipInk)
            .padding(.horizontal, M.techPaddingH)
            .padding(.vertical, M.techPaddingV)
            .background(P.chip, in: RoundedRectangle(cornerRadius: M.techRadius, style: .continuous))
    }
}

/// `.pill` — un identifiant ou une bande. Décrit, n'agit pas.
struct RadioLogPill: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.sqTechnical(M.pillSize))
            .foregroundStyle(P.chipInk)
            .sqSingleLine()
            .padding(.horizontal, M.pillPaddingH)
            .padding(.vertical, M.pillPaddingV)
            .background(P.chip, in: RoundedRectangle(cornerRadius: M.pillRadius, style: .continuous))
    }
}

/// `.state` — la pastille d'état, avec sa puce de couleur.
///
/// C'est la réponse à la seule question que pose la page : « ce site est-il déjà
/// identifié ? ». Elle est donc TOUJOURS visible, carte repliée comme dépliée.
struct RadioLogStatePill: View {
    let state: RadioLogSiteState
    /// Faux quand le balayage ne peut pas vérifier ce site : il ne reste alors
    /// pas « Vérification… » pour toujours (AF-RAD-09).
    var checkable = true

    private var label: String {
        if state == .unchecked, !checkable { return String(localized: "Non vérifiable") }
        return state.label
    }

    private var container: Color {
        switch state {
        case .identified: return P.okSoft
        case .unidentified: return P.chip
        case .unchecked: return checkable ? SQColor.warningSoft : P.chip
        }
    }

    private var ink: Color {
        switch state {
        case .identified: return P.okInk
        case .unidentified: return P.muted
        // Vérification en cours : ambre, comme le bandeau de vérification.
        case .unchecked: return checkable ? OutageTint.degradedInk : P.muted
        }
    }

    var body: some View {
        HStack(spacing: M.stateGap) {
            Circle()
                .fill(ink)
                .frame(width: M.stateDot, height: M.stateDot)
            Text(label)
                .font(SQFont.body(M.stateSize, .bold))
                .foregroundStyle(ink)
        }
        .padding(.horizontal, M.statePaddingH)
        .padding(.vertical, M.statePaddingV)
        .background(container, in: Capsule(style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(state == .unchecked && !checkable
            ? String(localized: "Non vérifiable : pays ou opérateur manquant dans les relevés")
            : state.label)
    }
}

/// `.btn` — l'action de la carte.
///
/// Un `Button` nu plutôt qu'un style Material/`.borderedProminent` : les mesures
/// de la maquette (8/14 pt de marge, rayon 11) ne survivent pas aux marges
/// internes imposées par les styles système. La cible tactile est ramenée à
/// 44 pt par une marge TRANSPARENTE, qui n'agrandit pas le bouton à l'œil.
struct RadioLogActionButton: View {
    let label: LocalizedStringKey
    var ghost = false
    var systemImage: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: SQSpace.xs) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .semibold))
                        .accessibilityHidden(true)
                }
                Text(label)
            }
                .font(SQFont.body(M.buttonSize, .bold))
                .sqSingleLine()
                .foregroundStyle(ghost ? P.ink : P.onAccent)
                .padding(.horizontal, M.buttonPaddingH)
                .padding(.vertical, M.buttonPaddingV)
                .background {
                    if ghost {
                        RoundedRectangle(cornerRadius: M.buttonRadius, style: .continuous)
                            .strokeBorder(P.hairStrong, lineWidth: 1)
                    } else {
                        RoundedRectangle(cornerRadius: M.buttonRadius, style: .continuous)
                            .fill(P.accent)
                    }
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// `.cell-pci` — le PCI en tête de rangée, à largeur fixe pour que la colonne
/// des identités reste alignée d'une ligne à l'autre.
struct RadioLogCellPciTag: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.sqTechnical(M.cellPciSize, .bold))
            .foregroundStyle(P.accentInk)
            .multilineTextAlignment(.center)
            .sqSingleLine()
            .frame(minWidth: M.cellPciMinWidth)
            .padding(.horizontal, M.cellPciPaddingH)
            .padding(.vertical, M.cellPciPaddingV)
            .background(P.accentSoft, in: RoundedRectangle(cornerRadius: M.cellPciRadius, style: .continuous))
    }
}

/// `.cells` — le filet POINTILLÉ qui ouvre le panneau de cellules.
///
/// Pointillé et non plein : il sépare deux natures d'information — ce que le
/// site EST, et ce qu'on y a relevé — là où un filet plein annoncerait une
/// nouvelle section.
struct RadioLogDashedSeparator: View {
    var body: some View {
        Rectangle()
            .fill(.clear)
            .frame(height: 1)
            .overlay {
                Line()
                    .stroke(P.hairStrong, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            .accessibilityHidden(true)
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: 0, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return path
        }
    }
}

/// L'intertitre d'opérateur : un repère à sa couleur, son nom, puis combien de
/// sites et de relevés tient la section.
struct RadioLogOperatorHeader: View {
    let operatorName: String
    let siteCount: Int
    let logCount: Int

    var body: some View {
        HStack(alignment: .center, spacing: SQSpace.sm) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(SQBrand.operatorColor(operatorName))
                .frame(width: 4, height: 16)
                .accessibilityHidden(true)
            Text(operatorName)
                .font(SQFont.body(14, .bold))
                .foregroundStyle(P.ink)
                .sqSingleLine()
            Text(verbatim: [String(localized: "\(siteCount) site"), String(localized: "\(logCount) relevé")].joined(separator: " · "))
                .font(SQType.caption)
                .foregroundStyle(P.muted)
                .sqSingleLine()
            Spacer(minLength: 0)
        }
        .monospacedDigit()
        .textCase(nil)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - La ligne site

/// Une ligne par eNB/gNB — l'unité de la page, posée dans la carte de son opérateur.
///
/// La ligne répond à une seule question : « que reste-t-il à faire sur ce site ? ».
/// Un site identifié se lit (sa commune, son support) et s'ouvre ; un site à
/// identifier montre ce que le serveur propose, avec « C'est lui » pour le
/// confirmer d'un geste. La composition détaillée (cellules, PCI, RSRP, carte des
/// relevés) vit sur la fiche du site, ouverte d'un appui sur la ligne.
struct RadioLogSiteCard: View {
    let site: RadioLogSite
    let state: RadioLogSiteState
    /// Commune et adresse, quand le site est identifié ET que la fiche a été
    /// chargée. Absente, la ligne ne prétend rien savoir.
    let siteName: String?
    /// Support proposé par le serveur pour un site à identifier.
    var proposal: RadioLogSiteHypothesis? = nil
    /// Identifié par le membre lui-même.
    var isMine = false
    /// La proposition de ce site part en ce moment.
    var isConfirming = false
    let onOpen: () -> Void
    let onIdentify: () -> Void
    let onOpenMap: () -> Void
    var onConfirmProposal: (() -> Void)? = nil

    /// Les actions s'alignent sous le texte, pas sous la pastille.
    private var actionInset: CGFloat { M.leadPill + M.cardInnerGap }

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Button(action: onOpen) {
                HStack(alignment: .top, spacing: M.cardInnerGap) {
                    leadTile
                    VStack(alignment: .leading, spacing: 3) {
                        titleLine
                        if let subtitle {
                            Text(subtitle)
                                .font(.sqTechnical(M.siteMetaSize, .semibold))
                                .foregroundStyle(P.muted)
                                .sqSingleLine()
                        }
                        Text(metaLine)
                            .font(SQFont.body(M.siteMetaSize))
                            .monospacedDigit()
                            .foregroundStyle(P.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint(Text("Ouvre la fiche du site"))
            .accessibilityIdentifier("radioLogs.site.\(site.node)")

            if state.isUnidentified {
                Group {
                    if let proposal, let onConfirmProposal {
                        proposalBlock(proposal, confirm: onConfirmProposal)
                    } else {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: M.ctaGap) { identifyActions }
                            VStack(alignment: .leading, spacing: M.ctaGap) { identifyActions }
                        }
                    }
                }
                .padding(.leading, actionInset)
            }
        }
        .padding(.vertical, SQSpace.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Sous-vues

    /// Commune quand elle est connue, sinon l'identifiant du nœud.
    private var title: String {
        if let siteName, let commune = siteName.components(separatedBy: " — ").first, !commune.isEmpty {
            return commune
        }
        return site.nodeLabel
    }

    private var titleIsNode: Bool { title == site.nodeLabel }

    /// « eNB 812345 · site 0381234 » sous une commune, « site 0381234 » sous le nœud.
    private var subtitle: String? {
        let siteId = state.siteId.flatMap { $0.isEmpty ? nil : $0 }
        let sitePart = siteId.map { String(localized: "site \($0)") }
        if titleIsNode { return sitePart }
        return [site.nodeLabel, sitePart].compactMap { $0 }.joined(separator: " · ")
    }

    private var titleLine: some View {
        HStack(spacing: SQSpace.sm) {
            Text(title)
                .font(titleIsNode ? .sqTechnical(M.siteIdSize, .semibold) : SQFont.body(M.siteIdSize, .bold))
                .tracking(titleIsNode ? M.siteIdTracking : 0)
                .foregroundStyle(P.ink)
                .lineLimit(2)
            RadioLogTechBadge(label: site.techLabel)
            Spacer(minLength: 0)
            trailing
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if state.isIdentified {
            if isMine {
                Text("Par toi")
                    .font(SQFont.body(M.stateSize, .bold))
                    .foregroundStyle(P.chipInk)
                    .padding(.horizontal, M.statePaddingH)
                    .padding(.vertical, M.statePaddingV)
                    .background(P.chip, in: Capsule(style: .continuous))
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(P.muted)
                .accessibilityHidden(true)
        } else {
            RadioLogStatePill(state: state, checkable: site.isCheckable)
        }
    }

    /// `3 cellules · 2 PCI · 128 relevés · vu il y a 2 h`
    private var metaLine: String {
        [
            site.compositionLabel,
            String(localized: "\(site.logCount) relevé"),
            String(localized: "vu \(site.lastSeenAt.formatted(.relative(presentation: .named)))")
        ].joined(separator: " · ")
    }

    /// La couleur et le symbole disent l'état avant toute lecture : coche pour un
    /// site identifié, antenne carmin pour un site à identifier.
    private var leadTile: some View {
        let style: (symbol: String, ink: Color, fill: Color) = {
            switch state {
            case .identified: return ("checkmark", P.okInk, P.okSoft)
            case .unidentified: return ("antenna.radiowaves.left.and.right", P.accentInk, P.accentSoft)
            case .unchecked:
                return site.isCheckable
                    ? ("ellipsis", P.muted, P.chip)
                    : ("questionmark", P.muted, P.chip)
            }
        }()
        return Image(systemName: style.symbol)
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(style.ink)
            .frame(width: M.leadPill, height: M.leadPill)
            .background(style.fill, in: RoundedRectangle(cornerRadius: M.leadPillRadius, style: .continuous))
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var identifyActions: some View {
        // Le site dans le libellé VoiceOver : la liste en répète des centaines.
        RadioLogActionButton(label: "Identifier", action: onIdentify)
            .accessibilityLabel(Text("Identifier \(site.nodeLabel)"))
            .accessibilityIdentifier("radioLogs.site.identify")
        if site.hasCoordinate {
            RadioLogActionButton(label: "Carte", ghost: true, systemImage: "map", action: onOpenMap)
                .accessibilityLabel(Text("Voir \(site.nodeLabel) sur la carte"))
                .accessibilityIdentifier("radioLogs.site.map")
        }
    }

    /// Le support que propose le serveur, et de quoi le confirmer d'un geste. « Un
    /// autre » ouvre la feuille complète, avec les voisins et la carte.
    private func proposalBlock(_ proposal: RadioLogSiteHypothesis, confirm: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            HStack(alignment: .top, spacing: SQSpace.sm) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(P.okInk)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Proposé : site \(proposal.siteId)")
                        .font(SQFont.body(13, .bold))
                        .foregroundStyle(P.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = proposalDetail(proposal) {
                        Text(detail)
                            .font(SQType.caption)
                            .monospacedDigit()
                            .foregroundStyle(P.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            HStack(spacing: M.ctaGap) {
                Button(action: confirm) {
                    HStack(spacing: SQSpace.xs) {
                        if isConfirming {
                            ProgressView().controlSize(.small).tint(SQColor.onInk)
                        }
                        Text("C’est lui")
                    }
                    .font(SQFont.body(M.buttonSize, .bold))
                    .foregroundStyle(SQColor.onInk)
                    .padding(.horizontal, M.buttonPaddingH)
                    .padding(.vertical, M.buttonPaddingV)
                    .background(P.ink, in: RoundedRectangle(cornerRadius: M.buttonRadius, style: .continuous))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isConfirming)
                .accessibilityLabel(Text("Confirmer le site \(proposal.siteId) pour \(site.nodeLabel)"))
                .accessibilityIdentifier("radioLogs.site.confirmProposal")
                RadioLogActionButton(label: "Un autre", ghost: true, action: onIdentify)
                    .accessibilityLabel(Text("Choisir un autre site pour \(site.nodeLabel)"))
                    .accessibilityIdentifier("radioLogs.site.identify")
                Spacer(minLength: 0)
            }
        }
        .padding(SQSpace.md)
        .background(P.chip, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
    }

    /// « à 240 m · Le Fontanil — rue du Rocher », ce que le serveur a donné.
    private func proposalDetail(_ proposal: RadioLogSiteHypothesis) -> String? {
        var parts: [String] = []
        if let distance = proposal.distanceMeters {
            parts.append(String(localized: "à \(SQUnits.distance(meters: Double(distance)))"))
        }
        if let place = proposal.placeLabel { parts.append(place) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
