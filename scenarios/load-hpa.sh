#!/usr/bin/env bash
# Load test with k6 -> the HorizontalPodAutoscaler adds a product-service pod.
# HPA (apps/product-service/values-dev.yaml): CPU > 70% of the 50m request for 2 min
# -> up to 2 pods. Watch meanwhile: Grafana "ShopLite overview" (Requests/s, p95) and
# Argo CD (2nd pod appears).
# Usage: bash scenarios/load-hpa.sh
source "$(dirname "$0")/lib.sh"

say "HPA before"
kubectl -n "$NS" get hpa product-service
if [ "$(kubectl -n "$NS" get hpa product-service -o jsonpath='{.status.currentReplicas}')" != 1 ]; then
  echo "Already more than 1 pod (an earlier load, or a JVM that just started)."
  echo "For a clean run wait until REPLICAS is 1: scale-down follows 5 min of low CPU."
fi

say "k6: ramp to 20 virtual users on GET /api/products for ~3 min"
(
  for _ in $(seq 1 14); do
    sleep 15
    kubectl -n "$NS" get hpa product-service 2>/dev/null \
      -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization} {.status.currentReplicas} {.status.desiredReplicas}' |
      awk -v t="$(date +%T)" '{print t "  cpu " $1 "% of request (target 70%)  replicas " $2 " -> " $3}'
  done
) &
watcher=$!
trap 'kill $watcher 2>/dev/null || true' EXIT

k6 <"$(dirname "$0")/k6/products.js"

say "HPA after"
kubectl -n "$NS" get hpa product-service
kubectl -n "$NS" get pods -l app.kubernetes.io/name=product-service
echo "Scale-down waits 5 min of low CPU (HPA stabilization window), so the 2nd pod lingers a bit."
