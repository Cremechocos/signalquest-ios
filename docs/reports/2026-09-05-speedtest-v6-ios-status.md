# Speedtest iOS v6 — suivi local

Worktree `codex/ios-speedtest-v6`, base `ff36f20a`. Aucun commit, push ni distribution.
Plan accepté : [plan commun](../../../android-speedtest-v6/docs/reports/2026-09-05-speedtest-v6-plan.md).

## Changements

- Mesures monotones, snapshots cohérents chauffe/fermeture, intervalles réellement observés, fenêtres glissantes communes 1 s/30 %, percentiles interpolés, silence inclus. Live : intersection exacte à la frontière de la seconde, EMA proportionnelle au temps écoulé.
- Correction de régression du diff initial : `SafeCounter.add(-1)` doit libérer les slots d'upload iPerf3. Les octets utiles restent figés après fermeture ; le compteur de trafic inclut les callbacks tardifs observés.
- Collecteur par run propagé par `TaskLocal`, identités run/tentative, trace v1 méthodologie6 pour iPerf3, Cloudflare et LibreSpeed. Tentatives remplacées séparées. `runTransferredBytes` compte les payloads client observés de toutes les tentatives, chauffe comprise ; ni overhead réseau ni estimation.
- Trace persistée dans `SpeedtestRunResult` et la file existante puis envoyée au POST ; décodage optionnel sur archives et détails distants. Versions anciennes non requalifiées en v6. Les anciens résultats sans version restent sans trace et conservent leur PING historique.
- PING principal centralisé (minimum v6), moyenne et statistiques conservées séparément. Sources client/serveur explicites dans les détails. Endpoints DL/UL/ping conservés ; correction du port DL anciennement remplacé par le port UL. ICMP n'a pas de port.
- Nouvelle préférence de durée 10 s ; préférences existantes et profils dédiés conservés.
- Historique déplacé dans Application Support non évictable, protection de fichier, reprise du cache historique. La limite existante de 20 résultats affichés demeure.
- Sérialisation de la création/envoi par soumission, du journal JSON iOS16 et de la projection historique. Les réponses doivent être HTTP 2xx avec `success:true` et identifiant non vide avant acquittement ; tests HTTP 500, successfalse, identifiant absent/blanc puis succès 201. Les claims du token sont liés au propriétaire capturé avant POST et après réponse ; le test compteA/tokenB ne touche jamais le transport. Les détails privés utilisent aussi l'auth capturée. Import SwiftData : rollback sur échec, aucune suppression du JSON source avant succès, test erreur de disque injectée puis reprise. Mapping serveur individuel durable avant acquittement. Contexte d'auth capturé pour la tentative HTTP ; invité reste invité ; les écritures utilisent le propriétaire capturé et non le nouveau compte.
- Courbes horodatées dans détails, partage historique, renderer d'aperçu actif et Drive Test. Courbe absente explicitée ; aucune ligne plate fabriquée. Moyenne cumulée distincte dans la courbe de détail ; axes temporels réels et libellé historique sans timestamps. Valeurs Gbps à partir de 1000 pour les surfaces principales/partage.
- Étapes préparation/chauffe/mesure/reconnexion et temps utile/total séparés. Grande police dans les détails et grille Drive Test ; cible fermeture 44 pt ; textes FR/EN ajoutés.

## Vérifications

- **157 tests ciblés, 10 suites, 0 échec**, `xcodebuild test` terminé avec code retour 0 le 5 septembre à 20:22 (simulateur SQ-Test, iOS 27, build Debug, signature désactivée). Journal : `/tmp/sq-speedtest-v6-ios-reviewed-final.log` ; résultat : `/tmp/sq-speedtest-v6-ios-derived/Logs/Test/Test-SignalQuest-2026.09.05_20-22-22-+0200.xcresult`.
- Suites : SpeedtestV6ContractTests, SpeedtestPeakWindowTests, SpeedtestTests, SpeedtestDetailSheetTests, SpeedtestShareImageTests, SpeedtestIcmpLiveProgressTests, SpeedtestUploadStreamLadderTests, CarPlaySpeedtestTests, SQShareCardBuilderTests, SQShareCardRenderTests.
- Régressions spécifiques : vecteurs JSON communs, fenêtre irrégulière/silence/reprise, fermeture + octets tardifs, slot upload libéré, trace et journal round-trip/legacy, retry concurrent exclusif, journal JSON concurrent rechargé, conservation sous-ms, trafic de tentatives abandonnées.
- Trace Swift exportée dans `/tmp/sq-ios-v6-contract-trace.json` acceptée par le schéma TypeScript (validation indépendante web_v6).
- 11 tests du catalogue i18n passent.
- Rendus simulés inspectés : `/tmp/sq-ios-v6-phone.png` (320pt, accessibility3, clair), `/tmp/sq-ios-v6-tablet.png` (768pt, sombre). Partage actif : `/tmp/sq-ios-v6-active-share.png`.

## Limites de clôture

- Aucun iPhone physique disponible : pas de runs cellulaires/Wi-Fi réels ni de comparaison radio/thermique HTTP/iPerf3.
- Rendus ImageRenderer et build simulateur ne prouvent pas navigation VoiceOver, interaction en grande police sur appareil, ni fluidité/profile p95.
- Tests de concurrence unitaires ne simulent pas toutes les coupures de processus à chaque fsync, ni les réponses réseau A/B et changements de comptes sur serveur réel. Ne pas déclarer ces scénarios QA physiques terminés.
- En upload iPerf3, un reçu est accepté uniquement avec ses propres bornes `start_time/end_time` (ou `end.sum_received.seconds`). Sinon, la paire octets/durée client est retenue. `serverBytesUsed` exprime la source effectivement retenue ; un reçu de zéro n'est jamais remplacé par un compteur client positif présenté comme serveur. Courbe/MAX/P90 restent fondés sur les callbacks client et sont explicités dans les détails ; `finalMeasurement` porte le reçu serveur sans MAX ni échantillons inventés.
- `runTransferredBytes` décrit les payloads vus par les callbacks jusqu'au snapshot, pas la consommation IP/TCP/TLS ni les paquets que les APIs publiques ne rapportent pas.
- Le backend doit déployer les migrations/contrats compatibles avant distribution mobile. Aucun changement de build/version, signature, TestFlight ni CI distante effectué ici.


## Commande de vérification finale

```sh
xcodebuild -project SignalQuest.xcodeproj -scheme SignalQuest -configuration Debug \
  -destination 'platform=iOS Simulator,id=F6E6853F-2E26-45B3-BB8A-4C9D537EA3E6' \
  -derivedDataPath /tmp/sq-speedtest-v6-ios-derived \
  -only-testing:SignalQuestTests/SpeedtestV6ContractTests \
  -only-testing:SignalQuestTests/SpeedtestPeakWindowTests \
  -only-testing:SignalQuestTests/SpeedtestTests \
  -only-testing:SignalQuestTests/SpeedtestDetailSheetTests \
  -only-testing:SignalQuestTests/SpeedtestShareImageTests \
  -only-testing:SignalQuestTests/SpeedtestIcmpLiveProgressTests \
  -only-testing:SignalQuestTests/SpeedtestUploadStreamLadderTests \
  -only-testing:SignalQuestTests/CarPlaySpeedtestTests \
  -only-testing:SignalQuestTests/SQShareCardBuilderTests \
  -only-testing:SignalQuestTests/SQShareCardRenderTests \
  CODE_SIGNING_ALLOWED=NO test
```

Verdict local : **OK avec réserves de QA physique/VoiceOver/performance**. L'implémentation et les régressions de revue ci-dessus sont vérifiées localement ; la campagne appareil, les scénarios de mort de processus réels et la distribution restent à effectuer.
