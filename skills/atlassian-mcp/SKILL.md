---
name: atlassian-mcp
description: Read, search, create and edit Jira issues and Confluence pages through the `atlassian-mcp` CLI (official Atlassian Rovo MCP server, browser OAuth login). Use whenever a task touches Jira or Confluence - an issue key like PROJ-123, JQL or CQL, a *.atlassian.net link, a wiki page, a space, a sprint, a comment, a transition.
---

# Atlassian (Jira + Confluence) via `atlassian-mcp`

`atlassian-mcp` (in PATH) is a CLI over the official Atlassian Rovo MCP server
(`https://mcp.atlassian.com/v2/mcp`). It is the only Atlassian tool in this
container. There is no API token; login is browser OAuth.

## Login

```bash
atlassian-mcp status        # "Not logged in." -> log in
atlassian-mcp login         # opens the operator's browser, waits up to 5 min
```

- Run `login` with `run_in_background: true` and tell the operator to approve
  the Atlassian consent page in their browser; you are notified when it exits.
- Tokens live in `~/.config/atlassian-mcp/` and are **not persisted** across
  container restarts, so expect to log in once per container.
- Access tokens refresh automatically. `Unauthorized` or `Token refresh failed`
  means: run `atlassian-mcp login` again.

## Calling tools

```bash
atlassian-mcp tools [-f confluence]          # list tools (name + first line)
atlassian-mcp tools <toolName>               # description + input schema - read it before first use
atlassian-mcp call <toolName> key=value key:=<json> key=@file key:=@file.json
```

- `key=value` passes a string, `key:=...` passes JSON (numbers, booleans,
  objects, arrays), `@path` reads the value from a file. `--json '{...}'` gives
  a base arguments object.
- `cloudId` is filled in automatically (single site, cached). Pass it only to
  target a different site; a Jira/Confluence URL also works as `cloudId`.
- Output is the tool's JSON text on stdout; pipe it through `jq`. Exit code 1
  means the tool reported an error. Errors often include a `repairHint` -
  follow it and retry. `--raw` prints the whole JSON-RPC result.

Built-in tools: `searchConfluence`, `getConfluenceContent`,
`createConfluenceContent`, `updateConfluenceContent`, `searchJiraIssuesUsingJql`,
`getJiraIssue`, `createJiraIssue`, `editJiraIssue`, `transitionJiraIssue`,
`addOrEditJiraIssueComment`, `atlassianUserInfo`, `getAccessibleAtlassianResources`.

Everything else (~300 operations: page children, comments, attachments,
versions, spaces, sprints, boards, worklogs, links, users, ...) goes through
**discover → execute**:

```bash
atlassian-mcp call discover query='list comments on a confluence page'
# read all returned matches, then use the exact name + inputs it gives:
atlassian-mcp call executeRead  name=<operation> inputs:='{"contentId":"123"}'
atlassian-mcp call executeWrite name=<operation> inputs:='{...}'
```

Never guess an operation name - use one from `discover` output. `inputs` is a
flat object (no `cloudId` needed inside it). `responseFields:='["key","fields.summary"]'`
trims large responses.

## Safety

- Jira and Confluence are shared with the whole company. Before any write
  (create/update page, comment, create/edit/transition issue, `executeWrite`)
  make sure the operator asked for that specific change; if you are inferring
  it, show what you will write and ask first.
- **Never** call `executeDestructive` (deletes, irreversible changes) without
  the operator's explicit approval of that exact operation.
- For page updates, use `dryRun:=true` first when the edit is non-trivial.

## Confluence

**Search (CQL):**
```bash
atlassian-mcp call searchConfluence cql='space = DOCS AND title ~ "runbook" ORDER BY lastmodified DESC' limit:=10 \
  | jq '.data.results[] | {id: .content.id, title: .content.title, url: .content._links.webui}'
```

**Read a page** (`content_id=` numeric ID, or `content_url=` a full page URL).
The default `detail` is `summary` (excerpt only) - pass `detail=full` for the body:
```bash
atlassian-mcp call getConfluenceContent content_id=123456 detail=full content_format=markdown | jq -r '.data.body.value'
```
The response also carries `snapshotToken` (needed for updates) and
`metadata.hasSpaceInstructions`.

**Before authoring** (create or update), unless the read returned
`metadata.hasSpaceInstructions=false`, load the space's authoring instructions
once and follow them:
```bash
atlassian-mcp call executeRead name=getConfluenceSpace inputs:='{"spaceIdOrKey":"DOCS"}' | jq '.data.spaceInstructions'
```

**Body format:** `{"format": "markdown" | "html", "value": "<string>"}`.
Markdown is fine for simple text. Use HTML for richer structure, and always for
editing a page that already has rich content (panels, tables, macros, embeds,
mentions): read it with `content_format=html` and preserve what is there,
including `data-local-id` attributes. Do not use Confluence storage XML
(`<ac:structured-macro>` etc.). Before writing non-trivial HTML, read the
format guide (long; save it to a file and read the relevant parts):
```bash
atlassian-mcp call executeRead name=getContentFormatGuide inputs:='{"toolName":"updateConfluencePage"}' | jq -r '.data.body' > /tmp/confluence-format.md
```

Build the body JSON with `jq` so the content is quoted correctly:
```bash
jq -n --rawfile v page.html '{format: "html", value: $v}' > body.json
```

**Update a page:** read it first (`detail=full`), keep the `snapshotToken`,
then:
```bash
atlassian-mcp call updateConfluenceContent contentId=123456 snapshotToken=v:86 body:=@body.json \
  versionMessage='Update runbook steps' dryRun:=true    # drop dryRun to save
```
`title=` renames; omit `body` for a title-only change. A stale
`snapshotToken` (someone edited meanwhile) fails - re-read and redo the edit.
`edits:=[...]` allows granular node edits by `data-local-id` instead of a full
body replacement (see `atlassian-mcp tools updateConfluenceContent`).

**Create a page:**
```bash
atlassian-mcp call createConfluenceContent contentType=page title='My page' \
  parent:='{"spaceId":"98765","parentContentId":"123456"}' body:=@body.json
```
`parent` forms: `{"spaceId"}` (space root), `{"spaceId","parentContentId"}`,
`{"parentContentId"}`, or `{"parentContentUrl"}`. Space ID is numeric - get it
from `getConfluenceSpace` (by key) or from a page read (`spaceId`).
`draft:=true` creates a draft; `private:=true` makes it visible only to the
operator.

Other Confluence work (comments, children/descendants, attachments, labels,
versions, moving pages) -> `discover`.

## Jira

If the operator's instructions name a default project, filters or required
fields for Jira work, apply them to every search and every created issue unless
the operator explicitly asks for something else. An issue key given directly
(e.g. `ABC-12`) is read as-is, whatever its project.

```bash
# search
atlassian-mcp call searchJiraIssuesUsingJql jql="project = PROJ AND assignee = currentUser() AND statusCategory != Done" maxResults:=20 \
  | jq '.data.issues[] | {key, summary: .fields.summary, status: .fields.status.name}'
# page with nextPageToken= until .data.isLast is true

# one issue (view=evidence adds custom fields + links; descriptions come back as markdown)
atlassian-mcp call getJiraIssue issueIdOrKey=PROJ-123 view=evidence

# create; extra or custom fields go in additional_fields, e.g. a cascading select:
atlassian-mcp call createJiraIssue projectKey=PROJ issueType=Task summary='...' description=@desc.md \
  additional_fields:='{"customfield_10000": {"value": "Parent", "child": {"value": "Child"}}}'

# edit fields (multi-value fields are replaced, not appended)
atlassian-mcp call editJiraIssue issueIdOrKey=PROJ-123 fields:='{"summary":"New title"}'

# transition: list transitions first, then use the transition's id (its name is not the target status)
atlassian-mcp call executeRead name=listJiraIssueTransitions inputs:='{"issueIdOrKey":"PROJ-123"}' | jq '.data.transitions[] | {id, name}'
atlassian-mcp call transitionJiraIssue issueIdOrKey=PROJ-123 transitionId=91

# comment (markdown); comments are listed via executeRead name=listJiraIssueComments
atlassian-mcp call addOrEditJiraIssueComment issueIdOrKey=PROJ-123 commentBody=@comment.md
```

User fields (assignee etc.) take account IDs: resolve names with
`executeRead name=lookupJiraAccountId` or `listJiraIssueAssignableUsers`
(use `discover` for their inputs). Sprints, boards, worklogs, versions,
issue links -> `discover`.
