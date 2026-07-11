#!/bin/sh

# Xcode Cloud hook. The target build phase runs the same validator again, but
# this early check fails before dependency compilation on a bad Beta workflow.

set -eu

if [ "${CONFIGURATION:-}" = "Staging" ]; then
  "${CI_PRIMARY_REPOSITORY_PATH:-$(pwd)}/ci_scripts/validate_build_environment.sh"
fi
