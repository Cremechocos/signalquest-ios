#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-all}"
IPHONE_DESTINATION="${SQ_IPHONE_DESTINATION:-platform=iOS Simulator,name=SQ-Test}"
IPAD_DESTINATION="${SQ_IPAD_DESTINATION:-platform=iOS Simulator,name=iPad (A16)}"
RESULT_ROOT="${SQ_RESULT_ROOT:-$ROOT/build/quality-gates}"
RUN_ID="${SQ_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
DERIVED_DATA="${SQ_DERIVED_DATA:-$RESULT_ROOT/$RUN_ID/DerivedData}"
# 'all' est le gate avant merge : il doit tout exécuter. 'debug' reste rapide
# pour les boucles de développement.
UI_SCOPE="${SQ_UI_SCOPE:-$([[ "$MODE" == "all" ]] && echo full || echo fast)}"

case "$MODE" in
  debug|staging|release|all) ;;
  *)
    echo "usage: $0 [debug|staging|release|all]" >&2
    exit 2
    ;;
esac

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  SELECTED_DEVELOPER_DIR="$(xcode-select -p 2>/dev/null || true)"
  if [[ "$SELECTED_DEVELOPER_DIR" == *"Xcode"* ]]; then
    export DEVELOPER_DIR="$SELECTED_DEVELOPER_DIR"
  elif [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  elif [[ -d /Applications/Xcode-beta.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
  else
    echo "error: Xcode introuvable; définir DEVELOPER_DIR." >&2
    exit 2
  fi
fi

mkdir -p "$RESULT_ROOT/$RUN_ID"

run_debug() {
  local result="$RESULT_ROOT/$RUN_ID/Debug-P0.xcresult"
  local -a scope_args=()

  # SQ_UI_SCOPE=fast (défaut) : unitaires + la seule classe UI déterministe.
  # SQ_UI_SCOPE=full : toute la suite UI. Les 7 classes gardées par
  # XCTSkipUnless (SQ_AUTH_TOKEN, SQ_E2EE_PASSWORD…) se signalent alors comme
  # « skipped » au lieu d'être invisibles — c'est le but : ne jamais laisser
  # croire qu'on a couvert 12 fichiers quand on n'en exécute qu'un.
  case "$UI_SCOPE" in
    fast)
      scope_args=(-only-testing:SignalQuestTests -only-testing:SignalQuestUITests/SignalQuestUITests)
      echo "== Debug: unitaires + parcours UI P0 sur iPhone (scope=fast) =="
      echo "   NOTE: 11 classes UI sur 12 ne sont PAS exécutées. SQ_UI_SCOPE=full pour la suite complète."
      ;;
    full)
      scope_args=()
      echo "== Debug: unitaires + suite UI complète sur iPhone (scope=full) =="
      ;;
    *)
      echo "error: SQ_UI_SCOPE doit valoir 'fast' ou 'full' (reçu: $UI_SCOPE)" >&2
      exit 2
      ;;
  esac

  xcodebuild test \
    -project "$ROOT/SignalQuest.xcodeproj" \
    -scheme SignalQuest \
    -configuration Debug \
    -destination "$IPHONE_DESTINATION" \
    -derivedDataPath "$DERIVED_DATA" \
    -resultBundlePath "$result" \
    -enableCodeCoverage YES \
    -parallel-testing-enabled NO \
    ${scope_args[@]+"${scope_args[@]}"} \
    CODE_SIGNING_ALLOWED=NO

  echo "== Debug: rotation et navigation iPad =="
  local ipad_result="$RESULT_ROOT/$RUN_ID/Debug-iPad.xcresult"
  xcodebuild test-without-building \
    -project "$ROOT/SignalQuest.xcodeproj" \
    -scheme SignalQuest \
    -configuration Debug \
    -destination "$IPAD_DESTINATION" \
    -derivedDataPath "$DERIVED_DATA" \
    -resultBundlePath "$ipad_result" \
    -parallel-testing-enabled NO \
    -only-testing:SignalQuestUITests/SignalQuestUITests/testIPadLandscapeKeepsPrimaryNavigationUsable \
    CODE_SIGNING_ALLOWED=NO

  "$ROOT/ci_scripts/check_coverage.sh" "$result"
  echo "Debug result bundle: $result"
  echo "iPad result bundle: $ipad_result"
}

run_staging() {
  echo "== Staging: build Beta isolée =="
  xcodebuild build \
    -project "$ROOT/SignalQuest.xcodeproj" \
    -scheme "SignalQuest Beta" \
    -configuration Staging \
    -destination "$IPHONE_DESTINATION" \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO
}

run_release() {
  echo "== Release: build optimisée sans signature =="
  xcodebuild build \
    -project "$ROOT/SignalQuest.xcodeproj" \
    -scheme SignalQuest \
    -configuration Release \
    -destination "$IPHONE_DESTINATION" \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO
}

case "$MODE" in
  debug) run_debug ;;
  staging) run_staging ;;
  release) run_release ;;
  all)
    run_debug
    run_staging
    run_release
    ;;
esac
