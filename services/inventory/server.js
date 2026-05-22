// inventory-service — downstream "edge" service. Real, non-fakeable dependency:
// it consumes from Kafka. If no message arrives on the topic, no order id ever
// shows up under /processed/:id and the test genuinely times out — which is
// exactly the symptom the orchestrator will see when auth is down upstream.
//
// In-process the service runs two things concurrently:
//   * an HTTP server exposing /health and /processed/:id
//   * a kafkajs consumer subscribed to KAFKA_TOPIC that records processed ids
//
// Both share the `processed` Map. State is in-memory only — restarts wipe it,
// which is fine for a demo (and is exactly what we want for clean reruns).

const express = require('express');
const { Kafka, logLevel } = require('kafkajs');

const PORT           = parseInt(process.env.PORT || '3003', 10);
const KAFKA_BROKERS  = (process.env.KAFKA_BROKERS || 'localhost:9092').split(',');
const KAFKA_TOPIC    = process.env.KAFKA_TOPIC    || 'order-placed';
const KAFKA_GROUP_ID = process.env.KAFKA_GROUP_ID || 'inventory-service';

const app = express();

// id (string) → ISO timestamp the message was processed at.
const processed = new Map();

app.get('/health', (_req, res) => {
  res.json({ status: 'ok' });
});

app.get('/processed/:id', (req, res) => {
  const id = req.params.id;
  if (processed.has(id)) {
    res.json({ id, processed: true, processedAt: processed.get(id) });
  } else {
    res.status(404).json({ id, processed: false });
  }
});

const kafka = new Kafka({
  clientId: 'inventory-service',
  brokers: KAFKA_BROKERS,
  logLevel: logLevel.WARN,
});
const consumer = kafka.consumer({ groupId: KAFKA_GROUP_ID });

async function startConsumer() {
  await consumer.connect();
  console.log('[inventory] kafka consumer connected');
  // fromBeginning: true so we don't lose messages published while the
  // consumer was still rebalancing. Combined with a fresh topic per run
  // (see scripts/restore.sh), this guarantees the test sees every event
  // published during the run regardless of timing.
  await consumer.subscribe({ topic: KAFKA_TOPIC, fromBeginning: true });
  await consumer.run({
    eachMessage: async ({ message }) => {
      const payload = JSON.parse(message.value.toString());
      processed.set(String(payload.id), new Date().toISOString());
      console.log(`[inventory] processed order id=${payload.id}`);
    },
  });
}

startConsumer().catch((err) => {
  console.error('[inventory] consumer failed to start:', err.message);
});

app.listen(PORT, () => {
  console.log(`[inventory] listening on :${PORT}`);
  console.log(`[inventory] kafka       : ${KAFKA_BROKERS.join(',')} topic=${KAFKA_TOPIC} group=${KAFKA_GROUP_ID}`);
});

process.on('SIGTERM', async () => {
  console.log('[inventory] shutting down');
  await consumer.disconnect().catch(() => {});
  process.exit(0);
});
