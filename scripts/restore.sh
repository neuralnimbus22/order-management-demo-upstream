#!/usr/bin/env bash
# restore.sh — bring auth back AND reset clean state (delete + recreate the
# Kafka topic, restart inventory) so the next run starts pristine. Verifies
# the restore by placing a healthy order end-to-end (proof that the system
# genuinely recovered).
#
# CLEAN-STATE MECHANISM (see ARCHITECTURE.md)
# -------------------------------------------
# Three layers can hold stale state between runs:
#   * Kafka log    → wiped by deleting + recreating the topic
#   * Consumer offset → wiped because inventory restarts (fresh consumer)
#   * Inventory in-memory `processed` Map → wiped because inventory restarts
# Doing all three is the only way every layer starts from zero. Any
# partial reset (e.g. just offset reset) leaves the Map populated and
# a false pass becomes possible.

set -o pipefail

NS="${NAMESPACE:-order-demo}"
TOPIC="${KAFKA_TOPIC:-order-placed}"
PROBE_PORT_ORDER="${PROBE_PORT_ORDER:-18501}"
PROBE_PORT_INV="${PROBE_PORT_INV:-18502}"
HEALTHY_POLL_TIMEOUT_S="${HEALTHY_POLL_TIMEOUT_S:-15}"

echo "=== restore (namespace=$NS, topic=$TOPIC) ==="
echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"

# --- 1. bring auth back ---------------------------------------------------
echo
echo "--- 1. scaling auth back to 1 ---"
kubectl -n "$NS" scale deploy/auth --replicas=1 >/dev/null
kubectl -n "$NS" rollout status deploy/auth --timeout=60s

# --- 2. clean-state: delete + recreate topic ------------------------------
echo
echo "--- 2. deleting + recreating topic '$TOPIC' ---"
# 'delete' is async; the broker accepts the request, then drops the log.
# The recreate that follows will block briefly if delete hasn't finished.
# Loop on the create until it succeeds (or 30s elapse).
kubectl -n "$NS" exec deploy/kafka -- /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server localhost:9092 --delete --topic "$TOPIC" 2>/dev/null \
  && echo "delete issued" || echo "delete: topic may not have existed (ok)"

for i in $(seq 1 30); do
  if kubectl -n "$NS" exec deploy/kafka -- /opt/kafka/bin/kafka-topics.sh \
       --bootstrap-server localhost:9092 --create --if-not-exists \
       --topic "$TOPIC" --partitions 1 --replication-factor 1 >/dev/null 2>&1; then
    echo "topic '$TOPIC' recreated"
    break
  fi
  sleep 1
done

# --- 3. clean-state: restart inventory (wipes in-memory Map + consumer) --
echo
echo "--- 3. restarting inventory (wipes in-memory state + resubscribes) ---"
kubectl -n "$NS" rollout restart deploy/inventory >/dev/null
kubectl -n "$NS" rollout status deploy/inventory --timeout=60s

# Give kafkajs a moment to reconnect + join the consumer group. Empirically
# the group is stable within ~3-5s of pod-Ready.
sleep 5

# --- 4. verify: place a healthy order, confirm inventory processes it ---
echo
echo "--- 4. verifying restore with a real end-to-end order ---"
kubectl -n "$NS" port-forward svc/order ${PROBE_PORT_ORDER}:3002 >/tmp/restore-pf-order.log 2>&1 &
PF_ORDER=$!
kubectl -n "$NS" port-forward svc/inventory ${PROBE_PORT_INV}:3003 >/tmp/restore-pf-inv.log 2>&1 &
PF_INV=$!
cleanup() {
  for p in "$PF_ORDER" "$PF_INV"; do
    [ -n "$p" ] && kill "$p" 2>/dev/null && wait "$p" 2>/dev/null
  done
}
trap cleanup EXIT
sleep 3

ORDER_ID="restore-probe-$(date +%s)-${RANDOM}"
CODE=$(curl -s -o /tmp/restore-post.json -w "%{http_code}" --max-time 5 -X POST \
  -H 'Content-Type: application/json' \
  -d "{\"id\":\"${ORDER_ID}\",\"item\":\"restore-widget\"}" \
  http://localhost:${PROBE_PORT_ORDER}/orders)

if [ "$CODE" != "201" ]; then
  echo "[FAIL] POST /orders returned HTTP $CODE (expected 201)"
  cat /tmp/restore-post.json 2>/dev/null
  cleanup; trap - EXIT
  exit 1
fi
echo "POST /orders id=${ORDER_ID} -> HTTP 201"

PROCESSED=0
for i in $(seq 1 ${HEALTHY_POLL_TIMEOUT_S}); do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 \
    "http://localhost:${PROBE_PORT_INV}/processed/${ORDER_ID}")
  if [ "$CODE" = "200" ]; then
    echo "GET /processed/${ORDER_ID} -> HTTP 200 (after ${i}s) — inventory processed it"
    PROCESSED=1
    break
  fi
  sleep 1
done

cleanup
trap - EXIT

echo
if [ $PROCESSED -eq 1 ]; then
  # The verification probe left a real message in the topic. Reset the
  # topic + inventory one more time so the system genuinely starts the
  # next run from zero state on every layer.
  echo "--- 5. final topic + inventory reset (clean state) ---"
  kubectl -n "$NS" exec deploy/kafka -- /opt/kafka/bin/kafka-topics.sh \
    --bootstrap-server localhost:9092 --delete --topic "$TOPIC" >/dev/null 2>&1 || true
  for i in $(seq 1 30); do
    if kubectl -n "$NS" exec deploy/kafka -- /opt/kafka/bin/kafka-topics.sh \
         --bootstrap-server localhost:9092 --create --if-not-exists \
         --topic "$TOPIC" --partitions 1 --replication-factor 1 >/dev/null 2>&1; then
      echo "topic '$TOPIC' recreated (empty)"
      break
    fi
    sleep 1
  done
  kubectl -n "$NS" rollout restart deploy/inventory >/dev/null
  kubectl -n "$NS" rollout status deploy/inventory --timeout=60s
  sleep 5
  echo
  echo "[OK] restore verified — system is back to a green, clean state"
  exit 0
else
  echo "[FAIL] inventory never processed the probe order after ${HEALTHY_POLL_TIMEOUT_S}s"
  echo "       check: kubectl -n $NS logs deploy/inventory --tail=30"
  exit 1
fi
