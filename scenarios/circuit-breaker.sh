#!/usr/bin/env bash
# product-service goes down -> order-service's circuit breaker (Resilience4j) opens:
# orders fail fast with 503 instead of every request waiting on a dead dependency.
#   break    scale product-service to 0, place orders, show the breaker state
#   status   breaker state + one order attempt
#   restore  scale product-service back; after 15s the breaker half-opens, then closes
# Breaker settings (order-service application.yaml): 5+ calls, >= 50% failed -> OPEN for 15s.
# Argo CD does not undo the scale-down: product-service's replicas belong to its HPA, not git.
# Usage: bash scenarios/circuit-breaker.sh break|status|restore
source "$(dirname "$0")/lib.sh"

breaker() {
  kubectl -n "$NS" port-forward deploy/order-service 18080:8080 >/dev/null 2>&1 &
  local pf=$!
  sleep 3
  local json
  json=$(curl -s http://localhost:18080/actuator/circuitbreakers)
  kill $pf 2>/dev/null || true
  echo "  breaker $(grep -o '"state":"[A-Z_]*"' <<<"$json")  $(grep -o '"failureRate":"[^"]*"' <<<"$json")  $(grep -o '"notPermittedCalls":[0-9]*' <<<"$json")"
}

case "${1:-}" in
  break)
    say "Stop product-service"
    kubectl -n "$NS" scale deploy/product-service --replicas=0
    kubectl -n "$NS" wait --for=delete pod -l app.kubernetes.io/name=product-service --timeout=2m || true
    TOKEN=$(token alice)
    say "Place 8 orders: the first ones try product-service, then the breaker opens"
    for i in $(seq 1 8); do printf '  order %s -> ' "$i"; place_order "$TOKEN"; done
    say "Breaker"
    breaker
    echo "In Grafana > Explore > Tempo, search service order-service, status error:"
    echo "the early traces have a failed call to product-service, the later ones none (short-circuited)."
    ;;
  status)
    breaker
    printf '  order -> '; place_order "$(token alice)"
    ;;
  restore)
    say "Start product-service again"
    kubectl -n "$NS" scale deploy/product-service --replicas=1
    kubectl -n "$NS" rollout status deploy/product-service --timeout=10m
    TOKEN=$(token alice)
    say "Orders work again (HALF_OPEN lets 2 trial calls through, then CLOSED)"
    for i in 1 2 3; do printf '  order %s -> ' "$i"; place_order "$TOKEN"; done
    breaker
    ;;
  *) echo "usage: $0 break|status|restore"; exit 1 ;;
esac
