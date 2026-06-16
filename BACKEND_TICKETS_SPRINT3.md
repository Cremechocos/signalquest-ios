# SignalQuest — Tickets backend (Sprint 3 + débloquages client)

> Tickets prêts pour le dev backend. Chaque ticket indique le contexte, l'état actuel,
> le contrat d'API attendu, les critères d'acceptation et la priorité.
> **Plusieurs sont déjà câblés côté iOS** (le client envoie/consomme déjà ce qu'il faut) —
> noté « Client prêt ✅ ».
> Réfs = findings de l'audit du 2026-06-13.

Légende priorité : **P0** bloquant lancement · **P1** avant lancement public · **P2** scale/qualité.

---

## BE-14 — Photos publiques par zone (carte « tous les membres »)  · P1 · réf carte juin 2026
**Contexte.** La carte iOS doit afficher les photos de TOUS les membres (pas seulement les amis du snapshot). Aujourd'hui aucune route ne renvoie des photos publiques avec lat/lng par bbox (les photos n'ont pas de coords propres → résolues via le site).
**Implémenté (additif, NON déployé/testé en prod).** Nouvelle route `GET /api/map/photos` ajoutée dans `map-nextjs/app/api/map/photos/route.ts` (n'altère aucune route existante). Réutilise `loadAndroidAntennaDataset('ALL')` pour résoudre les coords par `siteId`, scrape-guard `enforcePublicDataScrapeGuard` (profile tile, allowAndroidCompat), `getCurrentUser` optionnel pour le mode amis.
**Contrat.** `GET /api/map/photos?north&south&east&west&zoom&operator(=ALL)&market(=FR)&friendsOnly(0|1)` → `{ photos: [{ id, siteId, lat, lng, thumbnailUrl, operator, authorId, uploadedAt, isFriend }], hasMore }`. `operator` filtre sur l'opérateur **de la photo** (`AntennaPhoto.operator`/`operatorKey`). `friendsOnly`/`isFriend` résolus quand authentifié (amitié `Friendship`). `approved:true` + `moderationStatus:'approved'` uniquement. Scan max 2000 récentes, retour max 500 après filtre bbox. Cache `private, max-age=60, swr=120`.
**À faire backend.** Déployer + tester en prod ; vérifier perf du scan 2000 (index `uploadedAt`/`operator`) ; envisager une vraie requête géo si volumétrie élevée. Client iOS prêt ✅ (`MapSnapshotService.publicPhotos` + couche `publicPhotos`).

---

## BE-1 — Pagination par curseur généralisée  · P0 · réfs BACKENDAPI-03, SCALABILITY-01
**Problème.** Plusieurs collections renvoient un plafond dur (`take`/`limit`) + `truncated:true` SANS curseur → troncature silencieuse en zone dense, énumération impossible. Confirmé en prod (Paris Châtelet 1500 m → `{count:100, truncated:true}` sans `nextCursor`).
**Endpoints concernés.**
- `GET /api/antennas` (limit=1200)
- `GET /api/coverage/points` (limit=2000), `GET /api/coverage/tiles` (limit=2500)
- `GET /api/messages/conversations/{id}/messages` (take=80) — **Client prêt ✅** (envoie déjà `?cursor=`, lit `hasMore`/`nextCursor`)
- `GET /api/antennas` & tuiles carte
**Contrat attendu.** Réponse enveloppée :
```json
{ "items": [...], "nextCursor": "opaque-token-or-null", "hasMore": true, "total": 1234 }
```
- `nextCursor` opaque (encode l'offset/keyset interne). `null` quand terminé.
- Le client boucle tant que `nextCursor != nil` (déjà le pattern du feed).
**Acceptation.** [ ] Une zone dense renvoie toutes les antennes via N pages · [ ] `nextCursor` stable et déterministe · [ ] historique messages remonte au-delà de 80 (déjà branché iOS).

---

## BE-2 — Clustering serveur par niveau de zoom (carte)  · P1 · réfs SCALABILITY-01/06
**Problème.** Le client charge des points bruts plafonnés ; à l'échelle, les couches carte sont tronquées et lourdes.
**Demande.** Agréger côté serveur par tuile/zoom (z/x/y) et renvoyer des clusters `{lat, lon, count, dominantOperator}` aux zooms faibles, points détaillés aux zooms élevés. Tuiler aussi le **snapshot social** (actuellement bbox non borné).
**Acceptation.** [ ] À z<12, payload borné quelle que soit la densité · [ ] cohérence du compte total entre clusters et points.

---

## BE-3 — `operator=ALL` agrégé côté serveur  · P1 · réfs SCALABILITY-04, BACKENDAPI-08
**Problème.** Faute d'`operator=ALL`, le client fait un **fan-out x3** (et x2 sur les pannes) puis déduplique localement, masquant un bug de dédup serveur.
**Demande.** Supporter `operator=ALL` (FR) côté backend : une requête agrégée + dédup serveur. Idem couche pannes.
**Acceptation.** [ ] 1 requête au lieu de 3 pour « tous opérateurs » · [ ] pas de doublons de site dans la réponse.

---

## BE-4 — Enveloppe d'erreur structurée + `X-Request-Id`  · P1 · réfs BACKENDAPI-04  · Client prêt ✅
**Problème.** La prod renvoie des **chaînes nues** (« Site introuvable. », « Aucun eNB ou gNB valide n'est disponible… ») alors que le client attend `{error, code, requestId, details}` (`BackendErrorResponse`). Le décodage structuré échoue → le message serveur brut (parfois fautif) s'affiche tel quel.
**Demande.**
- Toutes les erreurs (4xx/5xx) renvoient :
```json
{ "code": "SITE_NOT_FOUND", "error": "message technique", "requestId": "uuid", "details": {} }
```
- Header `X-Request-Id: <uuid>` sur **toutes** les réponses (succès et erreur).
- `Retry-After` (secondes) sur 429/503 — **le client le respecte déjà** (backoff borné).
**Acceptation.** [ ] Le client distingue empty-state vs erreur via `code` · [ ] `requestId` corrélable dans les logs · [ ] plus aucun message FR fautif exposé (mapper `code`→message localisé côté client).

---

## BE-5 — Anonymisation des lectures publiques (GPS)  · P0 RGPD · réfs SECURITY-03, PRIVACY-01/02
**Problème.** Les lectures **non authentifiées** renvoient des coordonnées GPS à ~13 décimales (`lat:45.76061634812504`) + opérateur + timestamp + métriques radio → traces de mobilité scrapables. Risque RGPD (minimisation, art. 5).
**Demande.**
- Pour les lectures **anonymes** : arrondir les coordonnées à ~3-4 décimales (≈100 m) OU agréger en clusters ; ne jamais exposer la position fine sans authentification.
- Réserver la précision fine aux lectures authentifiées du propriétaire.
- (Le client tronque déjà à 3 décimales **à l'envoi** — le backend doit faire de même **à la lecture**.)
**Acceptation.** [ ] Une lecture anonyme ne renvoie pas > 4 décimales · [ ] rate-limit sur les lectures anonymes.

---

## BE-6 — Déduplication par `Idempotency-Key`  · P1 · réfs BACKENDAPI-02  · Client prêt ✅
**Problème.** Sur réseau mobile instable, un retry peut créer des doublons (message/post/validation).
**État client.** Le client envoie désormais un header **`Idempotency-Key: <uuid>`** sur tous les POST de création, **rejoué à l'identique** sur retry (refresh 401 ou backoff 429).
**Demande backend.** Dédupliquer sur `Idempotency-Key` (fenêtre ex. 24 h) : si une clé déjà traitée arrive, renvoyer la réponse d'origine sans recréer.
**Acceptation.** [ ] Deux requêtes même clé → une seule ressource créée · [ ] la 2ᵉ renvoie le même résultat.

---

## BE-7 — Endpoint d'export des données personnelles  · P1 RGPD · réfs PRIVACY-04
**Problème.** Pas d'export in-app (droit d'accès/portabilité art. 15/20). Intérim actuel : mailto vers `legal@signalquest.fr`.
**Demande.** `POST /api/user/export` → génère une archive (profil, speedtests, contributions, messages) et l'envoie par email / lien de téléchargement signé.
**Acceptation.** [ ] Une demande produit une archive complète · [ ] traçable. *(Brancher ensuite l'action in-app côté iOS à la place du mailto.)*

---

## BE-8 — Anonymisation à la suppression de compte  · P1 RGPD · réfs LEGAL-05, PRIVACY-08
**Problème.** Le texte actuel : « Toutes tes contributions resteront publiques ». Maintenir des mesures géolocalisées fines + horodatage + opérateur après suppression = potentiellement réidentifiable (droit à l'effacement art. 17).
**Demande.** À `POST /api/user/delete-account` : dissocier irréversiblement l'identifiant des contributions ET dégrader la précision GPS (arrondi ≈100 m). Définir/publier une politique de conservation.
**Acceptation.** [ ] Après suppression, aucune contribution réattribuable à l'utilisateur.

---

## BE-9 — Redirections des URLs légales  · P0 · réfs LEGAL-01  · Client corrigé ✅
**État.** Le client pointe désormais directement vers `/terms`, `/privacy`, `/legal` (les anciens `/cgu`, `/confidentialite` renvoyaient **404**). 
**Demande (optionnelle mais propre).** Ajouter des redirections 301 `/cgu→/terms`, `/confidentialite→/privacy` pour tout lien historique. **Surtout** : mettre à jour `/legal`, `/privacy`, `/terms` pour couvrir l'**app iOS** (actuellement rédigés « Android » — 45 occurrences « Android » vs 3 « Apple ») et lister les données réellement collectées par iOS (SSID, opérateur, position, modèle, OS).
**Acceptation.** [ ] Pages légales mentionnent explicitement l'app iOS · [ ] relecture juriste RGPD.

---

## BE-10 — Bugs de données en production  · P1 · réfs (sonde live)
1. **Dédoublonnage de site cassé** : `sites_nearby_from_place` (Bellecour, Lyon) renvoie le site `2218129` **en triple** (mêmes coords/anfrCode, `technologies[]` divergents), consommant 3/5 slots du `limit`. → Dédupliquer par `siteId` et FUSIONNER les `technologies[]`.
2. **Découplage radio↔référentiel** : `sites_find_by_radio(enb=39316)` = 0 site alors que cet eNB apparaît dans de nombreux speedtests Orange ; `sites_get_signal_stats`/`coverage` échouent systématiquement sur Lyon (counts.total:0). → Réconcilier la table radio (eNB/gNB) avec le référentiel sites.
3. **Champs sites systématiquement vides** : `commune`, `supportHeightMeters`, `antennaTypes[]`, `towerOwner`, `status`, `updatedAt` → enrichir ou retirer du contrat.
**Acceptation.** [ ] Plus de doublons de site · [ ] stats/couverture non vides sur une métropole testée.

---

## BE-11 — Versionnement de schéma / routes  · P2 · réfs BACKENDAPI-05
**Problème.** Aucun versionnement (un seul `/v2` isolé). Casse future garantie.
**Demande.** Adopter un versionnement explicite (`/api/v1/…` ou header `Accept-Version`) et figer le contrat. Côté client : renvoyer la version dans les réponses.

---

## BE-12 — Anti-abus & rate-limiting applicatif  · P1 · réfs SECURITY-06
**Demande.** Rate-limit par IP/compte sur `login`/`signup`/`forgot-password` (+ captcha sur signup), rate-limit sur les lectures anonymes et les écritures `community_submit_*` (déjà 30/h/user déclarés — étendre/observer). Headers `RateLimit-*`.
**Acceptation.** [ ] Brute-force login bloqué · [ ] pics de lecture anonyme throttlés.

---

## BE-13 — Tests de charge synthétiques  · P2 · réfs SCALABILITY-10
**Problème.** Volume réel actuel très clairsemé (Paris 5 km = 26 mesures), donc la pagination/clustering n'est pas éprouvée.
**Demande.** Densifier artificiellement antennes/mesures (×100, ×1000) et valider pagination curseur + clustering + temps de réponse aux p95.

---

## Récapitulatif priorités
- **P0 (bloquant lancement)** : BE-1 (pagination curseur), BE-5 (anonymisation lectures), BE-9 (légal iOS).
- **P1 (avant lancement public)** : BE-3, BE-4, BE-6, BE-7, BE-8, BE-10, BE-12.
- **P2 (scale/qualité)** : BE-2, BE-11, BE-13.

## Déjà fait côté iOS (en attente du backend)
- Envoi `Idempotency-Key` sur les POST (→ BE-6) · respect `Retry-After`/backoff 429 (→ BE-4) · curseur historique messages (→ BE-1) · troncature GPS à l'envoi (→ BE-5) · URLs légales corrigées (→ BE-9) · `BackendErrorResponse` prêt à consommer (→ BE-4) · action export intérim par mailto (→ BE-7).
