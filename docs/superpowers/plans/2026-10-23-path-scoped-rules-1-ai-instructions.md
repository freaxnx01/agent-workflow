# Path-scoped rules (1/4) — ai-instructions rule source Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `.ai/rules/` source tree to `freaxnx01/ai-instructions` with a CI-enforced frontmatter contract, and add the three pilot rules — as copies; the source sections stay in base and the ci overlay until plan 3.

**Architecture:** Rules are Markdown files with `name` + `globs` frontmatter under `.ai/rules/base/` and `.ai/rules/<stack>/`. A new `scripts/check-rules.sh` validates them; `build-stacks-drift.yml` runs it. The source sections stay untouched here: replacing them with pointers before the sync can install rules (plan 2) would strip them from every consumer that re-syncs in between — the base section from all stacks. Plan 3 does the swap.

**Tech Stack:** Bash 5 (`set -euo pipefail`), `awk`/`sed` for frontmatter, GitHub Actions.

**Spec:** `freaxnx01/agent-workflow` → `docs/superpowers/specs/2026-10-23-path-scoped-rules-design.md`

**Repo:** `freaxnx01/ai-instructions` (all paths below are relative to it).

## Global Constraints

- Rule layout: `.ai/rules/base/<name>.md` (every stack) and `.ai/rules/<stack>/<name>.md` (that stack only); `<stack>` must match a `.ai/stacks/<stack>.md`.
- Frontmatter keys: `name` (equals the filename stem) and `globs` (non-empty YAML flow list of quoted strings, e.g. `globs: ["**/*.sh"]`).
- A rule without a glob is invalid — that content belongs in base or the overlay.
- No rule name may appear in both `base/` and a stack folder.
- Rule bodies are copied **verbatim** from their source section (heading level kept as `##`).
- `.ai/base-instructions.md` and `.ai/stacks/ci.md` are **not modified** by this plan.
- Scripts follow the ci stack prelude: `#!/usr/bin/env bash`, `set -euo pipefail`, `IFS=$'\n\t'`; exit `0` ok, `1` validation failure, `2` usage error.

## Review Focus

- A rule file with Windows line endings (`\r\n`) — frontmatter must still parse, or fail with a clear message, not pass silently.
- `globs: []` or `globs:` missing entirely — must fail, naming the file.
- A stack folder under `.ai/rules/` with no matching `.ai/stacks/<stack>.md` (typo like `dotnet-webap`) — must fail, otherwise sync silently never installs it.
- A Markdown file in `.ai/rules/` with no frontmatter at all — must fail, not be skipped.
- A rule body that drifts from its still-present source section while both exist — out of scope for the validator; plan 3 removes the duplicate, so keep the window short.

---

### Task 1: Rule validator with fixture tests

**Files:**
- Create: `scripts/check-rules.sh`
- Create: `tests/run-check-rules-tests.sh`
- Create: `tests/fixtures/rules/valid/.ai/rules/base/ok.md`, `tests/fixtures/rules/valid/.ai/stacks/ci.md`, `tests/fixtures/rules/valid/.ai/rules/ci/ok-ci.md`
- Create one fixture root per failure under `tests/fixtures/rules/<case>/` for: `missing-globs`, `empty-globs`, `name-mismatch`, `no-frontmatter`, `unknown-stack`, `duplicate-name`, `crlf`

**Interfaces:**
- Produces: `scripts/check-rules.sh [ROOT]` — `ROOT` defaults to the repo root; validates every `ROOT/.ai/rules/**/*.md`; prints `ERROR: <path>: <reason>` per violation to stderr; exit `0`/`1`/`2`. Absent `.ai/rules/` → exit `0` with `No rules — skipping.`

- [ ] **Step 1: Write the fixture tests**

`tests/run-check-rules-tests.sh` runs the script against each fixture root and asserts:
- `valid` → exit 0
- each failure case → exit 1 and stderr contains the file path and these reasons: `missing-globs`/`empty-globs` → `globs`; `name-mismatch` → `name`; `no-frontmatter` → `frontmatter`; `unknown-stack` → `no .ai/stacks/`; `duplicate-name` → `duplicate`
- `crlf` (valid content with `\r\n` endings) → exit 0
- non-existent ROOT → exit 2

- [ ] **Step 2: Run tests — expect failure** (`bash tests/run-check-rules-tests.sh` → script not found)

- [ ] **Step 3: Implement `scripts/check-rules.sh`**

Strip `\r` before parsing. Frontmatter = lines between the first two `---` lines, file must start with `---`. Extract `name:` and `globs:` with `sed`; `globs` valid when it matches `^\[ *".+" *(, *".+" *)*\]$`. Collect names per folder for the duplicate check.

- [ ] **Step 4: Run tests — expect pass**; also `shellcheck -x scripts/check-rules.sh tests/run-check-rules-tests.sh` clean.

- [ ] **Step 5: Commit** — `feat(rules): add .ai/rules frontmatter validator`

### Task 2: Wire the validator into CI

**Files:**
- Modify: `.github/workflows/build-stacks-drift.yml`

**Interfaces:**
- Consumes: `scripts/check-rules.sh` (Task 1).

- [ ] **Step 1:** Add `.ai/rules/**`, `scripts/check-rules.sh` and `tests/**` to `on.pull_request.paths`.
- [ ] **Step 2:** Add two steps after the size check: `bash tests/run-check-rules-tests.sh` and `./scripts/check-rules.sh`.
- [ ] **Step 3: Verify:** `actionlint .github/workflows/build-stacks-drift.yml` clean.
- [ ] **Step 4: Commit** — `ci(rules): validate .ai/rules in build-stacks-drift`

### Task 3: Add the three pilot rules

**Files:**
- Create: `.ai/rules/base/powershell-5.1.md` — globs `["**/*.ps1", "**/*.psm1"]`, body = base `## Scripting` section body
- Create: `.ai/rules/ci/bash-conventions.md` — globs `["**/*.sh"]`, body = ci `## Bash Conventions` body
- Create: `.ai/rules/ci/github-actions.md` — globs `[".github/workflows/**", ".github/actions/**"]`, body = ci `## GitHub Actions Conventions` body

**Interfaces:**
- Produces: the three rule names `powershell-5.1`, `bash-conventions`, `github-actions` — plans 2–4 expect exactly these.

- [ ] **Step 1:** Create the three rule files (frontmatter + body copied verbatim, starting with the section's `##` heading).
- [ ] **Step 2: Verify:**
  - `./scripts/check-rules.sh` → exit 0
  - `git diff --stat` touches only `.ai/rules/**`
  - each rule body is byte-identical to its source section (`diff <(sed -n '/^## Bash Conventions/,/^## /p' .ai/stacks/ci.md | sed '$d') <(sed '1,/^---$/d' .ai/rules/ci/bash-conventions.md | sed '1,/^---$/d')` — adapt per rule; expect no output)
- [ ] **Step 3: Commit** — `feat(rules): add PowerShell, Bash and GH Actions conventions as path-scoped rules`

### Task 4: Document the rule tier

**Files:**
- Modify: `README.md` — add `.ai/rules/` to the layout section, with the frontmatter contract and the "glob required, otherwise it belongs in base/overlay" rule.
- Modify: `CHANGELOG.md` — `[Unreleased]` → `Added`: `.ai/rules/` tier, validator and the three pilot rules.

- [ ] **Step 1:** Edit both files.
- [ ] **Step 2: Verify:** `pre-commit run --files README.md CHANGELOG.md` passes.
- [ ] **Step 3: Commit** — `docs(rules): document the .ai/rules tier`
