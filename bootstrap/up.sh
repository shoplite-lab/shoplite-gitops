#!/usr/bin/env bash
# Bootstrap a local cluster: k3d -> Argo CD -> root app. After this, git is in charge.
# Idempotent: re-running skips what already exists.
#
#   bash bootstrap/up.sh          # create everything
#   k3d cluster delete shoplite   # tear down (data is lost)
set -euo pipefail
cd "$(dirname "$0")/.."

ARGOCD_CHART_VERSION=10.10.2 # keep in sync with platform/argocd.yaml

for bin in k3d kubectl helm; do
  command -v "$bin" >/dev/null || { echo "missing: $bin"; exit 1; }
done

echo "== 1. k3d cluster"
if k3d cluster list shoplite >/dev/null 2>&1; then
  echo "   already exists"
  kubectl config use-context k3d-shoplite >/dev/null
else
  k3d cluster create --config bootstrap/k3d-cluster.yaml
fi

echo "== 2. Argo CD (helm install once; afterwards Argo CD upgrades itself from git)"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm upgrade --install argocd argo/argo-cd --version "$ARGOCD_CHART_VERSION" \
  --namespace argocd --create-namespace \
  --values bootstrap/argocd-values.yaml --wait --timeout 10m

echo "== 3. Root app"
kubectl apply -f bootstrap/root-app.yaml

cat <<EOF

Done. Argo CD now syncs everything else from git (takes ~5-10 min the first time).

  Watch:     kubectl get applications -n argocd -w
  UI:        http://argocd.localhost  (works once the kong app is Healthy)
             or: kubectl port-forward -n argocd svc/argocd-server 8080:80  ->  http://localhost:8080
  User:      admin
  Password:  kubectl get secret -n argocd argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
EOF
