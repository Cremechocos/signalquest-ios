# SignalQuest iOS — Plan des nouvelles fonctionnalités (F1 → F8)

> **Statut : proposition à valider.** Plan dédié aux 8 fonctionnalités, distinct du backlog de correction (`PLAN.md`) et du rapport d'exécution (`EXECUTION_REPORT.md`).

## Contexte & contraintes transverses (à respecter pour TOUTES)

- **Limite radio iOS (non négociable)** : iOS n'expose PAS le signal fin (RSRP/RSRQ/SINR, Cell ID, bandes, voisines). iOS capte seulement : **génération** (2G/3G/4G/5G NSA/5G SA via CoreTelephony, passif/continu), **connectivité** (réseau utilisable ou non via Network.framework), **débit/latence** (moteur speedtest, actif), **position** (CoreLocation, consentie), **opérateur** (résolu — cf. Lot 1), **modèle d'appareil**. → Toute « couverture » contribuée par iOS = ces données, **jamais** du signal radio.
- **Backend = dépôt séparé en PROD** (`~/Site/map-nextjs`) : tout ajout est **additif** (aucune route web/Android cassée), **SQL idempotent uniquement** (`CREATE TABLE/ADD COLUMN IF NOT EXISTS`), **jamais** `prisma migrate dev`/`db push` sur la prod. Le backend de F1/F6 est décrit comme **ticket** (à exécuter dans `map-nextjs`), pas codé côté iOS.
- **Confidentialité** : données géolocalisées contribuées → **consentement** + **troncature des coordonnées** à l'envoi (réglage existant), alignées sur la minimisation (cf. BE-5).
- **Cible** : iOS 16 min / iPhone-only / Swift 6 ; API récentes (iOS 18+) **gated `if #available`**.
- **Design** : fidélité au design system (`SQBrand`/`SQComponents`).
- **Vérification** : build (`xcodebuild`) ici ; **pas de runtime simulateur** → UX/tests à valider **sur appareil**.

## Vue d'ensemble

| # | Feature | iOS | Backend | Effort | Risque | Bloquant |
|---|---|---|---|---|---|---|
| **F1** | Sessions de couverture iOS (génération/connectivité + débits, sur la carte) | ✅ gros | ⚠️ **nouvelle route POST + schéma** | Élevé | Moyen | **route backend** |
| **F2** | Live Activity / Île Dynamique dédiée Drive Test | ✅ petit | — | Faible | Faible | — |
| **F3** | Contrôle « Speedtest express » (Centre de contrôle, iOS 18) | ✅ moyen | — | Faible | Faible | iOS 18+ |
| **F4** | Siri / Raccourcis / Spotlight élargis | ✅ moyen | — | Faible-moyen | Faible | — |
| **F5** | Timeline / historique d'un site ANFR | ✅ moyen | — (routes existent) | Faible-moyen | **Faible** | — |
| **F6** | Quêtes & easter-eggs (branchés points/badges existants) | ✅ moyen | — (routes existent) | Moyen | Faible | — |
| **F7** | « Mes mesures sur la carte » (vue perso) | ✅ moyen | — (route existe) | Moyen | Faible | dépend de F1 |
| **F8** | Widget d'accueil « réseau autour de moi » | ✅ moyen | — | Faible-moyen | Faible | — |

---

## F1 — Sessions de couverture iOS *(centre du plan)*

**Objectif.** Pendant un parcours (mode Drive Test), enregistrer une **session** = trace GPS + relevés **génération/connectivité en continu** + **points de débit/latence** là où un test a tourné, puis la **stocker (backend)**, l'**afficher** (détail + carte de trace) et la **partager**. Sur la carte principale, exposer ces points (filtrables par génération).

**Ce qu'on enregistre (honnête, limites iOS).** Par point : `lat/lng` (tronqués), `timestamp`, **génération** (`5G NSA`/`4G`/… ou `null`), **connectivité** (`usable`/`none`), **opérateur**, et (aux points testés seulement) `downloadMbps`/`uploadMbps`/`pingMs`. **Pas de puissance de signal.**

### Périmètre iOS
- **Capture** : dans `DriveTestViewModel` ([DriveTestView.swift](SignalQuestApp/Features/DriveTest/DriveTestView.swift)), accumuler un point à chaque `onLocationUpdate` ({coord, génération via `services.networkPath.status.cellularTechnology`, connectivité, opérateur résolu}) ; enrichir le point courant avec débit/latence à la fin de chaque speedtest.
- **Envoi** : à `stop()`, `POST` la session (idempotency-key) ; best-effort si la route est absente (404 avalé, comme d'autres routes additives).
- **Affichage** : **réutiliser l'existant** — [SessionsListView / SessionDetailView / SessionTraceMapView](SignalQuestApp/Features/Sessions/) (lecture déjà branchée via `GET /api/coverage/sessions`, modèle [`CoverageSessionPoint`](SignalQuestApp/Models/SessionModels.swift:125)). Ajouter : coloration de la trace **par génération**, légende.
- **Carte principale** : la couche couverture existe déjà ([`CoverageHeatPoint`](SignalQuestApp/Models/MapModels.swift:509), `/api/coverage/points`) → exposer les points iOS dessus, filtrables par génération.
- **Service** : étendre [`SessionsService`](SignalQuestApp/Services/SessionsService.swift) avec une méthode `createSession(...)`.

### Périmètre backend *(ticket `map-nextjs` — additif/idempotent, NON codé ici)*
- **Route** `POST /api/coverage/sessions` : accepte `{ startedAt, endedAt, market, operator, device, viaVpn, points: [{lat,lng,t,generation,connectivity,downloadMbps?,uploadMbps?,pingMs?}] }` → renvoie `{ id }` (relisible via le `GET` existant).
- **Schéma** : confirmer le modèle `CoverageSession` existant (lecture déjà OK) ; ajouter en **SQL idempotent** les champs manquants (`generation`, `connectivity`, `source='ios'`, `hasSignal=false`) si besoin. Marquer `source:'ios'` pour distinguer des sessions Android (qui, elles, ont le signal).
- **Confidentialité** : troncature coords pour lectures anonymes (BE-5) ; rattacher la session au compte authentifié.

**Risque.** Moyen : dépend d'une route backend nouvelle (sinon F1 reste « enregistrement local sans persistance »). La capture iOS est sûre (données déjà disponibles).
**Done.** Un parcours produit une session persistée, visible dans « Sessions » avec trace colorée par génération, partageable ; points visibles sur la carte.
**Tests.** Unit : accumulation des points (génération/connectivité/débit) ; encodage du body `POST`. Appareil : un trajet réel → session relue.

---

## F2 — Live Activity / Île Dynamique dédiée Drive Test
**Objectif.** Pendant un parcours, infos en direct (opérateur, n° de test, débit, génération) sur écran verrouillé + **Île Dynamique**.
**iOS.** Le Drive Test **utilise déjà** une Live Activity (réutilise celle du speedtest, [SpeedtestLiveActivityController](SignalQuestApp/Features/Speedtest/SpeedtestLiveActivityController.swift)). Reste : un **layout dédié** « Drive Test » (mode continu : afficher « Test N » + opérateur + génération au lieu de « rafale i/N »), dans la cible widget isolée ([SpeedtestLiveActivity.swift](SignalQuestWidget/SpeedtestLiveActivity.swift)).
**Effort.** Faible. **Backend.** Aucun. **Done.** Île Dynamique affiche l'état Drive Test correctement (mode continu, opérateur).

## F3 — Contrôle « Speedtest express » (Centre de contrôle, iOS 18+)
**Objectif.** Lancer un speedtest en 1 tap depuis le Centre de contrôle / écran verrouillé.
**iOS.** `ControlWidget` (iOS 18, `if #available(iOS 18, *)`) déclenchant l'**App Intent speedtest existant** ([SpeedtestIntents](SignalQuestApp/Features/Intents/SpeedtestIntents.swift)). Cible widget.
**Effort.** Faible. **Backend.** Aucun. **Done.** Contrôle présent sur iOS 18+, lance un speedtest. (Invisible iOS 16/17 — normal.)

## F4 — Siri / Raccourcis / Spotlight élargis
**Objectif.** « Quel est mon opérateur/réseau ici ? » et « Lance un Drive Test » via Siri/Raccourcis ; présence Spotlight.
**iOS.** Nouveaux `AppIntent` (réseau actuel via NetworkPathMonitor + `/api/speedtest/operator` ; lancer Drive Test via routing) + `AppShortcutsProvider` ; étendre [SQSpotlight](SignalQuestApp/Features/Intents/SQSpotlight.swift).
**Effort.** Faible-moyen. **Backend.** Aucun (réutilise `/api/speedtest/operator`). **Done.** Intents fonctionnels (vérif appareil). **Risque.** Faible — un intent réseau+localisation nécessite test réel.

## F5 — Timeline / historique d'un site ANFR ⭐ *(le plus sûr, à faire en 1er)*
**Objectif.** Sur la fiche d'un site ANFR, une **frise** de son évolution (bandes/opérateurs au fil du temps).
**iOS.** Lecture pure via `/api/anfr/archives` + `/api/anfr/site-history/{supId}` (**existent**) ; nouvelle vue timeline branchée sur [ANFRSiteDetailSheet](SignalQuestApp/Features/ANFR/ANFRSiteDetailSheet.swift), composants `SQ*`.
**Effort.** Faible-moyen. **Backend.** Aucun. **Risque.** **Minimal** (aucune écriture). **Done.** Frise affichée pour un site ayant un historique ; états vide/chargement/erreur.

## F6 — Quêtes & easter-eggs *(branchés au système points/badges existant)*
**Objectif.** Surfacer des **quêtes** (« teste 5 lieux », « couvre une zone ») + easter-eggs à réclamer, **alimentant les points/badges actuels**.
**iOS.** Réutiliser [`GamificationService`](SignalQuestApp/Services/GamificationService.swift) (`catalog` = quêtes/badges, `events` = points, `profile` = points/niveau, `easter-eggs/claim`) ; nouvelle section dans [GamificationView](SignalQuestApp/Features/Profile/GamificationView.swift). **Pas de système parallèle** — on branche l'existant.
**Effort.** Moyen (surtout design produit des quêtes). **Backend.** Routes existantes (ajouter des entrées `catalog` côté serveur = contenu, pas de schéma). **Done.** Quêtes visibles, progression liée aux points existants, easter-egg réclamable.

## F7 — « Mes mesures sur la carte » *(version honnête de l'ancien « ma couverture »)*
**Objectif.** Une carte **personnelle** de **tes** mesures (tes speedtests + tes sessions F1), colorées par **débit** ou **génération**. Points épars (là où tu as testé/roulé), **pas** une couverture continue.
**iOS.** Couche/filtre MapLibre lisant `/api/user/speedtests` (**déjà consommé** par [SocialFeedService:252](SignalQuestApp/Services/SocialFeedService.swift:252)) + tes sessions F1 ; bascule « débit / génération ».
**Effort.** Moyen. **Backend.** Aucun (route existe ; complète F1). **Done.** Vue « mes mesures » filtrable. **Note.** Complète F1 (F1 = enregistrer/contribuer ; F7 = parcourir ton empreinte). **Dépend de F1** pour inclure les sessions.

## F8 — Widget d'accueil « réseau autour de moi »
**Objectif.** Widget home : antenne/opérateur le plus proche + ton dernier speedtest.
**iOS.** WidgetKit (cible existante) lisant [WidgetSharedStore](SignalQuestApp/Core/Shared/WidgetSharedStore.swift) (l'app y écrit déjà l'état speedtest ; ajouter l'opérateur résolu + l'antenne proche). Timeline de rafraîchissement raisonnable.
**Effort.** Faible-moyen. **Backend.** Aucun. **Done.** Widget affiche données à jour, états par défaut propres. **Contrainte.** Cible widget isolée (pas d'accès aux composants/couleurs de l'app → coder en dur).

---

## Ordre d'exécution recommandé

1. **Phase A — gains rapides, zéro backend** : **F5** (le plus sûr) → **F3** → **F4** → **F8** → **F2**.
2. **Phase B — gamification** : **F6** (branché aux points/badges existants).
3. **Phase C — couverture (avec backend)** :
   - **F1a** : **ticket backend** `POST /api/coverage/sessions` (additif/idempotent) — à valider/livrer dans `map-nextjs`.
   - **F1b** : capture + envoi + affichage iOS.
   - **F7** : « Mes mesures » (réutilise F1 + `/api/user/speedtests`).

**Points de validation** : démo/vérif appareil après chaque feature ; arrêt avant F1b tant que la route backend n'est pas confirmée.

## Vérification & tests
- Build `xcodebuild` (Xcode 27, iphonesimulator) après chaque feature ; tests unitaires ciblés (encodage F1, intents F4, décodage timeline F5).
- **Validation UX/exécution sur iPhone** (pas de runtime simulateur ici).
- F1 : tester un trajet réel (génération qui change, zone sans réseau) → session correcte.
