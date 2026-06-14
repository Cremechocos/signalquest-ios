# Signal Quest iOS — Plan de mise en production

> Plan d'exécution dérivé de l'audit du 2026-06-13. Objectif : passer du **NO-GO** actuel
> (préparation globale 51/100) à un lancement public conforme et crédible.
> Chaque tâche référence les findings de l'audit (ex. `IOSCOMPAT-01`).

---

## 0. Principes directeurs

1. **Rien ne part en soumission tant que les bloqueurs de livraison et de conformité ne sont pas verts.** Les portes GO/NO-GO sont mesurables, pas déclaratives.
2. **On corrige d'abord ce qui est cassé en production** (push, légal, RGPD), ensuite ce qui dégrade l'expérience, enfin ce qui prépare l'échelle.
3. **Ne jamais tester/QA contre la prod.** Mise en place d'une pré-production isolée en pré-requis transverse.
4. **Chaque correctif a un critère d'acceptation testable** et, quand c'est possible, un test automatisé qui empêche la régression.
5. **Périmètre v1 = mission télécom.** Tout ce qui n'y contribue pas est candidat au report (cf. recentrage produit).

### Rôles (à adapter à l'équipe réelle)
- **iOS** : Staff/Senior iOS (1 à 2 personnes)
- **BE** : Backend/SRE (1 personne)
- **DESIGN** : UX/UI + accessibilité (mi-temps)
- **LÉGAL** : Conseil RGPD/CNIL + rédaction CGU/Privacy (ponctuel)
- **QA** : tests appareils + critères GO/NO-GO

### Estimation globale
- **Sprint 0** : ~8-10 j·dev → débloque TestFlight fermé
- **Sprint 1** : ~12-15 j·dev → débloque lancement public conforme
- **Sprint 2** : ~12-15 j·dev → qualité/perf/a11y au niveau « premium »
- **Sprint 3** : ~20-30 j·dev → scalabilité + recentrage produit (« référence »)
- **Calendrier réaliste** : **5-7 semaines** jusqu'au lancement public (Sprints 0+1+2), Sprint 3 en continu.

---

## TRANSVERSE — Pré-requis à démarrer en parallèle de Sprint 0

| ID | Tâche | Owner | Effort | Détail |
|----|-------|-------|--------|--------|
| T-01 | **Pré-production isolée** | BE/DevOps | 2 j | Faire pointer `Config/Staging.xcconfig` vers un backend de pré-prod réel (actuellement identique à la prod → risque d'écritures réelles en QA/App Review). Base de données séparée, données de test. *(APPSTORE-07)* |
| T-02 | **Pipeline CI build + tests** | DevOps | 2 j | `xcodegen generate` + `xcodebuild test` sur simulateur en CI ; bloquer le merge si tests rouges. Ajouter une étape « vérif entitlements » (`codesign -d --entitlements`). |
| T-03 | **Matrice QA appareils** | QA | 1 j | iPhone SE (2e/3e gén), iPhone standard, Pro, Pro Max ; iOS 18.x. Définir scénarios batterie / hors-ligne / permissions / notifications. |
| T-04 | **Comptes de test App Review** | PM | 0.5 j | Compte de démo + notes pour le reviewer (modération <24h, fonctionnement VoIP). |

**Critère de sortie transverse** : la QA et l'App Review ne touchent jamais la base de production.

---

## SPRINT 0 — Déblocage livraison & conformité (Semaines 1-2)

**But : rendre une soumission TestFlight propre et fonctionnelle.** Ce sont majoritairement des Quick Wins à fort impact.

### S0-1 — Câbler les entitlements et réparer push / VoIP / Wi-Fi `[iOS]` — **CRITIQUE**
*Refs : IOSCOMPAT-01/02/03/04, APPSTORE-02, COMPLETENESS-01, STABILITY-01, SECURITY-01*

**Problème** : `SignalQuest.entitlements` n'est rattaché à aucun build → 0 entitlement signé → push, VoIP et SSID morts. De plus `aps-environment=development` casse APNs prod, et l'enregistrement push n'a lieu qu'au cold-start authentifié.

**Actions concrètes**
1. `project.yml` cible `SignalQuest` → ajouter `settings.base.CODE_SIGN_ENTITLEMENTS: SignalQuestApp/SignalQuest.entitlements` et **retirer** `SignalQuest.entitlements` de la liste `excludes` (ligne 34).
2. Gérer `aps-environment` par configuration : `development` en Debug, **`production`** en Release/Staging-distribution. (Idéalement un `.entitlements` par config, ou une variable `xcconfig`.)
3. Ajouter `com.apple.developer.networking.wifi-info` au fichier d'entitlements ; activer « Access WiFi Information » et « Push Notifications » sur l'App ID au portail développeur.
4. Renseigner `DEVELOPMENT_TEAM` (actuellement `""` dans `project.yml:17`).
5. Déclencher l'enregistrement push/VoIP sur la **transition** vers `.authenticated` : `.onChange(of: session.state)` (ou `.task(id:)`) au niveau `RootView`, appelant `requestAuthorizationAndRegister()` + `registerForVoIPPushes()` (déjà idempotents).

**Critères d'acceptation**
- [ ] `codesign -d --entitlements - <app>.app` montre `aps-environment=production` et `wifi-info` sur un build de distribution.
- [ ] Un **push réel** (message) arrive sur un build TestFlight, app en arrière-plan.
- [ ] Un **appel VoIP entrant** réveille l'app et affiche CallKit sur TestFlight.
- [ ] Après `installation → premier login` (sans relancer), les notifications fonctionnent.
- [ ] Le SSID Wi-Fi est renseigné dans une soumission speedtest sur Wi-Fi (autorisation localisation accordée).

**Effort** : 1.5 j·dev · **Dépendances** : compte développeur configuré.

---

### S0-2 — Réparer les liens légaux (404 en prod) `[iOS+BE]` — **CRITIQUE**
*Refs : LEGAL-01, PRIVACY-05, APPSTORE-04*

**Problème** : `SignupView.swift:102-103` pointe vers `/cgu` et `/confidentialite` → **HTTP 404** (vérifié 13/06). Les vraies pages sont `/terms`, `/privacy`, `/legal`.

**Actions**
1. Centraliser les URLs légales dans `AppConfig` (`termsURL`, `privacyURL`, `legalURL`, `contactURL`).
2. Corriger les chemins vers `/terms` et `/privacy` **OU** mettre des redirections 301 `/cgu→/terms`, `/confidentialite→/privacy` côté backend (BE).
3. Test d'intégration : vérifier un `200` sur chaque URL légale.

**Critères d'acceptation**
- [ ] Les deux liens du Signup ouvrent une page `200`.
- [ ] Test CI qui échoue si une URL légale renvoie ≠ 200.

**Effort** : 0.5 j·dev (iOS) + 0.5 j (BE).

---

### S0-3 — Consentement de publication GPS + minimisation `[iOS]` — **CRITIQUE**
*Refs : PRIVACY-01, PRIVACY-02*

**Problème** : `SpeedtestModels.swift:374` envoie `isVisibleOnMap: true` codé en dur + coordonnées pleine précision, sans information ni opt-in.

**Actions**
1. Ajouter un `@AppStorage("sq.publishToMap")` (défaut **OFF**) + un `Toggle` « Publier ce test sur la carte communautaire » dans l'écran de résultat speedtest **et** dans les réglages speedtest.
2. Propager sa valeur à `isVisibleOnMap` au lieu de `true` en dur.
3. Tronquer les coordonnées **avant envoi** à 3 décimales (~111 m, cohérent avec `kCLLocationAccuracyHundredMeters`) dans la construction de `Coordinates` (`SpeedtestView.swift:497-499`).
4. Afficher, avant la première soumission publiée, une note claire : « coordonnées (~100 m) et opérateur visibles publiquement ».

**Critères d'acceptation**
- [ ] Par défaut, une mesure n'est PAS publiée (vérifiable côté payload : `isVisibleOnMap=false`).
- [ ] Quand publié, les coordonnées envoyées ont ≤ 3 décimales.
- [ ] Texte d'information présent avant la 1ʳᵉ publication.

**Effort** : 1 j·dev.

---

### S0-4 — Blocage utilisateur complet (Guideline 1.2) `[iOS]` — **ÉLEVÉ**
*Refs : APPSTORE-03*

**Actions**
1. Exposer « Bloquer cet utilisateur » dans le menu toolbar de `UserProfileView` (réutiliser `FriendsService.block(userId:)`).
2. Exposer le blocage par expéditeur dans les conversations de groupe.
3. Masquer côté client le contenu d'un utilisateur bloqué (feed, commentaires).

**Critères d'acceptation**
- [ ] Depuis un profil public (Feed) et depuis un groupe, on peut bloquer un utilisateur.
- [ ] Après blocage, son contenu disparaît de l'UI sans recharger l'app.

**Effort** : 1.5 j·dev.

---

### S0-5 — Accès légal in-app + contact modération `[iOS]` — **ÉLEVÉ**
*Refs : LEGAL-04, APPSTORE-04*

**Actions** : ajouter une section « Informations légales » dans `SettingsView` (CGU, Politique de confidentialité, Mentions légales `/legal`, contact `legal@signalquest.fr` / formulaire de modération). Lien légal discret aussi sur `LoginView`.

**Critères d'acceptation**
- [ ] Un utilisateur déjà connecté (compte de test reviewer) accède aux CGU, à la confidentialité et à un contact depuis Réglages.

**Effort** : 0.5 j·dev.

---

### S0-6 — Correctif identité serveur speedtest `[iOS]` — **ÉLEVÉ**
*Refs : SPEEDTEST-01/02, BACKENDAPI-07, COMPLETENESS-07*

**Problème** : `serverName` et l'hôte de ping dérivent de la cible de **download** (CloudFront) au lieu du serveur de **mesure** (VPS) → images de partage « AWS », ping mesuré contre l'edge CDN.

**Actions**
1. Dériver `serverName` de `sessionResponse.selectedServer` (host/name/location), indépendamment de la cible de download (`SpeedtestService.swift:460-485`).
2. Distinguer deux notions : `downloadServerName` (origine des octets, ex. CloudFront) vs `serverName`/`uploadServerName` (serveur de mesure).
3. Mesurer le **ping de référence** contre l'hôte du serveur de mesure (`selectedServer.host`/hôte d'upload), pas contre la cible de download (`measurePings`, `:505`). Aligner les loaded-pings.
4. Mettre à jour `SpeedtestShareImageRenderer` pour afficher le serveur de mesure.

**Critères d'acceptation**
- [ ] Sur un test par défaut (CloudFront), l'image de partage affiche le **vrai serveur de mesure**, pas « AWS CloudFront ».
- [ ] `pingMs`/`jitterMs` reflètent la latence vers le serveur de mesure (test unitaire sur la sélection d'hôte).

**Effort** : 1 j·dev.

---

### S0-7 — Nettoyage `Info.plist` + permissions `[iOS]` — **MOYEN**
*Refs : IOSCOMPAT-06, APPSTORE-05/06, SECURITY-09*

**Actions** : retirer les clés racine d'orientation parasites (`Info.plist:7-14`), supprimer le doublon `ITSAppUsesNonExemptEncryption`, retirer `NSCameraUsageDescription` (caméra jamais utilisée — ou implémenter la capture). Vérifier l'exemption export crypto avec le conseil juridique.

**Critères d'acceptation** : [ ] `plutil -lint` OK ; [ ] aucune string de permission pour une capacité non utilisée.

**Effort** : 0.5 j·dev.

---

### 🚦 PORTE GO/NO-GO — Fin de Sprint 0 (→ TestFlight fermé)
**GO si TOUT est vrai :**
- [ ] Push + VoIP fonctionnels sur build TestFlight (S0-1).
- [ ] URLs légales 200 et accessibles in-app (S0-2, S0-5).
- [ ] Publication GPS opt-in + coordonnées minimisées (S0-3).
- [ ] Blocage utilisateur sur tous les points UGC (S0-4).
- [ ] QA/App Review pointent sur la pré-prod, pas la prod (T-01).
- [ ] Build de distribution s'archive et s'exporte sans erreur de signature.

---

## SPRINT 1 — Conformité RGPD, confiance & qualité (Semaines 2-4)

**But : rendre l'app conforme et digne de confiance pour un public européen.** Porte de sortie = lancement public possible.

### S1-1 — Écran de réglages de confidentialité `[iOS]` — **ÉLEVÉ**
*Refs : PRIVACY-03* — Câbler `PrivacyService.get/update` (et `SocialPrivacySettings` si supporté) dans un nouvel écran « Confidentialité » poussé depuis Profil : visibilité par défaut, DMs, mentions, suivi, partage position aux amis, données radio, photos sur la carte des amis, « vu pour la dernière fois ».
**Acceptation** : [ ] chaque réglage persiste côté backend et est rechargé. **Effort** : 2 j·dev.

### S1-2 — Export des données personnelles `[iOS+BE]` — **ÉLEVÉ**
*Refs : PRIVACY-04* — Endpoint backend `POST /api/user/export` (génération d'archive + email/téléchargement) + action « Télécharger mes données » dans Réglages.
**Acceptation** : [ ] une demande déclenche une archive contenant profil + speedtests + contributions + messages. **Effort** : 1 j (iOS) + 2 j (BE).

### S1-3 — Mise à jour des documents légaux pour iOS `[LÉGAL+BE]` — **ÉLEVÉ**
*Refs : LEGAL-02* — `/legal`, `/privacy`, `/terms` décrivent « Android » : ajouter explicitement l'app iOS, lister les données réellement collectées par iOS (SSID, opérateur, position, modèle, OS) et leurs finalités. Relecture juriste RGPD.
**Acceptation** : [ ] mention « App iOS (App Store) » + table des données iOS ; [ ] cohérence avec `PrivacyInfo.xcprivacy`. **Effort** : 2-3 j (légal).

### S1-4 — Conservation & anonymisation post-suppression `[BE+LÉGAL]` — **ÉLEVÉ/MOYEN**
*Refs : LEGAL-05, PRIVACY-08* — Définir/publier des durées de conservation ; à la suppression de compte, **anonymiser irréversiblement** les contributions (dissocier l'identifiant, dégrader la précision GPS), corriger le texte UI `SettingsView.swift:123`.
**Acceptation** : [ ] après suppression, aucune contribution n'est réattribuable à l'utilisateur ; [ ] politique de conservation publiée. **Effort** : 2 j (BE) + légal.

### S1-5 — Anonymisation des lectures publiques backend `[BE]` — **ÉLEVÉ/MOYEN**
*Refs : SECURITY-03* — Arrondir les coordonnées des lectures **non authentifiées** (~100 m) ou agréger en clusters ; réserver la précision fine aux lectures authentifiées ; ajouter rate-limit + pagination. Corriger aussi le **dédoublonnage cassé** (site renvoyé en triple à Lyon) et la **liaison radio↔référentiel** (`sites_get_signal_stats`/`coverage` vides).
**Acceptation** : [ ] une lecture anonyme ne renvoie pas de coordonnées > 4 décimales ; [ ] plus de doublons de site ; [ ] stats/couverture non vides sur une zone testée. **Effort** : 3 j (BE).

### S1-6 — Idempotence + gestion 429/Retry-After `[iOS+BE]` — **ÉLEVÉ**
*Refs : BACKENDAPI-02, SCALABILITY-03, BACKENDAPI-01* — `Idempotency-Key` (UUID) sur tous les POST de création, réémis à l'identique sur retry ; ne jamais rejouer un POST non-idempotent après refresh sans clé. Branche 429 dans `performWithRefresh` (respect `Retry-After` sinon backoff+jitter, essais bornés). Logger `requestId`.
**Acceptation** : [ ] un retry réseau ne crée pas de doublon (test) ; [ ] un 429 déclenche un backoff au lieu d'un re-tir immédiat. **Effort** : 1.5 j (iOS) + 1 j (BE).

### S1-7 — Contrat d'erreur backend aligné `[BE+iOS]` — **ÉLEVÉ**
*Refs : BACKENDAPI-04* — Backend renvoie `{code, message, requestId, details}` + `X-Request-Id` partout ; côté client, mapper `code → message localisé` plutôt qu'afficher la chaîne serveur (et corriger les messages FR fautés).
**Acceptation** : [ ] le client distingue empty-state vs erreur via `code` ; [ ] plus aucun message serveur brut affiché. **Effort** : 1 j (iOS) + 2 j (BE).

### S1-8 — Onboarding + priming des permissions `[iOS+DESIGN]` — **ÉLEVÉ/MOYEN**
*Refs : UX-01, UX-02, PRODUCT-04* — Onboarding 2-3 écrans (mission + value prop) avec mode découverte non connecté (tuiles déjà publiques) ; sheet de **priming** avant le 1er prompt localisation ; flag `hasCompletedOnboarding`.
**Acceptation** : [ ] au 1er lancement, écran de mission ; [ ] le prompt système localisation est toujours précédé d'un écran d'explication. **Effort** : 2.5 j·dev.

### 🚦 PORTE GO/NO-GO — Fin de Sprint 1 (→ lancement public conditionné à QA)
**GO si :**
- [ ] Réglages de confidentialité + export opérationnels (S1-1, S1-2).
- [ ] Documents légaux couvrent iOS, relus par un juriste (S1-3).
- [ ] Anonymisation post-suppression + lectures publiques (S1-4, S1-5).
- [ ] Pas de doublons sur retry, 429 géré (S1-6).
- [ ] Onboarding + priming en place (S1-8).
- [ ] Revue RGPD/CNIL formelle : avis favorable.

---

## SPRINT 2 — Qualité, performance, accessibilité (Semaines 4-6)

**But : niveau « premium » attendu d'une app de référence.**

| ID | Tâche | Refs | Owner | Effort | Acceptation |
|----|-------|------|-------|--------|-------------|
| S2-1 | **Accessibilité VoiceOver** sur les parcours cœur (Feed, Carte, Messages) : labels/values/traits, regroupement des cartes | UI-01 | iOS+DESIGN | 3 j | Audit VoiceOver : tous les boutons d'action annoncés ; carte de feed lue d'un bloc |
| S2-2 | **Dynamic Type** : `relativeTo:` par défaut dans `SQFont`, plafond a11y où la mise en page casse | UI-02 | iOS | 1.5 j | Texte cœur grossit jusqu'à `accessibility2` sans troncature |
| S2-3 | **Diffing MapLibre** : delta id→annotation dans le Coordinator, heatmap reconstruite seulement si features changent | PERF-01 | iOS | 3 j | Plus de flicker au pan/filtre ; framerate stable zone dense |
| S2-4 | **Loader d'images partagé** (downsampling + `NSCache` + cache disque borné) ; remplacer `AsyncImage` brut | PERF-02 | iOS | 3 j | Pas de pic mémoire au scroll de la grille Photos ; pas de full-res si vignette dispo |
| S2-5 | **Pagination historique conversation** (curseur `before`, fetch au haut de liste) | COMPLETENESS-04 | iOS+BE | 2 j | On remonte au-delà de 80 messages |
| S2-6 | **Badges tab bar + swipe-actions + états vides/erreur avec CTA/retry** | UX-04/05/06/09/10 | iOS | 2 j | Badge non-lus Messages ; swipe supprimer/lu ; tous les écrans de chargement ont un « Réessayer » |
| S2-7 | **Parallélisation du chargement carte** (`async let`/TaskGroup) | SCALABILITY-02 | iOS | 1 j | Latence carte = max(couches), pas somme |
| S2-8 | **Data races mineures** (`PushNotificationService.lastToken`, continuations `LocationService`) + interruption `AVAudioSession` en appel | STABILITY-02/03/05 | iOS | 1.5 j | Pas d'accès concurrent non synchronisé ; appel survit à une interruption |

### 🚦 PORTE GO/NO-GO — Fin de Sprint 2
- [ ] Pass VoiceOver complet des parcours cœur.
- [ ] Carte fluide (pas de flicker, 0 chute de framerate notable) sur zone dense.
- [ ] Pas de pression mémoire (jetsam) sur iPhone SE lors du scroll d'images.
- [ ] Matrice QA appareils verte (SE→Pro Max, iOS 18.x).

---

## SPRINT 3 — Scalabilité & recentrage produit (Semaines 6-9, en continu)

**But : tenir la promesse « référence » et préparer l'échelle (10k→100k DAU).**

### Scalabilité backend `[BE]`
- **S3-1 — Pagination par curseur généralisée** (antennes, couverture, tuiles, messages) + `truncated`/`total`. **CRITIQUE scale** *(BACKENDAPI-03, SCALABILITY-01)*. Effort : 4-5 j.
- **S3-2 — Clustering serveur par niveau de zoom** pour la carte (au lieu des plafonds durs). Effort : 3 j.
- **S3-3 — `operator=ALL` agrégé côté backend** (supprimer le fan-out client x3) + delta d'inbox temps réel *(SCALABILITY-04/05)*. Effort : 3 j.
- **S3-4 — Versionnement de schéma API** (`/v1` ou `Accept-Version`) *(BACKENDAPI-05)*. Effort : 2 j.
- **S3-5 — Tests de charge synthétiques** (densifier antennes/mesures ×100/×1000) pour valider pagination & clustering *(SCALABILITY-10)*. Effort : 2 j.

### Recentrage produit `[PM+iOS]`
- **S3-6 — Identité : Carte/Couverture en écran d'atterrissage**, remonter Carte ANFR + Stats ANFR au niveau d'onglet, reformuler la tagline mission *(PRODUCT-01)*. Effort : 2 j.
- **S3-7 — Décision de périmètre v1** : couper/reporter appels vidéo LiveKit, stories, sondages, rappels, messages programmés ; réduire la messagerie au 1:1 + groupe basique *(PRODUCT-02)*. Effort : variable (surtout du retrait).
- **S3-8 — Stratégie de densité de données** : boucle de contribution iOS incitée + intégration ANFR/ARCEP pour que la carte ne soit jamais vide ; restreindre les marchés affichés aux marchés réellement servis *(PRODUCT-03/06)*. Effort : 4 j + produit.
- **S3-9 — Nettoyage des services orphelins** (Coverage, Validations, AntennasService.validate/report, PrivacyService non câblé) : livrer l'UI ou retirer du binaire *(COMPLETENESS-02)*. Effort : 2 j.

### Sécurité de durcissement `[iOS+BE]`
- **S3-10 — Certificate pinning** via `NSPinnedDomains` (déclaratif, ATS) sur `signalquest.fr` + `speedtest.signalquest.fr`, avec backup pins *(SECURITY-02)*. Effort : 1 j.
- **S3-11 — Anti-abus inscription/login** (rate-limit, captcha) + `#if DEBUG` sur les flags QA (`--mock-auth`, `--demo-data`, `--reset-auth`) *(SECURITY-04/06)*. Effort : 1 j (iOS) + 2 j (BE).
- **S3-12 — Modèle d'auth unifié** (un seul mécanisme cookie httpOnly *ou* Bearer) *(SECURITY-05, BACKENDAPI-06)*. Effort : 2 j.

---

## Plan de tests & QA (continu)

### Tests automatisés à ajouter
- **Légal** : URLs `/terms`, `/privacy`, `/legal` → 200 (CI).
- **Entitlements** : `aps-environment=production` + `wifi-info` présents dans le build de distribution (étape CI post-archive).
- **Speedtest** : sélection d'hôte de ping = serveur de mesure ; `serverName` = `selectedServer` (unit).
- **Idempotence** : un retry post-401 ne crée pas de doublon (unit/integration avec `MockURLProtocol`).
- **Privacy** : payload speedtest par défaut `isVisibleOnMap=false` et coordonnées ≤ 3 décimales (unit).
- **Décodage** : étendre `ModelDecodeTests` aux nouvelles enveloppes d'erreur.

### Tests manuels (matrice T-03)
- Permissions : refus/accord localisation, micro, photos — l'app reste utilisable.
- Hors-ligne : carte (cache tuiles), feed, file d'envoi messages, bannière offline.
- Background/foreground : appel entrant pendant background, réouverture, badge reset.
- Batterie : session carte 15 min + speedtest + appel → pas de dérive anormale.
- Notifications : message, réaction, appel, deep-links push (tous types `AppRouter`).

---

## Récapitulatif planning

| Sprint | Semaines | Sortie | Porte |
|--------|----------|--------|-------|
| Transverse | dès S1 | Pré-prod isolée, CI, QA matrix | — |
| **Sprint 0** | 1-2 | Livraison + conformité de base | **→ TestFlight fermé** |
| **Sprint 1** | 2-4 | RGPD + confiance | **→ Lancement public (sous QA)** |
| **Sprint 2** | 4-6 | Qualité / perf / a11y | **→ Niveau premium** |
| **Sprint 3** | 6-9+ | Scalabilité + produit | **→ « Référence »** |

## Recommandation
- **GO conditionnel TestFlight fermé** après Sprint 0.
- **GO lancement public** après Sprints 0+1 validés par QA + avis RGPD favorable.
- Sprint 2 avant toute campagne d'acquisition large ; Sprint 3 en continu pour tenir la promesse « référence ».

---

## Backlog priorisé (ordre d'exécution recommandé)
1. S0-1 (push/entitlements) · 2. S0-2 (légal 404) · 3. S0-3 (consentement GPS) · 4. S0-4 (blocage) · 5. S0-5 (légal in-app) · 6. S0-6 (speedtest serveur) · 7. S0-7 (Info.plist) · 8. T-01 (pré-prod)
→ 9. S1-5 (anonymisation BE) · 10. S1-6 (idempotence/429) · 11. S1-7 (erreurs) · 12. S1-1 (privacy UI) · 13. S1-2 (export) · 14. S1-3/1-4 (légal/conservation) · 15. S1-8 (onboarding)
→ Sprint 2 puis Sprint 3.
