#!/bin/sh

#  ci_post_clone.sh
#  Exécuté automatiquement par Xcode Cloud juste après le clone du dépôt,
#  avant la résolution des dépendances et le build.
#
#  GoogleService-Info.plist est gitignoré (le dépôt est PUBLIC) → il est absent
#  du clone Xcode Cloud. On le régénère ici depuis une variable d'environnement
#  SECRÈTE contenant le plist encodé en base64.
#
#  À définir une fois dans :
#    App Store Connect ▸ Xcode Cloud ▸ (workflow) ▸ Environment ▸
#    Environment Variables ▸ + ▸ nom = GOOGLE_SERVICE_INFO_PLIST_BASE64,
#    valeur = <base64 du plist>, case « Secret » COCHÉE.

set -e

if [ -z "$GOOGLE_SERVICE_INFO_PLIST_BASE64" ]; then
  echo "error: variable secrète GOOGLE_SERVICE_INFO_PLIST_BASE64 absente de l'environnement Xcode Cloud."
  echo "       → App Store Connect ▸ Xcode Cloud ▸ Workflow ▸ Environment ▸ Environment Variables (Secret)."
  exit 1
fi

DEST="$CI_PRIMARY_REPOSITORY_PATH/SignalQuestApp/GoogleService-Info.plist"

# Décodage base64 robuste selon la version de base64 du runner macOS
# (--decode récent, -D façon BSD, openssl en dernier recours).
printf '%s' "$GOOGLE_SERVICE_INFO_PLIST_BASE64" | base64 --decode > "$DEST" 2>/dev/null \
  || printf '%s' "$GOOGLE_SERVICE_INFO_PLIST_BASE64" | base64 -D > "$DEST" 2>/dev/null \
  || printf '%s' "$GOOGLE_SERVICE_INFO_PLIST_BASE64" | openssl base64 -d -A > "$DEST"

if [ ! -s "$DEST" ]; then
  echo "error: GoogleService-Info.plist vide après décodage — la base64 est-elle valide ?"
  exit 1
fi

echo "✅ GoogleService-Info.plist régénéré → $DEST"
