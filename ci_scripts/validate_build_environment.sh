#!/bin/sh

# Fail closed when a Beta points to production or when a distribution build
# still contains placeholder staging services. Xcode invokes this as a build
# phase; it can also be called directly with build-setting overrides.

set -eu

configuration="${CONFIGURATION:-}"
environment="${SQ_ENVIRONMENT:-}"
bundle_id="${PRODUCT_BUNDLE_IDENTIFIER:-}"

fail() {
  echo "error: SignalQuest environment validation failed: $*" >&2
  exit 1
}

url_host() {
  printf '%s' "$1" | sed -E 's#^[A-Za-z][A-Za-z0-9+.-]*://([^/:]+).*$#\1#' | tr '[:upper:]' '[:lower:]'
}

is_production_host() {
  case "$1" in
    signalquest.fr|api.signalquest.fr) return 0 ;;
    *) return 1 ;;
  esac
}

validate_url() {
  key="$1"
  value="$2"
  [ -n "$value" ] || fail "$key is empty"
  host="$(url_host "$value")"
  [ -n "$host" ] || fail "$key is not an absolute URL"

  if [ "$environment" = "staging" ]; then
    is_production_host "$host" && fail "$key points to production ($host)"
    case "$host" in
      *.invalid) [ "${SQ_ALLOW_PLACEHOLDER_STAGING:-NO}" = "YES" ] || fail "$key still uses placeholder host $host" ;;
    esac
  fi
}

case "$configuration" in
  Staging)
    [ "$environment" = "staging" ] || fail "Staging configuration must set SQ_ENVIRONMENT=staging"
    [ "$bundle_id" = "fr.signalquest.ios.beta" ] || fail "Staging bundle identifier must be fr.signalquest.ios.beta"
    ;;
  Release)
    [ "$environment" = "production" ] || fail "Release configuration must set SQ_ENVIRONMENT=production"
    [ "$bundle_id" = "fr.signalquest.ios" ] || fail "Release bundle identifier must be fr.signalquest.ios"
    ;;
  Debug)
    [ "$environment" = "development" ] || fail "Debug configuration must set SQ_ENVIRONMENT=development"
    ;;
esac

validate_url SQ_APP_BASE_URL "${SQ_APP_BASE_URL:-}"
validate_url SQ_API_BASE_URL "${SQ_API_BASE_URL:-}"

# --- Garde-fou anti-récidive sur le code QA (SECURITY-04) -------------------
# Un binaire de distribution ne doit contenir ni jeu de démonstration (URLs S3
# et identifiants de photos de PRODUCTION, amis fictifs) ni lecture d'argument
# de lancement hors des accesseurs gardés d'AppEnvironment. Deux invariants,
# vérifiés sur les sources parce qu'ils sont structurels et donc stables :
#   1. `ProcessInfo.processInfo.arguments` et le préfixe `--qa-` n'existent que
#      dans AppEnvironment.swift, où ils sont derrière #if DEBUG ;
#   2. aucune URL S3 hors d'une région #if DEBUG.
if [ "$configuration" != "Debug" ]; then
  sources="${SRCROOT:-.}/SignalQuestApp"

  # `code_hits` ignore les lignes de commentaire : documenter un drapeau dans un
  # doc-comment est légitime, seul le code compilé compte.
  code_hits() {
    grep -rn "$1" "$sources" --include='*.swift' 2>/dev/null \
      | grep -v '^[^:]*/AppEnvironment\.swift:' \
      | awk -F: '{ line=$0; sub(/^[^:]*:[0-9]+:[[:space:]]*/, "", line); if (line !~ /^(\/\/|\*|\/\*)/) print $1 ":" $2 }' \
      || true
  }

  strays="$(code_hits 'ProcessInfo\.processInfo\.arguments')"
  [ -z "$strays" ] || fail "lecture d'arguments de lancement hors AppEnvironment : $(echo "$strays" | tr '\n' ' ')"

  strays="$(code_hits '"--qa-')"
  [ -z "$strays" ] || fail "drapeau --qa- référencé dans du code hors AppEnvironment : $(echo "$strays" | tr '\n' ' ')"

  # Suit l'imbrication des directives pour ne signaler que ce qui est réellement
  # compilé en distribution (le corps d'un #else de #if DEBUG en fait partie).
  leaks="$(find "$sources" -name '*.swift' -exec awk '
    /^[[:space:]]*#if[[:space:]]+DEBUG/ { stack[++d]="D"; next }
    /^[[:space:]]*#if/                  { stack[++d]="O"; next }
    /^[[:space:]]*#else/                { if (d>0 && stack[d]=="D") stack[d]="E"; next }
    /^[[:space:]]*#endif/               { if (d>0) d--; next }
    {
      inDebug=0
      for (i=1;i<=d;i++) if (stack[i]=="D") inDebug=1
      if (!inDebug && $0 ~ /s3\.signalquest\.fr/) print FILENAME ":" FNR
    }' {} + 2>/dev/null || true)"
  [ -z "$leaks" ] || fail "URL S3 de production hors #if DEBUG : $(echo "$leaks" | tr '\n' ' ')"
fi

if [ "$environment" = "staging" ] && [ -f "${SRCROOT:-.}/SignalQuestApp/GoogleService-Info.plist" ]; then
  firebase_bundle="$(/usr/libexec/PlistBuddy -c 'Print :BUNDLE_ID' "${SRCROOT:-.}/SignalQuestApp/GoogleService-Info.plist" 2>/dev/null || true)"
  [ "$firebase_bundle" = "$bundle_id" ] || fail "Firebase BUNDLE_ID does not match the Beta bundle identifier"
fi

echo "SignalQuest environment validation passed ($configuration/$environment)."
