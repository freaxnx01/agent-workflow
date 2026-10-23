# Path-scoped rules (4/4) — /integration finding + pilot re-sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `/integration` report a repo's path-scoped rules and flag `rules-invisible-to-opencode`, then re-sync agent-workflow itself as the pilot consumer.

**Architecture:** `instructions_of()` in `scripts/lib/integration-status.sh` gains two reads (the `.claude/rules` listing and `opencode.json`) and records them under `instructions.rules`. Grading stays pure jq: a new clause in `grade_workflow` (it needs `$w.agent`) emits the finding. Rendering adds a rules count to the instructions line. Tests go through the existing `--from` fixture seam.

**Tech Stack:** Bash 5, `jq`, `gh api`; Layer-1 tests in `tests/run-integration-status-tests.sh`.

**Spec:** `docs/superpowers/specs/2026-10-23-path-scoped-rules-design.md`

**Depends on:** Tasks 1–2 none. Task 3 needs plan 2 released **and** plan 3 merged (otherwise the re-sync installs rules but `CLAUDE.md` does not shrink).

## Global Constraints

- Record shape, added to `instructions`: `"rules": {"count": <int>, "opencode_instructions": <array of strings> | null}` — `null` means `opencode.json` is absent, has no `instructions` key, or holds a value of any other type there (a hand-edited file can).
- Covered = some entry of `opencode_instructions` starts with `.claude/rules/`.
- Finding code `rules-invisible-to-opencode`; severity `broken` when `$w.agent == "opencode"`, else `degraded`; only when `rules.count > 0` and not covered; only for repos with a workflow (no finding on `partial` repos); and only where opencode is runnable at all — `OPENROUTER_API_KEY` set on the repo *and* forwarded to the run, since `classify-agent.sh`'s credential guard forces claude otherwise.
- Finding text — opencode: `agent: opencode, but opencode does not read .claude/rules and opencode.json does not list them — runs proceed without these conventions`; Claude: `.claude/rules are not listed in opencode.json; a per-issue agent:opencode label would run without them`.
- Render: the `- instructions:` line gains `  ·  rules <count>` when `count > 0`.
- Each new read follows the existing guard pattern (`e=0; x="$(…)" || e=$?; (( e == 2 )) && ec=2`) — absent is not unreadable.

## Review Focus

- A record from an older `--json` dump with no `instructions.rules` key (`--from` replays) — no finding, no render error.
- `opencode.json` present but not valid JSON — must count as `opencode_instructions: null` (finding fires), not abort the repo's collection.
- `opencode.json` listing the rules by explicit path (`.claude/rules/bash-conventions.md`) rather than the glob — counts as covered.
- `.claude/rules/` containing only non-`.md` files (e.g. `.gitkeep`) — count `0`, no finding. The gh mock ignores `--jq`, so the listing filter is asserted directly against a canned payload.
- `opencode.json` whose `instructions` is not an array of strings — normalised to `null` by the collector, and the grading clause still tolerates it, because `--from` replays dumps collected before that.
- A repo where `OPENROUTER_API_KEY` is unset or unforwarded — no finding, since no opencode run can happen.
- A `partial` repo (instructions, no workflow) with uncovered rules — no finding, verdict stays `partial`.

---

### Task 1: Grade and render the rules state

**Files:**
- Modify: `scripts/lib/integration-status.sh` (header comment finding list; `grade_workflow` in `GRADE_JQ`; `render_repo`)
- Modify: `tests/fixtures/integration/records.json`
- Modify: `tests/run-integration-status-tests.sh`

**Interfaces:**
- Consumes: record field `instructions.rules` per Global Constraints (Task 2 produces it from the API; fixtures supply it here).
- Produces: finding code `rules-invisible-to-opencode`.

- [ ] **Step 1: Write the failing tests and fixtures**

Fixtures: give `freaxnx01/agent-workflow` `rules: {count: 3, opencode_instructions: [".claude/rules/*.md"]}`. Add four records copied from `freaxnx01/agent-workflow` (so they are otherwise healthy), changing only `repo`, `workflow.agent` and `instructions.rules`:

| repo | agent | rules |
|---|---|---|
| `freaxnx01/rules-opencode` | opencode (+ `OPENROUTER_API_KEY` set and forwarded) | `{count: 3, opencode_instructions: null}` |
| `freaxnx01/rules-claude` | claude | `{count: 3, opencode_instructions: null}` |
| `freaxnx01/rules-explicit` | opencode (+ key) | `{count: 1, opencode_instructions: [".claude/rules/bash-conventions.md"]}` |
| `freaxnx01/rules-partial` | workflow `null` | `{count: 3, opencode_instructions: null}` |

Tests (new `section "path-scoped rules"`):
- `assert_finding freaxnx01/rules-opencode rules-invisible-to-opencode` and verdict `broken`
- `assert_finding freaxnx01/rules-claude rules-invisible-to-opencode` and verdict `degraded`
- `assert_no_finding freaxnx01/rules-explicit rules-invisible-to-opencode`, verdict `healthy`
- `assert_no_finding freaxnx01/agent-workflow rules-invisible-to-opencode`, verdict still `healthy`
- verdict of `freaxnx01/rules-partial` is `partial`
- `freaxnx01/bridge` (no `rules` key) → `assert_no_finding … rules-invisible-to-opencode`
- `--repo freaxnx01/agent-workflow` render contains `rules 3`; `--repo freaxnx01/bridge` render does not contain `rules`

- [ ] **Step 2: Run** `bash tests/run-integration-status-tests.sh` — the new assertions fail, all existing ones still pass.
- [ ] **Step 3: Implement** the jq clause in `grade_workflow` (degraded/broken section placement: put it with the other `agent`-dependent clauses, after `opencode-without-key`), the render addition, and the header-comment entry describing why the failure is silent.
- [ ] **Step 4: Run** the test file — all pass; `bash tests/run-all.sh` — all pass; `shellcheck -x scripts/lib/integration-status.sh tests/run-integration-status-tests.sh` clean.
- [ ] **Step 5: Commit** — `feat(integration): flag path-scoped rules opencode cannot see`

### Task 2: Collect the rules state

**Files:**
- Modify: `scripts/lib/integration-status.sh` (`instructions_of`)
- Modify: `commands/integration.md` (add the finding to "The findings that justify the API calls"; note the two extra API calls per repo under "Cost")

**Interfaces:**
- Produces: `instructions.rules` as specified in Global Constraints.

- [ ] **Step 1:** In `instructions_of`, read `gh_json "repos/$repo/contents/.claude/rules" --jq '[.[] | select(.type == "file" and (.name | endswith(".md")))] | length'` (absent → `0`) and `gh_json "repos/$repo/contents/opencode.json" --jq '.content'`, base64-decode, then `jq -c '.instructions // null'` with a parse failure mapped to `null`. Add `rules` to the emitted object.
- [ ] **Step 2: Verify (Layer 3, real API):** `bash scripts/lib/integration-status.sh --repo freaxnx01/agent-workflow --json | jq '.[0].instructions.rules'` → `{"count":0,"opencode_instructions":null}` before Task 3; existing tests still pass (`bash tests/run-integration-status-tests.sh`).
- [ ] **Step 3: Commit** — `feat(integration): collect .claude/rules and opencode.json`

### Task 3: Re-sync agent-workflow as the pilot consumer

**Files:**
- Modify (generated): `CLAUDE.md`, `.github/copilot-instructions.md`, `SKILL.md`, `.ai/base-instructions.md`, `.ai/stacks/ci.md`
- Create (generated): `.claude/rules/{powershell-5.1,bash-conventions,github-actions}.md`, `.github/instructions/` (same three), `opencode.json`

- [ ] **Step 1:** Run `/sync-ai-instructions ci` (plan 2's released version).
- [ ] **Step 2: Verify:**
  - `CLAUDE.md` at least 4 000 bytes smaller than on `main`
  - after merge: `bash scripts/lib/integration-status.sh --repo freaxnx01/agent-workflow` shows `rules 3` and no `rules-invisible-to-opencode`
  - in a fresh Claude session in the worktree: `/memory` does **not** list `bash-conventions`; after `Read scripts/lib/integration-status.sh`, it does
- [ ] **Step 3: Commit** — `chore(ai-instructions): re-sync with path-scoped rules`
