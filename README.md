# runai

Runs coding agents (Claude Code, pi) in a Docker container. `run.sh` builds the
image from this checkout and starts it, with a host bridge so the container can
open URLs in the host browser and write to the host clipboard.

## Site-specific details are kept out of git

This repository is public. Anything specific to the site it is used at —
internal hostnames, OAuth client IDs, Jira project and field IDs — lives only
in the local checkout and must never be committed:

- **`local.env`** (gitignored): build settings that `run.sh` sources and
  passes to `docker build`:

  ```sh
  GLAB_HOST=gitlab.example.com      # self-hosted GitLab for glab
  GLAB_CLIENT_ID=<OAuth application client_id on that GitLab>
  ```

  Without it the image builds fine, just without glab pre-configured.

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
