#!/usr/bin/env bash
# Creates the few Secrets that must never live in git (local cluster only).
# On GKE the same Secrets come from GCP Secret Manager via External Secrets (Phase 6),
# so the manifests in git only ever reference them by name.
#
# Idempotent: values already in the cluster are kept and only missing ones are generated,
# so re-running after a secret is added here fills the gap without rotating anything.
# Rotate everything on purpose with:  bash bootstrap/secrets.sh --rotate   (then re-sync the keycloak app)
#
#   keycloak/realm-secrets         realm signing key, client secrets, demo user passwords
#                                  -> substituted into the realm by keycloak-config-cli
#   kong/keycloak-jwt              realm PUBLIC key -> Kong jwt plugin verifies tokens at the edge
#   shop-*/order-service-oidc      order-service client secret -> client-credentials grant
#   observability/grafana-secrets  Grafana OIDC client secret + break-glass admin password
#   argocd/argocd-oidc             Argo CD OIDC client secret (read by argocd-cm as $argocd-oidc:client-secret)
#   kafka/kafka-ui-oidc            Kafbat UI OIDC client secret
set -euo pipefail

ISSUER=http://auth.localhost/realms/shoplite # must equal the token "iss" claim

ROTATE=false
[[ "${1:-}" == "--rotate" ]] && ROTATE=true

for ns in keycloak kong kafka shop-dev shop-prod observability argocd; do
  kubectl get namespace "$ns" >/dev/null 2>&1 || kubectl create namespace "$ns" >/dev/null
done

# Value of <key> in Secret <ns>/<name>; empty if absent or when rotating.
current() {
  $ROTATE && return 0
  kubectl get secret -n "$1" "$2" -o jsonpath="{.data.$3}" 2>/dev/null | base64 -d || true
}
# Current value, or a new random hex string of <bytes> bytes.
keep_or_new() {
  local v
  v=$(current "$1" "$2" "$3")
  echo "${v:-$(openssl rand -hex "$4")}"
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# One RSA key pair: Keycloak signs with the private half, Kong verifies with the public half.
# Generated here (not by Keycloak) so Kong can be configured before Keycloak even starts.
private_key=$(current keycloak realm-secrets REALM_RSA_PRIVATE_KEY)
if [[ -z "$private_key" ]]; then
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$tmp/key.pem" 2>/dev/null
  private_key=$(grep -v -- '-----' "$tmp/key.pem" | tr -d '\n') # PKCS#8 body, the format Keycloak expects
else
  { echo "-----BEGIN PRIVATE KEY-----"; fold -w 64 <<<"$private_key"; echo "-----END PRIVATE KEY-----"; } >"$tmp/key.pem"
fi
openssl pkey -in "$tmp/key.pem" -pubout -out "$tmp/pub.pem"

order_secret=$(keep_or_new keycloak realm-secrets ORDER_SERVICE_CLIENT_SECRET 24)
grafana_secret=$(keep_or_new keycloak realm-secrets GRAFANA_CLIENT_SECRET 24)
argocd_secret=$(keep_or_new keycloak realm-secrets ARGOCD_CLIENT_SECRET 24)
kafka_ui_secret=$(keep_or_new keycloak realm-secrets KAFKA_UI_CLIENT_SECRET 24)

apply() { kubectl apply -f - >/dev/null; }

kubectl create secret generic realm-secrets -n keycloak \
  --from-literal=REALM_RSA_PRIVATE_KEY="$private_key" \
  --from-literal=ORDER_SERVICE_CLIENT_SECRET="$order_secret" \
  --from-literal=GRAFANA_CLIENT_SECRET="$grafana_secret" \
  --from-literal=ARGOCD_CLIENT_SECRET="$argocd_secret" \
  --from-literal=KAFKA_UI_CLIENT_SECRET="$kafka_ui_secret" \
  --from-literal=ALICE_PASSWORD="$(keep_or_new keycloak realm-secrets ALICE_PASSWORD 6)" \
  --from-literal=BOB_PASSWORD="$(keep_or_new keycloak realm-secrets BOB_PASSWORD 6)" \
  --from-literal=DEVOPS1_PASSWORD="$(keep_or_new keycloak realm-secrets DEVOPS1_PASSWORD 6)" \
  --from-literal=VIEWER1_PASSWORD="$(keep_or_new keycloak realm-secrets VIEWER1_PASSWORD 6)" \
  --dry-run=client -o yaml | apply

# Kong jwt credential: the plugin picks the credential whose `key` equals the token's iss claim.
kubectl create secret generic keycloak-jwt -n kong \
  --from-literal=key="$ISSUER" \
  --from-literal=algorithm=RS256 \
  --from-file=rsa_public_key="$tmp/pub.pem" \
  --dry-run=client -o yaml | kubectl label --local -f - konghq.com/credential=jwt -o yaml | apply

for ns in shop-dev shop-prod; do
  kubectl create secret generic order-service-oidc -n "$ns" \
    --from-literal=client-secret="$order_secret" \
    --dry-run=client -o yaml | apply
done

kubectl create secret generic grafana-secrets -n observability \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="$(keep_or_new observability grafana-secrets admin-password 12)" \
  --from-literal=oidc-client-secret="$grafana_secret" \
  --dry-run=client -o yaml | apply

# Argo CD only resolves $<secret>:<key> references from Secrets carrying this label.
kubectl create secret generic argocd-oidc -n argocd \
  --from-literal=client-secret="$argocd_secret" \
  --dry-run=client -o yaml | kubectl label --local -f - app.kubernetes.io/part-of=argocd -o yaml | apply

kubectl create secret generic kafka-ui-oidc -n kafka \
  --from-literal=client-secret="$kafka_ui_secret" \
  --dry-run=client -o yaml | apply

echo "   in place: keycloak/realm-secrets, kong/keycloak-jwt, shop-{dev,prod}/order-service-oidc,"
echo "             observability/grafana-secrets, argocd/argocd-oidc, kafka/kafka-ui-oidc"
