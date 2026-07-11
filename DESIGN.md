---
name: SignalQuest Apple
description: Un carnet de terrain éditorial pour mesurer, comprendre et partager le réseau.
colors:
  signal-red: "#E2001A"
  signal-red-deep: "#C00017"
  signal-red-dark: "#FF414F"
  field-paper: "#F4F0E6"
  field-paper-secondary: "#ECE7D8"
  field-surface: "#FBF9F3"
  field-raised: "#FFFFFF"
  field-ink: "#18150F"
  field-ink-secondary: "#3A352B"
  field-separator: "#C4BCA6"
  night-paper: "#100E0A"
  night-surface: "#26221A"
  night-ink: "#F3EFE3"
  info: "#1D4ED8"
  success: "#16A34A"
  warning: "#E8590C"
typography:
  display:
    fontFamily: "Archivo Expanded, SF Pro Display, sans-serif"
    fontSize: "34pt"
    fontWeight: 900
    lineHeight: 1.05
    letterSpacing: "-0.02em"
  title:
    fontFamily: "Archivo Expanded, SF Pro Display, sans-serif"
    fontSize: "22pt"
    fontWeight: 700
    lineHeight: 1.15
  headline:
    fontFamily: "Archivo, SF Pro Text, sans-serif"
    fontSize: "17pt"
    fontWeight: 600
    lineHeight: 1.25
  body:
    fontFamily: "Public Sans, SF Pro Text, sans-serif"
    fontSize: "16pt"
    fontWeight: 400
    lineHeight: 1.4
  label:
    fontFamily: "Archivo, SF Pro Text, sans-serif"
    fontSize: "15pt"
    fontWeight: 700
    lineHeight: 1.2
rounded:
  sm: "4pt"
  md: "6pt"
  lg: "8pt"
  xl: "10pt"
  xxl: "12pt"
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
    backgroundColor: "{colors.signal-red}"
    textColor: "{colors.field-raised}"
    typography: "{typography.label}"
    rounded: "{rounded.sm}"
    padding: "15pt 16pt"
    height: "50pt"
  button-secondary:
    backgroundColor: "{colors.field-surface}"
    textColor: "{colors.field-ink}"
    typography: "{typography.label}"
    rounded: "{rounded.sm}"
    padding: "15pt 16pt"
    height: "50pt"
  card:
    backgroundColor: "{colors.field-surface}"
    textColor: "{colors.field-ink}"
    rounded: "{rounded.xl}"
    padding: "16pt"
  chip:
    backgroundColor: "{colors.field-paper-secondary}"
    textColor: "{colors.field-ink}"
    rounded: "{rounded.pill}"
    padding: "8pt 12pt"
---

# Design System: SignalQuest Apple

## Overview

**Creative North Star: "Le Carnet de terrain"**

SignalQuest ressemble à un carnet de mesure contemporain : précis, lisible en extérieur et enrichi par la communauté. La structure reste familière à un utilisateur Apple ; l'identité apparaît dans la typographie éditoriale, le rouge de signal et une hiérarchie de surfaces inspirée du papier plutôt que dans des effets décoratifs.

La densité varie avec l'intention. Les actions et conclusions sont immédiates ; les métriques radio détaillées se déploient ensuite. L'interface refuse les tableaux de bord télécom saturés, le glassmorphism décoratif, les grilles de cartes imbriquées et les contrôles non natifs.

**Key Characteristics:**

- Une action principale évidente par contexte.
- Des surfaces tonales nettes et peu d'ombres.
- Une typographie expressive pour les titres, discrète pour l'interface.
- Des états de chargement, hors ligne, vide et erreur aussi soignés que l'état nominal.
- Des transitions de 150 à 250 ms qui expliquent un changement d'état.

## Colors

La palette associe un rouge franc à des neutres de terrain chauds, avec des couleurs sémantiques réservées aux données et aux états.

### Primary

- **Rouge Signal** : action principale, sélection active et moments de contribution. Sa rareté maintient sa force.
- **Rouge Signal profond** : état pressé ou accent de contraste ; jamais comme grande surface décorative.

### Secondary

- **Bleu Information** : information non destructive et catégories radio quand le rouge signifierait une action.
- **Vert Validation** : succès confirmé et qualité positive, jamais simple décoration.
- **Orange Alerte** : avertissement et attention non bloquante.

### Neutral

- **Papier de terrain** : arrière-plan principal clair.
- **Papier secondaire** : regroupement structurel, filtres inactifs et séparations tonales.
- **Surface de lecture** : contenu élevé d'un niveau sans effet de verre.
- **Encre terrain** : texte principal ; l'encre secondaire reste suffisamment contrastée pour le corps.
- **Papier nocturne** et **surface nocturne** : équivalents sombres, déclenchés par l'apparence système.

**The Signal Rule.** Le rouge sert aux actions primaires, à la sélection et aux états critiques ; il ne colore jamais tous les éléments d'un écran.

**The Meaning Rule.** Une couleur de technologie, d'opérateur ou d'état conserve la même signification sur la carte, les mesures, les classements et le social.

## Typography

**Display Font:** Archivo Expanded (repli SF Pro Display)

**Body Font:** Public Sans (repli SF Pro Text)

**Label Font:** Archivo (repli SF Pro Text)

**Character:** Archivo Expanded donne aux titres une autorité éditoriale ; Archivo rend les contrôles nets ; Public Sans garde les explications calmes et lisibles. Tous les rôles utilisent Dynamic Type et retombent sur les polices système si les fontes embarquées manquent.

### Hierarchy

- **Display** (Black, 34 pt, interligne 1,05) : titre principal d'une vue ou résultat marquant, jamais label de contrôle.
- **Title** (Bold, 22 pt, interligne 1,15) : sections majeures et feuilles de détail.
- **Headline** (Semibold, 17 pt, interligne 1,25) : titres de groupes et cartes.
- **Body** (Regular, 16 pt, interligne 1,4) : explications et contenu, avec une largeur de lecture limitée à environ 70 caractères.
- **Label** (Bold, 15 pt, interligne 1,2) : boutons et contrôles. Les micro-labels en capitales restent exceptionnels.

**The One Display Rule.** Un seul niveau Archivo Expanded domine un écran ; les contrôles, listes et données restent en Archivo ou Public Sans.

## Elevation

Le système est tonal par défaut. Les différences entre papier, surface et surface élevée portent la hiérarchie ; les séparateurs de 1 pt structurent les listes. Les ombres sont réservées aux éléments réellement flottants — chrome de carte, popover, feuille détachée — et restent courtes. Le Liquid Glass natif peut servir au chrome interactif sur iOS 26, jamais comme langage universel des cartes.

### Shadow Vocabulary

- **Chrome flottant** (`0 6pt 12pt rgba(0,0,0,0.12)`) : contrôles superposés à une carte ou une image.
- **Feedback accentué** (`0 4pt 8pt rgba(226,0,26,0.20)`) : état transitoire d'une action principale, jamais au repos.

**The Flat-by-default Rule.** Une carte de contenu ordinaire utilise une surface tonale ou un séparateur, pas une ombre diffuse.

## Components

### Buttons

- **Shape:** géométrie nette et continue (rayon 4 pt), zone tactile minimale de 44 pt et hauteur nominale de 50 pt.
- **Primary:** fond Rouge Signal, libellé Archivo Bold blanc, une seule action primaire visible par groupe.
- **Hover / Focus:** feedback natif, réduction d'échelle légère au press et contour d'accessibilité système ; aucune animation si Reduce Motion est actif.
- **Secondary / Ghost:** surface claire avec contour Encre terrain, ou fond transparent avec séparateur discret.

### Chips

- **Style:** capsule compacte, fond Papier secondaire, libellé Archivo et icône SF Symbol.
- **State:** sélection Rouge Signal avec contraste AA ; l'état ne dépend jamais de la couleur seule.

### Cards / Containers

- **Corner Style:** rayon de 8 à 10 pt.
- **Background:** Surface de lecture ou regroupement tonal.
- **Shadow Strategy:** aucune ombre au repos ; chrome flottant uniquement selon la règle d'élévation.
- **Border:** séparateur 1 pt lorsque le contraste tonal ne suffit pas.
- **Internal Padding:** 16 pt, avec 12 pt entre groupes proches.

### Inputs / Fields

- **Style:** surface de lecture, rayon 8 pt, libellé explicite et zone tactile de 44 pt minimum.
- **Focus:** comportement iOS natif et teinte Rouge Signal.
- **Error / Disabled:** message adjacent localisé, couleur sémantique plus icône/texte ; jamais une bordure rouge sans explication.

### Navigation

La navigation utilise `NavigationStack`, les titres système et une barre d'onglets adaptative. Les cinq destinations produit sont Accueil, Carte, Tester, Communauté et Profil ; Messages est une destination de Communauté. Sur iPad, les composants s'adaptent à la largeur disponible et à Split View sans agrandir artificiellement la typographie.

### Measurement Summary

Le résumé de mesure présente d'abord conclusion, technologie et trois métriques essentielles. Les identifiants radio, bandes, cellules et détails serveur sont disponibles dans une section progressive dédiée.

## Do's and Don'ts

### Do:

- **Do** utiliser les tokens `SQColor`, `SQFont`, `SQSpace`, `SQRadius` et `SQMotion` plutôt que des valeurs locales.
- **Do** conserver une zone tactile d'au moins 44 pt et tester Dynamic Type, VoiceOver et Reduce Motion.
- **Do** afficher skeleton, état vide pédagogique, hors ligne, erreur et confirmation persistée pour chaque flux réseau.
- **Do** utiliser des patterns Apple standards avant de créer un composant spécifique.
- **Do** réserver les données expertes à une divulgation progressive.

### Don't:

- **Don't** construire un tableau de bord télécom saturé de métriques, néons et jargon dès le premier écran.
- **Don't** utiliser du glassmorphism décoratif, des gradients omniprésents ou une large ombre avec une bordure sur la même carte.
- **Don't** empiler des grilles de cartes identiques ou imbriquer une carte dans une carte sans relation structurelle réelle.
- **Don't** confirmer une sauvegarde, un consentement ou une suppression avant la réponse serveur.
- **Don't** réinventer boutons, navigation, menus, alertes ou champs lorsqu'un contrôle Apple standard convient.
- **Don't** utiliser une couleur seule pour communiquer qualité, sélection, erreur ou abonnement.
