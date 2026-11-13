import SwiftUI

/// DISPUTED-SITE r1 : ce que le serveur sait du site qui porte déjà le nœud.
struct CustomSiteAlreadyLinked: Equatable {
    let check: CustomSiteRadioCheck
    let radio: CustomSiteRadioSnapshot
    /// Opérateur du nœud, en clair ; nil = tu.
    let operatorLabel: String?
    /// Envoi en attente « à revoir » ; nil = création refusée sous les yeux du membre.
    var pending: CustomSitePendingReview? = nil

    var nodeLabel: String { radio.nodeLabel ?? radio.cellId ?? "" }
    var isOwn: Bool { check.ownedByRequester }
    var siteId: String? { check.linkedSiteId }

    /// « données officielles ANFR », « site communautaire »… : la source, jamais devinée.
    var sourceLabel: String {
        if isOwn { return String(localized: "ton site communautaire") }
        switch check.source {
        case "anfr": return String(localized: "données officielles ANFR")
        case "registry" where check.registryMarket?.uppercased() == "CA": return String(localized: "données officielles ISED")
        case "custom": return String(localized: "site communautaire")
        default: return String(localized: "site déjà identifié")
        }
    }
}

/// Planche « Ce nœud a déjà un site » (validée le 11/11, Android 87c4c352f). Trois variantes :
/// un autre site, le site du membre, et l'envoi en attente « à revoir ». Les boutons absents
/// (callback nil) ne sont pas dessinés : rien n'ouvre un écran que l'hôte n'a pas.
struct CustomSiteAlreadyLinkedView: View {
    let linked: CustomSiteAlreadyLinked
    var onViewSite: (() -> Void)? = nil
    /// « Ce n'est pas le bon site » / « Corriger ton site ».
    var onWrongSite: (() -> Void)? = nil
    /// La note de bas de page décrit l'identification sur la carte : seulement si l'hôte l'ouvre.
    var opensMapIdentification = false
    var onCreateAnyway: (() -> Void)? = nil
    var onAbandon: (() -> Void)? = nil
    var isBusy = false

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            if linked.pending != nil {
                Text("Envoi en attente · à revoir").sqKicker()
            }
            HStack(alignment: .firstTextBaseline, spacing: SQSpace.sm) {
                if linked.pending == nil {
                    // Son propre site n'est pas une alerte : une information, à l'encre.
                    Image(systemName: linked.isOwn ? "info.circle" : "exclamationmark.circle")
                        .font(SQFont.body(18, .semibold, relativeTo: .title3))
                        .foregroundStyle(linked.isOwn ? SQColor.labelSecondary : SQColor.warning)
                        .accessibilityHidden(true)
                }
                Text(verbatim: title)
                    .font(SQType.title)
                    .foregroundStyle(SQColor.label)
                    .fixedSize(horizontal: false, vertical: true)
                    .sqHeader()
            }
            Text(verbatim: bodyText)
                .font(SQType.body)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            siteCard
            if linked.pending != nil, !linked.isOwn, let note = reviewNote {
                SQNotice(message: note, systemImage: "exclamationmark.circle", tone: .warning)
            }
            actions
            if linked.pending == nil, let footnote {
                Text(verbatim: footnote)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var title: String {
        linked.isOwn ? String(localized: "Ce nœud est déjà sur ton site") : String(localized: "Ce nœud a déjà un site")
    }

    private var bodyText: String {
        let node = linked.nodeLabel
        switch (linked.pending, linked.isOwn) {
        case let (pending?, true):
            return String(localized: "« \(pending.name) » n’a pas été créé : le nœud \(node) est déjà sur un site que tu as créé.")
        case let (pending?, false):
            return String(localized: "« \(pending.name) » n’a pas été créé : entre-temps, le nœud \(node) a été rattaché à un site.")
        case (nil, true):
            return String(localized: "Le nœud \(node) est rattaché à un site que tu as créé. Corrige-le plutôt que d’en créer un second.")
        case (nil, false):
            return String(localized: "Le nœud \(node) est déjà rattaché à un site. On n’en crée pas un second : il masquerait le premier.")
        }
    }

    /// Nom du site (communautaire seulement) et « Orange · données officielles ANFR » : ce qui est
    /// su, rien d'autre. La distance n'est pas donnée : iOS ne lit pas la position du site ici.
    private var siteCard: some View {
        let origin = [linked.operatorLabel, linked.sourceLabel].compactMap { $0 }.joined(separator: " · ")
        return VStack(alignment: .leading, spacing: SQSpace.xxs) {
            if let name = linked.check.siteName {
                Text(verbatim: name)
                    .font(SQType.rowTitle)
                    .foregroundStyle(SQColor.label)
            }
            Text(verbatim: origin)
                .font(SQType.callout)
                .foregroundStyle(SQColor.labelSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(SQSpace.md)
        .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    /// « Créer quand même » : ce que la création changera, avant de la confirmer.
    private var reviewNote: String? {
        let node = linked.nodeLabel
        switch linked.check.currentKind {
        case .custom:
            if let name = linked.check.siteName {
                return String(localized: "Créer quand même : le nœud \(node) quittera « \(name) », le site d’un autre membre.")
            }
            return String(localized: "Créer quand même : le nœud \(node) quittera le site d’un autre membre.")
        case .official:
            return String(localized: "Créer quand même : le site officiel ne change pas, ton site portera le nœud \(node).")
        case .unknown:
            return String(localized: "Créer quand même : le nœud \(node) sera rattaché à ton site.")
        }
    }

    private var footnote: String? {
        guard opensMapIdentification, onWrongSite != nil else { return nil }
        return linked.isOwn
            ? String(localized: "« Corriger ton site » ouvre l’identification sur la carte : tu rattaches la cellule au bon site.")
            : String(localized: "« Ce n’est pas le bon site » ouvre l’identification sur la carte : tu rattaches la cellule au bon site, ou tu en crées un si aucun ne convient.")
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: SQSpace.sm) {
            // Sans site désigné par le serveur, rien à ouvrir : pas de bouton plutôt qu'un site au hasard.
            if linked.siteId != nil, let onViewSite {
                GradientButton(linked.isOwn ? String(localized: "Voir ton site") : String(localized: "Voir ce site"),
                               allowsMultiline: true, action: onViewSite)
                    .accessibilityIdentifier("customSiteLinked.view")
            }
            if linked.pending != nil {
                if !linked.isOwn, linked.siteId != nil, let onCreateAnyway {
                    GradientButton(String(localized: "Créer quand même"), isBusy: isBusy, style: .secondary,
                                   allowsMultiline: true, action: onCreateAnyway)
                        .disabled(isBusy)
                        .accessibilityIdentifier("customSiteLinked.createAnyway")
                }
                if let onAbandon {
                    GradientButton(String(localized: "Abandonner mon site"), style: .ghost, allowsMultiline: true, action: onAbandon)
                        .disabled(isBusy)
                        .accessibilityIdentifier("customSiteLinked.abandon")
                }
            } else if let onWrongSite {
                GradientButton(linked.isOwn ? String(localized: "Corriger ton site") : String(localized: "Ce n’est pas le bon site"),
                               style: .secondary, allowsMultiline: true, action: onWrongSite)
                    .accessibilityIdentifier("customSiteLinked.wrongSite")
            }
        }
    }
}

extension CustomSiteDispute {
    /// Note du formulaire : ce que la création contestée changera.
    var formNote: String {
        switch kind {
        case .custom:
            if let siteName {
                return String(localized: "Le nœud \(nodeLabel) quittera « \(siteName) », le site d’un autre membre, pour celui-ci. « \(siteName) » reste sur la carte avec ses autres cellules.")
            }
            return String(localized: "Le nœud \(nodeLabel) quittera le site d’un autre membre pour celui-ci. L’ancien site reste sur la carte avec ses autres cellules.")
        case .official:
            return String(localized: "Le site officiel ne change pas : ton site portera le nœud \(nodeLabel), et l’écart restera visible.")
        case .unknown:
            return String(localized: "Le nœud \(nodeLabel) sera rattaché à ton nouveau site.")
        }
    }
}
