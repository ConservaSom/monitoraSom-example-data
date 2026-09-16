#!/usr/bin/env bash
# =============================================================================
# Remove the regenerable by-products a walkthrough run leaves inside an example
# directory.
#
# Rendering the walkthroughs produces, in every example directory:
#
#   templates/                  <- export_templates()
#   roi_cuts/                   <- export_roi_cuts() (legacy name)
#   app_presets/                <- set_workspace()
#   soundscapes_metadata.duckdb <- fetch_soundscape_metadata()
#   annotations/, detections/   <- sm4 import round-trip / audiomoth persisting
#
# None of them is a repo member: the repo ships only what cannot be recomputed.
# They must go before ep_verify() passes, and this happens after EVERY run, by
# design, because producing them is what the walkthroughs teach.
#
# This script removes those paths and nothing else. It never touches the audio,
# the ROI stores, the .qmd/.Rmd/.R sources, or the repo documents.
#
# Usage:  bash harness/clean_examples.sh [--dry-run]
# =============================================================================
set -euo pipefail

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

# Anchor on the repository root, derived from this script's own location, so the
# script cannot be made to delete somewhere else by being run from elsewhere.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACK="$ROOT"

[[ -d "$PACK" ]] || { echo "No repo at $PACK — nothing to do."; exit 0; }

# The only names this script is ever allowed to remove.
# `*_files`/`*_cache` are knitr/Quarto render sidecars of ANY walkthrough
# (the dsname-prefixed loop below is kept for the historical pattern).
BYPRODUCTS=(templates roi_cuts app_presets soundscapes_metadata.duckdb annotations detections)
# Anything matching these must survive; asserted after the deletion.
declare -a GUARDED=()
while IFS= read -r -d '' f; do GUARDED+=("$f"); done < <(
  find "$PACK" -maxdepth 2 \
    \( -name '*.qmd' -o -name '*.Rmd' -o -name '*.R' -o -name 'rois.duckdb' \
       -o -name 'MANIFEST.csv' -o -name 'README.md' -o -name 'AGENTS.md' \
       -o -name 'STATUS.md' \) \
    -print0
)
before=${#GUARDED[@]}

removed=0
for ds in "$PACK"/*/; do
  [[ -d "$ds" ]] || continue
  # Quarto's supporting-files directory, named after the document. Only needed
  # when the HTML is not self-contained; removed by derived name, never by glob.
  dsname="$(basename "$ds")"
  for name in "${BYPRODUCTS[@]}" "${dsname}_files"; do
    target="$ds$name"
    [[ -e "$target" ]] || continue
    if [[ $DRY_RUN -eq 1 ]]; then
      echo "would remove  ${target#"$ROOT"/}"
    else
      rm -rf -- "$target"
      echo "removed       ${target#"$ROOT"/}"
    fi
    removed=$((removed + 1))
  done
  # Render sidecars of any additional walkthrough in this dataset (any stem).
  for d in "$ds"*_files "$ds"*_cache; do
    [[ -e "$d" ]] || continue
    if [[ $DRY_RUN -eq 1 ]]; then
      echo "would remove  ${d#"$ROOT"/}"
    else
      rm -rf -- "$d"
      echo "removed       ${d#"$ROOT"/}"
    fi
    removed=$((removed + 1))
  done
done

if [[ $removed -eq 0 ]]; then
  echo "Already clean — no by-products found."
fi

# Fail loudly if anything protected disappeared.
if [[ $DRY_RUN -eq 0 ]]; then
  after=$(find "$PACK" -maxdepth 2 \
    \( -name '*.qmd' -o -name '*.Rmd' -o -name '*.R' -o -name 'rois.duckdb' \
       -o -name 'MANIFEST.csv' -o -name 'README.md' -o -name 'AGENTS.md' \
       -o -name 'STATUS.md' \) \
    | wc -l)
  if [[ "$after" -ne "$before" ]]; then
    echo "ERROR: protected file count changed ($before -> $after)." >&2
    exit 1
  fi
  echo
  echo "Protected files intact ($after). Next:"
  echo "  Rscript -e 'source(\"harness/build_example_pack.R\"); ep_manifest(); ep_verify()'"
fi
