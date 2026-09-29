#!/bin/sh

# Xcode Cloud hook. Après une archive réussie, envoie ses dSYM à Crashlytics :
# la phase de build peut sauter en silence (OBS-01), cette étape échoue si
# l'envoi est impossible plutôt que de distribuer une build sans symboles.

set -eu

[ "${CI_XCODEBUILD_ACTION:-}" = "archive" ] || exit 0
[ "${CI_XCODEBUILD_EXIT_CODE:-0}" = "0" ] || exit 0
[ -n "${CI_ARCHIVE_PATH:-}" ] || exit 0

"${CI_PRIMARY_REPOSITORY_PATH:-$(pwd)}/ci_scripts/upload_archive_dsyms.sh" \
  "$CI_ARCHIVE_PATH" "${CI_DERIVED_DATA_PATH:-}/SourcePackages"
