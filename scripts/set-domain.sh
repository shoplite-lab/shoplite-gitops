#!/usr/bin/env bash
# Replace the placeholder domain (and optionally the GCP project id) in clusters/gke-us.
# Every host there is <name>.<domain>; the domain is currently neststack.site:
#   shop.  dev.  auth.  argocd.  grafana.  kafka.
#
#   bash scripts/set-domain.sh shoplite.dev example.com             # example.com -> shoplite.dev
#   bash scripts/set-domain.sh newdomain.com neststack.site         # change it again later
# Review with `git diff clusters/` before committing.
set -euo pipefail
cd "$(dirname "$0")/.."

NEW=${1:?usage: set-domain.sh <new-domain> [current-domain]}
OLD=${2:-example.com}

[[ "$NEW" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] || { echo "not a domain: $NEW"; exit 1; }

files=$(grep -rIl --fixed-strings "$OLD" clusters/gke-us || true)
[ -n "$files" ] || { echo "nothing to replace: $OLD not found in clusters/gke-us"; exit 0; }

# Dots escaped for sed; "|" as delimiter because URLs contain slashes.
old_re=${OLD//./\.}
# shellcheck disable=SC2086
sed -i "s|$old_re|$NEW|g" $files
echo "replaced $OLD -> $NEW in:"; echo "$files" | sed 's/^/  /'
