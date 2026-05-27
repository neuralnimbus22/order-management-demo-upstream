#!/usr/bin/env bash
# deploy.sh — bring the entire order-demo stack up from scratch with one command.
#
# Captures the exact sequence verified by hand:
#   1. namespace
#   2. kafka + wait for it to become Available
#   3. pre-create the order-placed topic
#      (Kafka's auto-create-topics only fires on first PRODUCE, not SUBSCRIBE —
#       without this, inventory's consumer subscribe errors and the rollout
#       restart in step 6 can't fix it.)
#   4. apply the three services
#   5. wait for auth, order, inventory Deployments to become Available
#   6. rollout-restart order + inventory
#      (kafkajs retries a connect ~5 times then gives up. If those pods came
#       up before Kafka was reachable, they're now alive-but-disconnected.
#       A restart with Kafka already up + topic already created brings them
#       into a clean steady state.)
#   7. scripts/sanity-check.sh
#
# Exit code: 0 on success. Aborts immediately on any failure (set -e).
# Idempotent — safe to re-run on an already-deployed stack.
#
# Style and helpers match the other scripts in this folder.

set -e -o pipefail

NS="${NAMESPACE:-order-demo}"
TOPIC="${KAFKA_TOPIC:-order-placed}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ok()      { echo "[OK]   $*"; }
fail()    { echo "[FAIL] $*" >&2; }
hint()    { echo "       hint: $*"; }
section() { echo; echo "--- $* ---"; }

echo "=== deploy (namespace=$NS, topic=$TOPIC) ==="
echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"

# --- 1. namespace ----------------------------------------------------------
section "1. namespace"
kubectl apply -f "$REPO_ROOT/k8s/namespace.yaml"
ok "namespace '$NS' applied"

# --- 2. kafka --------------------------------------------------------------
section "2. kafka"
kubectl apply -f "$REPO_ROOT/kafka/"
echo "waiting for kafka to be Available..."
kubectl -n "$NS" wait --for=condition=available --timeout=180s deploy/kafka
ok "kafka is Ready"

# --- 3. pre-create topic ---------------------------------------------------
section "3. pre-create topic '$TOPIC'"
kubectl -n "$NS" exec deploy/kafka -- /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server localhost:9092 \
  --create --if-not-exists --topic "$TOPIC" \
  --partitions 1 --replication-factor 1
ok "topic '$TOPIC' exists"

# --- 4. services -----------------------------------------------------------
section "4. services (auth, order, inventory)"
kubectl apply -f "$REPO_ROOT/k8s/"
ok "manifests applied"

# --- 5. wait for service rollouts -----------------------------------------
section "5. wait for auth, order, inventory to be Available"
for d in auth order inventory; do
  echo "waiting for $d..."
  kubectl -n "$NS" wait --for=condition=available --timeout=120s deploy/"$d"
  ok "$d is Ready"
done

# --- 6. rollout-restart order + inventory (Kafka client race fix) ---------
section "6. rollout-restart order + inventory (Kafka client race fix)"
kubectl -n "$NS" rollout restart deploy/order deploy/inventory
kubectl -n "$NS" rollout status deploy/order --timeout=120s
kubectl -n "$NS" rollout status deploy/inventory --timeout=120s
ok "order + inventory restarted clean"

# --- 7. sanity check -------------------------------------------------------
section "7. sanity check"
"$REPO_ROOT/scripts/sanity-check.sh"

echo
ok "stack is deployed and green"
