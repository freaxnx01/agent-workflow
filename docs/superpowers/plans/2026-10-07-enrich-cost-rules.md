# Enrichment cost rules (#456) — Implementation Plan

**Goal:** Make enrichment cheaper by default. `commands/enrich.md` gains a
`## Cost rules` section covering the model choice by issue size, no dry runs
(bugs keep their reproduction), and a cap of 3–4 concurrent subagents. Both
Step 3 sections (GitHub and Forgejo) point at it.

**Scope (decided with the maintainer 2026-10-07):** rules only. `autopilot.sh`
is unchanged. It keeps one `MODEL` per run, Fable stays blocked there, and a
per-issue model choice in the lane is a separate follow-up. `/enrich-batch`
(#453) builds on this section and is not part of this plan.

## Global Constraints

- Use Test-Driven Development for every task: write a failing test first, watch it fail, implement minimally to pass, verify green.
- Surgical edits: change only the lines this plan names. The section is prose
  that an agent reads, so it is short and imperative and matches the voice of
  `## Headless mode`.
- Bash tests follow `tests/run-enrich-headless-doc-tests.sh`:
  - `set -euo pipefail`
  - `IFS=$'\n\t'`
  - pass/fail counters
  - exit 1 on any failure
- `tests/run-all.sh` discovers new runners by name. Do not register anything.
- `shellcheck -x -e SC1091` must pass on the new test file.

### Task 1: Cost rules section in commands/enrich.md

**Files:**
- Create: `tests/run-enrich-cost-rules-doc-tests.sh`
- Modify: `commands/enrich.md`. Insert a new `## Cost rules` section directly
  before `## GitHub`, after `### Never wait`. Add a one-line pointer in both
  `### Step 3 — Brainstorm spec` sections.

**Step 1 — failing test.** `tests/run-enrich-cost-rules-doc-tests.sh` extracts
the `## Cost rules` section (from that heading to the next `## ` heading, same
awk as the headless test) and asserts each of these:

1. The section exists.
2. It has `### Model by issue size`, `### No dry runs` and `### Concurrency`
   subheadings.
3. The model subsection names `Sonnet`, `Opus` and `Fable`.
4. It says the **caller** picks the model at launch: the text contains
   `caller`, and both `model` (the Agent tool parameter) and `--model` appear.
5. It says the batch caller states which model it picked: the text matches
   `states? which` (case-insensitive).
6. It names the unattended lane's limits: `MODEL` and `blocked-models.sh`.
7. No-dry-runs keeps bug reproduction mandatory: the text contains
   `reproduc` and `mandatory`.
8. No-dry-runs allows data probes: it contains `probe`.
9. Concurrency caps at four: it matches `at most 4` or `at most four`
   (case-insensitive).
10. Both `### Step 3 — Brainstorm spec` blocks (GitHub, Forgejo) link
    `(#cost-rules)`. Count the Step 3 blocks with the link, and expect exactly 2.

Run `bash tests/run-enrich-cost-rules-doc-tests.sh` and expect a FAIL (no section).

**Step 2 — implement.** Write the section with this content:

- An intro: enrichment subagents and pipeline implement runs share one
  subscription (`CLAUDE_CODE_OAUTH_TOKEN`), so enrichment spend starves
  dispatches. The 5-hour limit was hit twice in one day (#456).
- `### Model by issue size`, as a table of issue kind → model:
  - Simple (a clear one-file fix, a small UI tweak, an amendment to an
    already-enriched issue) → **Sonnet**
  - Architectural or cross-cutting, and bugs whose cause is unknown → **Opus**
  - Graphics and design work for new things → **Fable**

  A session cannot switch its own model. The **caller** picks it at launch:
  the Agent tool's `model` parameter for a subagent, or `claude --model` for a
  nested session. `/enrich --headless` runs on whatever it was launched with. A
  batch caller (`/enrich-batch`, #453) picks per issue and states which model it
  picked in its plan of work. The unattended lane is the exception: it takes one
  `MODEL` per run, and Fable is refused there by
  `scripts/lib/blocked-models.sh`.
- `### No dry runs`:
  - Where the issue already pins the problem down, do not trial-implement the
    plan's code, and do not run Playwright or pipeline scripts to confirm the fix.
  - **Bugs keep the reproduction.** Reproduce headless and measure the cause
    before planning. That stays mandatory.
  - Data probes (OSM, DSM, …) stay allowed when a decision depends on a
    measured number.
- `### Concurrency`: a caller that fans out enrich subagents runs **at most 4**
  at once (3–4). The agent box has 12 GB and no swap, and hitting the cap
  thrashes rather than OOM-killing.
- In each Step 3, after the `$QUICK` paragraph, add one line:
  `Follow [Cost rules](#cost-rules): no dry runs where the issue already pins the problem down.`

Run the test and expect all PASS. Then run `bash tests/run-all.sh` and
`shellcheck -x -e SC1091 tests/run-enrich-cost-rules-doc-tests.sh`, both green.

**Step 3 — commit.**
`docs(enrich): add cost rules — model by issue size, no dry runs, max 4 concurrent`
with `Closes #456` in the footer.
