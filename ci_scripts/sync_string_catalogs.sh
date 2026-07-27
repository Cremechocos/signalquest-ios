#!/bin/bash

# Met à jour les String Catalogs à partir des chaînes réellement compilées.
#
# Pourquoi un script : Xcode ne verse les `.stringsdata` produits par le
# compilateur dans les `.xcstrings` que lors d'un build DANS L'IDE. En ligne de
# commande, `xcodebuild` les produit mais ne les fusionne pas — le catalogue
# resterait figé et les nouvelles chaînes n'apparaîtraient jamais.
#
# À lancer après avoir ajouté ou modifié des libellés :
#
#     ./ci_scripts/sync_string_catalogs.sh
#
# Le catalogue reste en français seul tant qu'aucune traduction n'est fournie :
# sans valeur pour la langue source, la clé EST la valeur, donc l'app est
# inchangée. C'est ce qui rend l'extraction sûre à tout moment.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="${SQ_DERIVED_DATA:-$ROOT/build/string-catalog-sync}"
DESTINATION="${SQ_IPHONE_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro}"

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  SELECTED="$(xcode-select -p 2>/dev/null || true)"
  if [[ "$SELECTED" == *"Xcode"* ]]; then
    export DEVELOPER_DIR="$SELECTED"
  elif [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  elif [[ -d /Applications/Xcode-beta.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
  else
    echo "error: Xcode introuvable ; définir DEVELOPER_DIR." >&2
    exit 2
  fi
fi

TOOL="$DEVELOPER_DIR/usr/bin/xcstringstool"
[[ -x "$TOOL" ]] || { echo "error: xcstringstool introuvable ($TOOL)" >&2; exit 2; }

echo "== Compilation (production des .stringsdata) =="
xcodebuild build \
  -project "$ROOT/SignalQuest.xcodeproj" \
  -scheme SignalQuest \
  -configuration Debug \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO >/dev/null

sync_target() {
  local catalog="$1" build_dir_pattern="$2" exclude="${3:-}" label="$4"
  local list
  list="$(mktemp)"
  if [[ -n "$exclude" ]]; then
    find "$DERIVED" -name '*.stringsdata' -path "$build_dir_pattern" -not -path "$exclude" -print0 > "$list"
  else
    find "$DERIVED" -name '*.stringsdata' -path "$build_dir_pattern" -print0 > "$list"
  fi
  local count
  count="$(tr -dc '\0' < "$list" | wc -c | tr -d ' ')"
  if [[ "$count" == "0" ]]; then
    echo "warning: aucun .stringsdata pour $label — catalogue inchangé"
    rm -f "$list"
    return
  fi
  xargs -0 "$TOOL" sync "$catalog" --stringsdata < "$list"
  rm -f "$list"
  echo "  $label : $count unités compilées → $catalog"
}

echo "== Fusion dans les catalogues =="
sync_target "$ROOT/SignalQuestApp/Resources/Localizable.xcstrings" \
  '*SignalQuest.build*' '*Widget*' "app"
sync_target "$ROOT/SignalQuestWidget/Localizable.xcstrings" \
  '*SignalQuestWidget.build*' '' "widget"

for catalog in "$ROOT/SignalQuestApp/Resources/Localizable.xcstrings" \
               "$ROOT/SignalQuestWidget/Localizable.xcstrings"; do
  keys="$(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1])).get('strings',{})))" "$catalog")"
  echo "  $(basename "$(dirname "$catalog")")/$(basename "$catalog") : $keys clés"
done

echo "Synchronisation terminée."
