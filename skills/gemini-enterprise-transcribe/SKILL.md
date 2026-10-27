---
name: gemini-enterprise-transcribe
description: Transcribe meeting audio recordings (MP3, WAV, M4A, OGG) and query multimodal files using the company's Gemini Enterprise (Vertex AI Search / Agentspace) via direct Google OAuth. Use when transcribing audio recordings in Obsidian daily notes (`Assets/AudioRecordings/...`), analyzing recorded meetings, or calling Gemini Enterprise from `pi`.
---

# Gemini Enterprise Audio Transcription & File Assistant

This skill transcribes audio recordings and queries multimodal files through
the company's **Gemini Enterprise (Vertex AI Search / Agentspace)** instance,
authenticating with direct Google OAuth.

## The `gemini-enterprise` CLI

```bash
gemini-enterprise status
```

The OAuth client and the instance (GCP project, engine, widget config) come
from `GEMINI_ENTERPRISE_*` environment variables. If the CLI reports
`Not configured, missing: ...`, tell the operator: the values belong in the
untracked `local.env` of the runai checkout, and the container has to be
restarted to pick them up. Never guess the values.

### 1. Authentication & Token Refresh

OAuth credentials (including `refresh_token`) are persisted in:
- `~/.pi/agent/gemini-enterprise-oauth.json`
- `~/.claude/gemini-enterprise-oauth.json`

The CLI automatically refreshes the access token before every run. If no credentials exist or the refresh token is revoked:

1. Start the PKCE login flow (opens the operator's host browser via `host-browser` and redirects to `https://codeassist.google.com/authcode`):
   ```bash
   gemini-enterprise login
   ```
2. Ask the operator to sign in with their work Google account and paste the authorization code shown on `codeassist.google.com/authcode`.
3. Complete login:
   ```bash
   gemini-enterprise login --code "<AUTH_CODE>"
   ```

### 2. Transcribing Meeting Audio Files

For standard recordings:

```bash
gemini-enterprise transcribe \
  "Assets/AudioRecordings/<recording>.mp3" \
  --speakers "<Operator>, <Other Speaker>" \
  --out /tmp/transcript.md
```

For fine-grained control on long recordings (e.g., >15 minutes or when excluding an unrelated call at the end):

1. **Create a persistent session and upload the audio once** using `ask --keep-session`:
   ```bash
   gemini-enterprise ask \
     --file "Assets/AudioRecordings/<recording>.mp3" \
     --keep-session \
     --prompt "Listen to this audio file. Give a brief overview, identify the speakers, and list the start/end timestamps (MM:SS) of each meeting or section."
   ```
   Note the `Session:` (`projects/<project-number>/locations/<location>/collections/default_collection/engines/<engine-id>/sessions/<id>`) and `FileIds:` (`<fileId>`) printed to stderr.

2. **Request verbatim transcription in ~12–15 minute segments** so the model does not hit single-turn output token limits or summarize the tail end:
   ```bash
   gemini-enterprise ask \
     --session "<SESSION_NAME>" \
     --file-id "<FILE_ID>" \
     --keep-session \
     --out /tmp/part1.md \
     --prompt "Provide a complete, word-for-word verbatim transcript from 00:00 to 13:00. Do NOT summarize, skip, or condense anything. Format each turn as **[MM:SS] Speaker:** ... Output ONLY the transcript lines."
   ```
   Repeat for subsequent time windows (or specific topics/sections if timestamps shift slightly).

### 3. Obsidian Daily Note Convention

When inserting a transcription into a Daily Note (`Daily/YYYY-MM-DD.md`):
- Locate the `## #meet [[Person Name]]` section containing the embedded audio link `![[Assets/AudioRecordings/...]]`.
- Add a `### Transcription` subsection directly below the audio embed (and before `### Open items`).
- Format speaker turns as:
  ```markdown
  ### Transcription
  **[00:00] Speaker:** Verbatim text...
  **[00:13] Other Speaker:** Verbatim text...
  ```

## Underlying API Details (Reference)

`{engine}` is `projects/<project-number>/locations/<location>/collections/default_collection/engines/<engine-id>`.

- **Required Header**: `"x-goog-user-project": "<project-id>"` (mandatory so quota/IAM evaluates against the Agentspace project rather than the OAuth client's default project).
- **Session Creation**: `POST https://<location>-discoveryengine.googleapis.com/v1alpha/{engine}/sessions`
- **File Upload (Scotty Resumable)**: `POST https://content-<location>-discoveryengine.googleapis.com/upload/v1alpha/{engine}/sessions/{sessionId}:uploadFile` (`X-Goog-Upload-Protocol: resumable`)
- **Streaming Assist**: `POST https://content-<location>-discoveryengine.googleapis.com/v1alpha/locations/<location>/widgetStreamAssist` with `configId` (the widget config ID) and `streamAssistRequest.session` set to the relative session path (`collections/default_collection/engines/.../sessions/...`) plus `fileIds: ["<fileId>"]`.
