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
    signalquest.fr|api.signalquest.fr|speedtest.signalquest.fr|d2d31ihf1e95ah.cloudfront.net) return 0 ;;
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
validate_url SQ_SPEEDTEST_BASE_URL "${SQ_SPEEDTEST_BASE_URL:-}"
validate_url SQ_SPEEDTEST_DOWNLOAD_URL "${SQ_SPEEDTEST_DOWNLOAD_URL:-}"
validate_url SQ_SPEEDTEST_CLOUDFRONT_DOWNLOAD_URL "${SQ_SPEEDTEST_CLOUDFRONT_DOWNLOAD_URL:-}"

if [ "$environment" = "staging" ] && [ -f "${SRCROOT:-.}/SignalQuestApp/GoogleService-Info.plist" ]; then
  firebase_bundle="$(/usr/libexec/PlistBuddy -c 'Print :BUNDLE_ID' "${SRCROOT:-.}/SignalQuestApp/GoogleService-Info.plist" 2>/dev/null || true)"
  [ "$firebase_bundle" = "$bundle_id" ] || fail "Firebase BUNDLE_ID does not match the Beta bundle identifier"
fi

echo "SignalQuest environment validation passed ($configuration/$environment)."
