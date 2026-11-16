#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["imageio-ffmpeg"]
# ///
"""Transcribe any-length audio with Gemini Enterprise, staying under its 20 MiB upload limit.

Gemini Enterprise silently processes only the first ~20 MiB of an uploaded file and
hallucinates silence for the rest. This script re-encodes to 16 kHz mono 32 kbps MP3
(no measurable transcription loss versus 192 kbps stereo in testing), splits into segments
well under the limit, and transcribes each. Output turns are `**[MM:SS] Speaker:** text` on the
original timeline; pass --no-timestamps for plain `**Speaker:** text`.

Usage:
  transcribe_long.py <audio> --out <transcript.md> [--speakers "Alice, Bob"]
                     [--first-meeting-only] [--segment-minutes 45] [--no-timestamps]

Exit code 0 on success. Writes a JSON report next to --out (<out>.report.json).
"""
import argparse
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

import imageio_ffmpeg

UPLOAD_LIMIT_BYTES = 20 * 1024 * 1024
TARGET_BITRATE_KBPS = 32
END_MARKER = "END_OF_FIRST_MEETING"
END_GRACE_SECONDS = 120
TURN_RE = re.compile(r"^\W*\[(\d+):(\d{2})(?::(\d{2}))?\]\s*(.+?):\**\s*(.*)$")
DURATION_RE = re.compile(r"Duration: (\d+):(\d+):(\d+\.\d+)")


def probe_duration_seconds(ffmpeg, audio):
    stderr = subprocess.run([ffmpeg, "-i", str(audio)], capture_output=True, text=True).stderr
    h, m, s = DURATION_RE.search(stderr).groups()
    return int(h) * 3600 + int(m) * 60 + float(s)


def format_ts(seconds):
    h, rest = divmod(int(seconds), 3600)
    m, s = divmod(rest, 60)
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m:02d}:{s:02d}"


def encode_segment(ffmpeg, audio, start, length, out_path):
    subprocess.run([ffmpeg, "-loglevel", "error", "-y", "-ss", str(start), "-t", str(length), "-i", str(audio),
                    "-ac", "1", "-ar", "16000", "-c:a", "libmp3lame", "-b:a", f"{TARGET_BITRATE_KBPS}k",
                    str(out_path)], check=True)
    if out_path.stat().st_size > UPLOAD_LIMIT_BYTES:
        raise RuntimeError(f"{out_path} is {out_path.stat().st_size} bytes, over the 20 MiB upload limit")


def segment_prompt(index, start, length, speakers, first_meeting_only):
    stop_rule = (
        "If the first meeting clearly ends inside this clip (goodbyes, call disconnects) and is followed by "
        f"silence or a different, unrelated conversation, stop there and output a final line {END_MARKER}. "
        f"If the clip contains no part of the first meeting at all, output only {END_MARKER}. "
        if first_meeting_only else ""
    )
    return (
        f"This clip is part {index + 1} of a meeting recording; it starts at {format_ts(start)} of the original "
        f"and is {format_ts(length)} long. Likely speakers: {speakers}. "
        "Provide a complete, word-for-word verbatim transcript of the WHOLE clip, to its very end. "
        "Do NOT summarize, skip, or condense anything. Format each turn on its own line as "
        "**[MM:SS] Speaker:** text, with MM:SS relative to the start of THIS clip. "
        f"{stop_rule}Output ONLY the transcript lines."
    )


def ask_gemini(audio, prompt, out_path):
    for _ in range(3):
        result = subprocess.run(["gemini-enterprise", "ask", "--file", str(audio), "--out", str(out_path),
                                 "--prompt", prompt], capture_output=True, text=True)
        if result.returncode == 0 and out_path.exists() and out_path.stat().st_size > 0:
            return out_path.read_text()
    raise RuntimeError(f"gemini-enterprise failed for {audio}: {result.stderr[-500:]}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("audio", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--speakers", default="identify speakers by name if mentioned")
    parser.add_argument("--first-meeting-only", action="store_true")
    parser.add_argument("--segment-minutes", type=int, default=45)
    parser.add_argument("--no-timestamps", dest="timestamps", action="store_false",
                        help="omit the [MM:SS] prefix on each turn")
    args = parser.parse_args()

    ffmpeg = imageio_ffmpeg.get_ffmpeg_exe()
    duration = probe_duration_seconds(ffmpeg, args.audio)
    segment_seconds = args.segment_minutes * 60
    lines, report = [], {"audio": str(args.audio), "duration": round(duration), "segments": []}

    raw_dir = args.out.with_suffix(".segments")
    raw_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as work:
        start, index = 0, 0
        while start < duration - 1:
            length = min(segment_seconds, duration - start)
            is_final_segment = start + segment_seconds >= duration - 1
            segment = Path(work) / f"seg{index:02d}.mp3"
            encode_segment(ffmpeg, args.audio, start, length, segment)
            prompt = segment_prompt(index, start, length, args.speakers, args.first_meeting_only)
            for _attempt in range(2):
                text = ask_gemini(segment, prompt, raw_dir / f"seg{index:02d}.md")
                parsed = [m.groups() for m in (TURN_RE.match(raw.strip()) for raw in text.splitlines()) if m]
                if parsed or END_MARKER in text:
                    break
            turns, words, last_offset = 0, 0, 0
            for a, b, c, speaker, spoken in parsed:
                offset = int(a) * 3600 + int(b) * 60 + int(c) if c else int(a) * 60 + int(b)
                last_offset = max(last_offset, offset)
                timestamp = f"[{format_ts(start + offset)}] " if args.timestamps else ""
                lines.append(f"**{timestamp}{speaker.strip('* ')}:** {spoken.strip()}")
                turns, words = turns + 1, words + len(spoken.split())
            # Gemini tends to emit the end marker when a clip is merely cut off mid-meeting; the per-turn
            # timestamps are what detect that, so they are requested even with --no-timestamps.
            ended = END_MARKER in text and (is_final_segment or last_offset < length - END_GRACE_SECONDS)
            report["segments"].append({"start": start, "length": round(length), "turns": turns, "words": words,
                                       "ended_meeting": ended})
            print(f"segment {index} @{format_ts(start)} ({format_ts(length)}): {turns} turns, {words} words"
                  f"{', meeting ended' if ended else ''}", file=sys.stderr)
            if ended and args.first_meeting_only:
                break
            start, index = start + segment_seconds, index + 1

    args.out.write_text("\n".join(lines) + "\n")
    args.out.with_suffix(".report.json").write_text(json.dumps(report, indent=1))
    print(f"{len(lines)} turns -> {args.out}", file=sys.stderr)


if __name__ == "__main__":
    main()
