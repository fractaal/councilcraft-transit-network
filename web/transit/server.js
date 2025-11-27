const express = require('express');
const path = require('path');

// In-memory state for the transit control plane.
// - latestOpsState: last snapshot posted by the ops ComputerCraft node
// - lineOverrides: line_id -> { maintenance: boolean, force_dispatch?: boolean }
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

	  // Prepare a snapshot of overrides to send to ops.
	  // Any one-shot commands (e.g. force_dispatch) are cleared after sending
	  // so they are only applied once by ops.
	  const linesToSend = {};
	  for (const [lineId, cfg] of Object.entries(lineOverrides)) {
	    linesToSend[lineId] = { ...cfg };
	    if (cfg.force_dispatch) {
	      delete lineOverrides[lineId].force_dispatch;
	    }
	  }

	  res.json({ lines: linesToSend });
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

	// Browser UI requests a one-shot force dispatch for a specific line here.
	// This is analogous to pressing 'd' in ops, but scoped to a single line.
	app.post('/api/lines/:lineId/force-dispatch', (req, res) => {
	  const lineId = req.params.lineId;
	  if (!lineId) {
	    return res.status(400).json({ error: 'Missing lineId' });
	  }

	  const current = lineOverrides[lineId] || {};
	  lineOverrides[lineId] = { ...current, force_dispatch: true };

	  res.json({ ok: true, lineId });
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

