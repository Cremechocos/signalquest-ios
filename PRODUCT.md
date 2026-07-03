# Product

## Register

product

## Users

Utilisateurs mobiles francophones (France d'abord, multi-pays ensuite) curieux de la qualité réelle du réseau : passionnés télécom, contributeurs communautaires, utilisateurs en mobilité (drive test en voiture, mesures en extérieur, une seule main, luminosité variable). Ils viennent vérifier « qu'est-ce que ça capte ici, et chez quel opérateur ? » et contribuer leurs mesures s'ils le décident.

## Product Purpose

App iOS native de SignalQuest (signalquest.fr) : comprendre le réseau mobile autour de soi — antennes ANFR sur carte, speedtests fiables, contribution communautaire de couverture (génération/connectivité/débits, dans les limites radio d'iOS), sessions drive test, couche sociale (amis, messagerie E2EE, feed, stories) et gamification (points, badges). Succès = activation (comprendre la proposition de valeur avant le mur de connexion) puis contribution récurrente et consentie.

## Brand Personality

Éditorial, technique, honnête. « Réseau mobile, à nu » : la DA de la landing web portée au natif — rouge signature sur papier crème (sombre chaud en dark), typographie affirmée (Archivo Expanded pour les displays), coins nets, ton direct qui tutoie. Trois mots : éditorial, franc, précis.

## Anti-references

- SaaS générique (bleu corporate, cards uniformes, dégradés décoratifs).
- Look Material/Android transposé tel quel sur iOS.
- Speedtests « gamifiés casino » (Ookla-like saturé de néons).
- Toute UI qui suggère une précision radio qu'iOS n'expose pas (RSRP, Cell ID…) : l'honnêteté des données est un trait de marque, pas une contrainte subie.

## Design Principles

1. **La landing dans la poche** : même voix visuelle que le web (Archivo Expanded/Archivo/Public Sans, papier, rouge brand, kickers), traduite en idiomes iOS natifs, jamais copiée pixel par pixel.
2. **Honnête sur les données** : montrer ce qu'on mesure vraiment, nommer ce qu'on ne peut pas mesurer.
3. **Fluide et natif** : springs SQMotion, haptics discrets, Dynamic Type, reduce motion respecté — la sensation d'une app iOS soignée, pas d'une webview.
4. **Consentement d'abord** : localisation et contributions opt-in, la valeur se démontre avant de demander.
5. **Un seul vocabulaire de composants** : SQComponents/SQBrand partout ; si deux écrans divergent, l'un des deux a tort.

## Accessibility & Inclusion

Dynamic Type via `SQFont(relativeTo:)` partout ; `accessibilityReduceMotion` respecté sur toute animation ; VoiceOver (labels combinés par bloc logique, valeurs annoncées) ; contrastes encre-sur-papier vérifiés dans les deux modes ; cibles tactiles ≥ 44 pt.
