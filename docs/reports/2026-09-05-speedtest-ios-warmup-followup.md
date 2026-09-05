# Speedtest iOS — séparation chauffe / débit utile

Base de reprise : `b40baca2`, worktree `codex/ios-speedtest-v6`. Demande : vérifier le gonflement de la jauge upload pendant la chauffe puis au début utile, sans modifier moyennes finales ni traces.

## Constat vérifié

Le chemin iPerf3 partageait le même `SpeedtestLiveSampler` et son EMA entre chauffe et mesure utile. `OmitBridge` réintroduisait les octets et le temps de chauffe dans les compteurs utiles affichés.

Exécution des helpers du code avant correctif avec un jeu de données contrôlé :

- chauffe : 317 Mbps pendant 3 secondes ;
- première période utile : 150 ms à 62 Mbps ;
- jauge de chauffe : 317 Mbps ; première jauge utile : **303,6125 Mbps**, au lieu de 62 Mbps.

La reproduction est conservée dans `/tmp/sq-ios-warmup-reproduction.swift`. Ce n'est pas une mesure réseau réalisée sur iPhone.

## Correction

- `SpeedtestPhaseLiveSampler` utilise des fenêtres et EMA indépendantes pour la chauffe et la mesure utile.
- La chauffe upload retourne zéro à l'affichage avec l'étape « Chauffe » existante. Le trafic de chauffe continue d'être compté.
- La chauffe download conserve son débit reçu visible ; ses octets et son EMA ne contaminent plus la fenêtre utile.
- Une nouvelle tentative réinitialise les deux fenêtres.
- Aucun plafond ajouté et aucun remplacement du débit récent par la moyenne cumulée.
- Le diff ne change ni les compteurs de mesure, ni les calculs de moyenne/MAX, ni la collecte ou la sérialisation des traces.

## Vérification des trois transports

| Transport | Frontière examinée | Résultat |
|---|---|---|
| iPerf3 | callbacks `onWarmup` / `onProgress`, compteurs utiles post-omit | défaut présent ; corrigé pour upload et séparation des fenêtres DL/UL |
| Cloudflare | `measureCloudflareTransfer`, nouveau compteur et `SpeedtestLiveSampler` par phase | pas de phase de chauffe ni de réemploi de compteurs de chauffe ; pas de modification |
| LibreSpeed | `measureLibreSpeedTransfer`, nouveau compteur et `SpeedtestLiveSampler` par phase | même constat : pas de chauffe ni de fenêtre partagée ; pas de modification |

## Tests

**101 tests ciblés passent, 0 échec, code retour 0** : `SpeedtestV6ContractTests`, `SpeedtestTests`, `SpeedtestPeakWindowTests`.

Trois régressions ajoutées : chauffe upload 317 → première mesure utile 62 ; chauffe download distincte et reprise d'une tentative 1000 → 25 ; débit récent 100 pendant la seconde utile alors que la moyenne cumulée serait 81, puis zéro après silence. Le volume chauffe + utile est également vérifié.

Journal : `/tmp/sq-speedtest-v6-ios-warmup-tests.log`.

## Nouvelle distribution locale

La build reste **1.0 (148)** à la demande de la tâche principale. L'ancienne IPA reste conservée pour traçabilité ; la version corrigée est préparée dans `/tmp/sq-speedtest-v6-ios-148-warmup/`.

Archive et export App Store Connect terminés avec code retour 0.

- IPA corrigée : `/tmp/sq-speedtest-v6-ios-148-warmup/export/SignalQuest.ipa`.
- Archive : `/tmp/sq-speedtest-v6-ios-148-warmup/SignalQuest-1.0-148.xcarchive`.
- Taille IPA : 20924762 octets.
- SHA256 : `3321a5793452337664bf9ac420e58689ca2e9f154a5fa9d2acf301e63a6b84b9`.
- Trois bundles 1.0 (148), signature Apple Distribution, profils App Store valides, `get-task-allow=false`, APNs `production` pour l'app ; `codesign --verify --deep --strict` passe sur archive et IPA.
- Architecture arm64, OS minimum 16.0, SDK iphoneos27.0 ; dSYM principal correspondant au binaire (`31731D2B-23E8-3F40-966F-8D5D03BEC330`).
- Manifeste source inchangé après archive. Preuves JSON, journaux et réglages de signature temporaires dans le même dossier.

Cette IPA remplace l'IPA `/tmp/sq-speedtest-v6-ios-148/export/SignalQuest.ipa`, conservée uniquement pour traçabilité.

Aucun commit, push ni upload par cette tâche. La vérification sur iPhone physique reste à effectuer.


## Limite complémentaire : écriture locale et ACK TCP

Le correctif de chauffe n'élimine pas l'avance possible du compteur `contentProcessed` sur le drainage TCP. Ce compteur reste `client-written`, même dans la fenêtre utile. L'investigation publique Darwin/Network.framework, ses sondes et la décision de ne pas changer le transport sans preuve physique sont détaillées dans [la note TCP ACK](2026-09-05-ios-tcp-ack-feasibility.md). Aucun débit ACK local n'est déclaré mesuré.
