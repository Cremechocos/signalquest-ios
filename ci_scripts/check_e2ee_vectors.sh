#!/bin/bash

# Vecteurs E2EE partagés (spec §15) : identiques à l'octet dans les dépôts iOS,
# Android et serveur. Refuse tout vecteur ajouté, modifié ou retiré sans mise
# à jour de contracts/e2ee-v2/SHA256SUMS, qui sert aussi de référence aux
# autres dépôts.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/contracts/e2ee-v2"

expected="$(sort SHA256SUMS)"
actual="$(shasum -a 256 ./*.json | sed 's#  \./#  #' | sort)"

if [[ "$expected" != "$actual" ]]; then
  echo "error: les vecteurs E2EE et contracts/e2ee-v2/SHA256SUMS divergent :" >&2
  diff <(echo "$expected") <(echo "$actual") >&2 || true
  echo "Après une régénération voulue : (cd contracts/e2ee-v2 && shasum -a 256 *.json > SHA256SUMS)" >&2
  exit 1
fi

echo "Vecteurs E2EE : $(wc -l < SHA256SUMS | tr -d ' ') empreintes conformes."
