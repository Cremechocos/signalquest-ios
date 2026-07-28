import Foundation

/// Quantification des coordonnées publiées.
///
/// Deux exigences opposées se rencontrent ici. D'un côté la minimisation
/// (RGPD art. 5.1.c) : une trace de Drive Test ne doit pas permettre de suivre
/// quelqu'un au bâtiment près. De l'autre la lisibilité de la carte : la tuile de
/// couverture sert par défaut les coordonnées BRUTES, et sa grille d'agrégation
/// descend à ~27 m au zoom 13 — des points arrondis à 111 m s'y collent en
/// quadrillage régulier au lieu de dessiner une trace.
///
/// Le pas retenu (~50 m) est calé sur la cadence de capture : un point capturé,
/// un carreau publié, aucun doublon. Il correspond aussi à l'échelle à laquelle la
/// donnée iOS varie réellement — sans RSRP, la seule grandeur mesurée est la
/// génération, qui change au gré des cellules, pas tous les onze mètres. Publier
/// plus fin serait de la fausse précision.
///
/// ⚠️ Un pas en DEGRÉS ne vaut pas la même distance selon l'axe : 0,0005° font
/// ~55 m en latitude partout, mais seulement ~39 m en longitude à 45° N (et
/// moins encore vers les pôles). C'est voulu : la grille reste plus fine que la
/// cadence de capture sur les deux axes sous nos latitudes.
enum CoordinateGrid {

    /// Pas de publication, en degrés décimaux. ~55 m en latitude.
    static let publicationStep: Double = 0.0005

    /// Colle une coordonnée sur la grille.
    ///
    /// Les non-finis (`NaN`, `±infinity`) ressortent tels quels : c'est à
    /// l'appelant de refuser une coordonnée invalide, ce n'est pas le rôle d'un
    /// arrondi de décider à sa place.
    static func snap(_ value: Double, step: Double = publicationStep) -> Double {
        guard value.isFinite, step > 0 else { return value }
        // Le produit `n * step` traîne du bruit binaire (45,7645 devient
        // 45,764500000000005). On le rabote à 6 décimales : très au-delà de la
        // précision du pas, mais assez pour que deux points d'un même carreau
        // soient EXACTEMENT égaux — sinon aucun dédoublonnage ne fonctionne.
        let snapped = (value / step).rounded() * step
        return (snapped * 1_000_000).rounded() / 1_000_000
    }
}
