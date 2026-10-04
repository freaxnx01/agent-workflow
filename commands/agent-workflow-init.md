---
description: Onboard the current (or a named) repo onto agent-workflow in one call — secrets, labels, settings, consumer stub PR
argument-hint: "[owner/repo] [-- extra onboard-consumer.sh flags]"
---

Wire the target repo onto `freaxnx01/agent-workflow` by running
`scripts/onboard-consumer.sh` from this repo. This is the one-call replacement
for the manual §0–§4 checklist in `docs/CONSUMER-SETUP.md` — see that doc for
what each step actually does and why.

**Target:** $ARGUMENTS (optional `owner/repo`; defaults to the current
directory's `origin` remote. Anything after a bare `--` is forwarded verbatim
to `onboard-consumer.sh`, e.g. `/agent-workflow-init -- --ai-review-ai-merge --chain`.)

## Step 1 — Resolve the target repo

If `$ARGUMENTS` names an `owner/repo`, use it. Otherwise:

```bash
url=$(git remote get-url origin); url=${url%.git}
repo=$(echo "$url" | sed -E 's#.*[:/]([^/]+/[^/]+)$#\1#')
```

Stop if this isn't a git repo with an `origin` pointing at GitHub.

## Step 2 — Resolve the Passbolt secret sources

Look these up **by name**, not by a hardcoded ID (IDs can rot; names are the
stable handle):

```bash
passbolt list resources 2>/dev/null | grep -i "Claude Code OAuth"
passbolt list resources 2>/dev/null | grep -i "OpenRouter API Key 'OpenCode'"
```

Use the first column (the resource UUID) from each match to build:

```bash
SECRET_CMD="passbolt get resource --id <claude-uuid> --json | jq -r '.password'"
OPENROUTER_CMD="passbolt get resource --id <openrouter-uuid> --json | jq -r '.password'"
```

If either lookup finds zero or more than one match, stop and ask the user —
don't guess which resource is the right one. Never print the resource's
`.password` value yourself; only the command string (which `onboard-consumer.sh`
pipes internally) ever touches the secret.

## Step 3 — Run the script

```bash
bash "$(git -C ~/repos/github/freaxnx01/public/agent-workflow rev-parse --show-toplevel)/scripts/onboard-consumer.sh" \
  -R "$repo" \
  --secret-cmd "$SECRET_CMD" \
  --openrouter-cmd "$OPENROUTER_CMD" \
  $EXTRA_ARGS
```

Where `$EXTRA_ARGS` is whatever followed `--` in `$ARGUMENTS` (empty by
default — the script's own defaults are repo-scoped secrets, `agent claude`,
`model claude-sonnet-5`, matching this project's conventions, and it commits
the stub **directly to the default branch** rather than opening a PR — this
is one-shot infra bootstrapping, not day-to-day app code. Pass `-- --pr` if
the user wants the stub reviewed via a branch + PR first instead.).

If the repo already has `.github/workflows/agent.yml` on its default branch,
pass `--no-stub` — the stub already exists; re-running the full script would
just create a redundant no-diff commit (or PR, under `--pr`). Check with the
exit code, not `--jq` on a possibly-404 response (a 404's error body can
still print non-empty output through `--jq`, which silently defeats a
truthiness check):

```bash
default_branch=$(gh api "repos/$repo" --jq .default_branch)
gh api "repos/$repo/contents/.github/workflows/agent.yml?ref=$default_branch" >/dev/null 2>&1 && has_stub=true || has_stub=false
```

## Step 4 — Report

Print:

- Repo name
- What was set: secrets (names only, never values), labels created, the
  Actions "create/approve PRs" setting, and whether the stub was committed
  directly or (under `--pr`) opened as a PR
- If a PR was opened: its URL, and "review + merge it, then label an issue
  `ai-implement` to trigger the pipeline"
- If committed directly: "stub is live on `<default-branch>` — label an
  issue `ai-implement` to trigger the pipeline"
- If `--no-stub` was used because the stub already exists: say so plainly

---

If you hit a blocker (Passbolt resource not found, ambiguous match, the
onboard script erroring on a transient GitHub API failure), retry transient
failures a couple of times before giving up, then report clearly and update
this command for the future.
