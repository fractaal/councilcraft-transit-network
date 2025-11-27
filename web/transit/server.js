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

  // If ops never told us about this line before but we have overrides,
  // we still send them back so ops can honour them when the line appears.
  res.json({ lines: lineOverrides });
});

// Browser UI polls this for the latest state.
app.get('/api/state', (req, res) => {
  res.json({ ops: latestOpsState, overrides: lineOverrides });
});

// Helper: can we safely clear maintenance for a line?
// We only allow clearing once ALL stations on that line are in SHUTDOWN.
function canClearMaintenance(lineId) {
  if (!latestOpsState || !latestOpsState.lines) return false;
  const line = latestOpsState.lines[lineId];
  if (!line || !Array.isArray(line.stations) || line.stations.length === 0) return false;
  return line.stations.every((st) => st && st.state === 'SHUTDOWN');
}

// Browser UI toggles line-level maintenance here.
app.post('/api/lines/:lineId/maintenance', (req, res) => {
  const lineId = req.params.lineId;
  if (!lineId) {
    return res.status(400).json({ error: 'Missing lineId' });
  }

  const requested = !!(req.body && req.body.maintenance);

  const current = lineOverrides[lineId] || {};

  if (requested) {
    // Always allow entering maintenance: this marks the line "for maintenance".
    lineOverrides[lineId] = { ...current, maintenance: true };
    return res.json({ ok: true, lineId, maintenance: true });
  }

  // requested === false: only allow clearing if all stations are already in SHUTDOWN.
  if (canClearMaintenance(lineId)) {
    lineOverrides[lineId] = { ...current, maintenance: false };
  } else {
    // Guard: keep maintenance latched until the line is fully in maintenance.
    lineOverrides[lineId] = { ...current, maintenance: true };
  }

  res.json({ ok: true, lineId, maintenance: lineOverrides[lineId].maintenance });
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

