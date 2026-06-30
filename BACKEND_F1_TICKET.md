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

## Côté iOS — FAIT (commit `53224d06`)
`DriveTestViewModel` capture les points le long du trajet (génération via `NetworkPathMonitor.cellularTechnology`, débit/latence aux points testés) et **POST** la session à `import-ios` au `stop()` — best-effort, **uniquement** si consentement carte + hors VPN. **Contrat réel envoyé** : timestamps en **epoch millisecondes** (Int), points `{ latitude, longitude, timestamp, technology, downloadMbps?, uploadMbps?, pingMs? }`, session `{ startTime, endTime, mcc, mnc, operatorKey, marketCode, showOnMap, points }`. Tant que la route n'existe pas, le 404 est avalé (aucune régression).

## ⚠️ Vérification & impact (à faire AVANT de déployer)
- **Je n'ai PAS pu typer/builder le backend ici** (l'alias `@/` ne se résout pas dans mon invocation de `npm run typecheck` → ~6000 faux positifs `TS2307`). **Donc : ni schéma ni route poussés.** À typer/tester chez toi.
- **`signalStrength` est lu par 12+ routes** (cells, antennas/[id]/coverage, signal-stats, tiles/coverage, coverage/points, sessions, web…). Le rendre `Int?` change leur type → **lance `npm run typecheck` et corrige les lecteurs** (probable `?? null`/guards), OU garde-le `Int` et utilise un **sentinel** (ex. `0`) pour les points iOS + filtre `signalStrength < 0` sur les heatmaps de signal. À trancher selon ce que ton typecheck révèle.
- Heatmaps de **signal** : exclure les points iOS (via `source='ios'` de la session, ou `signalStrength IS NULL`/sentinel). Couche **génération** : les inclure.

## Implémentation de la route (prête — `apps/api/app/api/coverage/session/import-ios/route.ts`)
> Auth seule (contribution ouverte à tout utilisateur authentifié). Self-contained (n'importe que des helpers prouvés). Écrite pour `signalStrength` **nullable** ; si tu choisis le sentinel, remplace `signalStrength: null` par `signalStrength: 0` et retire `hasSignal`.

```ts
import { NextRequest } from 'next/server';
import { getCurrentUser } from '@/lib/auth';
import { prisma } from '@/lib/prisma';
import { apiError, apiJson, createApiRequestContext } from '@/lib/api-observability';

const MAX_POINTS = 50_000; const INSERT_CHUNK_SIZE = 1000;
type JsonRecord = Record<string, unknown>;
const asRecord = (v: unknown): JsonRecord | null => (v && typeof v === 'object' && !Array.isArray(v) ? (v as JsonRecord) : null);
const asArray = (v: unknown): unknown[] | null => (Array.isArray(v) ? v : null);
const asString = (v: unknown): string | null => (typeof v === 'string' && v.trim() ? v.trim() : typeof v === 'number' && Number.isFinite(v) ? String(v) : null);
const toNumber = (v: unknown): number | null => (typeof v === 'number' && Number.isFinite(v) ? v : typeof v === 'string' && Number.isFinite(Number(v)) ? Number(v) : null);
const toInteger = (v: unknown): number | null => { const n = toNumber(v); return n === null ? null : Math.round(n); };
function toDate(v: unknown): Date | null {
  if (typeof v === 'number' && Number.isFinite(v)) { const d = new Date(v > 1e12 ? v : v * 1000); return Number.isNaN(d.getTime()) ? null : d; }
  if (typeof v === 'string') { const d = new Date(v); return Number.isNaN(d.getTime()) ? null : d; }
  return null;
}
function normalizeIosTechnology(raw: unknown): string {
  const s = (asString(raw) ?? '').toUpperCase();
  if (s.includes('5G')) return '5G'; if (s.includes('4G') || s === 'LTE') return '4G';
  if (s.includes('3G')) return '3G'; if (s.includes('2G')) return '2G';
  return s === '' || s === 'NONE' || s === 'NO SERVICE' ? 'Aucun' : (s || 'Aucun');
}
function haversineKm(la1: number, lo1: number, la2: number, lo2: number): number {
  const R = 6371, dLa = ((la2 - la1) * Math.PI) / 180, dLo = ((lo2 - lo1) * Math.PI) / 180;
  const a = Math.sin(dLa / 2) ** 2 + Math.cos((la1 * Math.PI) / 180) * Math.cos((la2 * Math.PI) / 180) * Math.sin(dLo / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

export async function POST(request: NextRequest) {
  const context = createApiRequestContext(request, '/api/coverage/session/import-ios');
  try {
    const user = await getCurrentUser(request);
    if (!user) return apiError(context, 401, 'UNAUTHORIZED', 'Authentification requise');
    const payload = asRecord(await request.json().catch(() => null));
    if (!payload) return apiError(context, 400, 'INVALID_JSON', 'Corps JSON invalide');
    const rawPoints = asArray(payload.points);
    if (!rawPoints?.length) return apiError(context, 400, 'NO_POINTS', 'Aucun point fourni');
    if (rawPoints.length > MAX_POINTS) return apiError(context, 413, 'TOO_MANY_POINTS', `Max ${MAX_POINTS}`);

    const sMarket = asString(payload.marketCode), sOpKey = asString(payload.operatorKey);
    const sOp = asString(payload.operator) ?? asString(payload.mobileOperator);
    const sMcc = toInteger(payload.mcc), sMnc = toInteger(payload.mnc);
    const points = (rawPoints.map((raw) => {
      const p = asRecord(raw); if (!p) return null;
      const lat = toNumber(p.latitude ?? p.lat), lon = toNumber(p.longitude ?? p.lng), ts = toDate(p.timestamp ?? p.t);
      if (lat === null || lon === null || lat < -90 || lat > 90 || lon < -180 || lon > 180 || !ts) return null;
      return {
        latitude: lat, longitude: lon, accuracy: toNumber(p.accuracy),
        signalStrength: null as number | null, // sentinel: mettre 0 si signalStrength reste Int
        hasSignal: false,                       // retirer si schéma sans hasSignal
        technology: normalizeIosTechnology(p.technology ?? p.generation),
        networkType: asString(p.networkType),
        mobileOperator: asString(p.mobileOperator ?? p.operator) ?? sOp,
        mobileCountryCode: toInteger(p.mcc) ?? sMcc, mobileNetworkCode: toInteger(p.mnc) ?? sMnc,
        marketCode: asString(p.marketCode) ?? sMarket, operatorKey: asString(p.operatorKey) ?? sOpKey,
        timestamp: ts,
      };
    }).filter(Boolean) as NonNullable<ReturnType<typeof Object>>[]) as any[];
    if (!points.length) return apiError(context, 400, 'NO_VALID_POINTS', 'Aucun point exploitable');
    points.sort((a, b) => a.timestamp.getTime() - b.timestamp.getTime());

    const startTime = toDate(payload.startTime) ?? points[0].timestamp;
    const endTime = toDate(payload.endTime) ?? points[points.length - 1].timestamp;
    let distanceKm = 0;
    for (let i = 1; i < points.length; i++) distanceKm += haversineKm(points[i-1].latitude, points[i-1].longitude, points[i].latitude, points[i].longitude);
    const techs = Array.from(new Set(points.map((p) => p.technology)));
    const created = await prisma.$transaction(async (tx) => {
      const session = await tx.coverageSession.create({ data: {
        userId: user.id, name: asString(payload.name) ?? `Couverture iOS ${startTime.toLocaleDateString('fr-FR')}`,
        startTime, endTime, duration: Math.max(0, Math.floor((endTime.getTime() - startTime.getTime()) / 1000)),
        isActive: false, totalPoints: points.length, distance: distanceKm, technologiesDetected: JSON.stringify(techs),
        avgSignalStrength: null, minSignalStrength: null, maxSignalStrength: null,
        northBound: Math.max(...points.map((p) => p.latitude)), southBound: Math.min(...points.map((p) => p.latitude)),
        eastBound: Math.max(...points.map((p) => p.longitude)), westBound: Math.min(...points.map((p) => p.longitude)),
        showOnMap: payload.showOnMap === undefined ? true : Boolean(payload.showOnMap),
        deviceModel: asString(payload.device), source: 'ios', sourceSessionId: asString(payload.sessionId),
        marketCode: sMarket, operatorKey: sOpKey,
      } });
      for (let i = 0; i < points.length; i += INSERT_CHUNK_SIZE)
        await tx.coveragePoint.createMany({ data: points.slice(i, i + INSERT_CHUNK_SIZE).map((p) => ({ ...p, sessionId: session.id, userId: user.id })) });
      return session;
    });
    return apiJson(context, 200, { ok: true, sessionId: created.id, totalPoints: points.length }, { ok: true });
  } catch (e) {
    return apiError(context, 500, 'IMPORT_IOS_FAILED', e instanceof Error ? e.message : 'Erreur inconnue');
  }
}
```
