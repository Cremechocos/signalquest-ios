#!/bin/sh

# Téléverse vers Crashlytics les dSYM d'une ARCHIVE, une fois `xcodebuild archive`
# terminé.
#
# La phase de build « Upload Crashlytics dSYM » peut sauter sans bruit : quand
# `-clonedSourcePackagesDirPath` déplace les paquets SwiftPM, elle ne trouve pas
# l'outil Firebase et sort en simple avertissement. La 1.0 (159) est partie ainsi
# sans symboles (OBS-01). Lancée hors du build, sur l'archive finale, cette étape
# échoue au contraire bruyamment : une build de test ne part plus sans symboles.
#
# Usage : upload_archive_dsyms.sh <archive.xcarchive> [dossier SourcePackages]
# (Xcode Cloud : appelé par ci_post_xcodebuild.sh ; en local : après l'archive.)

set -eu

archive="${1:?usage: upload_archive_dsyms.sh <archive.xcarchive> [dossier SourcePackages]}"
packages="${2:-${SQ_SOURCE_PACKAGES_DIR:-}}"
root="$(cd "$(dirname "$0")/.." && pwd)"
plist="${SQ_FIREBASE_CONFIG_PATH:-$root/SignalQuestApp/GoogleService-Info.plist}"

fail() {
  echo "error: dSYM Crashlytics non envoyés — $*" >&2
  exit 1
}

[ -d "$archive/dSYMs" ] || fail "aucun dossier dSYMs dans $archive"
[ -f "$plist" ] || fail "GoogleService-Info.plist absent ($plist)"

tool=""
for candidate in \
  "$packages/checkouts/firebase-ios-sdk/Crashlytics/upload-symbols" \
  "${CI_DERIVED_DATA_PATH:-}/SourcePackages/checkouts/firebase-ios-sdk/Crashlytics/upload-symbols"; do
  if [ -x "$candidate" ]; then
    tool="$candidate"
    break
  fi
done
[ -n "$tool" ] || fail "outil upload-symbols introuvable (indiquer le dossier SourcePackages)"

count=0
for dsym in "$archive"/dSYMs/*.dSYM; do
  [ -d "$dsym" ] && count=$((count + 1))
done
[ "$count" -gt 0 ] || fail "aucun bundle dSYM dans $archive"

"$tool" -gsp "$plist" -p ios "$archive/dSYMs"
echo "dSYM Crashlytics envoyés : $count bundle(s) de $(basename "$archive")."
