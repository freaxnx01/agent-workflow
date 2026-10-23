# Path-scoped rules (3/4) — swap source sections for pointers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the three pilot sections' bodies from base and the ci overlay, leaving one-line pointers, so the assembled `CLAUDE.md` shrinks.

**Architecture:** Pure content edit in `freaxnx01/ai-instructions`. The rule copies from plan 1 become the only source; the sync from plan 2 installs them.

**Tech Stack:** Markdown, existing `scripts/check-*.sh`.

**Spec:** `freaxnx01/agent-workflow` → `docs/superpowers/specs/2026-10-23-path-scoped-rules-design.md`

**Repo:** `freaxnx01/ai-instructions`.

**Gate:** do **not** start before `sync-ai-instructions` 0.5.0 (plan 2) is released. Check: `gh api repos/freaxnx01/agent-skills/contents/plugins/sync-ai-instructions/.claude-plugin/plugin.json --jq .content | base64 -d | jq -r .version` → `0.5.0` or later.

## Global Constraints

- Pointer line, replacing each section body under its kept `##` heading:
  `Auto-loaded for <globs as code spans, joined by ", "> — see \`.claude/rules/<name>.md\` (Copilot: \`.github/instructions/<name>.instructions.md\`).`
- Before deleting a body, it must be byte-identical to its rule file's body; if it drifted since plan 1, move the drift into the rule first.

## Review Focus

- A body edited in base/overlay after plan 1 merged (drift) — lost unless carried into the rule.
- The assembled size check still passes and the ci assembly is ≥ 4 000 bytes smaller.
- No other stack's assembly changes except for the base `## Scripting` pointer.

---

### Task 1: Replace the three bodies with pointers

**Files:**
- Modify: `.ai/base-instructions.md` (`## Scripting`)
- Modify: `.ai/stacks/ci.md` (`## Bash Conventions`, `## GitHub Actions Conventions`)
- Modify: `CHANGELOG.md` (`[Unreleased]` → `Changed`)

- [ ] **Step 1: Baseline:** `cat .ai/base-instructions.md .ai/stacks/ci.md | wc -c`.
- [ ] **Step 2: Drift check:** for each of the three, diff the section body against the rule body (plan 1 Task 3 Step 2 command); carry any difference into the rule file.
- [ ] **Step 3:** Replace each body with its pointer line.
- [ ] **Step 4: Verify:** `./scripts/check-rules.sh` exit 0; `./scripts/check-claude-md-size.sh` pass; Step 1 command ≥ 4 000 bytes smaller; `./scripts/build-stacks.sh && git diff --exit-code .ai/stacks/dotnet-*.md` clean.
- [ ] **Step 5: Commit** — `feat(rules): replace PowerShell, Bash and GH Actions sections with rule pointers`
