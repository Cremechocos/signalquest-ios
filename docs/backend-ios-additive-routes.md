# Backend — tickets additifs iOS (Lot 8/9)

> **⚠️ Différé volontairement.** Le backend `~/Site/map-nextjs` est en plein
> **refactor monorepo** (branche `feat/monorepo-split`, `lib/ → packages/core/`,
> changements non committés). De plus la base est **prod distante** avec
> migrations divergées. **Règles non négociables :**
> - Aucune modification des routes web/Android existantes (tout est **additif**).
> - **Jamais** `prisma migrate dev` / `prisma db push` sur la prod.
> - Schéma : **SQL direct idempotent uniquement** (`ADD COLUMN IF NOT EXISTS`).
> - Appliquer **après** stabilisation du refactor monorepo.
>
> Le client iOS est **déjà prêt** à consommer ces champs/routes de façon tolérante
> (décodage optionnel) : livrer le backend ne casse rien tant que c'est additif,
> et l'absence de ces routes ne casse pas l'app non plus.

## 1. `DELETE /api/user/voip-token` (Lot 5 — CALL-VOIP-05)
Le client appelle déjà `DELETE /api/user/voip-token` au logout
(`CallManager.unregisterVoIPToken`, body `{ voipToken, platform: "ios" }`).
Tant que la route n'existe pas, l'appel est best-effort (404 avalé). À ajouter :
supprimer la ligne `voipToken` du device pour que l'ancien compte ne reçoive
plus de pushes VoIP. Route additive, aucune migration.

## 2. `GET /_ios/messages/unread-count` (Lot 8) — compteur non-lus autoritatif
Réponse `{ total: Int, perConversation: [{ conversationId, count }] }`. Évite la
dérive du compteur client. Lecture seule, aucune migration.

## 3. Opérateur IP/ASN enrichi MVNO (Lot 8/3.5) — `GET /api/speedtest/operator`
Ajouter (champs **optionnels**) à la réponse : `commercialOperator`,
`hostNetwork`, `isMVNO` (lookup ASN + table MVNO→réseau hôte). Permet l'affichage
« La Poste Mobile · Bouygues Telecom ». iOS ne peut PAS le déduire seul
(CoreTelephony ne donne que le réseau hôte). Additif, pas de migration.

## 4. Flag VPN + source opérateur en base (Lot 3.5) — **SQL idempotent**
Sur le modèle speedtest :
```sql
ALTER TABLE "Speedtest" ADD COLUMN IF NOT EXISTS "viaVpn" BOOLEAN;
ALTER TABLE "Speedtest" ADD COLUMN IF NOT EXISTS "operatorSource" TEXT; -- "ip-asn" | "sim" | "unknown"
```
Exposer ces champs dans l'API d'historique (iOS/Android/web) → badge « VPN » /
« Sans VPN ». Le client envoie déjà `viaVpn`/`operatorSource` et les coords
précises (`shareExactLocation`) à la soumission.

## 5. Filtre carte speedtest fiable (Lot 3.5)
La couche/tuiles speedtest n'expose que `viaVpn = false AND operatorSource = 'ip-asn'`
(filtre serveur additif). N'affiche sur la carte que les mesures fiables et
attribuables à un opérateur ; le test VPN reste visible dans l'historique (badge).

## 6. Direction d'appel (Lot 5 — CALL-HIST-07)
Ajouter `direction`/`isOutgoing` (optionnel) à la réponse historique d'appels
(`CallSession`). Le client masque les flèches tant que le champ est absent.

## 7. `maxSpeed` Speedtest — cohérence de nommage (Lot 8 — SPEEDTEST-MAXSPEED-01)
Le client envoie historiquement `maxSpeed = P90` (et le vrai pic dans
`downloadPeakMbps`/`downloadMax`). À clarifier de bout en bout (renommer ou
documenter) avec le portail web pour éviter d'afficher le P90 sous « pic ».
Décision iOS↔web↔Android à prendre ensemble avant tout changement de valeur émise.

## 8. (Optionnel) `GET /_ios/social/posts?authorId=` (Lot 8)
Feed par auteur, pour le filtrage local post-block. Complète le client.

## 9. `POST /api/auth/apple` — Sign in with Apple (✅ route écrite)
Fichier **déjà écrit** : `app/api/auth/apple/route.ts` (présent dans le working
tree, **non committé** — à intégrer dans le refactor monorepo). Vérifie le jeton
d'identité Apple (JWKS `appleid.apple.com/auth/keys` via `crypto.createPublicKey`
+ `jwt.verify`, `iss`/`aud=fr.signalquest.ios`), matche/crée l'utilisateur **par
email vérifié** (mot de passe aléatoire si nouveau, nom = `fullName` de la 1re
autorisation), respecte la 2FA, puis `issueSession` + `buildAuthSuccessResponse`.
**Aucune migration Prisma** (match par email, pas de colonne `appleUserId`).
Réutilise les helpers existants de `/login` et `/signup`.

**Prérequis hors-code :**
- Apple Developer : activer la capability **« Sign in with Apple »** sur l'App ID
  `fr.signalquest.ios` (fait automatiquement par la signature Xcode au build
  device — à confirmer dans le portail / pour la prod).
- Déployer la route en prod (le bouton iOS appelle `/api/auth/apple` ; tant que la
  route n'est pas en ligne, l'auth Apple renvoie 404).
- (Optionnel, robustesse) ajouter plus tard une colonne `appleUserId String? @unique`
  (SQL idempotent) pour lier les comptes même si l'email relais change.
