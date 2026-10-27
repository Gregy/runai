#!/usr/bin/env node
/**
 * Gemini Enterprise (Vertex AI Search / Agentspace) Audio & File Assistant CLI
 *
 * Supports:
 *   gemini-enterprise login [--code <auth_code_or_url>]
 *   gemini-enterprise status
 *   gemini-enterprise ask [--file <path>] [--prompt <text>] [--out <path>] [--keep-session]
 *   gemini-enterprise transcribe <audio_file> [--prompt <text>] [--out <path>]
 *
 * The OAuth client and the Gemini Enterprise instance are site-specific and
 * come from the environment (run.sh forwards them from the untracked
 * local.env; see README): GEMINI_ENTERPRISE_OAUTH_CLIENT_ID,
 * GEMINI_ENTERPRISE_OAUTH_CLIENT_SECRET, GEMINI_ENTERPRISE_PROJECT,
 * GEMINI_ENTERPRISE_PROJECT_NUMBER, GEMINI_ENTERPRISE_ENGINE_ID,
 * GEMINI_ENTERPRISE_CONFIG_ID and optionally GEMINI_ENTERPRISE_LOCATION
 * (default "us").
 */

import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import os from "node:os";
import { spawnSync } from "node:child_process";

const HOME = os.homedir();
// Saved to both agents' (host-mounted) config dirs so Claude Code and pi share one login.
const SAVE_PATHS = [
  path.join(HOME, ".pi/agent/gemini-enterprise-oauth.json"),
  path.join(HOME, ".claude/gemini-enterprise-oauth.json"),
  path.join(HOME, ".gemini/oauth_creds.json"),
];
const CREDS_PATHS = [process.env.GEMINI_OAUTH_CREDS, ...SAVE_PATHS].filter(Boolean);

const PKCE_STATE_PATH = path.join(HOME, ".pi/agent/gemini-enterprise-pkce.json");

// OAuth client that allows the cloud-platform scope and the
// codeassist.google.com/authcode redirect (e.g. the Gemini CLI's).
const OAUTH_CLIENT_ID = process.env.GEMINI_ENTERPRISE_OAUTH_CLIENT_ID;
const OAUTH_CLIENT_SECRET = process.env.GEMINI_ENTERPRISE_OAUTH_CLIENT_SECRET;
const OAUTH_REDIRECT_URI = "https://codeassist.google.com/authcode";
const OAUTH_SCOPES = [
  "https://www.googleapis.com/auth/cloud-platform",
  "https://www.googleapis.com/auth/userinfo.email",
  "https://www.googleapis.com/auth/userinfo.profile",
];

// The Gemini Enterprise (Agentspace) instance
const DEFAULT_CONFIG = {
  location: process.env.GEMINI_ENTERPRISE_LOCATION || "us",
  projectId: process.env.GEMINI_ENTERPRISE_PROJECT,
  projectNumber: process.env.GEMINI_ENTERPRISE_PROJECT_NUMBER,
  engineId: process.env.GEMINI_ENTERPRISE_ENGINE_ID,
  configId: process.env.GEMINI_ENTERPRISE_CONFIG_ID,
};

function requireConfig() {
  const missing = [
    "GEMINI_ENTERPRISE_OAUTH_CLIENT_ID",
    "GEMINI_ENTERPRISE_OAUTH_CLIENT_SECRET",
    "GEMINI_ENTERPRISE_PROJECT",
    "GEMINI_ENTERPRISE_PROJECT_NUMBER",
    "GEMINI_ENTERPRISE_ENGINE_ID",
    "GEMINI_ENTERPRISE_CONFIG_ID",
  ].filter((v) => !process.env[v]);
  if (missing.length) {
    throw new Error(
      `Not configured, missing: ${missing.join(", ")}. Set them in local.env (see README).`
    );
  }
}

function loadSavedCreds() {
  for (const p of CREDS_PATHS) {
    if (fs.existsSync(p)) {
      try {
        return { creds: JSON.parse(fs.readFileSync(p, "utf8")), path: p };
      } catch {
        // continue
      }
    }
  }
  return null;
}

function saveCreds(creds) {
  const updated = {
    ...creds,
    client_id: creds.client_id || OAUTH_CLIENT_ID,
    client_secret: creds.client_secret || OAUTH_CLIENT_SECRET,
    updated_at: Date.now(),
  };
  for (const p of SAVE_PATHS) {
    try {
      fs.mkdirSync(path.dirname(p), { recursive: true });
      fs.writeFileSync(p, JSON.stringify(updated, null, 2), { mode: 0o600 });
    } catch {
      // ignore if directory not writable
    }
  }
  return updated;
}

async function getValidAccessToken() {
  const loaded = loadSavedCreds();
  if (!loaded || !loaded.creds.refresh_token) {
    throw new Error(
      "No OAuth credentials found. Run `gemini-enterprise login` first."
    );
  }
  const { creds } = loaded;
  const body = new URLSearchParams({
    client_id: creds.client_id || OAUTH_CLIENT_ID,
    client_secret: creds.client_secret || OAUTH_CLIENT_SECRET,
    refresh_token: creds.refresh_token,
    grant_type: "refresh_token",
  });

  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: body.toString(),
  });

  if (!res.ok) {
    const errText = await res.text();
    throw new Error(
      `Failed to refresh OAuth token (${res.status}): ${errText}. Run \`gemini-enterprise login\` again.`
    );
  }

  const tokenData = await res.json();
  const merged = saveCreds({ ...creds, ...tokenData });
  return merged.access_token;
}

async function cmdLogin(args) {
  const codeIdx = args.indexOf("--code");
  if (codeIdx === -1) {
    const codeVerifier = crypto.randomBytes(32).toString("base64url");
    const codeChallenge = crypto
      .createHash("sha256")
      .update(codeVerifier)
      .digest("base64url");
    const state = crypto.randomBytes(32).toString("hex");

    fs.mkdirSync(path.dirname(PKCE_STATE_PATH), { recursive: true });
    fs.writeFileSync(
      PKCE_STATE_PATH,
      JSON.stringify(
        {
          client_id: OAUTH_CLIENT_ID,
          client_secret: OAUTH_CLIENT_SECRET,
          code_verifier: codeVerifier,
          redirect_uri: OAUTH_REDIRECT_URI,
          state,
        },
        null,
        2
      ),
      { mode: 0o600 }
    );

    const authUrl = new URL("https://accounts.google.com/o/oauth2/v2/auth");
    authUrl.searchParams.set("client_id", OAUTH_CLIENT_ID);
    authUrl.searchParams.set("redirect_uri", OAUTH_REDIRECT_URI);
    authUrl.searchParams.set("response_type", "code");
    authUrl.searchParams.set("scope", OAUTH_SCOPES.join(" "));
    authUrl.searchParams.set("access_type", "offline");
    authUrl.searchParams.set("prompt", "consent");
    authUrl.searchParams.set("code_challenge_method", "S256");
    authUrl.searchParams.set("code_challenge", codeChallenge);
    authUrl.searchParams.set("state", state);

    const urlStr = authUrl.toString();
    const browserBin = process.env.BROWSER || "/usr/local/bin/host-browser";
    if (fs.existsSync(browserBin)) {
      spawnSync(browserBin, [urlStr], { stdio: "ignore" });
    }
    console.log("Opened browser for Google OAuth login.");
    console.log("URL:", urlStr);
    console.log(
      "\nAfter signing in and approving access, copy the authorization code from the browser page and run:"
    );
    console.log(`  gemini-enterprise login --code "<AUTH_CODE>"`);
    return;
  }

  let rawCode = args[codeIdx + 1];
  if (!rawCode) {
    throw new Error("Missing value after --code");
  }
  if (rawCode.includes("code=")) {
    const u = new URL(rawCode.startsWith("http") ? rawCode : `https://x?${rawCode}`);
    rawCode = u.searchParams.get("code") || rawCode;
  }
  rawCode = decodeURIComponent(rawCode.trim());

  const pkce = JSON.parse(fs.readFileSync(PKCE_STATE_PATH, "utf8"));
  const body = new URLSearchParams({
    client_id: pkce.client_id,
    client_secret: pkce.client_secret,
    code: rawCode,
    code_verifier: pkce.code_verifier,
    redirect_uri: pkce.redirect_uri,
    grant_type: "authorization_code",
  });

  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: body.toString(),
  });

  if (!res.ok) {
    throw new Error(`Token exchange failed (${res.status}): ${await res.text()}`);
  }

  const tokens = await res.json();
  saveCreds(tokens);
  console.log("Successfully authenticated and saved OAuth credentials.");
}

function getHeaders(accessToken) {
  return {
    Authorization: `Bearer ${accessToken}`,
    "Content-Type": "application/json",
    "x-goog-user-project": DEFAULT_CONFIG.projectId,
    "X-Goog-Api-Client": "gemini-enterprise-classic/1.0.0",
    Origin: "https://vertexaisearch.cloud.google.com",
    Referer: "https://vertexaisearch.cloud.google.com/",
  };
}

function getEngineResourcePath() {
  return `projects/${DEFAULT_CONFIG.projectNumber}/locations/${DEFAULT_CONFIG.location}/collections/default_collection/engines/${DEFAULT_CONFIG.engineId}`;
}

async function createSession(accessToken, displayName = "Pi Audio Session") {
  const eng = getEngineResourcePath();
  const url = `https://${DEFAULT_CONFIG.location}-discoveryengine.googleapis.com/v1alpha/${eng}/sessions`;
  const res = await fetch(url, {
    method: "POST",
    headers: getHeaders(accessToken),
    body: JSON.stringify({ displayName }),
  });
  if (!res.ok) {
    throw new Error(`createSession failed (${res.status}): ${await res.text()}`);
  }
  return await res.json();
}

async function deleteSession(accessToken, sessionName) {
  const url = `https://${DEFAULT_CONFIG.location}-discoveryengine.googleapis.com/v1alpha/${sessionName}`;
  await fetch(url, {
    method: "DELETE",
    headers: getHeaders(accessToken),
  });
}

function detectMimeType(filePath) {
  const ext = path.extname(filePath).toLowerCase();
  const map = {
    ".mp3": "audio/mp3",
    ".wav": "audio/wav",
    ".m4a": "audio/m4a",
    ".ogg": "audio/ogg",
    ".flac": "audio/flac",
    ".webm": "audio/webm",
    ".mp4": "video/mp4",
    ".pdf": "application/pdf",
    ".txt": "text/plain",
    ".md": "text/markdown",
  };
  return map[ext] || "application/octet-stream";
}

async function uploadFileToSession(accessToken, sessionName, filePath) {
  const fileBuffer = fs.readFileSync(filePath);
  const fileName = path.basename(filePath);
  const mimeType = detectMimeType(filePath);

  const startUrl = `https://content-${DEFAULT_CONFIG.location}-discoveryengine.googleapis.com/upload/v1alpha/${sessionName}:uploadFile`;
  const startRes = await fetch(startUrl, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${accessToken}`,
      "x-goog-user-project": DEFAULT_CONFIG.projectId,
      "X-Goog-Api-Client": "gemini-enterprise-classic/1.0.0",
      "X-Goog-Upload-Protocol": "resumable",
      "X-Goog-Upload-Command": "start",
      "X-Goog-Upload-File-Name": encodeURIComponent(fileName),
      "X-Goog-Upload-Header-Content-Length": String(fileBuffer.length),
      "X-Goog-Upload-Header-Content-Type": mimeType,
      Origin: "https://vertexaisearch.cloud.google.com",
      Referer: "https://vertexaisearch.cloud.google.com/",
    },
    body: "",
  });

  if (!startRes.ok) {
    throw new Error(
      `Scotty upload start failed (${startRes.status}): ${await startRes.text()}`
    );
  }

  const uploadUrl = startRes.headers.get("x-goog-upload-url");
  if (!uploadUrl) {
    throw new Error("Missing x-goog-upload-url header from upload start response");
  }

  const finalizeRes = await fetch(uploadUrl, {
    method: "POST",
    headers: {
      "X-Goog-Upload-Command": "upload, finalize",
      "X-Goog-Upload-Offset": "0",
      "Content-Type": mimeType,
      Origin: "https://vertexaisearch.cloud.google.com",
      Referer: "https://vertexaisearch.cloud.google.com/",
    },
    body: fileBuffer,
  });

  if (!finalizeRes.ok) {
    throw new Error(
      `Scotty upload finalize failed (${finalizeRes.status}): ${await finalizeRes.text()}`
    );
  }

  const data = await finalizeRes.json();
  return data.fileId;
}

async function queryWidgetStreamAssist(accessToken, sessionName, prompt, fileIds = []) {
  // widgetStreamAssist requires relative session path: collections/default_collection/engines/.../sessions/...
  const relativeSession = sessionName.replace(
    /^projects\/[^/]+\/locations\/[^/]+\//,
    ""
  );
  const url = `https://content-${DEFAULT_CONFIG.location}-discoveryengine.googleapis.com/v1alpha/locations/${DEFAULT_CONFIG.location}/widgetStreamAssist`;

  const reqBody = {
    configId: DEFAULT_CONFIG.configId,
    additionalParams: { token: "-", origin: "ORIGIN_UNSPECIFIED" },
    streamAssistRequest: {
      session: relativeSession,
      query: { text: prompt },
      ...(fileIds.length > 0 ? { fileIds } : {}),
    },
  };

  const res = await fetch(url, {
    method: "POST",
    headers: getHeaders(accessToken),
    body: JSON.stringify(reqBody),
  });

  if (!res.ok) {
    throw new Error(`widgetStreamAssist failed (${res.status}): ${await res.text()}`);
  }

  const text = await res.text();
  const chunks = JSON.parse(text);
  let replyText = "";
  for (const c of chunks) {
    const replies = c.streamAssistResponse?.answer?.replies || [];
    for (const r of replies) {
      const t = r.groundedContent?.content?.text;
      const thought = r.groundedContent?.content?.thought;
      if (t && !thought) {
        replyText += t;
      }
    }
  }
  return replyText.trim();
}

async function cmdStatus() {
  const accessToken = await getValidAccessToken();
  const eng = getEngineResourcePath();
  const url = `https://${DEFAULT_CONFIG.location}-discoveryengine.googleapis.com/v1alpha/${eng}`;
  const res = await fetch(url, { headers: getHeaders(accessToken) });
  if (!res.ok) {
    throw new Error(`Engine check failed (${res.status}): ${await res.text()}`);
  }
  const data = await res.json();
  console.log("Authenticated and connected to Gemini Enterprise:");
  console.log(`  Engine: ${data.name}`);
  console.log(`  Display Name: ${data.displayName}`);
  console.log(`  Widget Config ID: ${DEFAULT_CONFIG.configId}`);
}

function getArgValue(args, flag) {
  const idx = args.indexOf(flag);
  return idx !== -1 && idx + 1 < args.length ? args[idx + 1] : null;
}

async function cmdAsk(args) {
  const filePath = getArgValue(args, "--file");
  const prompt = getArgValue(args, "--prompt");
  const outPath = getArgValue(args, "--out");
  const existingSession = getArgValue(args, "--session");
  const existingFileId = getArgValue(args, "--file-id");
  const keepSession = args.includes("--keep-session");

  if (!prompt) {
    throw new Error("Usage: gemini-enterprise ask --prompt <text> [--file <path>] [--out <path>]");
  }

  const accessToken = await getValidAccessToken();
  let sessionName = existingSession;
  let createdSession = false;

  if (!sessionName) {
    const sess = await createSession(accessToken, "Pi Assistant Session");
    sessionName = sess.name;
    createdSession = true;
  }

  try {
    const fileIds = [];
    if (existingFileId) {
      fileIds.push(existingFileId);
    } else if (filePath) {
      console.error(`Uploading ${filePath} to session ${sessionName}...`);
      const fileId = await uploadFileToSession(accessToken, sessionName, filePath);
      console.error(`Uploaded fileId: ${fileId}`);
      fileIds.push(fileId);
    }

    if (keepSession) {
      console.error(`Session: ${sessionName}`);
      if (fileIds.length) console.error(`FileIds: ${fileIds.join(",")}`);
    }

    const answer = await queryWidgetStreamAssist(
      accessToken,
      sessionName,
      prompt,
      fileIds
    );

    if (outPath) {
      fs.writeFileSync(outPath, answer + "\n", "utf8");
      console.error(`Saved output to ${outPath} (${answer.length} chars)`);
    } else {
      console.log(answer);
    }
  } finally {
    if (createdSession && !keepSession) {
      await deleteSession(accessToken, sessionName);
    }
  }
}

async function cmdTranscribe(args) {
  const audioFile = args.find((a) => !a.startsWith("--"));
  if (!audioFile || !fs.existsSync(audioFile)) {
    throw new Error(
      "Usage: gemini-enterprise transcribe <audio_file> [--speakers <names>] [--instructions <extra_instructions>] [--out <path>]"
    );
  }

  const speakers = getArgValue(args, "--speakers");
  const instructions = getArgValue(args, "--instructions") || "";
  const outPath = getArgValue(args, "--out");
  const chunkMinutes = Number(getArgValue(args, "--chunk-minutes") || "15");

  const accessToken = await getValidAccessToken();
  const sess = await createSession(
    accessToken,
    `Transcribe ${path.basename(audioFile)}`
  );
  const sessionName = sess.name;

  try {
    console.error(`Uploading ${audioFile} (${(fs.statSync(audioFile).size / 1e6).toFixed(2)} MB)...`);
    const fileId = await uploadFileToSession(accessToken, sessionName, audioFile);
    console.error(`Uploaded with fileId: ${fileId}`);

    // Probe overview & duration via Gemini
    const overviewPrompt = `Listen to this audio recording. Tell me:
1. The exact total duration of the conversation in MM:SS.
2. The names or labels of the speakers.
3. Whether there are multiple distinct calls/meetings in the recording and their start/end timestamps.
Return your answer concisely.`;
    console.error("Inspecting audio structure...");
    const overview = await queryWidgetStreamAssist(
      accessToken,
      sessionName,
      overviewPrompt,
      [fileId]
    );
    console.error("--- Audio Overview ---\n" + overview + "\n----------------------");

    const speakerHint = speakers
      ? `The speakers are: ${speakers}.`
      : "Identify each speaker by name if mentioned, or Speaker 1 / Speaker 2.";

    // Check file size/duration to decide if multi-part transcription is needed
    // Single pass works well up to ~15 minutes; for longer recordings, transcribe in windows
    const sizeMB = fs.statSync(audioFile).size / (1024 * 1024);
    const parts = [];

    if (sizeMB > 20) {
      const windows = [
        { start: "00:00", end: `${chunkMinutes}:00`, label: "Part 1" },
        { start: `${chunkMinutes}:00`, end: "the end of the recording", label: "Part 2" },
      ];
      for (const w of windows) {
        console.error(`Transcribing ${w.label} (${w.start} to ${w.end})...`);
        const p = `Provide a complete, word-for-word verbatim transcript of the audio from ${w.start} to ${w.end}.
Do NOT summarize, skip, condense, or omit any part of the conversation in this time range.
${speakerHint}
${instructions}
Format every turn as:
**[MM:SS] Speaker:** text...
Output ONLY the transcript lines without introductory or concluding commentary.`;
        const partText = await queryWidgetStreamAssist(
          accessToken,
          sessionName,
          p,
          [fileId]
        );
        parts.push(partText);
      }
    } else {
      console.error("Transcribing full audio...");
      const p = `Provide a complete, word-for-word verbatim transcript of the entire audio recording from start to finish.
Do NOT summarize, skip, condense, or omit any part of the conversation.
${speakerHint}
${instructions}
Format every turn as:
**[MM:SS] Speaker:** text...
Output ONLY the transcript lines without introductory or concluding commentary.`;
      const partText = await queryWidgetStreamAssist(
        accessToken,
        sessionName,
        p,
        [fileId]
      );
      parts.push(partText);
    }

    const fullTranscript = parts.join("\n\n");
    if (outPath) {
      fs.writeFileSync(outPath, fullTranscript + "\n", "utf8");
      console.error(`Saved transcript to ${outPath}`);
    } else {
      console.log(fullTranscript);
    }
  } finally {
    await deleteSession(accessToken, sessionName);
  }
}

async function main() {
  const [cmd, ...rest] = process.argv.slice(2);
  if (!cmd || cmd === "--help" || cmd === "-h") {
    console.log(`Usage:
  gemini-enterprise status
  gemini-enterprise login [--code <auth_code>]
  gemini-enterprise transcribe <audio_file> [--speakers "Alice, Bob"] [--instructions "..."] [--out <file>]
  gemini-enterprise ask --prompt "<question>" [--file <path>] [--out <file>] [--keep-session]`);
    process.exit(0);
  }

  requireConfig();

  if (cmd === "login") await cmdLogin(rest);
  else if (cmd === "status") await cmdStatus();
  else if (cmd === "ask") await cmdAsk(rest);
  else if (cmd === "transcribe") await cmdTranscribe(rest);
  else throw new Error(`Unknown command: ${cmd}`);
}

main().catch((err) => {
  console.error("Error:", err.message || err);
  process.exit(1);
});
