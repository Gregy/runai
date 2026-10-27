# runai

Runs coding agents (Claude Code, pi) in a Docker container. `run.sh` builds the
image from this checkout and starts it, with a host bridge so the container can
open URLs in the host browser and write to the host clipboard.

## Claude Code on Bedrock

`run.sh --bedrock` runs Claude Code against AWS Bedrock instead of the
Anthropic login (`CLAUDE_CODE_USE_BEDROCK=1`); it requires `--aws`. The rest
of the Bedrock settings live in `bedrock.env`, which `run.sh` passes to the
container with `docker --env-file`: copy `bedrock.env.example` and set the
region (Claude Code does not read it from `~/.aws/config`), and optionally the
AWS profile and the `ANTHROPIC_DEFAULT_*_MODEL` overrides. AWS variables
exported on the host (forwarded by `--aws`) override the file, e.g.
`AWS_PROFILE=other ./run.sh --aws --bedrock`.

Without `--bedrock`, Claude Code uses the Anthropic login. Keep the Bedrock
variables out of the `env` block of `~/.claude-code-docker/settings.json`:
settings there apply to every run and would force Bedrock even without the
flag.

## pi providers

`run.sh --pi` starts pi with the default model saved in its settings
(`~/.pi-docker/agent/settings.json`, mounted as `~/.pi`); choose another with
`/model` and press `Ctrl+S` to make it the default. Credentials, extensions
and settings all live in `~/.pi-docker`, so they persist across runs.

- **AWS Bedrock** needs `--aws` to forward the host's AWS credentials.
- **Cursor subscription**: install the community
  [pi-cursor](https://github.com/Rahularya01/pi-cursor) extension once with
  `pi install npm:@rahularya01/pi-cursor@<version>` (review the release
  first; it uses Cursor's unofficial protocol), then `/login cursor` inside
  pi. No `--aws` needed.

## Skills

`skills/` holds the agent skills the image ships. The Dockerfile copies them,
with `.claude-plugin/plugin.json`, to `/opt/runai` in the image, and both
agents read them from there in place; nothing is copied into `~/.claude` or
`~/.pi`:

- Claude Code is started with `--plugin-dir /opt/runai`, so the repo is loaded
  as the `runai` plugin and its skills are named `runai:<skill>`.
- pi is started with `--skill /opt/runai/skills`.

A skill change takes effect on the next `run.sh` (which rebuilds the image).
Skills of your own still go in `~/.claude-code-docker/skills` (Claude Code) or
`~/.pi-docker/agent/skills` (pi); avoid reusing a name from `skills/` there, as
pi lets the one in its own directory win.

## Site-specific details are kept out of git

This repository is public. Anything specific to the site it is used at —
internal hostnames, OAuth client IDs, Jira project and field IDs — lives only
in the local checkout and must never be committed:

- **`local.env`** (gitignored): sourced by `run.sh`. `GLAB_*` are passed to
  `docker build`; `GEMINI_ENTERPRISE_*` are passed to the container at runtime
  (`docker run -e`) for the `gemini-enterprise` CLI and its skill:

  ```sh
  GLAB_HOST=gitlab.example.com      # self-hosted GitLab for glab
  GLAB_CLIENT_ID=<OAuth application client_id on that GitLab>

  # Google OAuth client allowing the cloud-platform scope and the
  # https://codeassist.google.com/authcode redirect
  GEMINI_ENTERPRISE_OAUTH_CLIENT_ID=<...>.apps.googleusercontent.com
  GEMINI_ENTERPRISE_OAUTH_CLIENT_SECRET=<...>
  # Gemini Enterprise (Agentspace) instance
  GEMINI_ENTERPRISE_PROJECT=<GCP project ID>
  GEMINI_ENTERPRISE_PROJECT_NUMBER=<GCP project number>
  GEMINI_ENTERPRISE_ENGINE_ID=<engine ID>
  GEMINI_ENTERPRISE_CONFIG_ID=<widget config ID, the cid in the web app URL>
  #GEMINI_ENTERPRISE_LOCATION=us
  ```

  Without it the image builds fine, just without glab pre-configured, and
  `gemini-enterprise` reports which settings are missing.

- **`bedrock.env`** (gitignored): the Bedrock settings for `--bedrock` (AWS
  profile, region, model IDs); see `bedrock.env.example`.

- **`skills/atlassian-mcp/SKILL.md`**: the committed version is generic. The
  local checkout carries the site's Jira defaults (project, product
  classification, custom field IDs) as an **uncommitted modification** to this
  file.

These local changes have to be maintained going forward:

- Do not `git add -A` / `git commit -a` blindly; stage only what you mean to
  commit, and check `git diff --cached` for site details before pushing.
- When the committed `SKILL.md` changes, carry the local modification over
  (`git stash` before pulling or rebasing, `git stash pop` after, and resolve
  any conflict by hand).
