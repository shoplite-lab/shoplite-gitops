#!/usr/bin/env bash
# Kong rate limiting on /api/orders (KongClusterPlugin rate-limit-orders: 20/min per client IP).
# Requests beyond the limit get 429 from Kong and never reach order-service.
# Uses GET /api/orders (list my orders) so the test creates nothing.
# Note: the k3d load balancer spreads clients over 3 node IPs, so you may see up to ~60 pass.
# Usage: bash scenarios/rate-limit.sh
source "$(dirname "$0")/lib.sh"

say "Token for alice"
TOKEN=$(token alice)

say "80 requests as fast as possible"
for _ in $(seq 1 80); do
  curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $TOKEN" "http://$HOST/api/orders"
done | sort | uniq -c | awk '{print "  HTTP", $2, "x", $1}'

say "Headers Kong adds (remaining quota for this minute)"
curl -s -D - -o /dev/null -H "Authorization: Bearer $TOKEN" "http://$HOST/api/orders" |
  grep -i -E '^HTTP|ratelimit|retry-after'
echo "The counter resets at the next minute."
