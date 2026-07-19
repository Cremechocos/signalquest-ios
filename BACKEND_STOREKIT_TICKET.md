# Ticket backend — Activation des abonnements App Store (StoreKit)

> Cible : `~/Site/map-nextjs` (PROD). **Règles non négociables** : additif uniquement, **SQL direct idempotent** (`ALTER … IF …`, `CREATE … IF NOT EXISTS`), **jamais** `prisma migrate dev`/`db push` sur la prod. Appliquer le SQL **avant** de déployer le code.
>
> Contexte iOS : toute la plomberie StoreKit 2 est en place et branchée (`AppStoreTransactionSynchronizer`, flags `SQFeatures.storeKit*` ON en build staging). Il manque **la moitié serveur** décrite ici. Tant que cette route n'existe pas, l'app ne peut déclencher aucun débit (safe by default).

## Ce que l'app envoie / attend

Le client POST une **preuve de transaction** signée par Apple et attend en retour **l'état d'entitlement canonique** (même format que le GET existant `/api/billing/subscription`).

- **iOS → backend** : `POST /api/billing/apple/verify`
  - En-têtes : `Content-Type: application/json`, `Authorization: Bearer <auth_token>` (+ cookie `auth_token`), `Idempotency-Key: <transactionId>`.
  - Corps (`AppStoreTransactionProof`) :
    ```json
    {
      "signedTransaction": "<JWS de la transaction StoreKit 2 (Transaction.jwsRepresentation)>",
      "productId": "fr.signalquest.ios.premium.monthly",
      "transactionId": "2000000...",
      "originalTransactionId": "2000000..."
    }
    ```
- **backend → iOS** : réponse **200** au format `BillingSubscriptionResponse` (identique au GET `/api/billing/subscription`) :
  ```json
  {
    "tier": "premium",
    "purchases": [{
      "id": "<id interne>",
      "provider": "apple_appstore",
      "tier": "premium",
      "status": "active",
      "cancelAtPeriodEnd": false,
      "currentPeriodEnd": "2026-09-10T10:00:00.000Z",
      "expiresAt": "2026-09-10T10:00:00.000Z",
      "startsAt": "2026-08-10T10:00:00.000Z"
    }]
  }
  ```
  - `provider` doit valoir **`apple_appstore`** (mappé côté iOS en `EntitlementSource.appStore`).
  - `tier` ∈ `free | basic | premium` (canonique, résolu serveur). En paiement échoué, le tier canonique doit déjà être `free` (règle produit existante).
  - Erreur JWS invalide / rejet → **4xx** avec `{ "error": "...", "code": "APPLE_JWS_INVALID" }` (l'app propage l'échec, n'octroie rien).

## Travail backend

### 1. Vérification serveur de la transaction (App Store Server API)
- Vérifier la **signature JWS** du `signedTransaction` : décoder l'en-tête, valider la chaîne `x5c` jusqu'à la **racine Apple (Apple Root CA - G3)**, puis lire le payload (`JWSTransactionDecodedPayload` : `productId`, `originalTransactionId`, `expiresDate`, `type`, `revocationDate`, `environment`…).
- **Ne jamais faire confiance** aux seuls identifiants du corps client : le `productId`/`transactionId` faisant foi sont ceux **du JWS vérifié**.
- Recommander la lib officielle `app-store-server-library` (Node) pour la vérification + l'appel `getTransactionInfo`/`getAllSubscriptionStatuses` (App Store Server API, auth par clé `.p8` : issuer ID + key ID).
- Mapper le produit vérifié → tier/période via la table de correspondance des 4 identifiants (voir §ASC).

### 2. Persistance (SQL idempotent)
Réutiliser le modèle d'entitlement multiplateforme existant (Apple = une source à côté de Stripe/Google Play). Exemple (à adapter au schéma réel `Purchase`/`Entitlement`) :
```sql
-- Idempotence sur la transaction d'origine Apple : un rejeu ne crée pas de doublon.
ALTER TABLE "Purchase" ADD COLUMN IF NOT EXISTS "appleOriginalTransactionId" TEXT;
CREATE UNIQUE INDEX IF NOT EXISTS "Purchase_appleOriginalTx_key"
  ON "Purchase" ("appleOriginalTransactionId") WHERE "appleOriginalTransactionId" IS NOT NULL;
```
- Upsert par `originalTransactionId` : `provider='apple_appstore'`, `tier`, `status` (`active|past_due|canceled|expired`), `currentPeriodEnd/expiresAt` = `expiresDate` du JWS, rattaché au **compte authentifié** de la requête.
- Renvoyer ensuite le **snapshot canonique** recalculé (le même que le GET).

### 3. App Store Server Notifications v2 (webhook) — indispensable
- Endpoint `POST /api/billing/apple/notifications` (URL à déclarer dans App Store Connect, prod **et** sandbox).
- Vérifier le `signedPayload` (même vérif JWS), traiter `DID_RENEW`, `EXPIRED`, `DID_FAIL_TO_RENEW`/`GRACE_PERIOD`, `REFUND`, `REVOKE`, `DID_CHANGE_RENEWAL_STATUS` → mettre à jour l'entitlement (renouvellement, expiration, remboursement → `tier` repasse `free`).
- Sans ce webhook, l'app afficherait un droit qui ne s'éteint jamais côté serveur.

### 4. Sécurité / robustesse
- Idempotence stricte (rejeu du même JWS = no-op) ; auth requise ; ne jamais octroyer sur un JWS `environment: Sandbox` en prod (et inversement).
- Journaliser les échecs de vérification (sans logguer le JWS complet).

## App Store Connect (ops — hors code)
- Créer **4 abonnements auto-renouvelables** dans **un seul groupe d'abonnement**, IDs **exacts** (le code iOS et les tests en dépendent) :
  | Product ID | Tier | Période | Prix cible |
  |---|---|---|---|
  | `fr.signalquest.ios.basic.monthly` | Basic | P1M | 2,99 € |
  | `fr.signalquest.ios.basic.annual` | Basic | P1Y | 29,99 € |
  | `fr.signalquest.ios.premium.monthly` | Premium | P1M | 7,99 € |
  | `fr.signalquest.ios.premium.annual` | Premium | P1Y | 79,99 € |
  - Niveaux de service : Premium au-dessus de Basic (upgrade/downgrade dans le groupe).
  - Métadonnées localisées **FR + EN**, capture d'écran de review, description de l'abonnement.
- **Contrat Paid Apps** signé + informations **bancaires/fiscales** renseignées.
- **Clé App Store Server API** (issuer ID, key ID, fichier `.p8`) provisionnée pour le backend (§1/§3).
- **Compte sandbox** de test + note de review (accès à un compte de démo premium).

## Recette (staging d'abord)
1. Backend de pré-prod : route `verify` + webhook déployés, clé ASC sandbox configurée.
2. App **build staging** (flags déjà ON) pointant le backend de pré-prod, avec `SignalQuest.storekit` (simulateur) **ou** un compte sandbox (device).
3. Vérifier bout en bout : achat → `verify` renvoie `tier` correct → PaywallView bascule sur les prix StoreKit réels et débloque la fonctionnalité → un remboursement (notification) repasse le tier à `free`.
4. Seulement ensuite : activer les flags en **prod** (passer les deux `SQFeatures.storeKit*` à `true` inconditionnellement, cf. `AppConfig.swift`) et créer les produits en état « Prêt à soumettre » liés à la version.

## À trancher côté produit (non bloquant backend)
Le paywall vend des bénéfices **non encore verrouillés** dans l'app (badge Basic/Premium, « analyses détaillées du comparateur », « tendances/alertes du journal », journal synchronisé) — seule la **durée de story** est réellement gatée (`StoryComposer.swift:310`). Avant soumission : soit implémenter ces gates (`services.entitlements.confirmedServerTier`), soit **ajuster la copie** `benefits(for:)` (`PaywallView.swift:336-354`) pour ne promettre que ce qui existe (App Review 3.1.2 / 2.3.1).
