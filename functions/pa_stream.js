import { onRequest } from "firebase-functions/v2/https";
import { spawn } from "node:child_process";
import { randomUUID, createHash } from "node:crypto";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { createReadStream, createWriteStream, existsSync, mkdirSync } from "node:fs";
import { PassThrough } from "node:stream";
import { YtDlp } from "ytdlp-nodejs";
import { Storage } from "@google-cloud/storage";

const __dirname = dirname(fileURLToPath(import.meta.url));
const FFMPEG_PATH = join(__dirname, "bin", "ffmpeg");

const API_KEY = "COUNCILCRAFT_MINECRAFT_SERVER_XD";

// Local cache mode for development (set USE_LOCAL_CACHE=true or NODE_ENV=development)
const USE_LOCAL_CACHE = process.env.USE_LOCAL_CACHE === "true" || process.env.NODE_ENV === "development";
const LOCAL_CACHE_DIR = join(__dirname, "cache");
const CACHE_BUCKET = process.env.CACHE_BUCKET || process.env.GCLOUD_PROJECT + ".appspot.com";
const CACHE_PREFIX = "dfpwm_cache/";

const ytDlp = new YtDlp({ ffmpegPath: FFMPEG_PATH });
const storage = USE_LOCAL_CACHE ? null : new Storage();

// Ensure local cache directory exists
if (USE_LOCAL_CACHE && !existsSync(LOCAL_CACHE_DIR)) {
  mkdirSync(LOCAL_CACHE_DIR, { recursive: true });
}
const ffmpegArgs = [
  "-loglevel",
  "error",
  "-i",
  "pipe:0",
  "-f",
  "dfpwm",
  "-ar",
  "48000",
  "-ac",
  "1",
  "pipe:1",
];

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

function secondsToTimestamp(seconds) {
  if (!Number.isFinite(seconds) || seconds <= 0) {
    return "0:00";
  }
  const whole = Math.floor(seconds);
  const hours = Math.floor(whole / 3600);
  const minutes = Math.floor((whole % 3600) / 60);
  const secs = whole % 60;
  const pad = (value) => value.toString().padStart(2, "0");
  return hours > 0
    ? `${hours}:${pad(minutes)}:${pad(secs)}`
    : `${minutes}:${pad(secs)}`;
}

function ensureAuthorised(req, res) {
  const provided = typeof req.query.key === "string" ? req.query.key : "";
  if (provided !== API_KEY) {
    log("WARNING", "unauthorised_request", { path: req.path || "", query: req.query });
    res.status(403).send("Forbidden: invalid or missing key");
    return false;
  }
  return true;
}

function resolveReadable(streamHandle) {
  if (!streamHandle) {
    return null;
  }
  if (typeof streamHandle.pipe === "function") {
    return streamHandle;
  }
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

function getCacheKey(trackUrl) {
  const hash = createHash("sha256").update(trackUrl).digest("hex");
  if (USE_LOCAL_CACHE) {
    return join(LOCAL_CACHE_DIR, `${hash}.dfpwm`);
  }
  return `${CACHE_PREFIX}${hash}.dfpwm`;
}

// Local filesystem cache helpers
async function checkLocalCache(cacheKey) {
  return existsSync(cacheKey);
}

function createLocalCacheReadStream(cacheKey) {
  return createReadStream(cacheKey);
}

function createLocalCacheWriteStream(cacheKey) {
  return createWriteStream(cacheKey);
}

export const paStream = onRequest(
  { memory: "1024MiB", maxInstances: 2, timeoutSeconds: 540 },
  async (req, res) => {
    const requestId = randomUUID();
    log("INFO", "stream_request_received", {
      requestId,
      method: req.method,
      track: req.query.track,
      sourceIp: req.ip,
    });
    if (req.method !== "GET") {
      res.status(405).send(`Method Not Allowed: ${req.method}`);
      log("WARNING", "stream_request_rejected", { requestId, reason: "method" });
      return;
    }
    if (!ensureAuthorised(req, res)) {
      log("WARNING", "stream_request_rejected", { requestId, reason: "unauthorised" });
      return;
    }

    const trackParam = req.query.track;
    if (typeof trackParam !== "string" || trackParam.trim() === "") {
      res.status(400).send("Missing track parameter: pass ?track=<youtube url or id>");
      log("WARNING", "stream_request_rejected", { requestId, reason: "missing_track" });
      return;
    }

    let trackUrl;
    try {
      trackUrl = normaliseTrack(trackParam);
    } catch (error) {
      res.status(400).send(`Invalid track parameter: ${error.message || error}`);
      log("WARNING", "stream_request_rejected", { requestId, reason: "invalid_track" });
      return;
    }

    await installationReady;

    // Check cache first
    const cacheKey = getCacheKey(trackUrl);

    try {
      let exists = false;
      if (USE_LOCAL_CACHE) {
        exists = await checkLocalCache(cacheKey);
      } else {
        const bucket = storage.bucket(CACHE_BUCKET);
        const cacheFile = bucket.file(cacheKey);
        [exists] = await cacheFile.exists();
      }

      if (exists) {
        log("INFO", "cache_hit", { requestId, trackUrl, cacheKey, mode: USE_LOCAL_CACHE ? "local" : "cloud" });
        res.setHeader("Content-Type", "audio/dfpwm");
        res.setHeader("Cache-Control", "public, max-age=86400");
        res.setHeader("X-Cache", "HIT");

        const cacheStream = USE_LOCAL_CACHE
          ? createLocalCacheReadStream(cacheKey)
          : storage.bucket(CACHE_BUCKET).file(cacheKey).createReadStream();

        let bytesSent = 0;
        cacheStream.on("data", (chunk) => {
          bytesSent += chunk.length;
        });
        cacheStream.on("end", () => {
          log("INFO", "cache_stream_completed", { requestId, trackUrl, bytesSent });
        });
        cacheStream.on("error", (error) => {
          log("ERROR", "cache_stream_failed", { requestId, error: error.message });
          if (!res.headersSent) {
            res.status(500).send("Cache read failed");
          }
        });
        cacheStream.pipe(res);
        return;
      }
    } catch (error) {
      log("WARN", "cache_check_failed", { requestId, error: error.message });
      // Continue to transcode on cache errors
    }

    log("INFO", "cache_miss", { requestId, trackUrl, cacheKey, mode: USE_LOCAL_CACHE ? "local" : "cloud" });

    let downloadHandle;
    try {
      downloadHandle = ytDlp.stream(trackUrl, {
        format: {
          filter: "audioonly",
          quality: "best",
          type: "best",
        },
      });
    } catch (error) {
      const errMessage = error?.message || String(error);
      res.status(502).send(`Unable to start yt-dlp stream: ${errMessage}`);
      log("ERROR", "stream_request_failed", { requestId, step: "yt_dlp", error: errMessage });
      return;
    }

    const readable = resolveReadable(downloadHandle);
    if (!readable) {
      res.status(500).send("yt-dlp returned an unsupported stream type");
      log("ERROR", "stream_request_failed", { requestId, step: "yt_dlp_stream", error: "unsupported_stream" });
      return;
    }

    const startTime = Date.now();
    let bytesSent = 0;
    log("INFO", "stream_pipeline_start", { requestId, trackUrl });

    const ffmpeg = spawn(FFMPEG_PATH, ffmpegArgs, {
      stdio: ["pipe", "pipe", "pipe"],
    });

    res.setHeader("Content-Type", "audio/dfpwm");
    res.setHeader("Cache-Control", "no-store");
    res.setHeader("X-Cache", "MISS");

    // Create PassThrough stream to split output to client and cache
    const passThrough = new PassThrough();
    const cacheWriteStream = USE_LOCAL_CACHE
      ? createLocalCacheWriteStream(cacheKey)
      : storage.bucket(CACHE_BUCKET).file(cacheKey).createWriteStream({
          metadata: {
            contentType: "audio/dfpwm",
            metadata: {
              trackUrl,
              createdAt: new Date().toISOString(),
            },
          },
        });

    let cacheUploadFailed = false;
    cacheWriteStream.on("error", (error) => {
      cacheUploadFailed = true;
      log("WARN", "cache_upload_failed", { requestId, error: error.message, mode: USE_LOCAL_CACHE ? "local" : "cloud" });
    });
    cacheWriteStream.on("finish", () => {
      if (!cacheUploadFailed) {
        log("INFO", "cache_upload_completed", { requestId, trackUrl, cacheKey, mode: USE_LOCAL_CACHE ? "local" : "cloud" });
      }
    });

    let cleanedUp = false;
    const cleanup = (error) => {
      if (cleanedUp) {
        return;
      }
      cleanedUp = true;
      if (!res.writableEnded) {
        if (error && !res.headersSent) {
          const errMessage = error?.message || String(error);
          res.status(502).send(`Transcoding failed: ${errMessage}`);
        } else {
          res.end();
        }
      }
      const elapsedMs = Date.now() - startTime;
      if (error) {
        log("ERROR", "stream_request_failed", {
          requestId,
          step: "cleanup",
          error: error?.message || String(error),
          stack: error?.stack,
          elapsedMs,
          bytesSent,
          trackUrl,
        });
      } else {
        log("INFO", "stream_request_completed", {
          requestId,
          elapsedMs,
          bytesSent,
          trackUrl,
        });
      }
      readable.destroy?.();
      passThrough.destroy();
      cacheWriteStream.destroy();
      if (!ffmpeg.killed) {
        ffmpeg.stdin.destroy();
        ffmpeg.stdout.destroy();
        ffmpeg.stderr.destroy();
        ffmpeg.kill("SIGKILL");
      }
    };

    ffmpeg.stdin.on("error", (err) => cleanup(err));
    if (typeof readable.on === "function") {
      readable.on("error", (err) => cleanup(err));
      readable.on("close", () => {
        log("INFO", "yt_dlp_stream_closed", { requestId, trackUrl });
      });
    } else if (typeof readable.once === "function") {
      readable.once("error", (err) => cleanup(err));
    }
    ffmpeg.on("error", (err) => cleanup(err));
    ffmpeg.stderr.on("data", (chunk) => {
      log("DEBUG", "ffmpeg_stderr", { requestId, message: chunk.toString() });
    });

    res.on("close", () => cleanup());

    readable.pipe(ffmpeg.stdin);
    ffmpeg.stdout.on("data", (chunk) => {
      bytesSent += chunk.length;
    });

    // Split output to both client and cache
    ffmpeg.stdout.pipe(passThrough);
    passThrough.pipe(res);
    passThrough.pipe(cacheWriteStream);

    ffmpeg.on("close", (code) => {
      if (code !== 0) {
        log("ERROR", "ffmpeg_exit_nonzero", { requestId, code });
        cleanup(new Error(`ffmpeg exited with code ${code}`));
      } else {
        log("INFO", "ffmpeg_exit_zero", { requestId });
        cleanup();
      }
    });
  }
);

export const paInfo = onRequest({ memory: "256MiB", maxInstances: 5 }, async (req, res) => {
  const requestId = randomUUID();
  log("INFO", "info_request_received", {
    requestId,
    method: req.method,
    track: req.query.track,
  });
  if (req.method !== "GET") {
    res.status(405).send(`Method Not Allowed: ${req.method}`);
    log("WARNING", "info_request_rejected", { requestId, reason: "method" });
    return;
  }
  if (!ensureAuthorised(req, res)) {
    log("WARNING", "info_request_rejected", { requestId, reason: "unauthorised" });
    return;
  }

  const trackParam = req.query.track;
  if (typeof trackParam !== "string" || trackParam.trim() === "") {
    res.status(400).send("Missing track parameter: pass ?track=<youtube url or id>");
    log("WARNING", "info_request_rejected", { requestId, reason: "missing_track" });
    return;
  }

  let trackUrl;
  try {
    trackUrl = normaliseTrack(trackParam);
  } catch (error) {
    res.status(400).send(`Invalid track parameter: ${error.message || error}`);
    log("WARNING", "info_request_rejected", { requestId, reason: "invalid_track" });
    return;
  }

  await installationReady;

  try {
    const info = await ytDlp.getInfoAsync(trackUrl, {
      flatPlaylist: false,
      noWarnings: true,
    });

    if (info?._type === "playlist") {
      res.status(400).send("Playlists are not supported by this endpoint");
      log("WARNING", "info_request_rejected", { requestId, reason: "playlist" });
      return;
    }

    const durationSeconds = Number(info?.duration ?? info?.duration_seconds ?? 0) || 0;
    res.status(200).json({
      title: info?.title || info?.fulltitle || "",
      channel: info?.channel || info?.uploader || "",
      durationSeconds,
      durationFormatted: secondsToTimestamp(durationSeconds),
    });
    log("INFO", "info_request_completed", {
      requestId,
      title: info?.title || info?.fulltitle || "",
      channel: info?.channel || info?.uploader || "",
      durationSeconds,
      trackUrl,
    });
  } catch (error) {
    const errMessage = error?.message || String(error);
    res.status(502).send(`Unable to resolve track metadata: ${errMessage}`);
    log("ERROR", "info_request_failed", { requestId, error: errMessage, trackUrl });
  }
});
