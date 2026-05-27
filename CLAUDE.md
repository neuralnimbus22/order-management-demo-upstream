# CLAUDE.md — order-management-demo-upstream

## What this is
A three-service demo whose purpose is to make **upstream root-cause confirmation** visible end to end. The downstream test fails first (with a clear "message never arrived" symptom); an orchestrator (built **outside this repo**, in TestKube) walks back along the real dependency chain and confirms which boundary actually broke. The application here is deliberately decoupled from how it gets tested so the orchestration layer can be reasoned about on its own. See `ARCHITECTURE.md` for the deeper story.

## Architecture
```
auth-service         (deepest upstream — the one we break)
     │  order calls auth /authorize before doing anything
     ▼
order-service        (middle — victim AND producer)
     │  publishes "order-placed" event
     ▼
[ Kafka topic: order-placed ]   ← boundary where the cause goes invisible
     │  inventory consumes it
     ▼
inventory-service    (downstream "edge" — its test fails first)
```
**Failure flows down. The deepest upstream break is the true cause.**
- All three services are Node.js + Express. Order + inventory use `kafkajs`. Auth is pure HTTP.
- Kafka runs single-node KRaft (no Zookeeper) inside the cluster.
- All in namespace **`order-demo`**.

### Non-negotiable correctness rules (encoded in code, not in tests)
- `order` genuinely calls `auth` over HTTP before publishing. If `auth` is unreachable, `order` returns `502` and **never** calls `producer.send`. No fallback path.
- `inventory` genuinely consumes from Kafka. If no message arrives, the test genuinely times out — no synthetic assertion shortcut.

## Key directories
| Path | Contents |
|---|---|
| `services/auth/server.js` | `POST /authorize` always `200 {authorized:true}`; failure modeled by scaling the deployment to 0. Has SIGTERM handler for fast termination. |
| `services/order/server.js` | `POST /orders` → real `fetch` to `${AUTH_URL}/authorize` (2s timeout) → only on success calls `producer.send` on topic `order-placed`. |
| `services/inventory/server.js` | Express `/health` + `/processed/:id` AND a `kafkajs` consumer (group `inventory-service`, `fromBeginning: true`) in the same process. In-memory `Map` records processed ids. |
| `services/*/Dockerfile` | All `node:20-alpine`, `npm install --omit=dev`, run as USER `node`. |
| `kafka/kafka.yaml` | `apache/kafka:3.7.0` KRaft single-node combined mode (broker+controller), `emptyDir` storage, auto-create-topics enabled. |
| `k8s/namespace.yaml` | Creates `order-demo`. |
| `k8s/{auth,order,inventory}.yaml` | Deployment + Service for each. Images `ghcr.io/neuralnimbus22/order-demo-{auth,order,inventory}:latest` (public GHCR), `imagePullPolicy: IfNotPresent`. Auth has `terminationGracePeriodSeconds: 5`. |
| `tests/auth/test_auth.py` | pytest. Genuinely calls auth `/authorize`; fails with "AUTH-SERVICE UNREACHABLE" on connection error. |
| `tests/order/order.postman_collection.json` | Newman. Real `POST /orders` with assertions on `201` + `status:"placed"`. Fails with "expected 201 got 502" when auth is down. |
| `tests/inventory/test_inventory.py` | pytest. Places an order then polls `/processed/:id`. **Does not abort on order-side errors** — the inventory team's only verdict is "did the message arrive?". Failure message starts with `MESSAGE NEVER ARRIVED`. |
| `scripts/deploy.sh` | **One-command bring-up.** namespace → Kafka + wait → topic pre-create → services + wait → rollout-restart order/inventory (Kafka race) → sanity-check. Idempotent. |
| `scripts/break-auth.sh` | Scales auth → 0 and waits until cascade is observable (POST /orders returns 502). Typical 2–5s, capped by `WAIT_TIMEOUT_S=30`. |
| `scripts/restore.sh` | Scales auth → 1, deletes + recreates topic, restarts inventory (wipes in-memory Map), verifies with a real order, then resets topic + inventory ONCE MORE so HWM=0. |
| `scripts/sanity-check.sh` | Per-deployment health + topic existence + topic high-water-mark. `[OK]/[WARN]/[FAIL]` markers. |
| `scripts/place-order.sh` | Healthy-path helper: place one order, confirm inventory processed it. |
| `testkube/README.md` | Intentionally empty marker — TestWorkflows are built by hand outside this repo. |

## How to run / deploy
**Build images locally** (tag with the GHCR path so `IfNotPresent` uses your local build without pulling — fresh machines pull from GHCR automatically):
```bash
cd services/auth      && docker build -t ghcr.io/neuralnimbus22/order-demo-auth:latest .
cd ../order           && docker build -t ghcr.io/neuralnimbus22/order-demo-order:latest .
cd ../inventory       && docker build -t ghcr.io/neuralnimbus22/order-demo-inventory:latest .
# Optional: push to GHCR to share with other clusters
# docker push ghcr.io/neuralnimbus22/order-demo-auth:latest   (etc.)
```

**Deploy everything to k8s (one command):**
```bash
./scripts/deploy.sh
```
What it does, in order: applies `k8s/namespace.yaml` → applies `kafka/` and waits for Kafka Available → pre-creates the `order-placed` topic (auto-create only fires on first PRODUCE, so consumers need this) → applies `k8s/` (auth + order + inventory) → waits for all three Deployments Available → rollout-restarts order + inventory to clear the Kafka client race → runs `scripts/sanity-check.sh`. Idempotent.

If you'd rather apply manually:
```bash
kubectl apply -f k8s/namespace.yaml
kubectl apply -f kafka/
kubectl -n order-demo wait --for=condition=available --timeout=180s deploy/kafka
kubectl -n order-demo exec deploy/kafka -- /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server localhost:9092 --create --if-not-exists \
  --topic order-placed --partitions 1 --replication-factor 1
kubectl apply -f k8s/
kubectl -n order-demo rollout restart deploy/order deploy/inventory
```

**Sanity check:** `./scripts/sanity-check.sh` → expects all `[OK]`.

**Demo cycle (run from outside the cluster — scripts handle port-forwards themselves):**
```bash
./scripts/place-order.sh    # green-path proof
./scripts/break-auth.sh     # take auth down + wait for cascade
# … run downstream test or your orchestrator here …
./scripts/restore.sh        # bring auth back, reset state, verify
```

**Run a test standalone (port-forward first):**
```bash
kubectl -n order-demo port-forward svc/auth      13001:3001 &
kubectl -n order-demo port-forward svc/order     13002:3002 &
kubectl -n order-demo port-forward svc/inventory 13003:3003 &

# pytest (deps in tests/auth/requirements.txt or tests/inventory/requirements.txt)
AUTH_URL=http://localhost:13001 pytest tests/auth/test_auth.py -v
ORDER_URL=http://localhost:13002 INVENTORY_URL=http://localhost:13003 \
  pytest tests/inventory/test_inventory.py -v

# newman
npx --yes newman run tests/order/order.postman_collection.json \
  --env-var baseUrl=http://localhost:13002
```

## Conventions / gotchas
- **Namespace is `order-demo`** for the workload; the TestKube agent (where orchestrator runs) lives elsewhere — this repo doesn't deploy it.
- **Images come from public GHCR** (`ghcr.io/neuralnimbus22/order-demo-{auth,order,inventory}:latest`) with `imagePullPolicy: IfNotPresent`. Clusters without the image cached pull from GHCR automatically. For local iteration, build with the same ghcr-prefixed tag and the kubelet uses your local build instead of pulling.
- **Tests must run in different frameworks on purpose** (pytest / Newman / pytest). The tool heterogeneity is what proves the future orchestrator is tool-agnostic.
- **Inventory test does NOT fail on order-side errors** — it logs them and proceeds. The only verdict is "message arrived?". This makes the symptom the orchestrator sees clean and consistent ("MESSAGE NEVER ARRIVED"), regardless of where upstream broke.
- **`break-auth.sh` returns ONLY after cascade is observable** — `POST /orders → 502` is confirmed via probe. No race window for the next step.
- **`restore.sh` resets all three state layers** — Kafka log (topic delete + recreate), consumer offset (inventory restart), in-memory `processed` Map (inventory restart). Skipping any layer can cause false passes.
- **Auth has a SIGTERM handler + `terminationGracePeriodSeconds: 5`** in `k8s/auth.yaml`. Without these, the default 30s grace period made the cascade take ~31s instead of ~2–5s.
- **Kafka consumer + auto-create-topics interaction**: auto-create fires on PRODUCE, not SUBSCRIBE. If inventory starts before any order is published, its subscribe errors. Fix: pre-create the topic (the bring-up commands above do this).
- **Kafka client retry window**: `kafkajs` retries a broker connect ~5 times (~15s total) and then **gives up permanently**, leaving the pod alive but disconnected. If order/inventory pods start before Kafka is reachable (e.g. all manifests applied in one shot), they end up "Ready but broken". Fix: rollout-restart order + inventory after Kafka is proven up. `scripts/deploy.sh` does this automatically as its step 6 — if you bring the stack up manually, do the restart yourself.
- **Scripts use port-forwards internally** — they assume a working `kubectl` and proper cluster context. No external load balancer needed.
- **No TestKube content in this repo.** `testkube/` is intentionally empty; orchestration lives outside.

## Common tasks
- **Modify a service** → edit `services/<name>/server.js`, rebuild (`docker build -t ghcr.io/neuralnimbus22/order-demo-<name>:latest .`), `kubectl -n order-demo rollout restart deploy/<name>`. To publish for other clusters: `docker push ghcr.io/neuralnimbus22/order-demo-<name>:latest`.
- **Tune the cascade demo timing** → `WAIT_TIMEOUT_S`, `HEALTHY_POLL_TIMEOUT_S`, `INVENTORY_POLL_TIMEOUT_S` env vars in the relevant scripts/tests.
- **Add a new test in a different framework** → drop it in `tests/<framework>/`. Use env vars for URLs (`AUTH_URL`, `ORDER_URL`, `INVENTORY_URL`). Don't bake in invocation assumptions — the orchestrator wraps it later.
- **Reset state after a failed run** → `./scripts/restore.sh` (idempotent — works whether auth was down or up).
- **Debug "test fails but I don't know why"** → start at the downstream test's failure message, then walk back: `kubectl -n order-demo get pods,endpoints`, `kubectl -n order-demo logs deploy/inventory`, `kubectl -n order-demo exec deploy/kafka -- /opt/kafka/bin/kafka-get-offsets.sh --bootstrap-server localhost:9092 --topic order-placed --time -1`.
