# SignalQuest iOS — Plan d'amélioration globale (audit → backlog priorisé)

> **Statut : plan validé le 2026-06-29.** Aucune ligne de code n'a encore été modifiée.
> Exécution **lot par lot, sur validation explicite**, avec arrêt après chaque P0 (Phase D, en dehors de la session d'audit).

---

## Contexte (pourquoi ce plan)

L'app **SignalQuest iOS** (SwiftUI, Swift 6, iOS 16 min, iPhone-only ; mesure réseau mobile + cartographie d'antennes, social-first) a déjà traversé 8 « Lots » d'amélioration et deux plans (`PRODUCTION_READINESS_PLAN.md`, `BACKEND_TICKETS_SPRINT3.md`). Le choix retenu est de **repartir de zéro** : ce document est un **plan global neuf** issu d'un audit autonome multi-axes, qui **remplace** la planification iOS antérieure comme source de vérité (les tickets *backend* restent des dépendances externes, non traités ici).

**Objectif n°1 retenu : stabilité & correction de bugs d'abord**, puis qualité (perf/a11y/dette), puis nouvelles fonctionnalités. Déclencheur principal : un **bug produit Drive Test** (mauvais opérateur affiché) sur une feature toute neuve, plus une **fuite d'hygiène de dépôt** (secrets + `build/` trackés).

### Méthodologie & fiabilité des constats
Audit mené par 3 agents read-only (Core/Sécurité/Concurrence · Map/DriveTest/ANFR/Speedtest · Social/UI/A11y/Code-mort/Tests), **puis re-vérification manuelle** des constats P0/P1 les plus lourds. Cette vérification a **infirmé plusieurs findings** de l'agent Sécurité (voir §Annexe). Tout constat encore non vérifié ligne à ligne est tagué **(à confirmer)** et sera validé avant correction.

### Hypothèses de travail (à corriger au besoin avant exécution)
- **Cible** : on conserve **iOS 16.0 min / iPhone-only / Swift 6**. Les API iOS récentes (jusqu'aux plus modernes, « iOS 27 ») sont utilisées **sous `if #available`** pour ne pas relever le plancher (sauf décision de relever la cible).
- **Backend** : correction **100 % côté client** sans dépendre d'évolutions backend (FR prioritaire). On ne touche pas au backend.
- **Sécurité** : repo **reste public** (donc on durcit) ; lot d'hygiène côté iOS ; **rotation des mots de passe de test + purge d'historique = action humaine**.
- **Design** : **fidélité au design system** (`SQBrand`/`SQComponents`), polish + factorisation, pas de refonte visuelle.
- **Comportement** : préserver l'existant par défaut ; tout changement de comportement est **marqué** dans le lot concerné.
- **Tests** : tests unitaires ciblés sur les zones critiques ; CI optionnelle (à décider).

---

## Constats d'audit synthétisés par axe

Gravité : **P0** bloquant/sécurité/données fausses · **P1** régression/UX importante/race réelle · **P2** dette/amélioration.

### A. Sécurité & hygiène
| Grav. | Constat | Référence |
|---|---|---|
| **P0** | `build/` tracké par Git (**16 524 fichiers**, ~1,7 Go) alors qu'il est dans `.gitignore` → pollution massive du dépôt. | `git ls-files build/` |
| **P0** | Identifiants de comptes de test trackés (email + mot de passe) sur un **repo public** → fuite réelle. | `TestArtifacts/.test-account-credentials`, `.test-account-b-credentials` |
| P2 | Auth émet **à la fois** `Authorization: Bearer` et `Cookie: auth_token=` (volontaire, forward-compat). À nettoyer une fois le Bearer confirmé côté backend. | `SignalQuestApp/Core/Networking/APIClient.swift:220` |
| P2 | Pas de **certificate pinning** (`NSPinnedDomains`/ATS) sur `signalquest.fr` / `api.` / `speedtest.`. | `SignalQuest.entitlements` / `Info.plist` (à ajouter) |
| P2 | Keychain ne distingue pas `errSecInteractionNotAllowed` (item verrouillé biométrie) de `errSecItemNotFound` (absent) → risque théorique de **régénération de clé E2EE** (perte d'accès aux convs). **(à confirmer)** | `Core/Security/KeychainStore.swift` |
| ✅ | *Infirmé* : purge cookies logout couvre déjà les sous-domaines ; flags QA bien derrière `#if DEBUG` ; refresh token coalescé correct. | voir Annexe |

### B. Bug fonctionnel — Drive Test opérateur (cœur du sujet)
| Grav. | Constat | Référence |
|---|---|---|
| **P0** | Résolution opérateur SIM en 4 niveaux ; si tous échouent, `resolvedSim` reste `nil` et le code retombe **silencieusement** sur `"ALL"`. | `DriveTestView.swift:201`, `:167` |
| **P0** | `operator=="ALL"` + FR → liste **codée en dur** `["SFR","BOUYGUES","ALL"]` ; un utilisateur **Orange/Free** non résolu voit des antennes SFR/Bouygues, pas les siennes. Cause partielle **backend** (BE-3 : pas d'`operator=ALL` agrégé). | `Services/AntennasService.swift:59` |
| **P0** | **Aucun feedback UI** quand l'opérateur n'est pas détecté (WiFi/VPN/SIM masquée iOS 16.4+) : le bandeau reste vide. | `DriveTestView.swift:488` |
| **P0** | Live Activity codée en dur `runIndex:1, runTotal:0` → affiche toujours « Test 1/0 ». **(à confirmer ligne exacte)** | `DriveTestView.swift:103` |
| P1 | 3 requêtes **sérielles** (SFR+Bouygues+ALL) à chaque rafraîchissement, non parallélisées → latence ×3, charge serveur ×3 en continu. | `Services/AntennasService.swift:66` |
| P1 | Pas de **debounce** sur le rafraîchissement antennes au changement de position GPS (vs MapExplorer qui temporise). | `DriveTestView.swift` (`refreshAntennasIfNeeded`) |
| P1 | Logique de résolution opérateur/marché **dupliquée** Map ↔ DriveTest (deux cascades parallèles). | DriveTestView ~195-241 / MapExplorerView ~91-148 |
| P2 | `DriveTestMapView.syncSites` recrée toutes les annotations à chaque changement de signature (pas de diff incrémental). | `DriveTestMapView.swift` |

### C. Performance carte (transverse)
| Grav. | Constat | Référence |
|---|---|---|
| P1 | Recréation d'annotations sans diff id→annotation (DriveTest ; à vérifier sur Map/ANFR qui ont déjà reçu du travail perf au Lot 7). | DriveTestMapView, MapExplorerView, ANFRMapLibreView |
| P2 | `MapExplorerView` = **3843 lignes** (ViewModel + modèles + store + vue + coordinateurs) → maintenabilité limite, décomposition prudente justifiée. | `Features/Map/MapExplorerView.swift` |
| P2 | `DiskCache` : éviction bornée en taille/âge (Lot 7) mais pas en **nombre de fichiers** → scan disque lent après usage prolongé. **(à confirmer)** | `Core/Cache/DiskCache.swift` |

### D. Concurrence
| Grav. | Constat | Référence |
|---|---|---|
| P1 | Tasks optimiste+serveur dans `react/repost/favorite` sans garde d'annulation ferme → écriture `@Published` possible après pop de vue. **(à confirmer)** | FeedView/`FeedViewModel`, ExploreView `toggleFollow` |
| P1 | Envoi de message : risque de double-envoi si l'état `isSending` n'est pas verrouillé avant double-tap (l'Idempotency-Key limite l'impact backend). **(à confirmer)** | `ConversationDetailView` |
| P2 | `SpeedtestService` n'annule pas explicitement les `URLSessionTask` de stream à l'abandon → conso batterie/bande passante résiduelle. **(à confirmer)** | `Services/SpeedtestService.swift` |
| P2 | `SSEClient` : backoff exponentiel borné mais **sans hard-cap** de tentatives avant abandon explicite. **(à confirmer)** | `Core/Realtime/SSEClient.swift` |
| ✅ | *Infirmé* : continuations `LocationService` (classe `@MainActor`, gardes présentes) et lock de refresh `APIClient` sont corrects. | Annexe |

### E. Confidentialité
| Grav. | Constat | Référence |
|---|---|---|
| P2 | Tracking GPS background (`allowsBackgroundLocationUpdates`) **sans indicateur in-app persistant** ni arrêt auto après N heures (l'OS affiche la pastille système, mais pas d'affordance app). | `LocationService.swift:51` |
| P2 | Vérifier que `PrivacyInfo.xcprivacy` reflète la collecte réelle (10 m en Drive Test = « Precise » plausiblement correct ; 100 m one-shot). | `Resources/PrivacyInfo.xcprivacy` |

### F. UX / UI & Design system
| Grav. | Constat | Référence |
|---|---|---|
| P1 | États d'erreur sans action **« Réessayer »** sur plusieurs écrans (Feed loadMore silencieux, CommentsSheet, etc.). **(à confirmer)** | FeedView, `CommentsSheet`, … |
| P1 | `PrivacySettingsView` : bouton « Enregistrer » `disabled(!loaded)` mais `loaded` reste `false` si le load initial échoue → utilisateur **bloqué** sans retry. **(à confirmer)** | `PrivacySettingsView` |
| P2 | Conformité design system ~78 % : encadrés `.stroke(...)` répétés (15+), badges proches (`TechBadge`/`MetricPill`), avatars bordés non unifiés, valeurs magiques de padding (Leaderboards). | ProfileView, LeaderboardsView, StoriesBar, `SQComponents.swift` |
| P2 | Incohérences haptiques (LoginView sans `Haptics.error()` ; `favorite()` sans haptique). **(à confirmer)** | LoginView, `FeedViewModel` |

### G. Accessibilité
| Grav. | Constat | Référence |
|---|---|---|
| P1 | Icônes SF **sans `accessibilityLabel`** (barre d'actions de carte feed : like/repost/comment/favorite/share ; annotations carte ; badges réseau lus comme symboles). | CardActionsBar, DriveTestMapView ~151-211, `SQComponents` badges |
| P2 | Dynamic Type partiel (`GlassCard`, `StoryViewer` ne scalent pas tout) ; un delay d'anim ignore `reduceMotion` (ReactionPicker). **(à confirmer)** | GlassCard, StoryViewer, ReactionPicker |

### H. Code mort & duplication
| Grav. | Constat | Référence |
|---|---|---|
| P2 | **Services orphelins suspectés** (0 référence par type dans `Features/`) : `PrivacyService`, `ValidationsService`, `ReportsService`, `AntennasService.validate/reportIssue`. **À confirmer** (peuvent être injectés autrement) avant retrait. | `Services/*.swift` |
| P2 | États « zombie » déclarés non utilisés (`showReportUser`, `showGroupSettings`). **(à confirmer)** | `ConversationDetailView` |

### I. Tests
| Grav. | Constat | Référence |
|---|---|---|
| P1 | **Aucun test ne verrouille le « no-cleartext » E2EE** (le code lève bien `decryptFailed`, mais sans test de non-régression). | `SignalQuestTests/E2EETests.swift` |
| P2 | Zones non couvertes : flux E2EE complet (bootstrap→unlock→send→receive), envoi message (idempotency/double-send), pagination/loadMore, résolution opérateur Drive Test, Keychain edge-cases, annulation Speedtest. | `SignalQuestTests/`, `SignalQuestUITests/` |

---

## Section sécurité / confidentialité (en tête)

**Lot 0 ci-dessous est P0 et passe avant tout le reste.** Aucun secret n'est reproduit dans ce plan. Les actions à **risque irréversible** (rotation de mots de passe, réécriture d'historique Git) sont **explicitement déléguées à l'humain**.

---

## Backlog en lots thématiques (ordonné par priorité)

### 🔴 Lot 0 — Hygiène de dépôt & secrets (P0)
- **Objectif** : stopper la fuite et dépolluer le dépôt sans réécrire l'historique.
- **Fichiers** : `.gitignore`, index Git (`build/`, `TestArtifacts/.test-account*`).
- **Changement** : `git rm --cached -r build/` et `git rm --cached TestArtifacts/.test-account-credentials .test-account-b-credentials` ; vérifier `.gitignore` (ajouter explicitement `TestArtifacts/.test-account*`) ; commit de nettoyage.
- **Action humaine (hors code)** : (1) **rotation** des mots de passe des comptes de test côté backend ; (2) **purge d'historique** (`git filter-repo`/BFG) pour effacer secrets + `build/` du passé. *L'historique Git n'est pas modifié par l'agent.*
- **Risque** : faible (changement d'index). Le `git rm --cached` ne supprime pas les fichiers du disque.
- **Done** : `git ls-files build/` vide ; credentials non trackés ; build local toujours OK.
- **Tests** : `git status` propre ; vérif qu'aucun chemin sensible ne reste tracké.

### 🔴 Lot 1 — Drive Test : opérateur correct + finition (P0/P1) — *lot phare*
- **Objectif** : afficher **les bonnes antennes** et donner à l'utilisateur le contrôle + le feedback. Choix retenus : **sélecteur d'opérateur manuel** + **distinction visuelle par opérateur**.
- **Fichiers** : `DriveTestView.swift`, `DriveTestMapView.swift`, `AntennasService.swift`, un **nouveau** `OperatorMarketResolver` partagé, `MapExplorerView.swift` (adoption du resolver), `Models/MarketRegistryModels.swift`.
- **Changements** (chacun marqué *changement de comportement* le cas échéant) :
  1. **Resolver partagé** : extraire la cascade opérateur/marché (4 niveaux) dupliquée Map/DriveTest dans un type unique testable (factorisation prudente, comportement préservé).
  2. **Sélecteur manuel** : `@Published manualOperatorOverride` + Picker listant les opérateurs du marché détecté ; priorité `manualOverride ?? resolvedSim ?? …`. *(changement : l'utilisateur peut forcer l'opérateur.)*
  3. **Feedback non-détecté** : bandeau « Opérateur non identifié — choisis-le » quand `resolvedSim == nil` (au lieu du vide silencieux). *(changement visible.)*
  4. **Distinction visuelle** : colorer les annotations par opérateur sur la carte Drive Test (l'opérateur de chaque site est connu via le fan-out) + légende.
  5. **Live Activity** : passer le vrai `runIndex/runTotal` (corrige `1/0`). *(correction de bug.)*
  6. **Perf** : paralléliser les requêtes `ALL` (`async let`/`TaskGroup`) + **debounce** du refresh sur position GPS + diff incrémental des annotations dans `syncSites`.
- **Risque** : moyen (touche le cœur carte + réseau). Mitigation : diffs séparés par sous-point, validation après chaque.
- **Done** : un utilisateur Orange/Free non auto-résolu peut sélectionner son opérateur et voir SES antennes ; carte distingue les opérateurs ; Live Activity affiche le bon compteur ; 1 aller-retour réseau par opérateur en parallèle.
- **Tests** : unit `OperatorMarketResolver` (4 niveaux + nil) ; unit `AntennasService` (override vs ALL, dédup) ; UI : sélecteur visible quand non détecté.

### 🟠 Lot 2 — Robustesse réseau / concurrence + verrou E2EE (P1)
- **Objectif** : éliminer les races réelles et **verrouiller par test** les invariants de sécurité.
- **Fichiers** : `E2EEService`/`E2EETests`, `KeychainStore`, `SpeedtestService`, `SSEClient`, ViewModels Feed/Conversation **(après confirmation)**.
- **Changements** : test non-régression « no-cleartext » E2EE ; distinguer les `OSStatus` Keychain pour ne jamais régénérer une clé sur item verrouillé (à confirmer) ; annulation explicite des `URLSessionTask` Speedtest à l'abandon ; hard-cap de reconnexion SSE ; gardes `Task.isCancelled` / `isSending` là où une race est **confirmée**.
- **Risque** : faible-moyen (surtout des gardes + tests). Pas de changement de comportement nominal.
- **Done** : tests verts ; pas d'écriture d'état après dealloc ; pas de double-envoi.
- **Tests** : `E2EETests` (no-cleartext, bootstrap→unlock roundtrip), `MessagesService` E2EE error-paths, Speedtest cancellation.

### 🟠 Lot 3 — Accessibilité (P1)
- **Objectif** : rendre les parcours cœur (Feed, Carte, Drive Test, Messages) utilisables en VoiceOver + Dynamic Type.
- **Fichiers** : CardActionsBar, DriveTestMapView, `SQComponents` (badges), GlassCard, StoryViewer, ReactionPicker.
- **Changements** : `accessibilityLabel` sur toutes les icônes/annotations d'action ; regroupement des cartes feed ; uniformiser Dynamic Type (`relativeTo:`) ; respecter `reduceMotion` sur les delays.
- **Risque** : faible. Pas de changement fonctionnel.
- **Done** : pass VoiceOver des parcours cœur ; texte cœur lisible jusqu'à `accessibility2` sans troncature.
- **Tests** : UI test a11y (présence de labels), revue manuelle VoiceOver.

### 🟡 Lot 4 — Perf carte transverse (P1/P2)
- **Objectif** : fluidité au pan/zoom/filtre sur zone dense.
- **Fichiers** : DriveTestMapView, MapExplorerView, ANFRMapLibreView, `Core/Cache/DiskCache`.
- **Changements** : diff incrémental id→annotation partout où il manque ; chargement de couches parallèle (`async let`) ; borne de nombre de fichiers DiskCache (à confirmer).
- **Risque** : moyen (rendu carte). Mitigation : mesurer avant/après, fichier par fichier.
- **Done** : pas de flicker, framerate stable zone dense.
- **Tests** : manuel (zone dense) + éventuel snapshot.

### 🟡 Lot 5 — Finir l'inachevé, code mort & décomposition (P2)
- **Objectif** : livrer ou retirer ce qui pend ; réduire la dette.
- **Fichiers** : services orphelins suspectés, `MapExplorerView`, `SQComponents`.
- **Changements** : **confirmer** le câblage de `PrivacyService`/`ValidationsService`/`ReportsService`/`AntennasService.validate+report` → **brancher l'UI manquante ou retirer du binaire** ; supprimer états zombie ; extraire `MapFilterSheet` + `MapAnnotationRenderer` de `MapExplorerView` (étape 1) ; composant `SQBorderedContainer` pour les `.stroke` répétés.
- **Risque** : faible-moyen (retrait de code → vérifier non-référencé). Chaque retrait justifié par une recherche d'usage.
- **Done** : 0 service orphelin non documenté ; `MapExplorerView` < ~2500 l. après étape 1.
- **Tests** : build + tests existants verts après chaque extraction.

### 🟡 Lot 6 — Confidentialité & durcissement (P1/P2)
- **Objectif** : transparence du tracking + durcissement transport.
- **Fichiers** : LocationService + UI Drive Test, `PrivacyInfo.xcprivacy`, `Info.plist`/entitlements, APIClient.
- **Changements** : indicateur in-app persistant « suivi de position actif » + arrêt auto après N h ; vérifier/aligner `PrivacyInfo` ; `NSPinnedDomains` (déclaratif ATS) + backup pins ; nettoyer l'auth dual cookie/Bearer (après confirmation backend).
- **Risque** : moyen pour le pinning (mauvais pin = pannes réseau) → backup pins + test staging.
- **Done** : badge tracking visible ; pinning actif sans régression réseau.
- **Tests** : manuel réseau (cert valide/rotation), revue privacy.

### 🟢 Transverse — Tests & CI (option)
- Ajouter les tests cités (E2EE, Drive Test resolver, idempotency, pagination). **CI** GitHub Actions (build + tests + check entitlements post-archive) **si souhaitée** — sinon test manuel documenté.

---

## Section nouvelles fonctionnalités (cadrées)

Toutes **ancrées sur l'API SignalQuest réellement consommée** (inventaire relevé dans le code) et **faisables en iOS**, gated `if #available` pour les API récentes. Ce sont des **propositions à la carte** — on choisit lesquelles construire.

### Finir l'inachevé (complète des features déjà amorcées)
| # | Feature | Valeur | Faisabilité iOS | Dépendances API | Risque |
|---|---|---|---|---|---|
| F1 | **Drive Test → session de couverture persistée** (enregistrer parcours + points, revoir/partager) | Transforme la feature neuve en différenciateur réel | Background location déjà câblé ; `SessionTraceMapView` existe | `/api/coverage/sessions`, `/api/coverage/points` **existent** | Moyen (batterie/privacy → couplé Lot 6) |
| F2 | **Live Activity + Dynamic Island Drive Test** (opérateur, nb échantillons, techno en direct) | Visibilité écran verrouillé pendant un parcours | ActivityKit déjà utilisé (Speedtest) ; iOS 16.1+ | aucune (données locales) | Faible |

### Propositions nouvelles
| # | Feature | Valeur | Faisabilité iOS | Dépendances API | Risque |
|---|---|---|---|---|---|
| F3 | **Control Center / Lock-Screen control « Speedtest express »** (iOS 18 `ControlWidget`) | Lancement 1-tap, très moderne | App Intents Speedtest **existent** déjà ; gated `if #available(iOS 18)` | aucune nouvelle | Faible |
| F4 | **App Intents / Siri & Spotlight élargis** : « Quel opérateur/réseau ici ? », « Lancer un Drive Test » | Mains-libres, en voiture | `SQSpotlight` + `SpeedtestIntents` existent → AppShortcuts | `/api/speedtest/operator` + network path | Faible |
| F5 | **ANFR : timeline & historique d'un site** (évolution bandes/opérateurs) | Forte valeur informative, lecture pure | sheets ANFR existent | `/api/anfr/archives`, `/api/anfr/site-history/{supId}` **existent** | Faible |
| F6 | **Quêtes & easter-eggs de contribution** (boucle d'engagement pour densifier la donnée) | Densité de données (objectif produit) | surtout UI ; `GamificationView` existe | `/api/gamification/catalog\|events\|easter-eggs/claim` **existent** | Faible-moyen (design) |
| F7 | **Carte « ma couverture »** (heatmap de mes propres mesures) | Personnalisation, rétention | MapLibre déjà en place | `/api/user/speedtests` + coverage tiles | Faible |
| F8 | **Widget home « réseau autour de moi »** (antenne/opérateur/dernier speedtest) | Glanceable, viralité | WidgetKit + `WidgetSharedStore` déjà câblés | snapshot local + `/api/speedtest/operator` | Faible |

> Recommandation features : prioriser **F1+F2** (finir Drive Test) après le Lot 1, puis **F4/F3** (effort faible, effet « moderne »), puis F5/F7/F8 selon appétit. F6 = chantier produit.

---

## Ordre d'exécution recommandé & points de validation

1. **Lot 0** (P0 hygiène) → **arrêt + validation** (rotation/purge lancées en parallèle côté humain).
2. **Lot 1** (P0 Drive Test) → **arrêt + validation** (cœur du sujet).
3. **Lot 2** (P1 robustesse + tests E2EE).
4. **Lot 3** (P1 a11y).
5. **Lot 4** (perf carte) → **F1/F2** (finir Drive Test).
6. **Lot 5** (code mort/décomposition).
7. **Lot 6** (privacy/durcissement).
8. **Features** F3/F4 puis le reste, à la carte.
9. **Transverse tests/CI** en continu.

**Règles d'exécution (Phase D)** : diffs minimaux et relisibles ; **arrêt après chaque P0** pour validation ; tout changement de comportement explicitement signalé ; vérification (build/tests/manuel) après chaque lot ; aucun secret en clair ; aucune réécriture d'historique Git par l'agent.

**Vérification end-to-end** : `xcodegen generate` puis `xcodebuild test -scheme SignalQuest -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` (fallback iPhone 16 Pro). **Si aucun runtime simulateur n'est installé** (déjà constaté dans ce dépôt), le signaler et basculer sur validation manuelle device (build signé, équipe 835X2977R7) avec checklist par lot.

---

## Annexe — Findings d'agents infirmés après vérification (transparence)
- **Purge cookies logout** : couvre déjà `api.`/`speedtest.` (`CredentialStore.swift:79`). *Non-problème.*
- **Flags QA non gardés** : ils **sont** sous `#if DEBUG`, `false` en Release (`AppEnvironment.swift:15`). *Non-problème.*
- **Race continuations LocationService** : classe `@MainActor` + gardes anti-double-resume (`LocationService.swift:80-108`). *Non-problème.*
- **Defer refresh APIClient non exécuté** : `defer` s'exécute sur tous les chemins, lock correct (`APIClient.swift:301`). *Non-problème.*
- **« Remove cookie, Bearer only »** : direction erronée (le backend lit le cookie aujourd'hui) → simple nettoyage futur (P2).
