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

## CarPlay

Rien de CarPlay n'est vérifiable en XCUITest : les templates sont rendus par
l'interface du véhicule, **hors du process de l'app**, et `XCUIApplication` n'y a
pas accès. Les tests unitaires couvrent donc les parties pures — construction des
templates, suivi d'itinéraire, budget de recalcul, cadence des annonces, plafonds
du SDK — et tout le reste se contrôle à la main.

Prérequis de test :

- l'écran CarPlay du **simulateur** demande `Simulator.app`, qu'Xcode 27
  n'embarque plus (ses seules apps sont Create ML, Instruments, DeviceHub,
  FileMerge, Icon Composer, Accessibility Inspector) : installer un Xcode stable
  à côté ;
- l'entitlement doit être présent dans le binaire. Le simulateur signe en ad-hoc
  avec `ENTITLEMENTS_REQUIRED = NO` et n'embarque **aucun** entitlement — pointer
  `SQ_ENTITLEMENTS` sur `SignalQuest.CarPlay.entitlements` via un
  `Config/Local.xcconfig` git-ignoré (voir le commentaire en tête de ce fichier).

À contrôler en véhicule, dans cet ordre :

1. **connexion de la scène** — app fermée (le véhicule lance l'app en
   arrière-plan, la fenêtre iPhone peut ne jamais apparaître), puis app ouverte ;
2. **lisibilité** — thème jour/nuit du véhicule, longueur des libellés sur
   l'écran le plus étroit, marqueurs et lobes d'azimut ;
3. **guidage** — manœuvres, ETA, annonces vocales, sortie de route volontaire :
   vérifier qu'un aller-retour sur la limite ne déclenche pas une rafale de
   `MKDirections` (throttlé par Apple) ;
4. **arbitrage audio** — appel LiveKit reçu PENDANT un guidage : les annonces
   doivent se taire, pas se superposer. Écrit mais non testable automatiquement,
   c'est le point le plus important de cette liste ;
5. **alertes** — zone mal couverte, avec et sans la scène au premier plan (les
   deux chemins sont exclusifs, l'alerte ne doit jamais arriver en double) ;
6. **véhicule à molette** — vérifier que tout reste atteignable sans écran
   tactile, via « Autour de toi » et « Récents » ;
7. **coupure réseau** en cours de guidage, et **déconnexion** du véhicule : plus
   aucun timer, abonnement de position ni assertion d'arrière-plan ne doit
   survivre ;
8. **batterie et données** sur un trajet réel — GPS haute précision, tuiles
   denses et recalculs ne se mesurent pas au simulateur.

Deux dépendances externes conditionnent l'usage réel : l'entitlement
`com.apple.developer.carplay-maps`, à obtenir d'Apple, et l'ajout de
`"category": "SENTINELLE_ALERT"` au payload APNs côté backend — sans lui, les
alertes Sentinelle n'atteignent jamais l'écran du véhicule, quelle que soit la
configuration de l'app.
