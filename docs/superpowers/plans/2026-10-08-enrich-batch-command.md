# /enrich-batch command (#453) — Implementation Plan

**Goal:** Add `commands/enrich-batch.md`, an interactive batch-enrichment
session around `/enrich <n> --headless`. `/enrich` itself stays a one-issue
command. `/enrich-batch` is the interactive counterpart to `/autopilot`, with a
human in the loop.

**Decisions (with the maintainer, 2026-10-08):**

- **Selection** reuses `scripts/lib/autopilot-candidates.sh`
  (`autopilot_candidates <owner/repo> <limit>`). Optional arguments narrow it:
  explicit issue numbers, or `--milestone <name>`.
- **Bug reproduction** uses the repo's own tooling, for example Playwright for a
  web UI. It must pin the cause with numbers. A bug that cannot be reproduced
  gets `needs-human`.
- **Shape:** a prompt plus a Layer-1 doc test. No new scripts.
- **Cost rules** come from `commands/enrich.md` `## Cost rules` (#456): model by
  issue size, no dry runs, at most 4 subagents at once. Link to them; do not
  restate the table.
- **GitHub-only**, like `--headless` itself.

## Global Constraints

- Use Test-Driven Development for every task: write a failing test first, watch it fail, implement minimally to pass, verify green.
- The command is a prompt for an agent: terse and imperative, in the voice of
  `commands/enrich.md` and `commands/autopilot.md`.
- It starts with YAML frontmatter (`description:`, `argument-hint:`) and the same
  `detect_forge` opener as `/enrich`.
- It ends with: "If you run into blockers, find a solution and update this command for the future."
- Bash tests follow `tests/run-enrich-cost-rules-doc-tests.sh`:
  - `set -euo pipefail`
  - `IFS=$'\n\t'`
  - pass/fail counters
  - exit 1 on any failure
  - must be shellcheck-clean with `shellcheck -x -e SC1091`
- `tests/run-all.sh` discovers runners by name. Do not register anything.

### Task 1: commands/enrich-batch.md and its doc test

**Files:**
- Create: `tests/run-enrich-batch-doc-tests.sh`
- Create: `commands/enrich-batch.md`

**Step 1 — failing test.** The test reads `commands/enrich-batch.md` and
asserts the following. Each bullet is one check. Use `grep -qi` where the
casing of the prose may vary.

1. The file exists and has frontmatter with `description:` and `argument-hint:`.
2. It sources `detect-forge.sh`, and it says non-GitHub forges are unsupported:
   it contains a `## Forgejo` or `## Other forges` heading, and either
   `not supported` or `GitHub-only`.
3. Selection:
   - sources `autopilot-candidates.sh` and calls `autopilot_candidates`
   - mentions `--milestone`
4. Grouping names the three groups. Each of these phrases appears:
   - `quick and clear`
   - `needs decisions`
   - `cause-finding`
5. Interview first:
   - a heading matching `Interview first`
   - mentions `AskUserQuestion`
   - mentions `[confirmed]`
   - mentions `recommend`
6. Dispatch:
   - mentions `isolation`
   - mentions `worktree`
   - contains `/enrich <n> --headless` or `--headless`
   - links `enrich.md#cost-rules`
   - says the batch states which model it picked: matches `which model`
7. Bugs: mentions `reproduc` and `needs-human`. It must **not** mandate
   Playwright alone; if `Playwright` appears, the same line also contains
   `e.g.`, `for example` or `such as`.
8. Interview after:
   - a heading matching `Interview after`
   - mentions `[med]`
   - mentions `amend`
   - mentions the spec, the plan and the issue body
9. Housekeeping:
   - mentions `enrichment-ongoing`, saying to release cut-off runs' locks
   - mentions `scratchpad`, saying to save cut-off drafts
   - says worktrees are removed only when clean **and** have no commits missing
     from main: matches `clean` and `missing from main` or `not on main`
   - mentions `landing order`
10. Scope boundary:
    - a heading matching `Scope boundary`
    - mentions `ai-implement` alongside `never`
11. It ends with the self-improvement sentence (the last non-empty line).

Run `bash tests/run-enrich-batch-doc-tests.sh` and expect FAIL (the file is missing).

**Step 2 — implement `commands/enrich-batch.md`.** Structure:

- **Frontmatter:**
  - `description: Interactive batch enrichment — group, interview, fan out /enrich --headless, interview again`
  - `argument-hint: [<issue>...] [--milestone <name>]`
- The `detect_forge` block, then `## GitHub`.
- **`### Step 1 — Select`:**
  - `source "$HOME/.claude/scripts/lib/autopilot-candidates.sh"`, then
    `autopilot_candidates "$(gh repo view --json nameWithOwner -q .nameWithOwner)" 100`.
  - With explicit numbers, intersect the candidates with them, and name any
    number that is not a candidate and why (read its labels).
  - With `--milestone`, intersect with
    `gh issue list --milestone "<name>" --state open --json number`.
- **`### Step 2 — Group`:** read each issue. Sort into three groups:
  - quick and clear
  - needs decisions
  - bugs that need cause-finding

  Pick each issue's model per [Cost rules](enrich.md#cost-rules) and show a
  table: issue, group, model, and why.
- **`### Step 3 — Interview first`:**
  - For the "needs decisions" group, ask the real design questions with
    `AskUserQuestion`: 2–4 options each, the recommended option first.
  - Record the answers per issue. The subagent prompt passes them on as
    `[confirmed]` assumptions for the spec.
- **`### Step 4 — Dispatch`:**
  - One `Agent` call per issue, with `isolation: "worktree"` and the chosen
    `model`. The prompt runs `/enrich <n> --headless` plus the confirmed
    answers.
  - At most 4 at once, per Cost rules.
  - Bugs: the prompt requires reproducing headless with the repo's own tooling
    (for example Playwright for a web UI) and pinning the cause with numbers
    before planning. If it cannot be reproduced, the run escalates to
    `needs-human` (headless mode's own path).
  - Graphics and design work goes to Fable, per Cost rules.
- **`### Step 5 — Interview after`:** relay each subagent's report. Ask the
  human about the riskiest `[med]` assumptions. When an answer changes
  something, amend the spec, the plan **and** the issue body. The issue body
  is what the pipeline reads.
- **`### Step 6 — Housekeeping`:**
  - Release the `enrichment-ongoing` lock of any run that was cut off (usage
    limit): `gh issue edit <n> --remove-label enrichment-ongoing`.
  - Before removing a cut-off run's worktree, save its draft spec and plan to
    the scratchpad, and resume from them.
  - Remove a finished worktree only when `git status --porcelain` is empty
    **and** `git log origin/main..HEAD` is empty, so no commits are missing
    from main.
  - Record the landing order between related plans in their specs.
- **`### Scope boundary`:** the enrich session never dispatches
  (`ai-implement`), never reviews and never merges code. Write the dispatch
  order and the dependencies down as notes for the implement session. Do not
  offer them as next steps.
- A `## Forgejo` section ("Not supported — `--headless` is GitHub-only (see
  enrich.md Headless mode)") and a `## Unknown host` section, matching the
  shape of the other commands.
- The closing self-improvement line.

Run the test and expect all PASS. Then run `bash tests/run-all.sh` and
shellcheck on the test file, both green.

**Step 3 — commit:**
`feat(enrich-batch): add the interactive batch enrichment command`, with
`Refs #453` in the footer.

### Task 2: List /enrich-batch in the command docs

**Files:**
- Modify: `tests/run-enrich-batch-doc-tests.sh` (append the assertions)
- Modify: `commands/README.md`: add it to the **GitHub-only** list, next to
  `/autopilot`, with a short note that it is the interactive counterpart.
- Modify: `docs/COMMAND-CHEATSHEET.md`: one sentence at the end of
  "### The unattended shortcut", pointing at `/enrich-batch` as the interactive,
  human-in-the-loop version.

**Step 1 — failing test.** Append two checks. `commands/README.md` contains
`/enrich-batch`. `docs/COMMAND-CHEATSHEET.md` contains `/enrich-batch`. Run
the test and expect those two to FAIL.

**Step 2 — edit both docs.** Run the test (all pass) and `tests/run-all.sh`
(green).

**Step 3 — commit:** `docs(commands): list /enrich-batch`, with `Closes #453`
in the footer.
