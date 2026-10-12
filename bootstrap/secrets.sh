#!/usr/bin/env bash
# Creates the few Secrets that must never live in git (local cluster only).
# On GKE the same Secrets come from GCP Secret Manager via External Secrets (Phase 6),
# so the manifests in git only ever reference them by name.
#
# Idempotent: existing Secrets are kept, so re-running never rotates anything.
# Rotate on purpose with:  bash bootstrap/secrets.sh --rotate   (then re-sync the keycloak app)
#
#   keycloak/realm-secrets       realm signing key, order-service client secret, demo user passwords
#                                -> substituted into the realm by keycloak-config-cli
#   kong/keycloak-jwt            realm PUBLIC key -> Kong jwt plugin verifies tokens at the edge
#   shop-*/order-service-oidc    same client secret -> order-service client-credentials grant
set -euo pipefail

ISSUER=http://auth.localhost/realms/shoplite # must equal the token "iss" claim

ROTATE=false
[[ "${1:-}" == "--rotate" ]] && ROTATE=true

for ns in keycloak kong shop-dev shop-prod; do
  kubectl get namespace "$ns" >/dev/null 2>&1 || kubectl create namespace "$ns" >/dev/null
done

if kubectl get secret -n keycloak realm-secrets >/dev/null 2>&1 && ! $ROTATE; then
  echo "   secrets already exist (use --rotate to replace them)"
  exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# One RSA key pair: Keycloak signs with the private half, Kong verifies with the public half.
# Generated here (not by Keycloak) so Kong can be configured before Keycloak even starts.
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$tmp/key.pem" 2>/dev/null
openssl pkey -in "$tmp/key.pem" -pubout -out "$tmp/pub.pem"
private_key=$(grep -v -- '-----' "$tmp/key.pem" | tr -d '\n') # PKCS#8 body, the format Keycloak expects

client_secret=$(openssl rand -hex 24)

apply() { kubectl apply -f - >/dev/null; }

kubectl create secret generic realm-secrets -n keycloak \
  --from-literal=REALM_RSA_PRIVATE_KEY="$private_key" \
  --from-literal=ORDER_SERVICE_CLIENT_SECRET="$client_secret" \
  --from-literal=ALICE_PASSWORD="$(openssl rand -hex 6)" \
  --from-literal=BOB_PASSWORD="$(openssl rand -hex 6)" \
  --from-literal=DEVOPS1_PASSWORD="$(openssl rand -hex 6)" \
  --dry-run=client -o yaml | apply

# Kong jwt credential: the plugin picks the credential whose `key` equals the token's iss claim.
kubectl create secret generic keycloak-jwt -n kong \
  --from-literal=key="$ISSUER" \
  --from-literal=algorithm=RS256 \
  --from-file=rsa_public_key="$tmp/pub.pem" \
  --dry-run=client -o yaml | kubectl label --local -f - konghq.com/credential=jwt -o yaml | apply

for ns in shop-dev shop-prod; do
  kubectl create secret generic order-service-oidc -n "$ns" \
    --from-literal=client-secret="$client_secret" \
    --dry-run=client -o yaml | apply
done

echo "   created: keycloak/realm-secrets, kong/keycloak-jwt, shop-{dev,prod}/order-service-oidc"
