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

### Liaison de compte (associer / dissocier depuis les Réglages)
Fichiers **écrits** dans `map-nextjs` (non committés) :
- `lib/apple-auth.ts` — vérification JWKS factorisée (partagée auth + link).
- `app/api/auth/apple/route.ts` — **durci** : match par `appleUserId` (claim `sub`)
  puis par **email vérifié** (gate `email_verified`, sinon 409), stocke l'`appleUserId`.
- `app/api/auth/apple/link/route.ts` (auth) — associe l'Apple ID au compte courant
  (409 si déjà lié ailleurs).
- `app/api/auth/apple/unlink/route.ts` (auth) — dissocie.
- `app/api/auth/me/route.ts` + `app/api/auth/_shared.ts` — exposent `appleLinked`.
- `lib/validation.ts` — `emailSchema` normalise (`trim` + `toLowerCase`) → corrige
  les doublons de compte par casse (signup ne normalisait pas).
- `prisma/schema.prisma` — `appleUserId String? @unique`.
- `prisma/sql/2026-06-apple-user-id.sql` — **SQL idempotent** à exécuter sur la prod
  AVANT déploiement (`ADD COLUMN IF NOT EXISTS` + index unique partiel).

**Prérequis hors-code (À FAIRE) :**
1. Apple Developer : confirmer la capability **« Sign in with Apple »** sur l'App ID
   `fr.signalquest.ios` (ajoutée auto par la signature Xcode au build device).
2. **Exécuter** `prisma/sql/2026-06-apple-user-id.sql` sur la base prod (idempotent),
   PUIS `prisma generate`, PUIS déployer le code (l'ordre évite que le client Prisma
   référence une colonne absente).
3. (Optionnel) backfill casse email : `UPDATE "User" SET email = lower(email)` — à ne
   lancer qu'après vérification d'absence de collisions (deux comptes ne différant que
   par la casse). Non fourni automatiquement (risque de violation d'unicité).

## 10. AutoFill mot de passe (trousseau iCloud) — AASA `webcredentials`
Pour qu'iOS propose d'**enregistrer le mot de passe** à l'inscription/connexion et
l'**auto-remplisse** :
- **iOS** (fait) : entitlement `com.apple.developer.associated-domains` =
  `webcredentials:signalquest.fr` (provisionné auto au build device).
- **Backend** (fait, **non committé**) : `app/.well-known/apple-app-site-association/route.ts`
  sert désormais une section `webcredentials.apps` = `[<IOS_TEAM_ID>.fr.signalquest.ios,
  835X2977R7.fr.signalquest.ios]` (équipe prod + équipe de signature dev, dédupliqué ;
  surchargeable via `IOS_TEAM_ID_DEV`).
- **À FAIRE** : déployer l'AASA mis à jour (servi en `application/json`, sans redirection,
  à `https://signalquest.fr/.well-known/apple-app-site-association`). iOS le récupère via
  le CDN Apple (cache jusqu'à ~24 h). **Pour tester tout de suite** sur l'iPhone :
  Réglages → Développeur → activer **« Associated Domains Development »** (bypass du cache
  CDN), puis relancer l'app. Vérifier que `IOS_TEAM_ID` en prod = l'équipe réelle de l'App ID.
