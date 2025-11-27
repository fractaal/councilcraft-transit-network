const express = require('express');
const path = require('path');

// In-memory state for the transit control plane.
// - latestOpsState: last snapshot posted by the ops ComputerCraft node
// - lineOverrides: line_id -> { maintenance: boolean }
let latestOpsState = null;
let lineOverrides = {};

const app = express();
app.use(express.json({ limit: '1mb' }));

// Serve the dashboard frontend
app.use(express.static(path.join(__dirname, 'public')));

// Ops node POSTs its current state here.
// transit.lua should set control_plane_url to this endpoint.
//   e.g. control_plane_url = "http://your-host:8081/control-plane/ops-state"
app.post('/control-plane/ops-state', (req, res) => {
  latestOpsState = req.body || null;

  // Sync maintenance state from ops telemetry.
  // Ops may guard against clearing maintenance (e.g., not all stations in SHUTDOWN yet),
  // so we trust the ops-reported maintenance state as the source of truth.
  if (latestOpsState && latestOpsState.lines) {
    for (const [lineId, lineInfo] of Object.entries(latestOpsState.lines)) {
      if (lineInfo && typeof lineInfo.maintenance === 'boolean') {
        lineOverrides[lineId] = { ...(lineOverrides[lineId] || {}), maintenance: lineInfo.maintenance };
      }
    }
  }

  // Send current overrides to ops (including any pending requests).
  res.json({ lines: lineOverrides });
});

// Browser UI polls this for the latest state.
app.get('/api/state', (req, res) => {
  res.json({ ops: latestOpsState, overrides: lineOverrides });
});

// Browser UI toggles line-level maintenance here.
app.post('/api/lines/:lineId/maintenance', (req, res) => {
  const lineId = req.params.lineId;
  if (!lineId) {
    return res.status(400).json({ error: 'Missing lineId' });
  }

  const maintenance = !!(req.body && req.body.maintenance);

  // Ensure we always store a simple boolean flag.
  const current = lineOverrides[lineId] || {};
  lineOverrides[lineId] = { ...current, maintenance };

  res.json({ ok: true, lineId, maintenance });
});

// Simple health check
app.get('/health', (req, res) => {
  res.json({ ok: true, hasOpsState: !!latestOpsState });
});

// Export the app for testing, and only start the server if run directly.
module.exports = app;

if (require.main === module) {
  const PORT = process.env.PORT || 8081;
  app.listen(PORT, () => {
    console.log(`Transit control plane listening on http://localhost:${PORT}`);
  });
}

