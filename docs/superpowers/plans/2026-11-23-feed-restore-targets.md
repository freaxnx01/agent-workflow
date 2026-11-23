# Private-feed restore targets Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a consumer whose solution is not at the repo root use the
private-feed pre-restore, through `AWF_NUGET_RESTORE`. When no target exists,
refuse clearly instead of failing with `MSB1003`.

**Architecture:**
- `feed_restore_targets` replaces `feed_solutions` in
  `scripts/lib/private-feed-restore.sh`.
- `preflight_restore` gains a syntax check of the variable.
- `restore_private_feeds` distinguishes "no target" (rc 2) from "restore
  failed" (rc 1).

**Tech Stack:** Bash 5, the existing `tests/mocks/dotnet` and the Layer-1
harnesses.

**Spec:** `docs/superpowers/specs/2026-11-23-feed-restore-targets-design.md`

## Global Constraints

- **Entry syntax:** a regex `^[A-Za-z0-9._/-]+\.(sln|slnx|csproj|fsproj)$`, plus
  no leading `/` and no `..` path segment.
- **Messages, exactly:**
  - Preflight: `private feed setup: AWF_NUGET_RESTORE entry '<entry>' is not a relative solution or project path`
  - Missing entry: `AWF_NUGET_RESTORE entry '<entry>' is not in the seed commit`
  - No target: `no solution at the repository root; set AWF_NUGET_RESTORE to the solution or project to restore`
  - Refusal for rc 2: `private feed restore: <first stderr line>`
- **Return codes of `feed_pre_restore`:**
  - `0` — ok;
  - `1` — the restore failed (the Feed-Reader refusal, unchanged);
  - `2` — no target.
- **Refusal section:** `§14` for every feed refusal.

## Review Focus

- **An entry that is a symlink in the seed commit:** refused, rc 2. Task 1
  tests this.
- **Several entries, one missing:** rc 2 before any `dotnet` call. Task 1 tests
  this.
- **A blank variable (only spaces):** treated as unset. Task 1 and Task 2 test
  this.
- **`AWF_NUGET_RESTORE` set while `AWF_NUGET_FEEDS` is unset:** ignored, with no
  restore (`feed_restore_enabled` gates everything). Task 2 tests this.
- **A path containing `./`, as in `./samples/x.sln`:** allowed by the regex, and
  `dotnet` accepts it. No test.

---

### Task 1: `feed_restore_targets` and rc 2 in `feed_pre_restore`

**Files:**
- Modify: `scripts/lib/private-feed-restore.sh` (replace `feed_solutions`; adjust `feed_pre_restore`; add `feed_restore_targets_syntax_check`)
- Modify: `tests/run-private-feed-restore-tests.sh`

**Interfaces:**
- Produces:
  - `feed_restore_targets_syntax_check`: rc 0, or rc 1 with the preflight
    message on stderr, minus the `private feed setup: ` prefix. That prefix is
    added by the driver.
  - `feed_restore_targets <worktree>`: sets `FEED_TARGETS`. Returns rc 0, or
    rc 2 with the message on stderr.
  - `feed_pre_restore`: as before, plus rc 2.

- [ ] **Step 1: Write the failing tests**

```bash
# targets_DefaultRootSolutions: unset, root has a.sln b.slnx → FEED_TARGETS=(a.sln b.slnx)
# targets_BlankIsUnset: AWF_NUGET_RESTORE='  ' → same as unset
# targets_Explicit: AWF_NUGET_RESTORE='samples/dotnet/Sample.sln' committed → FEED_TARGETS=(samples/dotnet/Sample.sln)
# targets_NoRootSolution: unset, no root solution → rc 2, stderr == the "no solution at the repository root…" message
# targets_MissingEntry: 'x/Missing.sln' → rc 2, stderr names 'x/Missing.sln' and 'is not in the seed commit'
# targets_SymlinkEntry: committed symlink 'link.sln' → rc 2
# syntax_RejectsAbsolute / _DotDot / _BadExt / _BadChar: '/a.sln', 'a/../b.sln', 'a.txt', 'a b.sln' → rc 1
# syntax_AcceptsList: 'a.sln sub/b.csproj c/d.fsproj' → rc 0
# pre_restore_NoTarget_Rc2_NoDotnet_CleansUp: no root solution → rc 2, $DOTNET_LOG empty, no worktree/config left
# pre_restore_Explicit_RestoresThatPath: logged dotnet argv contains 'restore samples/dotnet/Sample.sln'
```

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/run-private-feed-restore-tests.sh`
Expected: the new cases FAIL.

- [ ] **Step 3: Implement**

Use the syntax regex and messages from the Global Constraints.
`feed_pre_restore` calls `feed_restore_targets` after the worktree exists and
before the config file is written, and returns 2 through the existing cleanup
path.

- [ ] **Step 4: Run tests and shellcheck**

Run: `bash tests/run-private-feed-restore-tests.sh && shellcheck -x -e SC1091 scripts/lib/private-feed-restore.sh`
Expected: `0 failed`, and shellcheck is clean.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/private-feed-restore.sh tests/run-private-feed-restore-tests.sh
git commit -m "fix(azdo): restore named targets when the repo root has no solution (#682)"
```

### Task 2: Driver refusals and §14

**Files:**
- Modify: `scripts/implement-azdo.sh` (`preflight_restore`, `restore_private_feeds`)
- Modify: `tests/run-implement-azdo-tests.sh`
- Modify: `docs/AZDO-PIPELINE-SETUP.md` (§14: an `AWF_NUGET_RESTORE` subsection)
- Modify: `CHANGELOG.md` (`[Unreleased]` → `Fixed`)

**Interfaces:**
- Consumes: Task 1's `feed_restore_targets_syntax_check`, and `feed_pre_restore`
  with rc 2.

- [ ] **Step 1: Write the failing tests**

```bash
# implement_RestoreBadSyntax_RefusedInPreflight: AWF_NUGET_FEEDS set, AWF_NUGET_RESTORE='/abs.sln'
#   → rc 1, report contains "private feed setup: AWF_NUGET_RESTORE entry '/abs.sln'", $DOTNET_LOG empty, no awf-agent-run workspace call
# implement_NoRootSolution_RefusedWithHint: feeds set, no root solution in the seed → report contains
#   'private feed restore: no solution at the repository root; set AWF_NUGET_RESTORE' and '§14', not 'Feed Reader'
# implement_ExplicitTarget_AgentRuns: AWF_NUGET_RESTORE=samples/dotnet/Sample.sln committed → restore then agent call, in order
# implement_RestoreFailure_KeepsFeedReaderText: DOTNET_MOCK_FAIL=1 → report still contains 'Feed Reader'
# implement_RestoreVarWithoutFeeds_Ignored: AWF_NUGET_RESTORE set, AWF_NUGET_FEEDS unset → no dotnet call, agent runs
```

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/run-implement-azdo-tests.sh`
Expected: the new cases FAIL.

- [ ] **Step 3: Implement**

- **`preflight_restore`:** after the existing config check, call
  `feed_restore_targets_syntax_check` and prefix its message with
  `private feed setup: `.
- **`restore_private_feeds`:** capture rc and stderr of `feed_pre_restore`,
  then branch on 2 versus 1.
- **§14:** document the variable, its default and both refusals.

- [ ] **Step 4: Run the full suite and lint**

Run: `just test`, then `git add` and `pre-commit run --all-files`
Expected: all runners report `0 failed`, and pre-commit passes.

- [ ] **Step 5: Commit**

```bash
git add scripts/implement-azdo.sh tests/run-implement-azdo-tests.sh docs/AZDO-PIPELINE-SETUP.md CHANGELOG.md
git commit -m "fix(azdo): refuse clearly when the private-feed restore has no target (#682)"
```
