# /enrich-batch outside the target repo: worktrees and credentials (#618)

## Problem

`commands/enrich-batch.md` assumes the session runs inside a clone of the repo
being enriched and that the default `gh` login can write labels. Two things
broke on 2026-11-16 (#495, #498-#501) when the session ran from an unrelated repo:

1. Step 4 dispatches with `isolation: "worktree"`. That worktree is cut from the
   calling session's cwd repo, not the target.
2. The default `gh` login could comment but not add labels, so `/enrich`'s lock
   step failed and the #498 run stopped.

## Design

Docs-only. Edit `commands/enrich-batch.md` and its Layer-1 test.

**New "Step 0 - Target repo and credentials"**, before Step 1. It is a no-op
(stated in its first line) when cwd is a clone of the target and the default
login can write labels.

- Target repo: new optional `--repo <owner/name>`; default is the cwd's repo.
  When the target is not the cwd repo, every `gh` call in the command gets
  `--repo`, and Step 1's `gh repo view` is replaced by the literal name.
- Target clone (only when cwd is not the target): the clone the user named,
  else the autopilot cache clone (`sync_autopilot_clone`). Verified by
  `git -C <clone> remote get-url origin`. A user-named clone is only ever
  fetched, never reset.
- Pre-flight label write: an idempotent write (`gh label create
  enrichment-ongoing ... || gh label edit enrichment-ongoing`) with the
  description `/enrich` Step 2.5 uses. Exit 0 proves label-write rights, which a
  read-only check does not.
- On failure, find the credential wrapper the way the user-level rule says:
  `direnv status` run inside the target clone; require an allowed RC; wrapper
  is `direnv exec <rc-dir>`. Re-run the probe wrapped. If it passes, every `gh`
  call of the session and every subagent `gh` call/push is wrapped; if it still
  fails, stop before dispatch and report the exact error. No interactive login.

**Step 4 changes**

- `isolation: "worktree"` stays only for the cwd-is-target case.
- Otherwise the coordinator creates each worktree itself, serially, before
  dispatch: `git -C <clone> fetch origin`, then `git -C <clone> worktree add
  <clone>/.worktrees/enrich-<n> -b enrich/<n> origin/main`, and the prompt names
  that path and branch. The subagent works only there (absolute paths, `cd`
  inside each Bash call).
- The subagent prompt carries the wrapper (never a token value): "run every `gh`
  call as `<wrapper> gh ...` and push with `<wrapper> bash -c
  'GITHUB_TOKEN="${GH_TOKEN:-$GITHUB_TOKEN}" git -C <worktree> push ...'`".
  A headless subagent does not switch credentials on its own.

**Step 6 change**: worktree removal and branch deletion run against the clone
that owns the worktree (`git -C "$clone" ...`), derived from the worktree's git
common dir, not against the cwd.

## Acceptance criteria

- `commands/enrich-batch.md` has a Step 0 covering target repo, target clone,
  the label-write pre-flight and the direnv wrapper, and says it is a no-op in
  the in-repo case.
- Step 4 uses `isolation: "worktree"` only when cwd is the target; otherwise the
  coordinator creates `<clone>/.worktrees/enrich-<n>` on `enrich/<n>` from
  `origin/main` and passes path and branch in the prompt.
- The Step 4 prompt template carries the auth wrapper and the push form with the
  `GITHUB_TOKEN` bridge, and no token value.
- Step 6 removes worktrees and branches via `git -C "$clone"`.
- `tests/run-enrich-batch-doc-tests.sh` asserts all of the above and passes,
  together with the rest of `tests/run-all.sh`.

## Assumptions

- **A1** [high] Docs-only change, no new script. Rejected: a helper in
  `scripts/lib/`. The command is a prompt (`commands/enrich-batch.md:1-10`) and
  its only tests are doc-shape checks (`tests/run-enrich-batch-doc-tests.sh:1-12`).
- **A2** [med] Add an optional `--repo <owner/name>` argument. Rejected: inferring
  the target from the issue numbers alone. Nothing in the command can name the
  repo when cwd is elsewhere; Step 1 uses `gh repo view`
  (`commands/enrich-batch.md:35,42`), which reads the cwd.
- **A3** [med] The coordinator creates the worktrees, serially, rather than each
  subagent as in the 2026-11-16 workaround. Rejected: subagent-created worktrees.
  Four parallel `git worktree add` calls on one repo contend on its locks, and
  Step 6 needs a known path for cut-off runs (`commands/enrich-batch.md:165-176`).
- **A4** [med] With no clone named, fall back to the autopilot cache clone via
  `sync_autopilot_clone`. Rejected: scanning the filesystem for a clone.
  `scripts/lib/autopilot-clone.sh:25-32` already owns a clean per-repo clone.
- **A5** [med] The pre-flight is an idempotent label write, not a permission
  read. Rejected: `gh api repos/<r> --jq .permissions`. The role field does not
  reflect token scope, and the failure on 2026-11-16 was a failed label write.
- **A6** [high] The wrapper is discovered with `direnv status` in the target
  clone and never hard-coded. Rejected: naming a path in the command. The command
  is shared; the credential layout is per user (user-level auth rule).
- **A7** [high] `.worktrees/` is added to the clone's local exclude
  (`git rev-parse --git-path info/exclude`) when not already ignored. Rejected:
  editing the clone's tracked `.gitignore`. This repo already ignores it
  (`.gitignore:3`).

## Consequences

- With cwd as the target and a working login, the command runs exactly as before
  apart from one idempotent label write at Step 0.
- That write can create `enrichment-ongoing` in a repo that lacks it, which
  `/enrich` Step 2.5 would have done anyway.
- A session outside the target now stops before dispatch when no credential
  wrapper can write labels, instead of four subagents failing one by one.
- No dependency on another issue's plan; no shared files with other open
  enrich-batch work.
