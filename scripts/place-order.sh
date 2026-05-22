#!/usr/bin/env bash
# place-order.sh — healthy-path helper. Places a single order and confirms
# inventory processed it. Use this any time you want to manually prove the
# whole chain is alive (no test framework involved).
#
# Exits 0 if the order propagates end-to-end within HEALTHY_POLL_TIMEOUT_S.
# Otherwise prints the order id + last inventory status and exits non-zero.

set -o pipefail

NS="${NAMESPACE:-order-demo}"
PROBE_PORT_ORDER="${PROBE_PORT_ORDER:-18601}"
PROBE_PORT_INV="${PROBE_PORT_INV:-18602}"
HEALTHY_POLL_TIMEOUT_S="${HEALTHY_POLL_TIMEOUT_S:-15}"

echo "=== place-order (namespace=$NS) ==="

kubectl -n "$NS" port-forward svc/order ${PROBE_PORT_ORDER}:3002 >/tmp/po-order.log 2>&1 &
PF_ORDER=$!
kubectl -n "$NS" port-forward svc/inventory ${PROBE_PORT_INV}:3003 >/tmp/po-inv.log 2>&1 &
PF_INV=$!
cleanup() {
  for p in "$PF_ORDER" "$PF_INV"; do
    [ -n "$p" ] && kill "$p" 2>/dev/null && wait "$p" 2>/dev/null
  done
}
trap cleanup EXIT
sleep 3

ORDER_ID="manual-$(date +%s)-${RANDOM}"
echo "placing order id=${ORDER_ID}"

RESP=$(curl -s -w "\n%{http_code}" --max-time 5 -X POST \
  -H 'Content-Type: application/json' \
  -d "{\"id\":\"${ORDER_ID}\",\"item\":\"manual-widget\",\"qty\":1}" \
  http://localhost:${PROBE_PORT_ORDER}/orders)
BODY=$(echo "$RESP" | head -1)
CODE=$(echo "$RESP" | tail -1)
echo "POST /orders -> HTTP ${CODE}  body=${BODY}"

if [ "$CODE" != "201" ]; then
  echo "[FAIL] order-service refused — system is not healthy"
  exit 1
fi

# Poll inventory
for i in $(seq 1 ${HEALTHY_POLL_TIMEOUT_S}); do
  INV_RESP=$(curl -s -w "\n%{http_code}" --max-time 3 \
    "http://localhost:${PROBE_PORT_INV}/processed/${ORDER_ID}")
  INV_BODY=$(echo "$INV_RESP" | head -1)
  INV_CODE=$(echo "$INV_RESP" | tail -1)
  if [ "$INV_CODE" = "200" ]; then
    echo "GET /processed/${ORDER_ID} -> HTTP 200 (after ${i}s)"
    echo "       ${INV_BODY}"
    echo "[OK] order propagated end-to-end"
    exit 0
  fi
  sleep 1
done

echo "[FAIL] inventory never processed ${ORDER_ID} after ${HEALTHY_POLL_TIMEOUT_S}s"
echo "       last inventory response: HTTP ${INV_CODE} ${INV_BODY}"
exit 1
