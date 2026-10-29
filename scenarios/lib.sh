# Shared helpers for the Phase 7 scenarios. Sourced, not run. Dev environment only.
set -euo pipefail

NS=shop-dev
HOST=dev.shop.localhost
KEYCLOAK=http://auth.localhost/realms/shoplite
K6_IMAGE=grafana/k6:1.3.0

say() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }

# Access token for a demo user: password grant on the public shop-frontend client
# (enabled for exactly this kind of script, see realm.yaml). Password read from the Secret.
token() {
  local user=${1:-alice} key pw
  key="$(tr '[:lower:]' '[:upper:]' <<<"$user")_PASSWORD"
  pw=$(kubectl get secret -n keycloak realm-secrets -o jsonpath="{.data.$key}" | base64 -d)
  curl -fsS "$KEYCLOAK/protocol/openid-connect/token" \
    -d grant_type=password -d client_id=shop-frontend \
    --data-urlencode "username=$user" --data-urlencode "password=$pw" |
    sed -E 's/.*"access_token":"([^"]+)".*/\1/'
}

# POST one order (product 1, quantity 1); prints "<status> <seconds>".
# A fresh idempotency key per call: two calls are two order intents, not a retry.
new_key() { printf 'key-%s-%s' "$(date +%s%N)" "$RANDOM"; }

place_order() {
  curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' -X POST "http://$HOST/api/orders" \
    -H "Authorization: Bearer $1" -H 'Content-Type: application/json' \
    -H "Idempotency-Key: $(new_key)" \
    -d '{"productId":1,"quantity":1}'
}

# Turn Argo CD auto-sync off/on for one app. Off = git stops being enforced for it, which
# is what you do during an incident or a drill so self-heal does not undo your changes.
# (apps/appset.yaml ignores syncPolicy differences, so the ApplicationSet leaves it alone.)
gitops_off() {
  kubectl -n argocd patch application "$1" --type merge \
    -p '{"spec":{"syncPolicy":{"automated":null}}}' >/dev/null
  echo "Argo CD auto-sync OFF for $1"
}
gitops_on() {
  kubectl -n argocd patch application "$1" --type merge \
    -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}' >/dev/null
  echo "Argo CD auto-sync ON for $1: it now puts everything back as git says"
}

# k6 in Docker, script on stdin. The container reaches Kong through the host's port 80.
k6() {
  docker run --rm -i --add-host "$HOST:host-gateway" -e HOST="$HOST" "$@" "$K6_IMAGE" run --quiet -
}
