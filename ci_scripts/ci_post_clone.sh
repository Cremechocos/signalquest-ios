#!/bin/sh

#  ci_post_clone.sh
#  Exécuté automatiquement par Xcode Cloud juste après le clone du dépôt,
#  avant la résolution des dépendances et le build.
#
#  GoogleService-Info.plist est gitignoré (le dépôt est PUBLIC) → il est absent
#  du clone Xcode Cloud. On le régénère ici depuis une variable d'environnement
#  SECRÈTE contenant le plist encodé en base64. Le schéma Beta exige le
#  projet Firebase staging ; les autres schémas utilisent le projet production.
#
#  À définir une fois dans :
#    App Store Connect ▸ Xcode Cloud ▸ (workflow) ▸ Environment ▸
#    Environment Variables ▸ + ▸ noms =
#      GOOGLE_SERVICE_INFO_STAGING_PLIST_BASE64
#      GOOGLE_SERVICE_INFO_PRODUCTION_PLIST_BASE64
#    valeur = <base64 du plist>, case « Secret » COCHÉE.

set -e

case "${CI_XCODE_SCHEME:-}" in
  "SignalQuest Beta")
    FIREBASE_BASE64="${GOOGLE_SERVICE_INFO_STAGING_PLIST_BASE64:-}"
    FIREBASE_VARIABLE="GOOGLE_SERVICE_INFO_STAGING_PLIST_BASE64"
    ;;
  *)
    FIREBASE_BASE64="${GOOGLE_SERVICE_INFO_PRODUCTION_PLIST_BASE64:-${GOOGLE_SERVICE_INFO_PLIST_BASE64:-}}"
    FIREBASE_VARIABLE="GOOGLE_SERVICE_INFO_PRODUCTION_PLIST_BASE64"
    ;;
esac

if [ -z "$FIREBASE_BASE64" ]; then
  echo "error: variable secrète $FIREBASE_VARIABLE absente de l'environnement Xcode Cloud."
  echo "       → App Store Connect ▸ Xcode Cloud ▸ Workflow ▸ Environment ▸ Environment Variables (Secret)."
  exit 1
fi

DEST="$CI_PRIMARY_REPOSITORY_PATH/SignalQuestApp/GoogleService-Info.plist"

# Décodage base64 robuste selon la version de base64 du runner macOS
# (--decode récent, -D façon BSD, openssl en dernier recours).
printf '%s' "$FIREBASE_BASE64" | base64 --decode > "$DEST" 2>/dev/null \
  || printf '%s' "$FIREBASE_BASE64" | base64 -D > "$DEST" 2>/dev/null \
  || printf '%s' "$FIREBASE_BASE64" | openssl base64 -d -A > "$DEST"

if [ ! -s "$DEST" ]; then
  echo "error: GoogleService-Info.plist vide après décodage — la base64 est-elle valide ?"
  exit 1
fi

echo "✅ GoogleService-Info.plist régénéré → $DEST"
