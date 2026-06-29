# SignalQuest iOS — Rapport d'exécution du plan (Phase D)

> Branche : `feature/audit-plan-execution` · Build : Xcode 27 (iphonesimulator), vérification par **compilation** (`xcodebuild build` / `build-for-testing`). **Aucun runtime simulateur installé** → tests et UX non exécutés ici (à lancer en CI/sur appareil).

## Principe appliqué
Chaque constat de l'audit a été **re-vérifié dans le code avant toute modification**. Résultat marquant : **la majorité des constats P0/P1 des agents étaient des faux positifs** (code déjà correct). Je n'ai modifié que ce qui correspond à un **vrai problème**, avec des diffs minimaux, et j'ai documenté tout ce qui a été écarté.

## Livré & committé (branche `feature/audit-plan-execution`)

| Commit | Lot | Contenu | Vérif |
|---|---|---|---|
| `e3a5e67d` | **0** | Hygiène dépôt : `git rm --cached` de `build/` (16 524 fichiers) + 2 fichiers de credentials de test ; `.gitignore` durci | `git ls-files` propre |
| `86c76db5` | **1** | **Drive Test — bon opérateur** : sélecteur manuel + feedback « non identifié » + couleur des marqueurs par opérateur + fan-out `/api/antennas` **parallélisé** | build OK |
| `0dec205a` | **2** | Test non-régression E2EE no-cleartext à la réception (`decryptText`) | build-for-testing OK |
| `dbbe1d11` | **3** | A11y : regroupement VoiceOver `MetricPill` + `CardMetricTile` | build OK |
| `d3ecf1df` | **5** | Retrait du **vrai** code mort `AntennasService.validate/reportIssue` (+ structs) | build-for-testing OK |

**Valeur réelle concentrée sur les Lots 0 et 1** (le bug produit du brief + la fuite de secrets).

## Constats d'audit INFIRMÉS après vérification (aucun changement nécessaire)

| Constat agent | Réalité vérifiée |
|---|---|
| Purge cookies logout incomplète (P0) | Couvre déjà les sous-domaines (`.hasSuffix(".signalquest.fr")`) |
| Flags QA non gardés `#if DEBUG` (P0) | **Sont** sous `#if DEBUG`, `false` en Release |
| Race continuations `LocationService` (P1) | Classe `@MainActor` + gardes anti-double-resume présentes |
| `defer` refresh `APIClient` non exécuté (P1) | `defer` correct sur tous les chemins |
| Keychain ne distingue pas item verrouillé/absent (P1) | `throw` déjà sur tout statut ≠ `errSecItemNotFound` |
| SSE sans hard-cap de reconnexion (P2) | Reconnexion infinie backoff ≤ 30 s = **correct** pour un flux temps réel |
| Speedtest streams non annulés (P2) | Annulation gérée (`session.data` async + `Task.isCancelled` + `SpeedtestURLSessionTaskBox`) |
| Double-envoi message (P1) | Bouton `.disabled(isSending)` + `Idempotency-Key` |
| Live Activity « Test 1/0 » (P0) | `isBurst = runTotal > 1` ⇒ `/0` jamais affiché |
| `CardActionsBar` icônes sans labels (P1) | **Déjà** entièrement labellisé (label/valeur/traits/hint/reduceMotion) |
| Services orphelins (PrivacyService, Validations, Reports, Gamification) (P2) | **Tous** injectés via `AppServices` ET utilisés par des vues |
| États « zombie » `showReportUser`/`showGroupSettings` (P2) | **Utilisés** (boutons + sheets) |

## Différé — action requise ou risque non vérifiable ici

| Item | Raison du report |
|---|---|
| **Certificate pinning** (`NSPinnedDomains`) | Nécessite les **empreintes SPKI réelles** des certificats prod. Un mauvais pin = panne réseau totale. **À fournir/valider par un humain.** |
| **Décomposition `MapExplorerView`** (3843 l.) | Refonte large et risquée ; la perf est **déjà** traitée (Lot 7). À faire comme effort dédié **avec vérification appareil**. |
| **Diff incrémental d'annotations** (Drive Test) | `syncSites` déjà signature-guardé ; gain modeste, régression de rendu **non vérifiable sans runtime**. |
| **Nettoyage auth dual cookie/Bearer** | Le backend lit le cookie aujourd'hui → **changement de comportement** ; à confirmer côté backend d'abord. |
| **Indicateur/arrêt auto tracking GPS** | Déjà mitigé (`onDisappear`→stop + panneau visible + indicateur système iOS) ; un arrêt auto nuirait aux longues sessions légitimes. |
| **Nouvelles fonctionnalités F1–F8** | Net-new, à **choisir** ; chacune mérite une vérification runtime/appareil que cet environnement ne permet pas. Cadrées dans `PLAN.md`. |

## Actions humaines (hors code, rappel)
1. **Rotation** des mots de passe des 2 comptes de test côté backend (ils ont fuité — repo public).
2. **Purge d'historique** Git (`git filter-repo` / BFG) pour effacer secrets + `build/` du passé.
3. Fournir les **empreintes SPKI** si l'on veut le certificate pinning.

## Pour lancer les tests (machine avec runtime simulateur)
```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
xcodegen generate
xcodebuild test -scheme SignalQuest -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

## Prochaine étape recommandée
Choisir 1–2 fonctionnalités parmi **F1–F8** (cf. `PLAN.md`) — p. ex. **F5 (timeline ANFR d'un site, lecture pure, API existante)** ou **F4 (App Intents/Siri élargis)** — à implémenter **avec vérification sur appareil**.
