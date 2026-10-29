#!/usr/bin/env bash
# Idempotency drill on POST /api/orders: one Idempotency-Key = one order, however many requests.
#   1. five parallel POSTs with the same key -> one order, one unit of stock
#   2. the same key with a different payload -> 422 (key reuse, not a new order)
#   3. no key -> 400
# Watch order-service logs for a single "Order N placed"; My orders shows one new row.
# Usage: bash scenarios/order-idempotency.sh
source "$(dirname "$0")/lib.sh"

TOKEN=$(token alice)
KEY="drill-$(date +%s%N)"

stock() { curl -fsS "http://$HOST/api/products/1" | sed -E 's/.*"stock": *([0-9]+).*/\1/'; }
orders() { curl -fsS -H "Authorization: Bearer $TOKEN" "http://$HOST/api/orders" | grep -o '"id"' | wc -l | tr -d ' '; }

BEFORE_STOCK=$(stock)
BEFORE_ORDERS=$(orders)

say "5 parallel POSTs with the same key ($KEY)"
seq 1 5 | xargs -P5 -I{} curl -s -o /dev/null -w '%{http_code}\n' \
  -X POST "http://$HOST/api/orders" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -H "Idempotency-Key: $KEY" -d '{"productId":1,"quantity":1}' | sort | uniq -c

sleep 1

say "Same key, different payload (expect 422)"
curl -s -o /dev/null -w '  HTTP %{http_code}\n' -X POST "http://$HOST/api/orders" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -H "Idempotency-Key: $KEY" -d '{"productId":2,"quantity":1}'

say "No key (expect 400)"
curl -s -o /dev/null -w '  HTTP %{http_code}\n' -X POST "http://$HOST/api/orders" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"productId":1,"quantity":1}'

say "Result"
echo "  stock:  $BEFORE_STOCK -> $(stock)  (exactly one unit, not five)"
echo "  orders: $BEFORE_ORDERS -> $(orders)  (exactly one new order)"
echo "A 409 with Retry-After means the first request is still in flight; the key stays the same."
