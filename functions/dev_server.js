  import express from "express";
  import { paStream, paInfo } from "./pa_stream.js";

  const app = express();

  app.get("/stream", (req, res) => paStream(req, res));
  app.get("/info", (req, res) => paInfo(req, res));

  const port = Number(process.env.PORT || 7000);
  app.listen(port, () => {
    console.log(`Local PA service listening on http://localhost:${port}`);
  });