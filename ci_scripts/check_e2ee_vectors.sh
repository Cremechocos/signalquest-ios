#!/bin/bash

# Vecteurs E2EE partagés (spec §15, contrat E2EE-AUTO §11) : identiques à
# l'octet dans les dépôts iOS, Android et serveur. Refuse tout vecteur ajouté,
# modifié ou retiré sans mise à jour du SHA256SUMS de son dossier, qui sert
# aussi de référence aux autres dépôts.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

for dir in e2ee-v2 e2ee-auto; do
  cd "$ROOT/contracts/$dir"

  expected="$(sort SHA256SUMS)"
  actual="$(shasum -a 256 ./*.json | sed 's#  \./#  #' | sort)"

  if [[ "$expected" != "$actual" ]]; then
    echo "error: les vecteurs E2EE et contracts/$dir/SHA256SUMS divergent :" >&2
    diff <(echo "$expected") <(echo "$actual") >&2 || true
    echo "Après une régénération voulue : (cd contracts/$dir && shasum -a 256 *.json > SHA256SUMS)" >&2
    exit 1
  fi

  echo "Vecteurs E2EE ($dir) : $(wc -l < SHA256SUMS | tr -d ' ') empreintes conformes."
done
