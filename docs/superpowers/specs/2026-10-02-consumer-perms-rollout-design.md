# Roll missing caller permissions out to the consumer fleet

**Issue:** [#441](https://github.com/freaxnx01/agent-workflow/issues/441)
**Follow-up to:** [#434](https://github.com/freaxnx01/agent-workflow/issues/434) (merged `6c6ac39`)
**Date:** 2026-10-02
**Status:** Draft (quick-mode enrichment — assumptions recorded in the issue body)

## Problem

#434 made the gap visible: `scripts/migrate-consumers.sh` now prints
`perms:ok | perms:MISSING <scopes> | perms:ERROR` per consumer, computed by
`scripts/check-caller-permissions.sh`. A read-only sweep found **37** `game-*`
consumers on `@v2` whose `agent.yml` lacks `actions: write`. Each of them fails
every `ai-implement` dispatch at `startup_failure`, because a reusable workflow
can't be granted more than its caller (game-sky-fury#7 was the hand fix for one).

What is missing is the *rollout*: a supported, reviewable way to add the scope
to 37 repos — one PR per repo, dry-run first — instead of 37 hand edits or
another throwaway script (the v1→v2 throwaway mangled a full-version pin, which
is why `migrate-consumers.sh` exists at all).

### Evidence the fleet is uniform

A read-only dry run of a prototype (`gh api …/contents` + `gh pr list` only, no
writes) against all 37 repos on 2026-10-02: **37/37** were editable and
`would fix → actions`; one repo read as `UNREADABLE` once and succeeded on a
retry (transient). Every stub has the shape game-sky-fury had before #7: a
top-level `permissions:` block with aligned trailing comments, no job-level
block on the calling job.

## Design

A third mode of `scripts/migrate-consumers.sh`, `--fix-perms`, beside
inventory and migrate. It reuses the script's discovery (`--owner`, `--repo`,
`$CONSUMERS`), its per-repo read, its `perms_verdict`, and its write path
(`--apply`, branch creation, contents `PUT`). Two pieces are new.

### 1. `rewrite_perms` — the part that has to be exactly right

A pure stdin→stdout function, exposed through a `FIX_PERMS_STDIN=1` seam
(`GRANTS=actions=write`), exactly like `rewrite_pin` / `REWRITE_STDIN`:

- **Which block.** The one GitHub applies to the job whose `uses:` names
  `agent-implement.yml` — that job's own `permissions:` if it has one (a
  job-level block *replaces* the top-level one), else the top-level block.
  These are #434's semantics; using the same rule means the checker and the
  rewriter can never disagree about where the gap is.
- **What it writes.** A missing scope is appended after the block's last entry,
  at the entries' indentation, without a comment. A scope granted at a lower
  level (`read` where `write` is needed) is raised in place, trailing comment
  kept. Every other byte of the file is printed unchanged.
- **Idempotent.** A scope already at or above the requested level is left alone.
- **Refuses, never guesses** (exit 3, reason on stderr) on: flow style
  (`permissions: { … }`), `read-all` / `write-all` (expanding them into a map
  would silently change every other scope), no block for the calling job at
  all, and no job calling `agent-implement.yml`.

### 2. `fix_perms_repo` — the per-repo verdict

| `perms` verdict | Dry run | `--apply` |
|---|---|---|
| `perms:ok` | `perms ok`, skipped | same |
| `perms:ERROR` | `perms:ERROR  not edited`, failed | same |
| `perms:MISSING …`, uneditable | `cannot edit: <reason>`, failed | same |
| `perms:MISSING …`, fix PR already open | `PR already open <url>`, skipped | same |
| `perms:MISSING …` | `would fix → <scopes>  perms:MISSING …` | PUT on branch + `gh pr create` → `fixed → PR <url>` |

- Scopes to add come from the checker (`<scope>: needs <level>, …` →
  `scope=level`), never from a hard-coded `actions: write`.
- Belt and braces: the rewritten stub is re-checked with `perms_verdict`; if it
  is not `perms:ok` the repo is reported `cannot edit` and not written.
- **Always via a PR** (`--fix-perms` implies `--pr`). Default branch
  `fix/agent-workflow-caller-permissions` (`--branch` overrides). Commit and PR
  title `fix(ci): grant actions: write to the agent-workflow caller` — the
  wording game-sky-fury#7 used.
- The written file keeps its trailing newline.
- `--fix-perms` with `--to` is a usage error (exit 2): a pin bump and a
  permissions fix are separate concerns and separate PRs.
- Exit 1 when any repo failed (ERROR, uneditable, write or PR failure), so the
  operator cannot miss it in a 37-line run.

The existing contents-PUT / branch-create block is extracted into `put_stub`
and shared by migrate and fix-perms; migrate's behaviour is unchanged.

### Operator rollout (not part of the implementation)

```bash
bash scripts/migrate-consumers.sh --owner freaxnx01 --fix-perms           # dry run
bash scripts/migrate-consumers.sh --owner freaxnx01 --fix-perms --apply   # 37 PRs
# merge them, then:
bash scripts/migrate-consumers.sh --owner freaxnx01                       # expect perms:ok
```

Documented in the script header and `docs/CONSUMER-SETUP.md`. Running it is a
human step after merge; the implementation and its tests touch no real repo.

## Testing

All Layer-1, in `tests/run-script-tests.sh`, `gh` mock only:

- Rewriter: the exact pre-#7 game-sky-fury stub → exact expected output;
  idempotence; calling-job block vs. top-level; unrelated job's block ignored;
  `read`→`write` in place; refusals (flow, read-all, no block, no caller); seam
  without `GRANTS` exits 2.
- Fleet: dry run writes nothing; `--apply` PUTs on the fix branch and opens one
  PR, and the PUT content decodes to exactly the rewriter's output; `perms:ok`
  untouched; open PR not duplicated; uneditable, `perms:ERROR` and failed
  `pr create` each reported and exit 1; `--fix-perms --to` exits 2.
- Docs: `CONSUMER-SETUP.md` documents the `--fix-perms --apply` command.

## Out of scope (discoveries, not acted on)

- Migrate mode swallows a failed `gh pr create` (`|| true`) and still prints
  `migrated`; it also drops the stub's trailing newline. Same class as the
  failures fix-perms reports — worth its own issue.
- A re-run after `PR FAILED` (branch written, no PR) hits `WRITE FAILED`
  because the PUT uses the default branch's blob sha; the operator opens that
  PR by hand. Not worth handling for a one-off rollout.
