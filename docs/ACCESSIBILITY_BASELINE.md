# Baseline d'accessibilité — audit automatique

Relevé produit par `SignalQuestUITests/AccessibilityAuditTests`, qui exécute
`XCUIApplication.performAccessibilityAudit` — l'auditeur d'Apple — sur les cinq
onglets et l'écran Réglages.

```bash
./ci_scripts/run_a11y_audit.sh
```

## Pourquoi une baseline et pas un test bloquant

L'audit démarre en **mode rapport** : il journalise et n'échoue pas. Un gate
rouge à 93 problèmes serait ignoré dès la deuxième semaine. Chaque écran passe
`blocking: true` quand son compteur atteint zéro, et ne peut alors plus
régresser.

## Le relevé n'est pas déterministe

Deux exécutions consécutives, même binaire, même simulateur, ont donné **93**
puis **84** problèmes. L'écart vient du contenu : les onglets affichent ce qui a
fini de charger au moment de l'audit, et un écran plus rempli expose plus
d'éléments à auditer.

À en tirer : **un écart de quelques unités ne prouve rien**. Ne conclure à une
amélioration ou à une régression que sur un mouvement franc, et de préférence
sur le compteur d'un écran précis plutôt que sur le total.

## Relevé du 27 juillet 2026 — 93 problèmes

| Écran      | Contraste | Texte tronqué | Dynamic Type | Élément non détecté | Cible tactile |
|------------|----------:|--------------:|-------------:|--------------------:|--------------:|
| Accueil    |         4 |             4 |            0 |                   0 |             0 |
| Carte      |         0 |             2 |            0 |                   5 |             1 |
| Tester     |        10 |             4 |            4 |                   0 |             0 |
| Communauté |        16 |            15 |           12 |                   0 |             0 |
| Profil     |         7 |             0 |            0 |                   0 |             0 |
| Réglages   |         4 |             1 |            4 |                   0 |             0 |
| **Total**  |    **41** |        **26** |       **20** |               **5** |         **1** |

Exécution suivante, à titre de dispersion : 84 au total — 38 contraste,
22 tronqués, 20 Dynamic Type, 3 non détectés, 1 cible tactile.

## Ce que l'audit a appris qu'aucun test unitaire ne disait

`DesignTokenContrastTests` mesure les tokens à leur **valeur nominale**.
L'écran, lui, rend du texte **anti-crénelé** : les pixels du glyphe ne sont
jamais tout à fait la couleur du token.

Mesuré au pixel sur une capture réelle (`labelSecondary` 12,5 pt sur `surface`) :

| | cœur du glyphe | moyenne de l'encre |
|---|---:|---:|
| Sous-titre signalé par l'audit | 5,41:1 | **4,35:1** |
| Titre non signalé (contrôle)   | 13,25:1 | 10,68:1 |

Le nominal passait AA, le rendu non — d'où des dizaines d'échecs invisibles au
test unitaire. `LabelSecondary` a donc été assombri (clair `#71634F` →
`#6A5B45`, sombre `#A8987E` → `#B4A48A`).

Le compteur de contraste est passé de 52 à 41 sur des exécutions successives.
Compte tenu de la dispersion décrite plus haut, **ce chiffre seul ne prouve pas
le gain** ; ce qui l'établit est la mesure au pixel ci-dessus, reproductible sur
une capture donnée, et le fait que les cinq écrans aient baissé simultanément.

Conséquence de méthode : **un seuil nominal de 4,5:1 ne suffit pas** pour du
texte sous 13 pt. Viser ~6:1 nominal, ou faire porter la hiérarchie par la
taille et la graisse plutôt que par la couleur.

Corollaire vérifié et écarté : passer le sous-titre en `.medium` ne récupère
rien (4,35 → 4,30). La perte vient du rastérisage, pas de la finesse du trait.

## Reste à traiter, par ordre de rendement

1. **~40 contrastes, cause non encore établie.** L'hypothèse naturelle —
   des `Text` restés en `labelTertiary`, token volontairement sous AA
   (3,81:1) — a été **vérifiée et écartée** : sur les 50 usages du token,
   43 sont des `Image(systemName:)` et 2 des formes. Ce sont des objets
   graphiques, pour lesquels le seuil est 3:1 : l'usage est conforme, et la
   redistribution que prévoyait le plan est sans objet.

   Les éléments encore signalés sont de petits libellés dispersés
   (« Mbps médian », « Réception », « Envoi », « En ligne », séparateurs
   « — » et « · »). Point commun relevé : **leur taille**. « Mbps médian »
   est en `SQFont.body(11)`, les sous-titres de tuile en 12,5. À 23 % de
   perte au rastérisage, un token à 6,10:1 nominal ne rend que ~4,7:1 — juste
   au-dessus du seuil, sans marge.

   Piste la plus probable, à confirmer au pixel : **le problème n'est plus la
   couleur mais la taille**. Continuer à assombrir `labelSecondary`
   l'écraserait contre `label` (déjà 14,73:1) sans régler les 11 pt. Relever
   le plancher du texte secondaire à 12-13 pt traiterait la cause.

   Ampleur : **38 sites** associent `labelSecondary` à une police de 10 à
   11,5 pt (19 en `body(11)`, 15 en `body(11.5)`, 4 à 10-10,5). C'est un
   ajustement de DA, à arbitrer explicitement.

   Méthode : mesurer au pixel avant de toucher au moindre token — c'est ce
   qui a évité de corriger au jugé la première fois, et ce qui a permis
   d'écarter l'hypothèse `labelTertiary`.
2. **26 textes tronqués** — concentrés sur Communauté (15).
3. **20 Dynamic Type** — polices partiellement non redimensionnables.
4. **5 éléments non détectés** — tous sur la carte, sur les points denses
   dessinés en Core Graphics, qui ne peuvent pas être des éléments individuels.
   Correctif prévu : liste synthétique des plus proches du centre.
5. **1 cible tactile** trop petite, sur la carte.

## Piège : `accessibilityElement(children: .combine)` casse les tests UI

Regrouper `ErrorStateView` avec `.sqCard` a fait échouer
`testFiveTabsAndPrimaryStatesWithMockAuth` : XCUITest ne retrouvait plus
`feed.header` ni le bouton « Messages » — alors que ce sont des **frères** de
l'état d'erreur, pas ses enfants. Isolé par bissection (test vert sans le
changement, rouge avec, vert à nouveau une fois la fusion retirée) ; le
mécanisme n'a pas été élucidé.

À en retenir : **fusionner un composant partagé se vérifie avec la suite UI**,
pas seulement à la compilation. Une fusion retire des éléments de l'arbre
d'accessibilité, donc du champ de vision de XCUITest — et parfois plus large
que le sous-arbre visé. Le même modificateur sur `EmptyStateView` est sans
effet de bord et a été conservé.

## Deuxième passe — encre translucide et libellés tronqués

Un premier relevé n'avait trouvé que 3 sites d'`onAccent` translucide sur du
texte ; un rescan propre en a trouvé **14** (le premier dédoublonnait trop).
Table mesurée sur `brandRed` :

| α | clair | sombre |
|---|---:|---:|
| 0,70 | 3,29:1 | 3,75:1 |
| 0,85 | 4,10:1 | 4,92:1 |
| 1,00 | **5,05:1** | 6,03:1 |

**En mode clair, aucun alpha < 1,0 n'atteint 4,5:1.** Les 13 petits textes
concernés sont repassés en alpha plein ; le grand texte (30 et 20 pt dans
`ShareCardBubble`) reste à 0,7, qui franchit son seuil de 3:1, comme les icônes
et les traits.

`DesignTokenContrastTests.testNoSmallTextUsesTranslucentOnAccent` verrouille la
règle en relisant les sources. Il a fallu **deux** filtres combinés, chacun seul
produisant des faux positifs constatés : sans le filtre `foregroundStyle`, des
`.background()` de `Capsule` passaient pour du texte ; sans le filtre sur le
constructeur le plus proche, les `Image(systemName:)` aussi. Sa capacité à
détecter a été vérifiée en réintroduisant volontairement une infraction.

Trois libellés de tuile se tronquaient par ailleurs à Dynamic Type élevé
(`pulseTile`, `NetworkPulseHero.stat`, la pastille métrique de
`SignalFormatters`) : la **valeur** avait `lineLimit(1)` + `minimumScaleFactor`,
le **libellé** n'avait rien.

Après ces correctifs : **71 problèmes** contre 84 — contraste 38 → 28, tronqués
22 → 18. Chiffre à prendre avec réserve : ce relevé ne couvre que 5 écrans, le
6ᵉ (Profil) n'ayant pas pu être audité (voir ci-dessous).

## Le crash qui empêche d'auditer Profil

L'app meurt systématiquement au passage sur l'onglet Profil (3 fois sur 3),
sur une vérification d'isolation MainActor dans `SignalQuestApp.body` —
`_swift_task_checkIsolatedSwift` → `closure #1 in SignalQuestApp.body.getter`.

Sans rapport avec l'accessibilité, mais il plafonne ce que le harnais peut
mesurer : tant qu'il n'est pas corrigé, Profil reste hors couverture.

## Limite connue

L'audit n'expose **pas** le ratio qu'il a mesuré (`detailedDescription` dit
seulement « Contrast failed for SwiftUI.AccessibilityNode »). Pour instruire un
cas précis, mesurer les pixels d'une capture — c'est ce qui a établi le tableau
ci-dessus.
