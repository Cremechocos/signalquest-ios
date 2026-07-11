---
name: SignalQuest Crème
description: Un compagnon réseau chaleureux — mesurer, comprendre et partager le signal, avec la douceur d'un carnet crème.
colors:
  brique: "#B04A3C"
  brique-pressed: "#963D31"
  brique-dark: "#D97A66"
  creme: "#F3EDE2"
  creme-secondary: "#EDE5D5"
  creme-surface: "#FBF7EF"
  creme-raised: "#FFFFFF"
  encre: "#332818"
  encre-secondary: "#8D7C64"
  encre-tertiary: "#C0B098"
  separator: "#E5DCC9"
  nuit: "#191410"
  nuit-surface: "#262019"
  nuit-muted: "#332B20"
  nuit-encre: "#F2EAD9"
  olive: "#7E8C5C"
  olive-dark: "#A3B37A"
  ambre: "#C08A3E"
  danger: "#C13B2C"
typography:
  display:
    fontFamily: "Bricolage Grotesque, SF Pro Display, sans-serif"
    fontSize: "26pt"
    fontWeight: 700
    lineHeight: 1.1
  title:
    fontFamily: "Bricolage Grotesque, SF Pro Display, sans-serif"
    fontSize: "24pt"
    fontWeight: 700
    lineHeight: 1.15
  headline:
    fontFamily: "Bricolage Grotesque, SF Pro Text, sans-serif"
    fontSize: "16.5pt"
    fontWeight: 600
    lineHeight: 1.25
  body:
    fontFamily: "Figtree, SF Pro Text, sans-serif"
    fontSize: "15pt"
    fontWeight: 400
    lineHeight: 1.45
  label:
    fontFamily: "Figtree, SF Pro Text, sans-serif"
    fontSize: "15pt"
    fontWeight: 600
    lineHeight: 1.2
  caption:
    fontFamily: "Figtree, SF Pro Text, sans-serif"
    fontSize: "13pt"
    fontWeight: 400
    lineHeight: 1.35
rounded:
  sm: "10pt"
  md: "14pt"
  lg: "20pt"
  xl: "22pt"
  xxl: "26pt"
  pill: "999pt"
spacing:
  xxs: "2pt"
  xs: "4pt"
  sm: "8pt"
  md: "12pt"
  lg: "16pt"
  xl: "20pt"
  xxl: "24pt"
  xxxl: "32pt"
  huge: "40pt"
components:
  button-primary:
    backgroundColor: "{colors.encre}"
    textColor: "{colors.creme-surface}"
    typography: "{typography.headline}"
    rounded: "{rounded.pill}"
    padding: "16pt 24pt"
    height: "56pt"
  button-accent:
    backgroundColor: "{colors.brique}"
    textColor: "{colors.creme-surface}"
    typography: "{typography.headline}"
    rounded: "{rounded.pill}"
    height: "56pt"
  card:
    backgroundColor: "{colors.creme-surface}"
    textColor: "{colors.encre}"
    rounded: "{rounded.xl}"
    padding: "18pt"
    shadow: "0 4pt 18pt rgba(51,40,24,0.06)"
  chip:
    backgroundColor: "{colors.creme-surface}"
    textColor: "{colors.encre}"
    rounded: "{rounded.pill}"
    padding: "8pt 13pt"
  tile:
    backgroundColor: "{colors.creme-secondary}"
    rounded: "{rounded.md}"
    padding: "10pt 12pt"
---

# Design System : SignalQuest Crème

## Overview

**Creative North Star : « Le compagnon de terrain »**

SignalQuest devient un outil chaleureux et accueillant : un fond crème, des surfaces douces qui flottent sans bordures, des capsules généreuses et une brique terreuse pour l'action. La précision de la mesure reste au premier plan, mais elle est portée par la rondeur et la lumière plutôt que par des filets et des majuscules.

La densité reste progressive : une action évidente par écran, les métriques détaillées ensuite. L'interface refuse les tableaux de bord saturés, les bordures systématiques, le glassmorphism décoratif et les contrôles non natifs.

**Key Characteristics :**

- Beige crème comme couleur principale ; la brique est rare et signifiante.
- Zéro bordure sur les cartes : la hiérarchie vient des tons et d'ombres très courtes.
- Capsules (pill) pour tout ce qui se touche : boutons, chips, champs, dock.
- Icônes SF Symbols posées dans des pastilles circulaires teintées.
- Titres Bricolage Grotesque ronds et affirmés ; corps Figtree calme.
- Clair et sombre au même niveau de soin (le sombre est brun chaud, jamais gris).

## Colors

### Primary

- **Brique** (`#B04A3C`, sombre `#D97A66`) : action principale, sélection active, badges non-lus, tuile Tester, bulles sortantes. Une grande surface brique par écran maximum.
- **Brique pressée** (`#963D31`) : état pressé uniquement.
- Teinte douce : brique à 12 % d'alpha (18 % en sombre) pour pastilles d'icônes, pilule active du dock, tags.

### Secondary

- **Olive** (`#7E8C5C`, sombre `#A3B37A`) : succès, état « Stable », validations, phases terminées.
- **Ambre** (`#C08A3E`) : avertissements.
- **Danger** (`#C13B2C`) : destructif — distinct de la brique par sa vivacité et toujours accompagné d'un libellé.

### Neutral

- **Crème** (`#F3EDE2` / nuit `#191410`) : fond principal.
- **Surface** (`#FBF7EF` / `#262019`) : cartes, dock, sheets.
- **Crème secondaire** (`#EDE5D5` / `#332B20`) : tuiles internes, tracks de jauges, champs de saisie.
- **Encre** (`#332818` / `#F2EAD9`) : texte principal, bouton primaire.

**The Brique Rule.** La brique signale l'action et la sélection ; elle ne colore jamais tout un écran. Quand tout est important, rien ne l'est.

**The Meaning Rule.** Une couleur de technologie, d'opérateur ou d'état garde la même signification sur la carte, les mesures, les classements et le social.

## Typography

**Display Font :** Bricolage Grotesque (repli SF Pro Display)

**Body Font :** Figtree (repli SF Pro Text)

**Character :** Bricolage donne aux titres et aux chiffres une rondeur confiante ; Figtree garde l'interface légère et lisible. Casse normale partout — plus de micro-labels majuscules tracés. Dynamic Type respecté via les styles relatifs.

### Hierarchy

- **Display** (Bold 26, interligne 1.1) : salutation, titres d'écran.
- **Title** (Bold 24) : sections majeures, sheets.
- **Headline** (SemiBold 16.5) : cartes, tuiles, boutons.
- **Chiffres** (Bold 20–58) : métriques — 58 pt au centre du cadran, 30 pt dernière mesure, 22 pt stats.
- **Body** (Regular 15 / 1.45) : contenu.
- **Caption** (Regular 12.5–13.5) : sous-titres, horodatages.

## Elevation

Le système remplace les bordures par des ombres chaudes très courtes :

- **Repos** (`0 2pt 8pt rgba(51,40,24,0.05)`) : chips, petites tuiles.
- **Carte** (`0 4pt 18pt rgba(51,40,24,0.06)`) : toutes les cartes de contenu.
- **Accent** (`0 8pt 22pt brique@28%`) : uniquement sous les surfaces brique.
- **Dock flottant** (`0 10pt 30pt rgba(51,40,24,0.14)`) : dock, sheets détachées.

**The No-Border Rule.** Une carte n'a jamais à la fois ombre et bordure. La seule bordure du système : la rangée « moi » des classements (brique 1.5 pt sur fond teinté).

## Components

### Buttons

- Capsules, hauteur 56 pt, zone tactile ≥ 44 pt, libellé Bricolage SemiBold 16.
- **Primary** : fond encre, texte crème. **Action en cours / stop** : fond brique.
- **Secondary** : fond surface + ombre repos, texte encre. **Destructif** : texte danger sur teinte danger 10 %.
- Press : scale 0.97, 160 ms ; aucun effet si Reduce Motion.

### Chips

- Capsules Figtree 600 12–13 pt ; inactif surface + ombre repos, actif brique plein texte crème. Jamais de bordure, jamais de majuscules.

### Cards / Containers

- Rayon 22 pt continu, fond surface, padding 18 pt, ombre carte. Tuiles internes : crème secondaire, rayon 14, sans ombre.

### Inputs

- Capsules 44 pt, fond crème secondaire, sans bordure ; focus par teinte brique native.

### Navigation

- **Dock flottant** : capsule surface à 95 % + blur, marges 16 pt, 14 pt du bas, ombre dock. Item actif : pilule teintée brique 12 % + icône/libellé brique ; inactifs bruns discrets. Icônes 22 pt, libellés 9.5 pt.
- Destinations : Accueil, Carte, Tester, Communauté, Profil. Messages et Classements sont des pushes.
- Le dock disparaît en conversation (composer au clavier).

### Measurement Dial

- Arc 270° (départ 135°), track 22 pt bouts ronds crème secondaire, remplissage brique, disque central surface. Valeur Bricolage 58, phase en Figtree 12, badge d'état en capsule teintée.

## Do's and Don'ts

### Do :

- **Do** passer par les tokens (`SQColor`, `SQFont`, `SQRadius`, `SQSpace`, `SQMotion`) — aucune valeur locale.
- **Do** poser les icônes SF Symbols dans des pastilles circulaires teintées.
- **Do** garder une seule grande surface brique par écran.
- **Do** soigner squelettes, états vides, hors ligne et erreurs dans le même langage (formes arrondies, tons crème).
- **Do** tester Dynamic Type, VoiceOver, Reduce Motion et le mode sombre brun.

### Don't :

- **Don't** ajouter des bordures aux cartes ou aux chips (règle No-Border).
- **Don't** réintroduire majuscules trackées, kickers rouges ou coins nets.
- **Don't** utiliser la brique en grand aplat décoratif ou sur plusieurs éléments concurrents.
- **Don't** empiler carte dans carte sans relation structurelle.
- **Don't** confirmer une action avant la réponse serveur.
- **Don't** réinventer un contrôle quand un composant Apple standard convient.
