# SignalQuest iOS

> Langue / ton / posture : voir `~/.claude/CLAUDE.md` (global).
> Détail : `README.md` (meilleure source), `docs/ios-quality-gates.md`,
> `docs/backend-ios-additive-routes.md`, `DESIGN.md`.

## Projet (vérifié)
- App **SwiftUI-first + interop UIKit**. Entrée : `@main struct SignalQuestApp`
  (`SignalQuestApp/SignalQuestApp.swift`) → `AppDelegate` UIKit via
  `@UIApplicationDelegateAdaptor` (`Core/Push/AppDelegate.swift`,
  `FirebaseApp.configure()`). Pas de SceneDelegate. Cible **iOS 16.0**,
  **Swift 6.0**, iPhone + iPad. Langue de dev : **français**.
- Bundle id `fr.signalquest.ios` (Staging → `.beta`).
- Dépendances **SPM uniquement** (pas de CocoaPods/Carthage) : LiveKit 2.14
  (appels), Firebase 12.13 (**Messaging + Crashlytics** seulement — Analytics
  retiré volontairement). ~218 fichiers Swift.

## ⚠️ XcodeGen fait autorité
- Le `.xcodeproj` est **généré** par XcodeGen depuis **`project.yml`** (la source
  de vérité, git-suivie). Le `.pbxproj` est aussi committé mais **régénéré** :
  **n'édite jamais le `.pbxproj` à la main** — modifie `project.yml` puis lance
  `xcodegen generate`.
- Les lignes `FirebaseMessaging` / `FirebaseCrashlytics` de `project.yml` doivent
  rester déclarées explicitement, sinon la régénération casse le lien (noté en
  commentaire dans le fichier).

## Build / test (vérifié)
- **Chemin préféré** : le runner du repo
  `ci_scripts/run_ios_quality_gates.sh [debug|staging|release|all]`
  (tests iPhone + iPad + couverture via `check_coverage.sh`).
- Build direct :
  ```
  xcodebuild build -project SignalQuest.xcodeproj -scheme SignalQuest \
    -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
    CODE_SIGNING_ALLOWED=NO
  ```
- Test direct : `xcodebuild test -project SignalQuest.xcodeproj -scheme SignalQuest -destination 'platform=iOS Simulator,name=iPhone 16 Pro'`.
- ⚠️ Deux schemes : **`SignalQuest`** et **`SignalQuest Beta`** (avec un espace).
- **Aucun** SwiftLint / SwiftFormat — style par convention. Pas de Fastlane/Makefile.
- Avant de supposer une destination, vérifie les runtimes installés
  (`xcrun simctl list runtimes`) — l'environnement a connu des dérives Xcode 26/27.

## Architecture
- `Core/` (Networking, Security/Keychain, Realtime/LiveKit, Push, Cache),
  `Features/` (18 modules SwiftUI), `Models/` (Codable), `Services/` (~30, agrégés
  par `AppServices.swift`, injectés en `@EnvironmentObject`), `Design/` (design
  system préfixé `SQ*`, « SignalQuest Crème »).
- Réseau : `APIClient` maison sur **URLSession** (pas d'Alamofire). Auth **par
  cookie** (`auth_token`, stocké Keychain, rejoué en `Cookie:`) ; coalescence des
  refresh sur 401. URLs via `AppConfig.swift` (clés Info.plist `SQ_API_BASE_URL` /
  `SQ_APP_BASE_URL` ; prod `api.signalquest.fr` / `signalquest.fr`).
- Persistance : **SwiftData** (`@Model`, sessions/speedtests) + **Keychain**
  (auth + clés E2EE) + caches fichiers. Pas de CoreData.

## Landmines
- **Garde-fou d'environnement** : `ci_scripts/validate_build_environment.sh`
  (phase pré-build) **échoue** si un build Staging/Beta pointe vers la prod, ou si
  Staging garde les hôtes placeholder `.invalid`. Ces placeholders sont
  **volontaires** — un Beta doit les surcharger ; l'échec dans cet état est normal.
- **Feature flags = constantes compile-time** (`enum SQFeatures` dans
  `AppConfig.swift`), pas de remote config. Pour changer, on modifie la constante
  et on recompile.
- **Secrets non commités** : `GoogleService-Info.plist` (git-ignoré, fourni hors
  repo), clés `.p8`, `.env*`, `TestArtifacts/`. Ne jamais hardcoder de secret.
- **iOS ne lit pas les métriques radio** (RSRP/PCI/Cell ID… impossibles) — c'est
  **volontaire** : tech grossière seulement, le détail radio vient du serveur.
  Ne tente pas d'ajouter du scan modem.
- Dans les `.xcconfig`, l'idiome `https:/$()/host` échappe le `//` — **ne pas le
  « corriger »**.
