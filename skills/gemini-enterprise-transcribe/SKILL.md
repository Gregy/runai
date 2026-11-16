---
name: gemini-enterprise-transcribe
description: Transcribe meeting audio recordings (MP3 only; any length via the bundled splitter, which respects the 20 MiB upload limit) and query multimodal files using the company's Gemini Enterprise (Vertex AI Search / Agentspace) via direct Google OAuth. Use when transcribing audio recordings in Obsidian daily notes (`Assets/AudioRecordings/...`), analyzing recorded meetings, or calling Gemini Enterprise from `pi`.
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

### 2. Upload Limits & Audio Format (READ FIRST)

> **WARNING: Gemini Enterprise silently processes only the first ~20 MiB of an uploaded file.**
> It does not return an error. It transcribes the first ~20 MiB and then confidently reports
> "silence" or invents an early end of the meeting for the rest. A 192 kbps stereo MP3 is cut
> after ~14.5 minutes. Never trust overview/duration answers about a file larger than 20 MiB,
> and never delete source audio based on them.

- **Accepted formats (verified):** MP3 works. OGG Opus, OGG Vorbis, and AAC/M4A are rejected with
  `UNSUPPORTED_FILE_TYPE`. WAV/FLAC are accepted but are much larger, so they never help with the limit.
- **Recommended format:** MP3, **16 kHz mono, 32 kbps** (~14 MB/hour, ~85 min per 20 MiB). In a
  test on 4 meeting clips x 3 runs, 192 kbps stereo, 64 kbps mono and 24 kHz mono gave no measurable
  improvement in word accuracy over it; run-to-run variation was larger than any quality effect.
  How Gemini Enterprise processes audio internally is undocumented.
- The built-in `transcribe` command's ">20 MB" branch is broken: it asks for two time windows of
  the same truncated upload, so the second window is hallucinated. Do not use `transcribe` on
  files over 20 MiB.
- Timestamps drift on long uploads (up to ~25% on a 56-minute file) and speaker attribution is
  the weakest part. Words themselves are reliable. Asking for `[MM:SS]` per turn costs nothing: in a
  test (5 clips, 3-4 runs each) prompts without timestamps were no better (WER 7.9% vs 7.1%) and one
  45-minute run returned nothing. Transcripts keep the timestamps by default.
- Occasionally a run returns leaked reasoning or a repetition loop instead of a transcript (seen once
  in 60 runs: ~5x the expected word count). Re-run if word count is far off ~130-150 words/minute.

### 3. Transcribing Meeting Audio Files

**Default: use the bundled helper for any recording.** It re-encodes to 16 kHz mono 32 kbps MP3,
splits into 45-minute segments (~11 MB, well under the limit), transcribes each with
`gemini-enterprise ask`, and writes `**[MM:SS] Speaker:** text` turns on the original timeline. It
refuses to upload any segment over 20 MiB. Add `--no-timestamps` for plain `**Speaker:** text`.

```bash
uv run --script <skill-dir>/scripts/transcribe_long.py \
  "Assets/AudioRecordings/<recording>.mp3" \
  --speakers "<Operator>, <Other Speaker>" \
  --out /tmp/transcript.md \
  [--first-meeting-only]   # stop at the first meeting's goodbyes (recorder left running)
```

It prints per-segment turn/word counts and writes `<out>.report.json`. A non-final segment
with very few words per minute (and no `END_OF_FIRST_MEETING` marker) means Gemini dropped
content: re-run that recording before relying on it.

For small files (< 20 MiB) the plain CLI also works:

```bash
gemini-enterprise transcribe "<recording>.mp3" --speakers "<Operator>, <Other>" --out /tmp/transcript.md
```

For follow-up questions about one recording, keep a session and reuse the uploaded file
(only valid for files under 20 MiB):

```bash
gemini-enterprise ask --file "<recording>.mp3" --keep-session --prompt "Give a brief overview..."
# note Session: and FileIds: from stderr, then:
gemini-enterprise ask --session "<SESSION_NAME>" --file-id "<FILE_ID>" --keep-session --prompt "..."
```

### 4. Plain-Text Alternative: NotebookLM Enterprise (no speakers, no timestamps)

Use when only the words matter (searching, summarising, archiving a long recording), not who
said what or when. Uploading audio as a notebook **source** makes NotebookLM transcribe it with
a separate speech-to-text step:

- **No 20 MiB limit and no splitting.** An 80 MB, 56-minute file came back complete in ~30 s,
  identical to its 13 MB re-encode.
- **Words are about as accurate as chat** (~10.5% disagreement with other transcripts versus
  8.6-10.4% among them), with more misspelled names (company and product names especially).
- **No speaker labels, no timestamps.** Paragraph breaks follow pauses, not speakers: a 6-minute
  call came back as 7 paragraphs, one of them 283 words spanning both speakers and a 2-minute gap.
  Do not use paragraphs as speaker turns.
- **No prompting.** Source processing takes no instructions, and the public API has no notebook
  chat. You cannot ask it for timestamps, speakers, or first-meeting-only.
- **Undocumented.** The text is read from a `tailwindDoc` field of
  `GET .../notebooks/{id}/sources/{sourceId}` that the published API description omits (the server
  accepts `?fields=tailwindDoc`, so it is a real field). It may change without notice. There is no
  other way to get the content: `view`, `alt=media`, `/content`, v1/v1beta, and a sources list all fail.

```bash
python3 <skill-dir>/scripts/notebook_transcribe.py "<recording>.mp3" --out /tmp/transcript.txt
```

It creates a temporary notebook in the user's NotebookLM, uploads the file
(`.../upload/v1alpha/.../notebooks/{id}/sources:uploadFile`, raw bytes), polls until the source
status is `SOURCE_STATUS_COMPLETE`, writes the paragraphs, then deletes the notebook
(`--keep-notebook` to keep it). It authenticates with the CLI's OAuth token (same bearer token
and `x-goog-user-project` header). It fails loudly if `tailwindDoc` is missing.

### 5. Obsidian Daily Note Convention

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
