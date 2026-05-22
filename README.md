# order-management-demo-upstream

A small three-service demo whose purpose is to make **upstream root-cause confirmation** visible end to end. The failure case is deliberate: a downstream test reports the symptom, then an orchestrator (built separately in TestKube — **not** in this repo) walks back along the real dependency chain and confirms which boundary actually broke.

## The story

A real dependency chain. Failure flows **down**; the deepest **upstream** break is the true cause.

```
auth-service           (deepest upstream — stands in for "IAM nobody downstream sees into")
      │
      │   order-service must call auth before it can act
      ▼
order-service          (middle — victim AND producer; publishes to Kafka)
      │
      │   publishes "order-placed" event
      ▼
[ Kafka topic: order-placed ]   ← boundary where the cause goes invisible
      │
      │   inventory-service consumes it
      ▼
inventory-service      (downstream "edge" — its test fails first with
                        "message never arrived")
```

When `auth` is down, the cascade is:

1. `order-service` calls `auth.POST /authorize` → it fails.
2. `order-service` refuses to publish to Kafka. (This is the key honesty rule below.)
3. `inventory-service` never receives a message → its downstream test times out with a clear "message never arrived" assertion.

From the downstream test's perspective the only thing visible is the missing message. The upstream cause (`auth` down) is invisible across the Kafka boundary — that invisibility is the whole point of the demo.

## Dependency-direction rules (non-negotiable)

These rules make the demo honest. The orchestration layer can only prove what the system actually does.

- **Dependencies are real, never faked.** `order` genuinely calls `auth`; `inventory` genuinely consumes from Kafka. There is no staged cascade — if you stop `auth`, the cascade fires because the code paths really require those calls.
- **If `auth` is unreachable, `order` MUST fail to publish.** Not a soft-warn, not a fallback "publish anyway" — a hard refusal. Otherwise inventory would still see the message and the demo collapses.
- **If `order` never published, `inventory` MUST genuinely time out** waiting on the consumer. Not a synthetic assertion error — a real "I waited and nothing arrived" condition.
- **Each test runs in a different framework on purpose.** pytest for inventory, Postman/Newman for order, pytest for auth. The orchestrator that walks upstream has to be tool-agnostic, and proving that requires actual heterogeneity.

## What's in this repo

The application + the raw plumbing that any test orchestrator can drive:

| Path | Contents |
|---|---|
| `services/auth`, `services/order`, `services/inventory` | The three tiny services |
| `kafka/` | KRaft-mode single-broker Kafka manifests + topic setup |
| `k8s/` | Per-service Deployment + Service manifests + namespace |
| `tests/auth`, `tests/order`, `tests/inventory` | Per-team raw test files — runnable standalone |
| `scripts/` | Healthy-path helpers, `break-auth.sh`, `restore.sh`, `sanity-check.sh` |
| `testkube/` | Intentionally empty — see `testkube/README.md` |

## What's NOT in this repo

The TestKube TestWorkflows, the orchestrator that walks upstream, the condition/execute branching logic, the composite workflow, and any control-plane wiring all live **outside** this repo and are built separately, by hand. The application here is deliberately decoupled from how it gets tested so that the orchestration layer can be reasoned about on its own.
