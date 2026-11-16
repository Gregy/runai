#!/usr/bin/env python3
"""Plain-text transcript of an audio file via a temporary NotebookLM Enterprise notebook.

No 20 MiB limit, no splitting, ~30 s processing. The output has NO speaker labels and NO
timestamps: paragraph breaks follow pauses, not speakers. Reads the undocumented `tailwindDoc`
field of a source, so it may stop working without notice.

Usage: notebook_transcribe.py <audio> --out <transcript.txt> [--keep-notebook]
"""
import argparse
import json
import mimetypes
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

LOCATION = os.environ.get("GEMINI_ENTERPRISE_LOCATION", "us")
PROJECT_NUMBER = os.environ["GEMINI_ENTERPRISE_PROJECT_NUMBER"]
QUOTA_PROJECT = os.environ["GEMINI_ENTERPRISE_PROJECT"]
PARENT = f"projects/{PROJECT_NUMBER}/locations/{LOCATION}"
API = f"https://{LOCATION}-discoveryengine.googleapis.com/v1alpha/{PARENT}"
UPLOAD_API = f"https://{LOCATION}-discoveryengine.googleapis.com/upload/v1alpha/{PARENT}"
CREDS_FILES = [Path(p) for p in [os.environ.get("GEMINI_OAUTH_CREDS")] if p] + [
    Path.home() / ".pi/agent/gemini-enterprise-oauth.json",
    Path.home() / ".claude/gemini-enterprise-oauth.json"]
PROCESSING_TIMEOUT_SECONDS = 900


def access_token():
    subprocess.run(["gemini-enterprise", "status"], capture_output=True, check=True)
    creds_file = next(p for p in CREDS_FILES if p.exists())
    return json.loads(creds_file.read_text())["access_token"]


def call(token, method, url, body=None, content_type="application/json", extra_headers=None):
    data = json.dumps(body).encode() if isinstance(body, dict) else body
    headers = {"Authorization": f"Bearer {token}", "x-goog-user-project": QUOTA_PROJECT,
               "Content-Type": content_type, **(extra_headers or {})}
    request = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=900) as response:
            return json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as error:
        raise RuntimeError(f"{method} {url} -> {error.code}: {error.read()[:500]!r}") from None


def paragraphs(source):
    content = source.get("tailwindDoc", {}).get("body", {}).get("content", [])
    texts = ("".join(e.get("textRun", {}).get("content", "") for e in c.get("paragraph", {}).get("elements", []))
             for c in content)
    return [t.strip() for t in texts if t.strip()]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("audio", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--keep-notebook", action="store_true")
    args = parser.parse_args()

    token = access_token()
    notebook = call(token, "POST", f"{API}/notebooks", {"title": f"TEMP transcript {args.audio.name}"})
    notebook_id = notebook["notebookId"]
    try:
        mime_type = mimetypes.guess_type(args.audio.name)[0] or "audio/mpeg"
        uploaded = call(token, "POST", f"{UPLOAD_API}/notebooks/{notebook_id}/sources:uploadFile",
                        args.audio.read_bytes(), content_type=mime_type,
                        extra_headers={"X-Goog-Upload-File-Name": args.audio.name,
                                       "X-Goog-Upload-Protocol": "raw"})
        source_url = f"{API}/notebooks/{notebook_id}/sources/{uploaded['sourceId']['id']}"
        deadline = time.time() + PROCESSING_TIMEOUT_SECONDS
        while True:
            source = call(token, "GET", source_url)
            status = source.get("settings", {}).get("status", "")
            if status == "SOURCE_STATUS_COMPLETE":
                break
            if status not in ("SOURCE_STATUS_TENTATIVE", "SOURCE_STATUS_PENDING", "") or time.time() > deadline:
                raise RuntimeError(f"source not processed: {status} {source.get('settings')}")
            time.sleep(10)
        text = paragraphs(source)
        if not text:
            raise RuntimeError("source processed but tailwindDoc is empty or missing (API may have changed)")
        args.out.write_text("\n\n".join(text) + "\n")
        word_count = source.get("metadata", {}).get("wordCount")
        print(f"{len(text)} paragraphs, {word_count} words -> {args.out}", file=sys.stderr)
    finally:
        if args.keep_notebook:
            print(f"kept notebook {notebook['name']}", file=sys.stderr)
        else:
            call(token, "POST", f"{API}/notebooks:batchDelete", {"names": [notebook["name"]]})


if __name__ == "__main__":
    main()
