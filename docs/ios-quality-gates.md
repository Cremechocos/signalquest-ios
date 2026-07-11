# Quality gates iOS

Ces commandes sont reproductibles localement et en CI. Elles ne modifient pas le
projet Xcode ni les sources, mais XCUITest installe et lance l'app, modifie les
permissions du simulateur et l'oriente pendant le test iPad. Utiliser des
simulateurs CI dédiés ou réinitialisables. Le script sélectionne Xcode stable en
priorité, puis Xcode bêta seulement si stable n'est pas installé.
`DEVELOPER_DIR` reste prioritaire.

## Commandes

```bash
./ci_scripts/run_ios_quality_gates.sh debug
./ci_scripts/run_ios_quality_gates.sh staging
./ci_scripts/run_ios_quality_gates.sh release
./ci_scripts/run_ios_quality_gates.sh all
```

Le gate Debug exécute tous les tests unitaires et la classe
`SignalQuestUITests` : login, cinq entrées, écrans principaux, carte et
speedtest invités, Communauté/Messages et profil. Le speedtest réel conditionné
par `SQ_AUTH_TOKEN` reste explicitement ignoré sans jeton et ne compte donc pas
comme couvert. Le script rejoue ensuite le test de navigation/rotation sur iPad
et contrôle la couverture. Les gates
Staging et Release vérifient des builds optimisés sans signature. Une archive de
distribution signée reste un gate Xcode Cloud/App Store Connect distinct :

```bash
xcodebuild archive \
  -project SignalQuest.xcodeproj \
  -scheme SignalQuest \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath build/SignalQuest.xcarchive
```

Variables utiles :

- `SQ_IPHONE_DESTINATION`, défaut `platform=iOS Simulator,name=SQ-Test` ;
- `SQ_IPAD_DESTINATION`, défaut `platform=iOS Simulator,name=iPad (A16)` ;
- `SQ_RESULT_ROOT`, `SQ_RUN_ID` et `SQ_DERIVED_DATA` pour les artefacts ;
- `DEVELOPER_DIR` pour pinner la version Xcode retenue par Apple.

La configuration Staging contient volontairement des domaines `.invalid` tant
que l'infrastructure isolée et le plist Firebase Beta ne sont pas fournis. Son
échec dans cet état est un garde-fou attendu, pas un contournement à désactiver.

## Couverture

Le gate lit le `.xcresult` avec `xccov` et applique par défaut :

- lignes applicatives : 70 % ;
- branches : 60 % lorsqu'un rapport xccov expose cette métrique ;
- logique critique listée dans `ci_scripts/critical_coverage_paths.txt` : 90 %.

Les seuils sont paramétrables avec `SQ_LINE_COVERAGE_MIN`,
`SQ_BRANCH_COVERAGE_MIN` et `SQ_CRITICAL_COVERAGE_MIN`. La cible peut être
sélectionnée via la regex `SQ_COVERAGE_TARGET`. Une autre liste de fichiers
critiques peut être fournie par `SQ_CRITICAL_COVERAGE_PATHS`.

Xcode 27 expose les lignes mais pas les branches dans le JSON `xccov`. Le script
signale donc explicitement le gate branches comme indisponible. Pour imposer un
échec tant qu'un outil de couverture de branches n'est pas branché, définir
`SQ_REQUIRE_BRANCH_COVERAGE=1`.

Exécution isolée :

```bash
SQ_LINE_COVERAGE_MIN=70 \
SQ_BRANCH_COVERAGE_MIN=60 \
SQ_CRITICAL_COVERAGE_MIN=90 \
./ci_scripts/check_coverage.sh build/quality-gates/<run>/Debug-P0.xcresult
```

## Ce qui reste hors simulateur

- iOS 16, 17 et 18 nécessitent les runtimes correspondants ; ce poste ne possède
  actuellement que le runtime iOS 27 ;
- Split View et le redimensionnement multitâche doivent être contrôlés sur iPad
  réel ou manuellement, XCUITest ne fournit pas un pilotage stable de cette UI
  système ;
- lancement froid, FPS carte, mémoire soutenue, appels, APNs, BackgroundTasks,
  réseau cellulaire et PiP doivent être mesurés sur appareils physiques ;
- les parcours staging bout en bout nécessitent les endpoints, secrets et
  datasets synthétiques du VPS staging isolé.
