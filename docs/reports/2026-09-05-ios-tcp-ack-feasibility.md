# iOS — faisabilité d'un compteur TCP acquitté

Investigation du 5 septembre 2026 sur `a6ed0778`. Aucun moteur, transport ni artefact mobile modifié. Les sondes de compilation et de boucle locale sont hors dépôt dans `/tmp`.

## Limite du compteur live actuel

`StreamSender` utilise `NWConnection.send(... .contentProcessed ...)` et ajoute la taille du bloc lors du callback réussi (`SpeedtestService.swift`, autour des lignes 4724–4731). Le SDK précise que cette complétion indique un traitement/enfilement par la pile, pas un acquittement du pair et pas nécessairement une sortie de l'hôte.

La séparation chauffe/utile corrige le mélange des deux fenêtres, mais ne transforme pas les octets écrits en octets acquittés. Même après la chauffe, le débit récent de cette source peut devancer le débit réseau tant que les tampons se remplissent. Le résultat final fondé sur un reçu serveur conserve sa propre paire octets/durée ; aucune estimation ACK ne doit la remplacer.

## API publiques vérifiées

| API | Ce qui est disponible | Limite dans notre transport |
|---|---|---|
| `getsockopt(fd, IPPROTO_TCP, TCP_CONNECTION_INFO, ...)` / `tcp_connection_info.tcpi_snd_sbbytes` | champ public contenant les octets du buffer d'envoi, données en vol incluses ; compilable pour iOS 16 avec le SDK installé | aucun fd BSD n'est exposé par notre code iPerf3, qui crée des `NWConnection` |
| `NWProtocolTCP.Metadata.availableSendBuffer` / `nw_tcp_get_available_send_buffer` | API publique depuis iOS 12, décrite par le header comme les octets attendant un ACK | ce compteur n'est pas atomiquement aligné avec les callbacks `contentProcessed` comptés par l'application |

Le SDK distingue `TCP_CONNECTION_INFO`, public, des variantes internes de `TCP_INFO`. Aucune recherche de fd privé, réflexion ou API non documentée n'est proposée.

La compilation de `/tmp/sq-ios-tcp-ack-api-check.swift` a réussi avec la cible `arm64-apple-ios16.0` et le SDK `iphoneos27.0`. Elle ne prouve pas un comportement runtime sur iPhone.

## Sonde locale et résultat observé

Sonde Swift autonome utilisant `NWListener` / `NWConnection` sur boucle locale, exécutée sur macOS 27.0. Le lecteur applicatif est volontairement suspendu pendant 1,5 seconde. Aucun trafic vers un serveur externe.

`availableSendBuffer` est réellement dynamique : file non nulle pendant le blocage, puis zéro après drainage. Toutefois, même sur la même queue Dispatch côté application :

```text
completion processed=131072 pending=179756 candidate=-48684
```

Cette observation invalide un raccordement direct `totalContentProcessed - availableSendBuffer` comme compteur ACK exact. La pile peut avoir avancé et partiellement traité d'autres envois avant l'exécution de leurs callbacks. Prendre `max(0, ...)`, imposer la monotonie ou lisser la différence masquerait cette incohérence de base.

À la fin de la même sonde, après drainage : `processed=8388608`, `pending=0`, `appReceived=8388608`. Cette convergence finale ne valide pas tous les instants intermédiaires.

Sondes conservées : `/tmp/sq-nw-send-buffer-probe.swift` et `/tmp/sq-nw-send-buffer-callback-probe.swift`.

## Décision et périmètre futur

- Ne pas remplacer le transport iOS sans preuve physique ; aucune modification moteur effectuée dans cette investigation.
- Conserver la provenance `client-written` du live local iOS. Un ACK TCP atteste la pile TCP du pair, pas la lecture applicative par iPerf3 ; les ACK peuvent aussi arriver groupés.
- Aucune nouvelle limite de débit, aucun lissage compensatoire et aucune approximation du résultat final.
- Si Android valide un compteur ACK cumulatif noyau et si le contrat partagé ajoute `tcp-acknowledged`, iOS pourra décoder/afficher cette source dans un résultat ou historique reçu. Les modèles de trace Swift stockent déjà la source sous forme de chaîne ; les libellés devront être complétés une fois le contrat confirmé. Cela ne doit pas activer ou prétendre un ACK local iOS.
- Les essais iPhone, IPv4/IPv6, pertes, ACK retardés, annulation, multi-flux et cohérence aux frontières resteraient nécessaires avant toute future source ACK locale.

## Sources primaires

- [Apple — NWProtocolTCP.Metadata](https://developer.apple.com/documentation/network/nwprotocoltcp/metadata) et [availableSendBuffer](https://developer.apple.com/documentation/network/nwprotocoltcp/metadata/availablesendbuffer).
- SDK installé : `Network.framework/Headers/tcp_options.h`, lignes 401–411 (sémantique ACK, disponibilité iOS 12) ; `connection.h`, lignes 434–444 et 591–598 (la complétion d'envoi n'est pas un ACK).
- SDK installé : `usr/include/netinet/tcp.h`, lignes 242–290 (`TCP_CONNECTION_INFO` et `tcpi_snd_sbbytes`, données en vol comprises).
- [Apple XNU — tcp_usrreq.c](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/netinet/tcp_usrreq.c) : `tcp_connection_fill_info` affecte `so_snd.sb_cc` à `tcpi_snd_sbbytes` ; l'option `TCP_CONNECTION_INFO` exporte cette structure.
- [Apple XNU — tcp_input.c](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/netinet/tcp_input.c) : traitement des ACK et retrait des octets acquittés du buffer d'envoi via `sbdrop`.

## Suite : présentation d'une source ACK reçue

À la demande de la tâche principale après validation du compteur Android, iOS reconnaît désormais le libellé de provenance reçu `tcp-acknowledged` : **« Acquittés TCP (en-têtes inclus) »** / **“TCP acknowledged (headers included)”**.

- Le DTO des détails distants décode facultativement `uploadMeasurementSource`, déjà exposé par l'API.
- La source affichée du résultat privilégie `finalMeasurement.source` lorsqu'elle est présente ; le MAX absent du reçu conserve la source des échantillons via `sampleByteSource`.
- Le détail d'historique et le détail d'un speedtest partagé affichent la source reçue. Une courbe ACK n'est plus décrite comme des octets écrits côté client.
- Aucun compteur, transport ni résultat local iOS n'est modifié ; aucun ACK local n'est fabriqué.

Validation : **23 tests ciblés passent**, dont décodage phase `client-written`, samples `tcp-acknowledged`, finalMeasurement TCP, repli MAX sur samples et labels FR/EN. **11 tests i18n passent** ; `git diff --check` passe.

Journaux : `/tmp/sq-ios-tcp-ack-provenance-tests.log` et `/tmp/sq-ios-tcp-ack-provenance-i18n.log`.

Aucun commit, push ou nouvel archivage dans cette étape. L'IPA 148 précédemment préparée ne contient pas encore ces nouveaux libellés.

### Revue de présentation courbe / MAX

La présentation est désormais générique, sans branche spéciale qui masque une provenance :

- sources identiques : une ligne « Courbe et MAX : … » ;
- sources différentes : lignes séparées « Courbe : … » et « MAX : … ».

`maxByteSource` reste la référence : source du reçu uniquement si son MAX est présent, sinon source des échantillons. La fenêtre MAX affichée suit la même règle ; aucun débit n'est recalculé.

Tests FR/EN dédiés : VPS avec courbe TCP et MAX serveur confirmé ; iPerf avec courbe TCP et MAX TCP de repli ; Cloudflare avec résultat final TCP et MAX TCP. Le cas VPS vérifie aussi une fenêtre serveur de 3 s distincte de la fenêtre des échantillons.

**26 tests ciblés passent, code retour 0**, plus **11 tests i18n** ; `git diff --check` passe. Journal final : `/tmp/sq-ios-tcp-max-source-final-tests.log`.

Prêt pour revue avant commit et archive par la tâche principale. Aucun commit, push ou archivage effectué dans cette étape ; moteur inchangé.

### Bornes propres des échantillons reçus

Le modèle de phase accepte maintenant `sampleStartOffsetMs` et `sampleEndOffsetMs`, optionnels et relatifs au début du run. Sans ces champs, l'origine et la fin des échantillons retombent respectivement sur `warmupEndOffsetMs` et `measurementEndOffsetMs`.

La moyenne cumulée, l'origine des axes et la durée des courbes utilisent les bornes effectives des samples dans les détails, les deux renderers de partage et le détail Drive Test. `peakWindowMs` reste utilisé tel que fourni pour un MAX issu des samples ; un MAX explicite du reçu conserve sa propre fenêtre. `finalMeasurement` garde sa source et sa durée indépendantes.

Le producteur local iOS reste inchangé. Un test sur `SpeedtestTraceRecorder` confirme que l'encodage local n'émet ni `sampleStartOffsetMs` ni `sampleEndOffsetMs`.

Validation : **55 tests ciblés passent, code retour 0** (`SpeedtestV6ContractTests`, `SpeedtestDetailSheetTests`, `SpeedtestShareImageTests`, `SQShareCardBuilderTests`). Cas nouveau : phase payload de 12 s, samples décalés de 10 s, reçu serveur de 8 s ; moyenne samples maintenue à 100 Mbps, axe normalisé de 0,1 à 1,0 et fenêtre MAX des samples de 3 s. Le repli legacy est également testé.

Journal : `/tmp/sq-ios-sample-boundaries-tests.log`. `git diff --check` passe. Aucun commit, push ni archivage dans cette étape ; les changements restent regroupés avec les libellés de provenance pour revue.
