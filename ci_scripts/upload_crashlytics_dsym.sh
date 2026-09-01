#!/bin/sh

# Téléverse les symboles de debug (dSYM) vers Crashlytics après compilation.
#
# Sans cette étape, les rapports de crash arrivent NON SYMBOLISÉS : on obtient
# des adresses mémoire au lieu de noms de fonctions, ce qui les rend
# inexploitables. C'est l'oubli classique d'une intégration Crashlytics.
#
# Le script est volontairement tolérant : il sort en succès (avec un warning
# visible dans le log de build) plutôt que de casser le build quand les
# conditions ne sont pas réunies. Un contributeur sans `GoogleService-Info.plist`
# — le fichier est gitignoré, cf. AppDelegate — doit pouvoir compiler.

set -eu

configuration="${CONFIGURATION:-}"
platform="${PLATFORM_NAME:-}"

skip() {
  echo "warning: upload dSYM Crashlytics ignoré — $*"
  exit 0
}

# Debug produit `dwarf` sans bundle dSYM (cf. DEBUG_INFORMATION_FORMAT) : rien à
# téléverser, et on évite un appel réseau à chaque compilation locale.
[ "$configuration" != "Debug" ] || exit 0

# Un dSYM de simulateur ne peut symboliser aucun crash d'un iPhone et pollue le
# projet Crashlytics. Les builds Release locaux doivent donc rester hors ligne.
case "$platform" in
  *simulator*) exit 0 ;;
esac

plist="${SRCROOT:-.}/SignalQuestApp/GoogleService-Info.plist"
[ -f "$plist" ] || skip "GoogleService-Info.plist absent"

# Le SDK est résolu par SwiftPM ; son emplacement dérive de BUILD_DIR.
run="${BUILD_DIR%/Build/*}/SourcePackages/checkouts/firebase-ios-sdk/Crashlytics/run"
[ -x "$run" ] || skip "script Crashlytics introuvable ($run)"

dsym="${DWARF_DSYM_FOLDER_PATH:-}/${DWARF_DSYM_FILE_NAME:-}"
[ -d "$dsym" ] || skip "bundle dSYM introuvable ($dsym)"

"$run" -gsp "$plist"
echo "dSYM Crashlytics téléversés ($configuration)."
