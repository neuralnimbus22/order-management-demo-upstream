// auth-service — the deepest upstream service. This is the one the demo
// breaks (scale to 0) to trigger the cascade.
//
// Endpoints:
//   GET  /health     → {status:"ok"}        liveness
//   POST /authorize  → {authorized:true}    always 200 (no real auth logic;
//                                            failure is modeled by taking the
//                                            whole service down)

const express = require('express');

const PORT = parseInt(process.env.PORT || '3001', 10);

const app = express();
app.use(express.json());

app.get('/health', (_req, res) => {
  res.json({ status: 'ok' });
});

app.post('/authorize', (_req, res) => {
  res.json({ authorized: true });
});

const server = app.listen(PORT, () => {
  console.log(`[auth] listening on :${PORT}`);
});

// Exit immediately on SIGTERM so the pod terminates fast when scaled to 0.
// Without this, Node ignores SIGTERM and Kubernetes waits the full
// terminationGracePeriodSeconds before SIGKILL — making the cascade in the
// demo take ~30s instead of a few seconds.
process.on('SIGTERM', () => {
  console.log('[auth] SIGTERM — shutting down');
  server.close(() => process.exit(0));
});
