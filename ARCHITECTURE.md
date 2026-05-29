# Architecture

## 1. System overview

An order-management system composed of four components arranged in a strict dependency chain. Each component has a single, well-defined role; failures propagate in one direction along the chain.

## 2. Dependency chain and failure direction

```
auth-service  ──►  order-service  ──►  Kafka (order-placed topic)  ──►  inventory-service
                                       ────────────────────────────
                                       message-passing boundary
```

| Component | Role |
|---|---|
| **auth-service** | Deepest upstream. Authorizes the order. `order-service` calls it first; nothing else proceeds without its OK. |
| **order-service** | Middle of the chain. Calls `auth-service` to authorize, then — and only then — publishes an `order-placed` event to Kafka. |
| **Kafka — `order-placed` topic** | The message-passing boundary between `order-service` (producer) and `inventory-service` (consumer). |
| **inventory-service** | Downstream consumer of the `order-placed` topic. The first place a failure surfaces as an observable symptom. |

**Failure direction rule:** failures flow strictly downstream. A break anywhere in the chain manifests at, or downstream of, the break point. **The deepest upstream break is the true root cause** — any downstream symptom is a consequence, not the cause.

## 3. In-cluster addresses

All four components run in the `order-demo` namespace. Reachable from inside the cluster at:

| Component | Address | Health-probe surface |
|---|---|---|
| `auth-service` | `auth.order-demo.svc.cluster.local:3001` | HTTP |
| `order-service` | `order.order-demo.svc.cluster.local:3002` | HTTP |
| `inventory-service` | `inventory.order-demo.svc.cluster.local:3003` | HTTP |
| Kafka broker | `kafka.order-demo.svc.cluster.local:9092` | TCP |
| Kafka topic | `order-placed` | — |

## 4. Where the tests live

Each service owns its own test folder under `tests/` in this repo:

```
tests/
├── auth/
├── order/
└── inventory/
```

The contents of each folder are the source of truth for what that service's test does and how to invoke it — discover by reading the folder. This file deliberately does not describe frameworks, commands, images, or environment variables.

## 5. Repository

- **Git URL:** `https://github.com/neuralnimbus22/order-management-demo-upstream`
- **Default branch:** `main`

TestKube workflows targeting this system should pull test code from the paths above on this branch.
