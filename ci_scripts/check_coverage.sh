#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RESULT_BUNDLE="${1:-${SQ_XCRESULT_PATH:-}}"
TARGET_PATTERN="${SQ_COVERAGE_TARGET:-^SignalQuest([.]app)?$}"
LINE_MIN="${SQ_LINE_COVERAGE_MIN:-70}"
BRANCH_MIN="${SQ_BRANCH_COVERAGE_MIN:-60}"
CRITICAL_MIN="${SQ_CRITICAL_COVERAGE_MIN:-90}"
CRITICAL_PATHS="${SQ_CRITICAL_COVERAGE_PATHS:-$ROOT/ci_scripts/critical_coverage_paths.txt}"
REQUIRE_BRANCH="${SQ_REQUIRE_BRANCH_COVERAGE:-0}"

if [[ -z "$RESULT_BUNDLE" || ! -d "$RESULT_BUNDLE" ]]; then
  echo "error: fournir un bundle .xcresult existant en premier argument ou via SQ_XCRESULT_PATH." >&2
  exit 2
fi

if [[ ! -f "$CRITICAL_PATHS" ]]; then
  echo "error: liste de logique critique introuvable: $CRITICAL_PATHS" >&2
  exit 2
fi

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  SELECTED_DEVELOPER_DIR="$(xcode-select -p 2>/dev/null || true)"
  if [[ "$SELECTED_DEVELOPER_DIR" == *"Xcode"* ]]; then
    export DEVELOPER_DIR="$SELECTED_DEVELOPER_DIR"
  elif [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  elif [[ -d /Applications/Xcode-beta.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
  fi
fi

JSON_FILE="$(mktemp -t signalquest-xccov.XXXXXX)"
trap 'rm -f "$JSON_FILE"' EXIT

xcrun xccov view --report --json "$RESULT_BUNDLE" > "$JSON_FILE"

/usr/bin/python3 - "$JSON_FILE" "$TARGET_PATTERN" "$LINE_MIN" "$BRANCH_MIN" "$CRITICAL_MIN" "$CRITICAL_PATHS" "$REQUIRE_BRANCH" <<'PY'
import json
import re
import sys
from pathlib import Path

(
    report_path,
    target_pattern,
    line_min_raw,
    branch_min_raw,
    critical_min_raw,
    critical_paths_raw,
    require_branch_raw,
) = sys.argv[1:]


def threshold(raw: str, label: str) -> float:
    try:
        value = float(raw)
    except ValueError as error:
        raise SystemExit(f"error: seuil {label} invalide: {raw}") from error
    if not 0 <= value <= 100:
        raise SystemExit(f"error: seuil {label} hors plage 0...100: {raw}")
    return value


def percent(value):
    if value is None:
        return None
    numeric = float(value)
    return numeric * 100 if 0 <= numeric <= 1 else numeric


def branch_percent(node):
    for key in ("branchCoverage", "branchesCoverage"):
        if key in node:
            return percent(node[key])
    covered = node.get("coveredBranches")
    executable = node.get("executableBranches") or node.get("totalBranches")
    if covered is not None and executable:
        return 100 * float(covered) / float(executable)
    return None


line_min = threshold(line_min_raw, "lignes")
branch_min = threshold(branch_min_raw, "branches")
critical_min = threshold(critical_min_raw, "logique critique")
require_branch = require_branch_raw.lower() in {"1", "true", "yes", "on"}

with open(report_path, encoding="utf-8") as stream:
    report = json.load(stream)

matcher = re.compile(target_pattern)
targets = [target for target in report.get("targets", []) if matcher.search(target.get("name", ""))]
if len(targets) != 1:
    names = ", ".join(target.get("name", "?") for target in targets) or "aucune"
    raise SystemExit(
        f"error: SQ_COVERAGE_TARGET doit sélectionner exactement une cible; sélection: {names}"
    )

target = targets[0]
covered = int(target.get("coveredLines", 0))
executable = int(target.get("executableLines", 0))
if executable <= 0:
    raise SystemExit(f"error: aucune ligne exécutable pour {target.get('name', '?')}")
line_coverage = 100 * covered / executable

patterns = []
for raw_line in Path(critical_paths_raw).read_text(encoding="utf-8").splitlines():
    candidate = raw_line.strip()
    if candidate and not candidate.startswith("#"):
        patterns.append(candidate.replace("\\", "/"))
if not patterns:
    raise SystemExit("error: la liste des chemins critiques est vide")

critical_files = []
for file_entry in target.get("files", []):
    path = str(file_entry.get("path", "")).replace("\\", "/")
    if any(pattern in path for pattern in patterns):
        critical_files.append(file_entry)

if not critical_files:
    raise SystemExit("error: aucun fichier critique ne correspond au rapport xccov")

critical_covered = sum(int(file_entry.get("coveredLines", 0)) for file_entry in critical_files)
critical_executable = sum(int(file_entry.get("executableLines", 0)) for file_entry in critical_files)
if critical_executable <= 0:
    raise SystemExit("error: aucun code exécutable dans la sélection critique")
critical_coverage = 100 * critical_covered / critical_executable

branch_coverage = branch_percent(target)
if branch_coverage is None:
    # Repli pondéré pour un éventuel format xccov publiant uniquement les
    # compteurs par fichier. Un simple moyennage des pourcentages serait faux.
    file_branch_covered = 0
    file_branch_executable = 0
    for file_entry in target.get("files", []):
        covered_branches = file_entry.get("coveredBranches")
        executable_branches = file_entry.get("executableBranches") or file_entry.get("totalBranches")
        if covered_branches is not None and executable_branches:
            file_branch_covered += int(covered_branches)
            file_branch_executable += int(executable_branches)
    if file_branch_executable:
        branch_coverage = 100 * file_branch_covered / file_branch_executable

print(
    f"coverage target={target.get('name', '?')} "
    f"lines={line_coverage:.2f}% ({covered}/{executable}) min={line_min:.2f}%"
)
print(
    f"coverage critical={critical_coverage:.2f}% "
    f"({critical_covered}/{critical_executable}, {len(critical_files)} fichiers) "
    f"min={critical_min:.2f}%"
)

failures = []
if line_coverage + 1e-9 < line_min:
    failures.append(f"couverture lignes {line_coverage:.2f}% < {line_min:.2f}%")
if critical_coverage + 1e-9 < critical_min:
    failures.append(f"couverture critique {critical_coverage:.2f}% < {critical_min:.2f}%")

if branch_coverage is None:
    message = (
        "coverage branches=INDISPONIBLE: ce rapport xccov n'expose ni "
        "branchCoverage ni compteurs de branches"
    )
    if require_branch:
        failures.append(message)
    else:
        print(f"warning: {message}; seuil {branch_min:.2f}% non appliqué", file=sys.stderr)
else:
    print(f"coverage branches={branch_coverage:.2f}% min={branch_min:.2f}%")
    if branch_coverage + 1e-9 < branch_min:
        failures.append(f"couverture branches {branch_coverage:.2f}% < {branch_min:.2f}%")

if failures:
    for failure in failures:
        print(f"error: {failure}", file=sys.stderr)
    raise SystemExit(1)

print("coverage gate: OK")
PY
