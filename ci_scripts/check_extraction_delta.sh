#!/bin/bash

# Vérifie qu'un commit d'EXTRACTION n'a fait que déplacer du code.
#
# Le risque d'une découpe de gros fichier n'est pas de casser la compilation —
# le compilateur le dit. C'est d'en profiter pour « améliorer au passage » : un
# renommage, une réindentation, une condition simplifiée. Ces changements se
# fondent dans un diff de plusieurs milliers de lignes et deviennent
# indétectables à la relecture.
#
# Le contrat : un commit d'extraction a un delta NORMALISÉ vide. Autrement dit,
# l'ensemble des lignes retirées est exactement l'ensemble des lignes ajoutées,
# une fois neutralisés l'indentation et les mots-clés d'accès (une déclaration
# `private` qui sort de son fichier doit devenir `internal`).
#
# Usage :
#     git add -A && ./ci_scripts/check_extraction_delta.sh [base]
#
# Les changements doivent être INDEXÉS : une extraction crée des fichiers neufs,
# et `git diff` seul ignore les fichiers non suivis — il ne verrait que les
# suppressions et conclurait à tort que du code a été perdu. Le script refuse de
# se prononcer si l'arbre contient des fichiers Swift non indexés.
#
# `base` par défaut : HEAD. Passer un SHA pour vérifier un commit déjà écrit.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE="${1:-HEAD}"
cd "$ROOT"

normalize() {
  # Retire l'indentation, les lignes vides, et les mots-clés d'accès qui
  # changent légitimement quand une déclaration quitte son fichier d'origine.
  sed -E \
    -e 's/^[[:space:]]+//' \
    -e 's/[[:space:]]+$//' \
    -e 's/^(private|fileprivate|internal|public) //' \
    -e 's/(^|[[:space:]])(private|fileprivate)[[:space:]]+(var|let|func|struct|enum|class|extension|init)/\1\3/g' \
  | grep -v '^$' \
  | LC_ALL=C sort
}

untracked="$(git ls-files --others --exclude-standard -- '*.swift')"
if [[ -n "$untracked" ]]; then
  echo "error: fichiers Swift non indexés — le verdict serait faux." >&2
  echo "$untracked" | sed 's/^/  /' >&2
  echo "Lancer d'abord : git add -A" >&2
  exit 2
fi

added="$(mktemp)"; removed="$(mktemp)"
trap 'rm -f "$added" "$removed"' EXIT

# `|| true` : sans diff, grep sort en 1 et `set -e` tuerait le script.
{ git diff --cached "$BASE" -- '*.swift' | grep '^+' | grep -v '^+++' | cut -c2- | normalize || true; } > "$added"
{ git diff --cached "$BASE" -- '*.swift' | grep '^-' | grep -v '^---' | cut -c2- | normalize || true; } > "$removed"

only_added="$(comm -23 "$added" "$removed")"
only_removed="$(comm -13 "$added" "$removed")"

status=0
if [[ -n "$only_added" ]]; then
  echo "── Lignes AJOUTÉES sans équivalent retiré ($(echo "$only_added" | wc -l | tr -d ' ')) ──"
  echo "$only_added" | head -40
  status=1
fi
if [[ -n "$only_removed" ]]; then
  echo "── Lignes RETIRÉES sans équivalent ajouté ($(echo "$only_removed" | wc -l | tr -d ' ')) ──"
  echo "$only_removed" | head -40
  status=1
fi

if [[ "$status" == "0" ]]; then
  echo "Delta normalisé VIDE : le changement n'a fait que déplacer du code."
else
  echo
  echo "Delta normalisé NON vide. Soit l'extraction a modifié du code — à corriger —,"
  echo "soit les ajouts sont légitimes (en-têtes de fichier, imports) : les relire un par un."
fi
exit "$status"
