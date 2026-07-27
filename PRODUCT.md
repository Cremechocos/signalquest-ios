# Product

## Register

product

## Users

SignalQuest s'adresse aux personnes qui veulent comprendre la qualité réelle de leur réseau mobile, comparer leurs mesures et contribuer à une cartographie communautaire fiable. Le public va de l'utilisateur curieux qui lance ponctuellement un speedtest au contributeur régulier qui réalise des Drive Tests, avec un niveau expert disponible sans encombrer les parcours courants.

L'application est utilisée en mobilité, souvent en extérieur, avec une seule main, une connectivité imparfaite et parfois dans des situations où la vitesse de compréhension compte davantage que la densité d'information. Elle doit aussi rester pleinement utilisable sur iPad, en multitâche et avec les technologies d'assistance.

## Product Purpose

SignalQuest réunit mesure réseau, cartographie et communauté dans une expérience Apple native. L'objectif principal est de permettre à chacun de mesurer, comprendre et partager la qualité d'un réseau sans expertise préalable, tout en préservant la précision nécessaire aux utilisateurs avancés.

Le produit réussit lorsque les parcours essentiels — découvrir, mesurer, consulter la carte, contribuer et échanger — sont évidents, résilients hors ligne, honnêtes sur la confidentialité et cohérents sur iPhone, iPad, Android et le web.

## Brand Personality

Précise, humaine, chaleureuse.

La voix est claire et directe, jamais technocratique. SignalQuest inspire la confiance d'un outil de terrain sérieux avec la chaleur d'un compagnon du quotidien : surfaces crème, formes rondes, célébrations sobres. Les données sont expliquées, les limites sont dites, les succès sont soulignés avec retenue (badge olive, jamais de confettis).

## Anti-references

- Les tableaux de bord télécom saturés de métriques, de néons et de jargon dès le premier écran.
- Les interfaces « imprimées » froides : bordures systématiques, majuscules trackées, coins durs.
- Le glassmorphism décoratif, les gradients omniprésents et les ombres longues qui brouillent la hiérarchie.
- Les grilles de cartes identiques et imbriquées qui transforment chaque information en conteneur.
- Les interfaces sociales manipulatrices, les permissions surprises et les confirmations de succès avant persistance réelle.
- Les contrôles réinventés qui ne se comportent pas comme une application Apple.

## Design Principles

1. **La tâche avant la donnée.** L'action principale et son état doivent être compris avant les métriques détaillées.
2. **Expertise progressive.** Montrer une synthèse accessible, puis révéler les données radio avancées à la demande.
3. **Confiance vérifiable.** Ne confirmer une action qu'après validation réelle ; expliquer permissions, confidentialité et limites techniques au bon moment.
4. **Résilience de terrain.** Les parcours critiques survivent aux pertes réseau, suspensions et reprises sans perte silencieuse.
5. **Natif, chaleureux, distinctif.** Utiliser les conventions iOS et iPadOS, puis porter l'identité SignalQuest par le crème, la brique, Bricolage Grotesque et la douceur des surfaces.

## Accessibility & Inclusion

La cible minimale est WCAG 2.2 AA. Tous les écrans doivent prendre en charge Dynamic Type, VoiceOver, contraste suffisant, Reduce Motion, différenciation des états autrement que par la couleur, zones tactiles d'au moins 44 points et navigation clavier sur iPad.

Sur le contraste, la règle est désormais tenue par un test (`DesignTokenContrastTests`) qui mesure chaque token **réellement résolu** par le système, dans les deux apparences : `label` et `labelSecondary` sont à ≥ 4,5:1 et portent le texte courant ; `labelTertiary` (`#8B7B63`) est à ≥ 3:1 et **réservé aux éléments graphiques** — icônes, traits, points inactifs. Sur une pastille teintée, utiliser `accentInk` / `dangerInk` plutôt que la couleur pleine.

L'interface est en **français**. L'infrastructure de localisation est en place (String Catalogs, `SWIFT_EMIT_LOC_STRINGS`, catalogue `InfoPlist` pour les prompts de permission) et les chaînes sont extraites, mais aucune traduction n'est encore fournie : l'anglais reste à livrer.
