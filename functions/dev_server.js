import http from "node:http";
import express from "express";
import { paStream, paInfo } from "./pa_stream.js";
import { agentHub } from "./agent_hub.js";

const app = express();

app.get("/stream", (req, res) => paStream(req, res));
app.get("/info", (req, res) => paInfo(req, res));

const port = Number(process.env.PORT || 7000);
const server = http.createServer(app);

agentHub.attachToServer(server, "/agents");

server.listen(port, () => {
  console.log(`Local PA service listening on http://localhost:${port}`);
  console.log(`Agent WebSocket endpoint ws://localhost:${port}/agents`);
});