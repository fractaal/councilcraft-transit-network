import WebSocket, { WebSocketServer } from "ws";
import { randomUUID } from "node:crypto";
import { PassThrough } from "node:stream";

const AGENT_SECRET = process.env.PA_AGENT_SECRET || null;
const INFO_TIMEOUT_MS = Number(process.env.PA_AGENT_INFO_TIMEOUT_MS || 15000);
const STREAM_TIMEOUT_MS = Number(process.env.PA_AGENT_STREAM_TIMEOUT_MS || 60000);

const log = (severity, message, fields = {}) => {
  // Keep logging format consistent with pa_stream.js
  console.log(JSON.stringify({ severity, message, ...fields }));
};

class AgentHub {
  constructor() {
    this.wss = null;
    this.agents = new Map(); // agentId -> { ws }
    this.pending = new Map(); // requestId -> { agentId, type, ... }
  }

  attachToServer(server, path = "/agents") {
    if (this.wss) return;
    this.wss = new WebSocketServer({ server, path });
    this.wss.on("connection", (ws, req) => {
      try {
        const url = new URL(req.url || "", `http://${req.headers.host || "localhost"}`);
        if (AGENT_SECRET) {
          const token = url.searchParams.get("secret") || req.headers["x-agent-secret"];
          if (token !== AGENT_SECRET) {
            ws.close(4001, "unauthorised");
            log("WARNING", "agent_connection_rejected", { reason: "secret_mismatch" });
            return;
          }
        }
      } catch {
        // If URL parsing fails, be conservative and drop the connection
        ws.close(4002, "bad_request");
        return;
      }

      const agentId = randomUUID();
      this.agents.set(agentId, { ws });
      log("INFO", "agent_connected", { agentId, count: this.agents.size });

      ws.on("message", (data) => this.handleMessage(agentId, data));
      ws.on("close", () => this.handleDisconnect(agentId, new Error("agent_disconnected")));
      ws.on("error", (err) => this.handleDisconnect(agentId, err));
    });
  }

  hasAgents() {
    return this.agents.size > 0;
  }

  pickAgent() {
    for (const [agentId, { ws }] of this.agents.entries()) {
      if (ws.readyState === WebSocket.OPEN) {
        return { agentId, ws };
      }
    }
    return null;
  }

  requestInfo(trackUrl) {
    const chosen = this.pickAgent();
    if (!chosen) {
      throw new Error("no_agents_available");
    }
    const { agentId, ws } = chosen;
    const requestId = randomUUID();

    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.pending.delete(requestId);
        reject(new Error("agent_info_timeout"));
      }, INFO_TIMEOUT_MS);

      this.pending.set(requestId, {
        type: "info",
        agentId,
        resolve: (value) => {
          clearTimeout(timeout);
          this.pending.delete(requestId);
          resolve(value);
        },
        reject: (error) => {
          clearTimeout(timeout);
          this.pending.delete(requestId);
          reject(error);
        },
      });

      try {
        ws.send(
          JSON.stringify({ type: "info_request", requestId, trackUrl }),
          (err) => {
            if (err) {
              const entry = this.pending.get(requestId);
              if (entry) {
                entry.reject(err);
              }
            }
          },
        );
      } catch (error) {
        const entry = this.pending.get(requestId);
        if (entry) {
          entry.reject(error);
        }
      }
    });
  }

  createAudioStream(trackUrl) {
    const chosen = this.pickAgent();
    if (!chosen) {
      throw new Error("no_agents_available");
    }
    const { agentId, ws } = chosen;
    const requestId = randomUUID();
    const stream = new PassThrough();

    const timeout = setTimeout(() => {
      const entry = this.pending.get(requestId);
      if (entry && entry.type === "stream") {
        this.pending.delete(requestId);
        stream.destroy(new Error("agent_stream_timeout"));
      }
    }, STREAM_TIMEOUT_MS);

    this.pending.set(requestId, {
      type: "stream",
      agentId,
      stream,
      timeout,
    });

    try {
      ws.send(
        JSON.stringify({ type: "stream_request", requestId, trackUrl }),
        (err) => {
          if (err) {
            const entry = this.pending.get(requestId);
            if (entry && entry.type === "stream") {
              clearTimeout(entry.timeout);
              this.pending.delete(requestId);
              stream.destroy(err);
            }
          }
        },
      );
    } catch (error) {
      const entry = this.pending.get(requestId);
      if (entry && entry.type === "stream") {
        clearTimeout(entry.timeout);
        this.pending.delete(requestId);
        stream.destroy(error);
      }
    }

    return stream;
  }

  handleMessage(agentId, data) {
    let message;
    try {
      const text = typeof data === "string" ? data : data.toString("utf8");
      message = JSON.parse(text);
    } catch (error) {
      log("WARN", "agent_message_parse_failed", { agentId, error: error.message });
      return;
    }

    const { type, requestId } = message;
    if (!requestId || !type) {
      return;
    }
    const entry = this.pending.get(requestId);
    if (!entry || entry.agentId !== agentId) {
      return;
    }

    if (entry.type === "info") {
      if (type === "info_response") {
        entry.resolve(message.info || {});
      } else if (type === "info_error") {
        const err = new Error(message.error?.message || "agent_info_error");
        entry.reject(err);
      }
      return;
    }

    if (entry.type === "stream") {
      if (type === "stream_chunk" && typeof message.chunk === "string") {
        const chunk = Buffer.from(message.chunk, "base64");
        entry.stream.write(chunk);
      } else if (type === "stream_end") {
        clearTimeout(entry.timeout);
        this.pending.delete(requestId);
        entry.stream.end();
      } else if (type === "stream_error") {
        clearTimeout(entry.timeout);
        this.pending.delete(requestId);
        const err = new Error(message.error?.message || "agent_stream_error");
        entry.stream.destroy(err);
      }
    }
  }

  handleDisconnect(agentId, error) {
    const err = error instanceof Error ? error : new Error(String(error));
    for (const [requestId, entry] of this.pending.entries()) {
      if (entry.agentId !== agentId) continue;
      this.pending.delete(requestId);
      if (entry.type === "info") {
        entry.reject(err);
      } else if (entry.type === "stream") {
        clearTimeout(entry.timeout);
        entry.stream.destroy(err);
      }
    }
    this.agents.delete(agentId);
    log("INFO", "agent_disconnected", { agentId, count: this.agents.size });
  }
}

export const agentHub = new AgentHub();

