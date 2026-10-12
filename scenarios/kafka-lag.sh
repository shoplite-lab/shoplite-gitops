#!/usr/bin/env bash
# Async resilience: notification-service is down, orders keep working, events wait in Kafka.
#   break    auto-sync off + scale notification-service to 0, then place 5 orders
#   status   consumer group lag (messages not yet processed)
#   restore  auto-sync on: Argo CD restores the replica, the consumer catches up, lag -> 0
# Watch: Grafana "Kafka consumer lag" panel, Kafka UI (http://kafka.localhost) > Consumers,
# and the KafkaConsumerLagHigh alert (fires above 50 for 2 min; try `break` with more orders).
# Usage: bash scenarios/kafka-lag.sh break [orders]|status|restore
source "$(dirname "$0")/lib.sh"

GROUP=notification-service-dev

lag() {
  # MSYS_NO_PATHCONV: stop Git Bash on Windows from rewriting /opt/kafka/... into C:/...
  MSYS_NO_PATHCONV=1 kubectl -n kafka exec shoplite-dual-role-0 -- /opt/kafka/bin/kafka-consumer-groups.sh \
    --bootstrap-server localhost:9092 --describe --group "$GROUP" 2>/dev/null |
    awk '/TOPIC/ || /dev.order.created/ {printf "  %-18s %-9s %-14s %-14s %s\n", $2, $3, $4, $5, $6}'
}

case "${1:-}" in
  break)
    n=${2:-5}
    say "Stop notification-service (auto-sync off first, or Argo CD would restart it at once)"
    gitops_off notification-service-dev
    kubectl -n "$NS" scale deploy/notification-service --replicas=0
    kubectl -n "$NS" wait --for=delete pod -l app.kubernetes.io/name=notification-service --timeout=2m || true
    TOKEN=$(token alice)
    say "Place $n orders: all succeed, order-service does not wait for notifications"
    for i in $(seq 1 "$n"); do printf '  order %s -> ' "$i"; place_order "$TOKEN"; done
    say "Lag = messages waiting for the consumer group"
    lag
    ;;
  status)
    lag
    ;;
  restore)
    say "Auto-sync on: Argo CD sees replicas 0 != 1 in git and fixes it"
    gitops_on notification-service-dev
    kubectl -n "$NS" rollout status deploy/notification-service --timeout=10m
    for _ in $(seq 1 12); do
      out=$(lag); echo "$out"
      awk '!/TOPIC/ && $5 != "0" {bad=1} END {exit bad}' <<<"$out" && { echo "Caught up: every order got its notification."; exit 0; }
      sleep 10
    done
    ;;
  *) echo "usage: $0 break [orders]|status|restore"; exit 1 ;;
esac
