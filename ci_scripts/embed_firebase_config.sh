#!/bin/sh

# Le plist Firebase est injecté après le clone par Xcode Cloud et reste absent du
# dépôt public. Une phase Resources statique rendrait donc tout checkout propre
# impossible à compiler. Cette phase l'embarque quand il existe et conserve le
# mode dégradé explicite d'AppDelegate dans le cas contraire.

set -eu

source_plist="${SRCROOT:-.}/SignalQuestApp/GoogleService-Info.plist"
resources_dir="${TARGET_BUILD_DIR:-}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}"

if [ -f "$source_plist" ]; then
  mkdir -p "$resources_dir"
  cp "$source_plist" "$resources_dir/GoogleService-Info.plist"
  echo "Firebase config embedded."
else
  rm -f "$resources_dir/GoogleService-Info.plist"
  echo "warning: GoogleService-Info.plist absent; Firebase push and Crashlytics stay disabled."
fi
