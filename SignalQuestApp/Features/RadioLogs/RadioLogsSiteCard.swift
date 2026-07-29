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
            .lineLimit(1)
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

    private var container: Color {
        switch state {
        case .identified: return P.okSoft
        case .unidentified: return P.chip
        case .unchecked: return P.chip
        }
    }

    private var ink: Color {
        switch state {
        case .identified: return P.okInk
        case .unidentified, .unchecked: return P.muted
        }
    }

    var body: some View {
        HStack(spacing: M.stateGap) {
            Circle()
                .fill(ink)
                .frame(width: M.stateDot, height: M.stateDot)
            Text(state.label)
                .font(SQFont.body(M.stateSize, .bold))
                .foregroundStyle(ink)
        }
        .padding(.horizontal, M.statePaddingH)
        .padding(.vertical, M.statePaddingV)
        .background(container, in: Capsule(style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(state.label)
    }
}

/// `.btn` — l'action de la carte.
///
/// Un `Button` nu plutôt qu'un style Material/`.borderedProminent` : les mesures
/// de la maquette (8/14 pt de marge, rayon 11) ne survivent pas aux marges
/// internes imposées par les styles système. La cible tactile est ramenée à
/// 44 pt par une marge TRANSPARENTE, qui n'agrandit pas le bouton à l'œil.
struct RadioLogActionButton: View {
    let label: String
    var ghost = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(SQFont.body(M.buttonSize, .bold))
                .lineLimit(1)
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
            .lineLimit(1)
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

/// `.oph` — l'intertitre d'opérateur.
///
/// La maquette y inverse la hiérarchie attendue : le nom de l'opérateur est
/// DISCRET, le décompte est en encre pleine. C'est juste — on sait déjà chez quel
/// opérateur on est, ce qu'on cherche c'est combien de sites tient cette section.
///
/// ÉCART ASSUMÉ avec la maquette : elle met ces libellés en capitales tracées.
/// La DA « Crème & Terre cuite » les proscrit explicitement (`sqKicker` a été
/// réécrit pour les supprimer partout). On garde la hiérarchie et les mesures,
/// pas la casse — sinon cette page détonnerait dans l'app.
struct RadioLogOperatorHeader: View {
    let operatorName: String
    let siteCount: Int
    let logCount: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: M.operatorHeaderGap) {
            Text(operatorName)
                .font(SQFont.body(M.operatorHeaderSize, .bold))
                .foregroundStyle(P.muted)
                .lineLimit(1)
            Text(siteCount <= 1 ? "\(siteCount) site" : "\(siteCount) sites")
                .font(SQFont.body(M.operatorHeaderStrongSize, .bold))
                .foregroundStyle(P.ink)
                .lineLimit(1)
            Text(logCount <= 1 ? "\(logCount) relevé" : "\(logCount) relevés")
                .font(SQFont.body(M.operatorHeaderSize, .bold))
                .foregroundStyle(P.muted)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .monospacedDigit()
        .padding(.top, M.operatorHeaderTop)
        .padding(.bottom, M.operatorHeaderBottom)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - La carte site

/// Une carte par eNB/gNB — l'unité de la page.
///
/// Un seul niveau : les groupes PCI et les rangées cellule imbriquées de
/// l'ancienne version ont disparu, et avec eux les chevrons de repli emboîtés.
/// Le dépliement montre la COMPOSITION du site, en lecture seule : aucune
/// pastille d'état ni bouton n'y figure, parce qu'aucune identification n'est
/// calculée par cellule.
struct RadioLogSiteCard: View {
    let site: RadioLogSite
    let state: RadioLogSiteState
    /// Commune et adresse, quand le site est identifié ET que la fiche a été
    /// chargée. Absente, la carte ne prétend rien savoir.
    let siteName: String?
    let isExpanded: Bool
    let onIdentify: () -> Void
    let onOpenMap: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: M.cardInnerGap) {
            leadPill
            VStack(alignment: .leading, spacing: 0) {
                identifierLine
                if let siteName {
                    Text(siteName)
                        .font(SQFont.body(M.siteNameSize, .semibold))
                        .foregroundStyle(P.ink)
                        .lineLimit(2)
                        .padding(.top, M.siteNameTop)
                }
                // À QUEL site ce nœud est rattaché. La commune ne suffit pas :
                // deux antennes d'une même commune se ressemblent, et c'est
                // l'identifiant qu'on retrouve dans « Mes identifications » ou
                // qu'on compare avec le terrain.
                if let identifiedSiteId = state.siteId, !identifiedSiteId.isEmpty {
                    Text("Site \(identifiedSiteId)")
                        .font(.sqTechnical(M.siteMetaSize, .semibold))
                        .foregroundStyle(P.muted)
                        .lineLimit(1)
                        .padding(.top, siteName == nil ? M.siteNameTop : 1)
                }
                Text(metaLine)
                    .font(SQFont.body(M.siteMetaSize))
                    .monospacedDigit()
                    .foregroundStyle(P.muted)
                    .padding(.top, M.siteMetaTop)

                RadioLogStatePill(state: state)
                    .padding(.top, M.stateTop)

                if state.isUnidentified {
                    HStack(spacing: M.ctaGap) {
                        RadioLogActionButton(label: "Identifier", action: onIdentify)
                        if site.hasCoordinate {
                            RadioLogActionButton(label: "Carte", ghost: true, action: onOpenMap)
                        }
                    }
                    .padding(.top, M.ctaTop)
                }

                if isExpanded {
                    cellsPanel
                }
            }
            chevron
        }
        .padding(.horizontal, M.cardPaddingH)
        .padding(.vertical, M.cardPaddingV)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(P.card, in: RoundedRectangle(cornerRadius: M.cardRadius, style: .continuous))
        .sqShadowCard()
    }

    // MARK: Sous-vues

    /// `.lead-pill` — pastille d'accent quand le site est identifié, neutre sinon.
    /// C'est le seul repère qui se lit au balayage vertical, avant même de lire.
    private var leadPill: some View {
        Image(systemName: site.kind == .gnb ? "antenna.radiowaves.left.and.right" : "cellularbars")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(state.isIdentified ? P.accentInk : P.muted)
            .frame(width: M.leadPill, height: M.leadPill)
            .background(
                state.isIdentified ? P.accentSoft : P.chip,
                in: RoundedRectangle(cornerRadius: M.leadPillRadius, style: .continuous)
            )
            .accessibilityHidden(true)
    }

    private var identifierLine: some View {
        HStack(spacing: SQSpace.sm) {
            Text(site.nodeLabel)
                .font(.sqTechnical(M.siteIdSize, .semibold))
                .tracking(M.siteIdTracking)
                .foregroundStyle(P.ink)
                .lineLimit(1)
            RadioLogTechBadge(label: site.techLabel)
            Spacer(minLength: 0)
        }
    }

    /// `3 cellules · 2 PCI · 128 relevés` — la composition, jamais une promesse.
    private var metaLine: String {
        var parts = [site.compositionLabel]
        parts.append(site.logCount <= 1 ? "\(site.logCount) relevé" : "\(site.logCount) relevés")
        return parts.joined(separator: " · ")
    }

    private var chevron: some View {
        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(P.muted)
            .accessibilityHidden(true)
    }

    /// `.cells` — la composition du site. DESCRIPTIVE : aucune pastille de statut,
    /// aucun bouton. On ne calcule plus d'identification par cellule, donc il n'y
    /// a plus rien à y valider.
    private var cellsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            RadioLogDashedSeparator()
                .padding(.top, M.cellsTop)
            Text("Cellules relevées")
                .font(SQFont.body(M.cellsHeaderSize, .bold))
                .foregroundStyle(P.muted)
                .padding(.top, M.cellsTop)
                .padding(.bottom, M.cellsHeaderBottom)

            ForEach(Array(site.cells.enumerated()), id: \.element.id) { index, cell in
                HStack(spacing: M.cellRowGap) {
                    RadioLogCellPciTag(label: cell.pciLabel)
                    Text(cell.identityLabel ?? "—")
                        .font(.sqTechnical(M.cellIdSize))
                        .foregroundStyle(P.ink)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let bandLabel = cell.bandLabel {
                        Text(bandLabel)
                            .font(SQFont.body(M.cellBandSize))
                            .monospacedDigit()
                            .foregroundStyle(P.muted)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, M.cellRowPaddingV)
                .accessibilityElement(children: .combine)

                if index < site.cells.count - 1 {
                    Rectangle()
                        .fill(P.hair)
                        .frame(height: 1)
                }
            }
        }
    }
}
