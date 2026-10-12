#!/usr/bin/env bash
# Two layers of self-healing:
#   kill   Kubernetes: a deleted pod is replaced by its ReplicaSet (desired state = 1 pod).
#   drift  Argo CD: a manual change (kubectl scale) is reverted to what git says (selfHeal).
# Usage: bash scenarios/self-healing.sh kill|drift
source "$(dirname "$0")/lib.sh"

case "${1:-}" in
  kill)
    say "Delete the order-service pod"
    kubectl -n "$NS" delete pod -l app.kubernetes.io/name=order-service --wait=false
    say "The ReplicaSet creates a new one right away (watch AGE)"
    kubectl -n "$NS" get pods -l app.kubernetes.io/name=order-service
    kubectl -n "$NS" rollout status deploy/order-service --timeout=10m
    kubectl -n "$NS" get pods -l app.kubernetes.io/name=order-service
    echo "While it booted, orders failed with 503 from Kong: 1 replica = no redundancy."
    echo "Prod runs product-service with 2 replicas + a PodDisruptionBudget for that reason."
    ;;
  drift)
    say "Scale order-service to 2 by hand (git says 1)"
    kubectl -n "$NS" scale deploy/order-service --replicas=2
    say "Argo CD sees OutOfSync and self-heals back to 1"
    for _ in $(seq 1 24); do
      r=$(kubectl -n "$NS" get deploy order-service -o jsonpath='{.spec.replicas}')
      s=$(kubectl -n argocd get application order-service-dev -o jsonpath='{.status.sync.status}')
      echo "$(date +%T) spec.replicas=$r argo=$s"
      [ "$r" = 1 ] && [ "$s" = Synced ] && { echo "Back to git. The fix belongs in git, not in kubectl."; exit 0; }
      sleep 5
    done
    echo "Not reverted after 2 min: is auto-sync on? (kubectl -n argocd get application order-service-dev -o yaml)"
    ;;
  *) echo "usage: $0 kill|drift"; exit 1 ;;
esac
