# Path-scoped rules (1/3) — ai-instructions rule source Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `.ai/rules/` source tree to `freaxnx01/ai-instructions` with a CI-enforced frontmatter contract, and move the three pilot sections into it.

**Architecture:** Rules are Markdown files with `name` + `globs` frontmatter under `.ai/rules/base/` and `.ai/rules/<stack>/`. A new `scripts/check-rules.sh` validates them; `build-stacks-drift.yml` runs it. The moved sections in base and the ci overlay become one-line pointers, so the assembled `CLAUDE.md` shrinks without losing the reference.

**Tech Stack:** Bash 5 (`set -euo pipefail`), `awk`/`sed` for frontmatter, GitHub Actions.

**Spec:** `freaxnx01/agent-workflow` → `docs/superpowers/specs/2026-10-23-path-scoped-rules-design.md`

**Repo:** `freaxnx01/ai-instructions` (all paths below are relative to it).

## Global Constraints

- Rule layout: `.ai/rules/base/<name>.md` (every stack) and `.ai/rules/<stack>/<name>.md` (that stack only); `<stack>` must match a `.ai/stacks/<stack>.md`.
- Frontmatter keys: `name` (equals the filename stem) and `globs` (non-empty YAML flow list of quoted strings, e.g. `globs: ["**/*.sh"]`).
- A rule without a glob is invalid — that content belongs in base or the overlay.
- No rule name may appear in both `base/` and a stack folder.
- Rule bodies are moved **verbatim** from their source section (heading level kept as `##`).
- Pointer line format, replacing the moved section body under its kept `##` heading:
  `Auto-loaded for <globs as code spans, joined by ", "> — see \`.claude/rules/<name>.md\` (Copilot: \`.github/instructions/<name>.instructions.md\`).`
- Scripts follow the ci stack prelude: `#!/usr/bin/env bash`, `set -euo pipefail`, `IFS=$'\n\t'`; exit `0` ok, `1` validation failure, `2` usage error.

## Review Focus

- A rule file with Windows line endings (`\r\n`) — frontmatter must still parse, or fail with a clear message, not pass silently.
- `globs: []` or `globs:` missing entirely — must fail, naming the file.
- A stack folder under `.ai/rules/` with no matching `.ai/stacks/<stack>.md` (typo like `dotnet-webap`) — must fail, otherwise sync silently never installs it.
- A Markdown file in `.ai/rules/` with no frontmatter at all — must fail, not be skipped.
- The assembled size check (`check-claude-md-size.sh`) still passes and the ci-stack assembly is smaller than before.

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

### Task 3: Move the three pilot sections into rules

**Files:**
- Create: `.ai/rules/base/powershell-5.1.md` — globs `["**/*.ps1", "**/*.psm1"]`, body = base `## Scripting` section body
- Create: `.ai/rules/ci/bash-conventions.md` — globs `["**/*.sh"]`, body = ci `## Bash Conventions` body
- Create: `.ai/rules/ci/github-actions.md` — globs `[".github/workflows/**", ".github/actions/**"]`, body = ci `## GitHub Actions Conventions` body
- Modify: `.ai/base-instructions.md` (`## Scripting` body → pointer)
- Modify: `.ai/stacks/ci.md` (both section bodies → pointers)

**Interfaces:**
- Produces: the three rule names `powershell-5.1`, `bash-conventions`, `github-actions` — plan 2's acceptance run and plan 3's re-sync expect exactly these.

- [ ] **Step 1: Record the baseline:** `cat .ai/base-instructions.md .ai/stacks/ci.md | wc -c` (expected ≈ 31 000).
- [ ] **Step 2:** Create the three rule files (frontmatter + body moved verbatim, starting with the section's `##` heading).
- [ ] **Step 3:** Replace each moved body with the pointer line from Global Constraints; keep the `##` heading.
- [ ] **Step 4: Verify:**
  - `./scripts/check-rules.sh` → exit 0
  - `./scripts/check-claude-md-size.sh` → pass
  - re-run the Step 1 command → at least 4 000 bytes smaller
  - `./scripts/build-stacks.sh && git diff --exit-code .ai/stacks/dotnet-*.md` → no drift (base is not part of the dotnet build, this guards against accidental edits)
  - `git diff` shows each removed body appears in exactly one new rule file
- [ ] **Step 5: Commit** — `feat(rules): move PowerShell, Bash and GH Actions conventions into path-scoped rules`

### Task 4: Document the rule tier

**Files:**
- Modify: `README.md` — add `.ai/rules/` to the layout section, with the frontmatter contract and the "glob required, otherwise it belongs in base/overlay" rule.
- Modify: `CHANGELOG.md` — `[Unreleased]` → `Added`: `.ai/rules/` tier and validator; `Changed`: three sections moved to rules.

- [ ] **Step 1:** Edit both files.
- [ ] **Step 2: Verify:** `pre-commit run --files README.md CHANGELOG.md` passes.
- [ ] **Step 3: Commit** — `docs(rules): document the .ai/rules tier`
