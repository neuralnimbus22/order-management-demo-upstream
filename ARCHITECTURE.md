# Architecture

Stub — to be filled in as the system takes shape.

Suggested sections (fill in as we go):

- **System diagram** — auth → order → Kafka → inventory, with the test framework per service.
- **Service contracts** — endpoint signatures, env vars, failure modes.
- **Kafka topology** — single broker (KRaft), topic `order-placed`, partitions, consumer group naming.
- **Failure model** — what "auth down" actually causes at each hop, and why each step is honest (no synthetic shortcuts).
- **Clean-state policy** — how repeated runs avoid false passes from leftover state.
- **Out of scope** — the orchestration layer (TestKube workflows, condition/execute, composite) is documented separately.
