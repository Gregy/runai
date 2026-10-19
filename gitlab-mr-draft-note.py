#!/usr/bin/env python3
"""Create GitLab MR draft notes (unpublished review comments) anchored to diff lines.

Why this exists: hand-rolling the `line_code` for a diff note is easy to get
wrong, and GitLab accepts a malformed position with HTTP 201 and then silently
fails to render it. This computes the position from the MR's own diff and
verifies the result server-side.

Usage:
  gitlab-mr-draft-note.py --project group/repo --mr 300 \
      --file path/to/file.py --start 162 --end 166 --body-file note.md
  gitlab-mr-draft-note.py --project group/repo --mr 300 --list
  gitlab-mr-draft-note.py --project group/repo --mr 300 --delete-all
"""
import argparse, hashlib, json, re, subprocess, sys, urllib.parse


def glab(method, path, body=None):
    cmd = ["glab", "api", "--method", method, path]
    if body is not None:
        cmd += ["-H", "Content-Type: application/json", "--input", "-"]
    p = subprocess.run(cmd, input=json.dumps(body) if body else None,
                       capture_output=True, text=True)
    if p.returncode != 0:
        sys.exit(f"glab api {method} {path} failed:\n{p.stderr.strip()}")
    return json.loads(p.stdout) if p.stdout.strip() else None


def diff_map(project, mr):
    """new_path -> {new_line: (kind, old_pos)} replicating Gitlab::Diff::Parser."""
    versions = glab("GET", f"projects/{project}/merge_requests/{mr}/versions")
    latest = glab("GET", f"projects/{project}/merge_requests/{mr}/versions/{versions[0]['id']}")
    out = {}
    for ch in latest["diffs"]:
        m, old, new = {}, 0, 0
        for line in ch["diff"].split("\n"):
            h = re.match(r"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@", line)
            if h:
                old, new = int(h.group(1)), int(h.group(2))
                continue
            if line.startswith("\\"):
                continue
            if line[:1] == "+":
                m[new] = ("new", old); new += 1
            elif line[:1] == "-":
                old += 1
            else:
                m[new] = ("context", old); old += 1; new += 1
        out[ch["new_path"]] = m
    return out


def line_code(path, old_pos, new_line):
    return f"{hashlib.sha1(path.encode()).hexdigest()}_{old_pos}_{new_line}"


def endpoint(path, lines, n):
    """Only ADDED lines are safe endpoints: a context line needs old_line set too,
    and anchoring one with type=new makes GitLab store line_code=None silently."""
    if n not in lines:
        sys.exit(f"{path}:{n} is not part of the diff (deleted line, or outside any hunk)")
    kind, old_pos = lines[n]
    if kind != "new":
        sys.exit(f"{path}:{n} is a {kind} line. Pick an ADDED (green) line as the "
                 f"range endpoint, or the note will not anchor.")
    return {"line_code": line_code(path, old_pos, n), "type": "new",
            "old_line": None, "new_line": n}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--project", required=True, help="group/repo (not URL-encoded)")
    ap.add_argument("--mr", required=True)
    ap.add_argument("--file"); ap.add_argument("--start", type=int); ap.add_argument("--end", type=int)
    ap.add_argument("--body"); ap.add_argument("--body-file")
    ap.add_argument("--list", action="store_true"); ap.add_argument("--delete-all", action="store_true")
    a = ap.parse_args()
    proj = urllib.parse.quote(a.project, safe="")
    base = f"projects/{proj}/merge_requests/{a.mr}/draft_notes"

    if a.list or a.delete_all:
        for n in glab("GET", base):
            pos = n.get("position") or {}
            if a.delete_all:
                glab("DELETE", f"{base}/{n['id']}"); print("deleted", n["id"])
            else:
                ok = "ok  " if n.get("line_code") else "BAD "
                print(f"{ok}{n['id']} {pos.get('new_path')}:{pos.get('new_line')} "
                      f"lc={n.get('line_code')} | {n['note'].splitlines()[0][:60]}")
        return

    if not (a.file and a.start):
        sys.exit("--file and --start are required")
    body = open(a.body_file).read() if a.body_file else a.body
    if not body:
        sys.exit("--body or --body-file is required")
    end = a.end or a.start

    refs = glab("GET", f"projects/{proj}/merge_requests/{a.mr}")["diff_refs"]
    lines = diff_map(proj, a.mr).get(a.file)
    if lines is None:
        sys.exit(f"{a.file} is not in this MR's diff")

    s, e = endpoint(a.file, lines, a.start), endpoint(a.file, lines, end)
    pos = {"base_sha": refs["base_sha"], "start_sha": refs["start_sha"],
           "head_sha": refs["head_sha"], "position_type": "text",
           "new_path": a.file, "old_path": a.file, "old_line": None, "new_line": end,
           "line_range": {"start": s, "end": e}}
    created = glab("POST", base, {"note": body, "position": pos})

    # HTTP 201 does not mean anchored: GitLab derives line_code itself and
    # stores None when the position does not resolve.
    check = [n for n in glab("GET", base) if n["id"] == created["id"]][0]
    if not check.get("line_code"):
        glab("DELETE", f"{base}/{created['id']}")
        sys.exit(f"REJECTED: GitLab stored line_code=None for {a.file}:{a.start}-{end}. "
                 "Draft deleted. Pick different lines.")
    print(f"ok {created['id']} {a.file}:{a.start}-{end} lc={check['line_code']}")
    print("NOTE: if the reviewer cannot see it, have them enable "
          "'Show whitespace changes' in the Changes tab (see CLAUDE.md).")


if __name__ == "__main__":
    main()
