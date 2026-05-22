#!/usr/bin/env bash
# break-auth.sh — deterministically take auth-service down and wait until
# the cascade is fully confirmed at the boundary the orchestrator cares about.
#
# WHAT "WAIT" MEANS HERE
# ----------------------
# A live demo cannot afford "I scaled but the symptom hasn't propagated yet."
# This script returns ONLY after:
#   1. the auth pod is fully deleted
#   2. the auth Service has zero endpoints
#   3. order-service POST /orders returns HTTP 502 ("auth unreachable")
# At that point an orchestrator (or a manual test run) is guaranteed to
# observe the cascade — there is no race window.
#
# MEASURED TIMING (Docker Desktop k8s, single node, this repo)
# ------------------------------------------------------------
# WITHOUT a SIGTERM handler in auth + default 30s grace:
#   ~31s from scale to cascade live (full grace consumed, then SIGKILL).
# WITH SIGTERM handler in auth (server.js) + terminationGracePeriodSeconds: 5
# in k8s/auth.yaml:
#   ~5s from scale to cascade live (grace-period-capped pod deletion).
# Wait budget below uses 30s as a safety ceiling — typical run completes in 5–8s.

set -o pipefail

NS="${NAMESPACE:-order-demo}"
WAIT_TIMEOUT_S="${WAIT_TIMEOUT_S:-30}"
PROBE_PORT="${PROBE_PORT:-18402}"

echo "=== break-auth (namespace=$NS, timeout=${WAIT_TIMEOUT_S}s) ==="
echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"

# Idempotency: if auth is already at 0, just confirm cascade and exit.
current=$(kubectl -n "$NS" get deploy auth -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "?")
if [ "$current" = "0" ]; then
  echo "[info] auth is already scaled to 0 — verifying cascade is live"
fi

START=$(date +%s)
echo "T+0: kubectl -n $NS scale deploy/auth --replicas=0"
kubectl -n "$NS" scale deploy/auth --replicas=0 >/dev/null

# --- 1. wait for pod-gone -------------------------------------------------
# 'rollout status' would return as soon as the SPEC matches (instant),
# NOT when the existing pod has finished terminating. We need the pod
# actually gone, so use 'wait --for=delete'.
kubectl -n "$NS" wait --for=delete pod -l app=auth --timeout=${WAIT_TIMEOUT_S}s >/dev/null 2>&1 \
  && echo "T+$(( $(date +%s) - START ))s: auth pod fully deleted" \
  || echo "[warn] timed out waiting for pod-delete (or pod was already gone)"

# --- 2. wait for endpoints cleared ----------------------------------------
# The Service may still list a stale endpoint for a moment after the pod
# is deleted. We wait until the endpoint list is empty — only then is
# every in-cluster client guaranteed to fail when calling auth.
for i in $(seq 1 ${WAIT_TIMEOUT_S}); do
  ep=$(kubectl -n "$NS" get endpoints auth -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)
  if [ -z "$ep" ]; then
    echo "T+$(( $(date +%s) - START ))s: auth Service endpoints emptied"
    break
  fi
  sleep 1
done

# --- 3. confirm cascade by probing order ----------------------------------
# Open a port-forward to order-service and POST a probe order. The probe id
# is clearly marked '-DELETEME' so if it ever sneaks through (it shouldn't,
# but defense in depth) it's identifiable in the topic. Real test runs use
# uuid-based ids so there is no collision possible.
kubectl -n "$NS" port-forward svc/order ${PROBE_PORT}:3002 >/tmp/break-auth-pf.log 2>&1 &
PF_PID=$!
cleanup_pf() {
  if [ -n "${PF_PID:-}" ] && kill -0 "$PF_PID" 2>/dev/null; then
    kill "$PF_PID" 2>/dev/null
    wait "$PF_PID" 2>/dev/null
  fi
}
trap cleanup_pf EXIT

# Let the port-forward bind locally.
for i in 1 2 3 4 5; do
  curl -sf -o /dev/null --max-time 1 http://localhost:${PROBE_PORT}/health 2>/dev/null && break
  sleep 0.5
done

CASCADED=0
for i in $(seq 1 ${WAIT_TIMEOUT_S}); do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 -X POST \
    -H 'Content-Type: application/json' \
    -d "{\"id\":\"break-probe-${RANDOM}-DELETEME\",\"item\":\"x\"}" \
    http://localhost:${PROBE_PORT}/orders 2>/dev/null)
  if [ "$CODE" = "502" ]; then
    echo "T+$(( $(date +%s) - START ))s: order POST /orders returns 502 — cascade confirmed"
    CASCADED=1
    break
  fi
  sleep 1
done

cleanup_pf
trap - EXIT

echo
if [ $CASCADED -eq 1 ]; then
  echo "[OK] auth is down, cascade is live — ready for orchestrator / test run"
  exit 0
else
  echo "[FAIL] cascade never fired within ${WAIT_TIMEOUT_S}s"
  echo "       check: kubectl -n $NS get pods,endpoints"
  exit 1
fi
