#!/usr/bin/env bash
# platform/, apps/ and platform-resources/kong/ double as kustomize bases for cluster overlays
# (clusters/<name>/). Their kustomization.yaml lists files by hand; a new manifest that is
# not listed would silently be missing from every overlay-based cluster.
# This fails if a manifest in a base directory is not listed, or a listed file does not exist.
# Usage: bash scripts/check-kustomize-bases.sh
set -euo pipefail
cd "$(dirname "$0")/.."

bad=0
check() { # dir files-that-must-be-listed...
  local dir=$1; shift
  for f in "$@"; do
    grep -qE "^[[:space:]]*-[[:space:]]+$f[[:space:]]*$" "$dir/kustomization.yaml" || { echo "NOT LISTED: $dir/$f"; bad=1; }
  done
  # listed but missing
  while read -r f; do [ -e "$dir/$f" ] || { echo "MISSING FILE: $dir/$f"; bad=1; }; done < <(
    awk '/^resources:/{r=1;next} r && /^[[:space:]]*-[[:space:]]/{print $2} r && !/^[[:space:]]*-/ && !/^[[:space:]]*#/ && NF{r=0}' "$dir/kustomization.yaml")
}

check platform $(cd platform && ls *.yaml | grep -v '^kustomization.yaml$')
check platform-resources/kong $(cd platform-resources/kong && ls *.yaml | grep -v '^kustomization.yaml$')
check apps appset.yaml

[ "$bad" = 0 ] && echo "kustomize bases are complete"
exit "$bad"
