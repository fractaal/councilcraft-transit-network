import WebSocket from "ws";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { YtDlp } from "ytdlp-nodejs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const FFMPEG_PATH = join(__dirname, "bin", "ffmpeg");

const WS_URL = process.env.PA_BACKEND_WS_URL || "ws://localhost:7000/agents";
const AGENT_SECRET = process.env.PA_AGENT_SECRET || "";

const ytDlp = new YtDlp({ ffmpegPath: FFMPEG_PATH });
const installationReady = ytDlp
  .checkInstallationAsync({ ffmpeg: true })
  .catch(() => undefined);

const log = (severity, message, fields = {}) => {
  console.log(JSON.stringify({ severity, message, ...fields }));
};

function normaliseTrack(input) {
  const trimmed = input.trim();
  if (!/^https?:/i.test(trimmed)) {
    if (/^[A-Za-z0-9_-]{11}$/.test(trimmed)) {
      return `https://www.youtube.com/watch?v=${trimmed}`;
    }
    throw new Error("Invalid track identifier");
  }
  return trimmed;
}

function resolveReadable(streamHandle) {
  if (!streamHandle) return null;
  if (typeof streamHandle.pipe === "function") return streamHandle;
  if (streamHandle.stream && typeof streamHandle.stream.pipe === "function") {
    return streamHandle.stream;
  }
  if (streamHandle.stdout && typeof streamHandle.stdout.pipe === "function") {
    return streamHandle.stdout;
  }
  if (Array.isArray(streamHandle) && streamHandle[0] && typeof streamHandle[0].pipe === "function") {
    return streamHandle[0];
  }
  if (streamHandle.readable && typeof streamHandle.readable.pipe === "function") {
    return streamHandle.readable;
  }
  return null;
}

async function handleInfoRequest(ws, message) {
  const { requestId, trackUrl } = message;
  try {
    await installationReady;
    const url = normaliseTrack(String(trackUrl || ""));
    const info = await ytDlp.getInfoAsync(url, { flatPlaylist: false, noWarnings: true });
    if (info?._type === "playlist") {
      throw new Error("Playlists are not supported");
    }
    const durationSeconds = Number(info?.duration ?? info?.duration_seconds ?? 0) || 0;
    ws.send(
      JSON.stringify({
        type: "info_response",
        requestId,
        info: {
          title: info?.title || info?.fulltitle || "",
          channel: info?.channel || info?.uploader || "",
          durationSeconds,
        },
      }),
    );
  } catch (error) {
    ws.send(
      JSON.stringify({
        type: "info_error",
        requestId,
        error: { message: error?.message || String(error) },
      }),
    );
  }
}

async function handleStreamRequest(ws, message) {
  const { requestId, trackUrl } = message;
  let readable;
  try {
    await installationReady;
    const url = normaliseTrack(String(trackUrl || ""));
    const handle = ytDlp.stream(url, {
      format: { filter: "audioonly", quality: "best", type: "best" },
    });
    readable = resolveReadable(handle);
    if (!readable) {
      throw new Error("yt-dlp returned an unsupported stream type");
    }
  } catch (error) {
    ws.send(
      JSON.stringify({
        type: "stream_error",
        requestId,
        error: { message: error?.message || String(error) },
      }),
    );
    return;
  }

  readable.on("data", (chunk) => {
    if (ws.readyState !== WebSocket.OPEN) return;
    const payload = {
      type: "stream_chunk",
      requestId,
      chunk: Buffer.from(chunk).toString("base64"),
    };
    ws.send(JSON.stringify(payload));
  });

  readable.on("end", () => {
    if (ws.readyState !== WebSocket.OPEN) return;
    ws.send(JSON.stringify({ type: "stream_end", requestId }));
  });

  readable.on("error", (error) => {
    if (ws.readyState !== WebSocket.OPEN) return;
    ws.send(
      JSON.stringify({
        type: "stream_error",
        requestId,
        error: { message: error?.message || String(error) },
      }),
    );
  });
}

function buildWebSocketUrl() {
  try {
    const url = new URL(WS_URL);
    if (AGENT_SECRET) {
      url.searchParams.set("secret", AGENT_SECRET);
    }
    return url.toString();
  } catch {
    return WS_URL;
  }
}

function startAgent() {
  const url = buildWebSocketUrl();
  log("INFO", "agent_connecting", { url });
  const ws = new WebSocket(url);

  ws.on("open", () => {
    log("INFO", "agent_connected_to_backend", {});
  });

  ws.on("close", (code, reason) => {
    log("WARN", "agent_disconnected_from_backend", { code, reason: reason?.toString?.() });
    setTimeout(startAgent, 3000);
  });

  ws.on("error", (error) => {
    log("ERROR", "agent_websocket_error", { error: error?.message || String(error) });
  });

  ws.on("message", (data) => {
    let message;
    try {
      const text = typeof data === "string" ? data : data.toString("utf8");
      message = JSON.parse(text);
    } catch (error) {
      log("WARN", "agent_message_parse_failed", { error: error.message });
      return;
    }

    if (!message || typeof message !== "object") return;
    if (message.type === "info_request") {
      handleInfoRequest(ws, message);
    } else if (message.type === "stream_request") {
      handleStreamRequest(ws, message);
    }
  });
}

startAgent();

