# Ticket backend — F1 « Sessions de couverture iOS »

> Cible : `~/Site/map-nextjs` (PROD). **Règles non négociables** : additif uniquement, **SQL direct idempotent** (`ALTER … IF …`), **jamais** `prisma migrate dev`/`db push` sur la prod. Appliquer le SQL **avant** de déployer le code.

## Problème
Le modèle `CoveragePoint` exige **`signalStrength Int` (NON nullable)** et la route `POST /api/coverage/session/import` **rejette** tout point sans signal (`normalizeSignal === null → invalidSignal++`, point ignoré), et utilise même `signalStrength` comme **sentinelle « Aucun »** (`if (signalStrength > -10) technology = 'Aucun'`). Or **iOS ne peut PAS fournir de signal** (RSRP/dBm indisponible). iOS ne dispose que de : **génération** (2G/3G/4G/5G NSA/5G SA → `technology`), **connectivité** (réseau utilisable / `Aucun`), **débit/latence**, **position**, **opérateur**, **MCC/MNC**.

## Changement demandé (additif)

### 1. Schéma — rendre le signal optionnel (SQL idempotent)
```sql
ALTER TABLE "CoveragePoint" ALTER COLUMN "signalStrength" DROP NOT NULL;
-- Distinguer les points sans mesure radio (iOS) pour les exclure des heatmaps signal :
ALTER TABLE "CoveragePoint" ADD COLUMN IF NOT EXISTS "hasSignal" BOOLEAN NOT NULL DEFAULT true;
```
> `CoverageSession.source` existe déjà (`session/start` lit `normalizeCoverageSessionSource(body.source)`) → marquer les sessions iOS `source: 'ios'`.
Côté Prisma (après le SQL, pour aligner le client) : `signalStrength Int?` + `hasSignal Boolean @default(true)`. **Pas de `migrate`** — `prisma db pull` ou édition manuelle + `prisma generate`.

### 2. Route — accepter les points iOS sans signal
Deux options (au choix) :
- **(préférée, la moins risquée)** une route **additive** `POST /api/coverage/session/import-ios` qui **n'altère pas** l'`import` existant : accepte des points `{ latitude, longitude, timestamp, technology, networkType?, operatorKey, mobileCountryCode, mobileNetworkCode, downloadMbps?, uploadMbps?, pingMs? }`, force `signalStrength = null`, `hasSignal = false`, `technology` pris **tel quel** (déjà `4G`/`5G`/`Aucun`, sans dériver du signal), `source = 'ios'`.
- ou : garder une seule route `import` et **brancher sur `source === 'ios'`** pour ne pas exiger `signalStrength` et ne pas re-dériver `technology`.

### 3. Couches carte
- Exclure `hasSignal = false` (ou `signalStrength IS NULL`) des **heatmaps de signal**.
- Inclure ces points dans une couche **« génération/couverture »** (couleur par `technology`), et dans le détail de session (`/sessions`, `/coverage/points`).

### 4. Confidentialité
Troncature des coordonnées (≈3-4 déc.) pour lectures anonymes (cf. BE-5) ; session rattachée au compte authentifié.

## Contrat iOS → backend (ce que le client enverra)
`POST /api/coverage/session/start { source:'ios', device, market, operator }` → `{ id }`, puis
`POST /api/coverage/session/import-ios { sessionId, points:[{ latitude, longitude, timestamp, technology, networkType, operatorKey, mobileCountryCode, mobileNetworkCode, downloadMbps?, uploadMbps?, pingMs? }] }`, puis
`POST /api/coverage/session/end { sessionId }`.

## Acceptation
- [ ] Un point iOS sans `signalStrength` est **accepté** et stocké (`hasSignal=false`).
- [ ] `technology` iOS (`5G NSA`/`4G`/`Aucun`) conservé sans dérivation par signal.
- [ ] Points iOS **absents** des heatmaps signal, **présents** sur la couche génération + le détail de session.
- [ ] SQL idempotent appliqué sur la prod **avant** déploiement ; aucune route web/Android cassée.

## Côté iOS (déjà prévu, lot F1b)
Capture des points le long du trajet (génération via `NetworkPathMonitor.cellularTechnology`, connectivité, opérateur résolu, débit/latence aux points testés) dans `DriveTestViewModel` → `start`/`import-ios`/`end` ; affichage réutilise `SessionTraceMapView` (trace colorée par génération).
