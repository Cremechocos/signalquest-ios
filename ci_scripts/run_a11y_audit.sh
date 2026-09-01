#!/bin/bash

# Lance l'auditeur d'accessibilité d'Apple sur les écrans principaux et imprime
# le relevé par écran et par type.
#
# À comparer avec docs/ACCESSIBILITY_BASELINE.md : le total ne doit jamais
# remonter. Les écrans migrés sont bloquants : le rapport reste imprimé, puis
# le statut xcodebuild est propagé pour que la CI refuse une régression.
#
# Usage :
#     ./ci_scripts/run_a11y_audit.sh [udid-ou-nom-de-simulateur]

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Le collecteur de diagnostics d'xcodebuild lance `xcrun simctl` sans hériter de
# DEVELOPER_DIR : sans simctl dans le PATH, le run échoue en erreur 72.
if [[ -d /Applications/Xcode-beta.app ]]; then
  export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
fi
[[ -n "${DEVELOPER_DIR:-}" ]] && export PATH="$DEVELOPER_DIR/usr/bin:$PATH"

DEST="${1:-platform=iOS Simulator,name=iPhone 17 Pro}"
[[ "$DEST" != platform=* ]] && DEST="platform=iOS Simulator,id=$DEST"

LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT

set +e
xcodebuild test -scheme SignalQuest -destination "$DEST" \
  -only-testing:SignalQuestUITests/AccessibilityAuditTests > "$LOG" 2>&1
status=$?
set -e

if ! grep -q 'SQ_A11Y' "$LOG"; then
  echo "Aucun relevé produit — l'audit n'a pas tourné. Dernières erreurs :" >&2
  grep -E 'error:|Testing failed' "$LOG" | sort -u | head -5 >&2
  exit 1
fi

echo "── par écran ──"
grep -E '^SQ_A11Y [^ ]+ :' "$LOG" | sed 's/^SQ_A11Y /  /'

echo "── par type ──"
grep -oE '\[[^]]+\]' "$LOG" | sort | uniq -c | sort -rn | sed 's/^/  /'

total="$(grep -cE '^SQ_A11Y   \[' "$LOG")"
echo "── total : $total ──"
echo "Baseline de référence : docs/ACCESSIBILITY_BASELINE.md"
exit "$status"
