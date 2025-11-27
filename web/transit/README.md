# Transit Control Plane (Web)

This directory contains a small Node/Express + petite-vue web app that acts as an HTTP **control plane** for the CouncilCraft Transit ops node.

- Ops (`transit.lua` in **ops mode**) periodically POSTs telemetry here.
- The web app stores the latest snapshot in memory and exposes:
  - A JSON API for a browser dashboard.
  - Per-line **maintenance** flags that ops honours when deciding dispatch.

> This is intended for a trusted LAN / dev environment. It does **not** persist any state and is **not** hardened for the public internet.

---

## Directory Layout

- `server.js` – Express app exposing the control-plane API + serving static files.
- `public/index.html` – petite-vue dashboard UI.
- `public/style.css` – 80s ComputerCraft-style theme.
- `package.json`, `package-lock.json` – Node dependencies (primarily `express`).

---

## Prerequisites

- Node.js (LTS is fine: 18+ recommended).

Install dependencies (once):

```bash
cd web/transit
npm install
```

> The repo already includes a `package-lock.json` pinned to a working set of versions.

---

## Running the Server

From the repo root:

```bash
cd web/transit
node server.js
# or, if you add a script:
# npm start
```

Defaults:

- Listens on `http://localhost:8081` (configurable via `PORT` env var).
- Serves the dashboard at `/`.

Health check:

```bash
curl http://localhost:8081/health
# { "ok": true, "hasOpsState": false }
```

---

## Wiring Ops to the Control Plane

On the **ops** ComputerCraft node, set `control_plane_url` in its config (e.g. `/.transit_config`) to point at the control-plane endpoint:

```lua
control_plane_url = "http://YOUR-HOST:8081/control-plane/ops-state"
```

Notes:

- When `control_plane_url` is `nil` or empty, ops does **not** perform any HTTP.
- Ops sends a compact JSON snapshot every `control_plane_push_interval` seconds (default `2`).
- The HTTP integration is fully asynchronous (uses `http.request` + `http_success`/`http_failure`).

---

## API Overview

### 1) Ops → Control Plane

`POST /control-plane/ops-state`

- Body: JSON payload built by `transit.lua` (type `"ops_state"`).
- Effect: server updates `latestOpsState` in memory.
- Response: line-level overrides ops should honour, e.g.

```json
{
  "lines": {
    "red_line":  { "maintenance": true },
    "blue_line": { "maintenance": false }
  }
}
```

### 2) Browser → Control Plane

`GET /api/state`

- Returns the latest ops snapshot plus current overrides:

```json
{
  "ops": { "type": "ops_state", "lines": { "red_line": { /* ... */ } } },
  "overrides": {
    "red_line": { "maintenance": true }
  }
}
```

`POST /api/lines/:lineId/maintenance`

- Request body:

```json
{ "maintenance": true }
```

- Response:

```json
{ "ok": true, "lineId": "red_line", "maintenance": true }
```

The petite-vue UI in `public/index.html` uses these endpoints to:

- Poll `/api/state` every ~2 seconds.
- Render lines and stations.
- Toggle per-line maintenance flags which ops respects when deciding dispatch.

---

## Persistence & Safety

- State is **in-memory only**:
  - If you restart `server.js`, it forgets telemetry and overrides until ops sends again.
- There is no authentication or CSRF protection.
  - Run it only on trusted networks, or put it behind your own reverse proxy/auth if needed.

