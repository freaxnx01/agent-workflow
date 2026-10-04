# `/advisor` in Claude Code Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let any Claude Code session become the Software Factory advisor via `/advisor <topic>`, with the advisor's rules moved from claude.ai Project memory into git and its "never merges" guarantee enforced by a permission deny-list.

**Architecture:** Three markdown/JSON deliverables plus one Layer-1 test runner that pins their contract. `commands/advisor.md` is a prompt (sibling of `commands/autopilot.md`); `setup/advisor-settings.json` is a Claude Code settings file loaded with `claude --settings`; `docs/ADVISOR-PROMPT.md` gains rules and failure modes. No scripts — there is no runtime code to test beyond the static contract.

**Tech Stack:** Markdown, Claude Code settings JSON, bash + `jq` for the test runner.

**Spec:** GitHub issue freaxnx01/agent-workflow#459 (parts 1–3; part 4, the `auto-lane-v1` milestone, is already done — milestone #5 holds #373 #433 #457 #458).

## Global Constraints

- Use Test-Driven Development for every task: write a failing test first, watch it fail, implement minimally to pass, verify green.
- Test runner follows `tests/run-*-tests.sh` conventions (prelude `set -euo pipefail` + `IFS=$'\n\t'`, pass/fail counters, summary, exit 1 on any failure) so `tests/run-all.sh` discovers it.
- Command front-matter matches siblings: a single `description:` line.
- Reference #459 in every commit; Conventional Commits.
- Docs are English; no new dependencies.

## Review Focus

- `/advisor` with **no** argument must ask for a topic and not scan — pinned by a test grepping for the empty-`$ARGUMENTS` rule.
- Deny rules must also catch flag-first forms (`gh pr merge --squash 12`) — the rule is a prefix match on `gh pr merge`, pinned by asserting the exact rule strings.
- A session started **without** `--settings` has no guardrail — the command must say so, pinned by a test grepping `advisor-settings.json` in `commands/advisor.md`.
- Listing drift: the command must appear in `commands/README.md`, `docs/COMMAND-CHEATSHEET.md` and the root `README.md` command block — pinned by tests.
- The milestone agenda must be read live (`gh`), never from a table in the doc — pinned by grepping for `auto-lane-v1` with a `gh` call in the command.

---

### Task 1: Test runner (red)

**Files:** Create `tests/run-advisor-tests.sh`

Asserts (each a named case):

1. `commands/advisor.md` exists, line 1 is `---`, has `description:` front-matter.
2. It mentions `docs/ADVISOR-PROMPT.md` and `docs/FACTORY-MAP.md`.
3. It handles empty `$ARGUMENTS` by asking for a topic (`$ARGUMENTS` present and the phrase `ask for one`).
4. It names `auto-lane-v1` and `gh api` / `gh issue list` for the agenda.
5. It names `triggeringActor` (run verification beyond labels).
6. It names `setup/advisor-settings.json`.
7. `setup/advisor-settings.json` is valid JSON (`jq -e .`) and `.permissions.deny` contains each required rule string (see Task 2).
8. `docs/ADVISOR-PROMPT.md` contains `TL;DR`, `Trusting \`ai:done\``, `numbering gaps`, `read-back`, `bridge#335`, `advisor-settings.json`.
9. `/advisor` appears in `commands/README.md`, `docs/COMMAND-CHEATSHEET.md`, `README.md`.

- [ ] Write runner; run `bash tests/run-advisor-tests.sh` → FAIL (files missing).
- [ ] Commit `test(advisor): pin the /advisor contract (#459)`.

### Task 2: Guardrail settings + command + listings (green for 1–7, 9)

**Files:** Create `setup/advisor-settings.json`, `commands/advisor.md`; modify `commands/README.md`, `docs/COMMAND-CHEATSHEET.md`, `README.md`.

`setup/advisor-settings.json` — deny-list, rule strings as fixed in the test (syntax verified against the Claude Code permissions docs).

`commands/advisor.md` — front-matter `description: Run the Software Factory advisor — read the canonical docs, then work one topic`. Body: read both docs first every time; topic from `$ARGUMENTS`, ask if empty; auto-lane topic → list `auto-lane-v1` open issues via `gh issue list --milestone auto-lane-v1`; verify runs with `gh pr view/checks`, `gh run list/view --json actor,triggeringActor`, diff vs plan; guardrail note pointing at `claude --settings setup/advisor-settings.json`.

- [ ] Implement; run tests → cases 1–7, 9 pass; 8 still fails.
- [ ] Commit `feat(commands): add /advisor and its guardrail settings (#459)`.

### Task 3: ADVISOR-PROMPT additions (green for 8)

**Files:** Modify `docs/ADVISOR-PROMPT.md`

Add: TL;DR rule under Ground rules; three rows to Known failure modes (#430/#457 ai:done, numbering gaps, write without read-back); Tool note on bridge MCP limits (no PR/run tools — freaxnx01/bridge#335 → hand over to Claude Code); a "Running in Claude Code" section with the launch line and the deny-list.

- [ ] Implement; `bash tests/run-advisor-tests.sh` and `bash tests/run-all.sh` → all green.
- [ ] Commit `docs(advisor): move Project-memory rules into ADVISOR-PROMPT (#459)`.

### Not automatable (left to the operator)

- AC 3 live part: a session launched with the settings file refuses `gh pr merge`.
- AC 5: one real Remote Control advisor session verifying a dispatched run.
