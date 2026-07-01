# qwen3.6-27b Benchmarking Campaign — Implementation Plan

> **For agentic workers:** This is a **human/assistant-run operational runbook**, not an
> autonomous code task. Do **not** label issue #114 `ai-implement`. Steps use checkbox
> (`- [ ]`) syntax for tracking. Each "run" dispatches the agent-pipeline on the consumer
> repo `freaxnx01/quotes`; the work here is dispatching, scoring, recording, and deciding.

**Goal:** Gather defensible evidence on `qwen3.6-27b` vs `gpt-oss-120b` across two new task
shapes (bugfix + small refactor), then apply a promote/selectable-only decision to the
`gh:route` policy.

**Architecture:** 12 draft-PR runs on `freaxnx01/quotes` (2 shapes × 2 models × 3 runs),
staggered to avoid the concurrent-run race (#100). Each run is scored with objective gates +
an AC checklist; the 3-run sets aggregate to a pass-rate + mean score per model per shape.
Results append to `docs/model-comparison.md` as Rounds 4 (bugfix) and 5 (refactor).

**Tech Stack:** `gh` CLI + GitHub Actions (the pipeline), `.NET` consumer repo, bash.

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-07-01-qwen3-27b-benchmark-campaign-design.md` — read it first.
- **Consumer repo:** `freaxnx01/quotes`. **Target file:** `WebApplication/Controllers/QuotesApiController.cs`.
- **Credentials:** active `gh` account (`anim-bossinfo-ch`) is **pull-only** on `freaxnx01`.
  Prefix every write with `direnv exec /home/admin/repos/github/freaxnx01 bash -c '...'` and
  use `GH_TOKEN="${GH_TOKEN}"` inside (the `.envrc` carries the `freaxnx01` token).
- **Models/labels:** qwen3-27b → `agent:opencode` + `model:qwen3-27b`; gpt-oss-120b →
  `agent:opencode` + `model:gpt-oss-120b`. Both labels already exist on `quotes`.
- **Pin precondition:** `quotes` `.github/workflows/claude.yml` must pin an agent-pipeline SHA
  containing `model:qwen3-27b` (bumped in quotes#39 → SHA `38875ee`).
- **Guardrails:** stagger runs (never two concurrent); GitHub-hosted runners only; draft PRs
  only; close each benchmark issue + PR as an artifact after scoring.
- **Trigger semantics:** the run fires when `ai-implement` is **added**; the `agent:*` +
  `model:*` labels must already be on the issue at that moment. Create issues with the model
  labels first, add `ai-implement` last.

---

### Task 0: Verify preconditions

**Files:** none (read-only checks).

- [ ] **Step 1: Confirm labels + pin are in place**

```bash
direnv exec /home/admin/repos/github/freaxnx01 bash -c '
GH_TOKEN="${GH_TOKEN}" gh api repos/freaxnx01/quotes/labels/model:qwen3-27b --jq .name
GH_TOKEN="${GH_TOKEN}" gh api repos/freaxnx01/quotes/contents/.github/workflows/claude.yml --jq .content | base64 -d | grep -c 38875eee'
```

Expected: prints `model:qwen3-27b` then `2`.

- [ ] **Step 2: Confirm the two defects still exist on master** (specs stay honest)

```bash
direnv exec /home/admin/repos/github/freaxnx01 bash -c '
GH_TOKEN="${GH_TOKEN}" gh api "repos/freaxnx01/quotes/contents/WebApplication/Controllers/QuotesApiController.cs?ref=master" --jq .content | base64 -d' \
  | grep -nE 'Next\(0, ids.Count - 1\)|authorPattern|textPattern'
```

Expected: the off-by-one `Next(0, ids.Count - 1)` line and the two `*Pattern` lines are present.
If they are gone (someone fixed them), pick a replacement target of the same shape and note it
in the round write-up before proceeding.

---

### Task 1: Author the two benchmark spec bodies

**Files:**
- Create: `scratchpad/bench-bugfix.md` (Shape A spec body)
- Create: `scratchpad/bench-refactor.md` (Shape B spec body)

These are the **identical** issue bodies handed to both models within a shape. Copy the AC
verbatim from the design spec.

- [ ] **Step 1: Write the Shape A (bugfix) body**

````markdown
**Model-comparison benchmark round** (agent-pipeline `docs/model-comparison.md`).
Identical spec handed to two OpenCode/OpenRouter models; only the `model:*` label differs.

## Bug

`GET /Api/random` (`WebApplication/Controllers/QuotesApiController.cs`) has two defects:

1. `new Random().Next(0, ids.Count - 1)` — `Random.Next(min, max)` has an **exclusive**
   upper bound, so the last (highest-`ID`) quote is never returned.
2. When the `Quote` table is empty, `Next(0, -1)` throws `ArgumentOutOfRangeException`.

## Acceptance criteria

- [ ] Every quote, including the highest-`ID` one, can be returned by `/Api/random`.
- [ ] An empty `Quote` table returns a graceful result (e.g. `404`/empty), never a `500`.
- [ ] `/Api/random` still returns a single quote in the existing response shape.
- [ ] No other endpoint (`GetAll`, `Search`, `GetById`) is altered; compiles cleanly
      (no duplicate `using`s, no unused code).
````

- [ ] **Step 2: Write the Shape B (refactor) body**

````markdown
**Model-comparison benchmark round** (agent-pipeline `docs/model-comparison.md`).
Identical spec handed to two OpenCode/OpenRouter models; only the `model:*` label differs.

## Refactor

In `Search` (`WebApplication/Controllers/QuotesApiController.cs`) the case-insensitive
substring filter is built inline twice (for `author` and for `q`):

```csharp
var authorPattern = $"%{author.ToLower()}%";
query = query.Where(qt => EF.Functions.Like(qt.Author.ToLower(), authorPattern));
// ...
var textPattern = $"%{q.ToLower()}%";
query = query.Where(qt => EF.Functions.Like(qt.QuoteText.ToLower(), textPattern));
```

Extract this into a single reusable helper. Behavior-preserving.

## Acceptance criteria

- [ ] The duplicated pattern is extracted into one reusable helper (extension method or
      private method) used by both the `author` and `q` filters.
- [ ] `/Api/search` returns identical results and validation behavior before/after —
      same EF-translatable semantics (`EF.Functions.Like`, still translates to SQL).
- [ ] No endpoint is deleted or altered in observable behavior; compiles cleanly.
````

- [ ] **Step 3: Commit the spec bodies is NOT needed** — these are scratchpad inputs, not repo artifacts. Keep them under `scratchpad/` (gitignored / not committed).

---

### Task 2: Reusable single-run procedure

**Files:** none (this task documents the procedure Tasks 3 & 5 invoke 6× each).

For ONE run of `<MODEL_LABEL>` (`model:qwen3-27b` or `model:gpt-oss-120b`) on `<BODY_FILE>`:

- [ ] **Step 1: Create the issue with model labels (no trigger yet)**

```bash
direnv exec /home/admin/repos/github/freaxnx01 bash -c '
cd /home/admin/repos/github/freaxnx01
cp <BODY_FILE> body.tmp.md
N=$(GH_TOKEN="${GH_TOKEN}" gh issue create --repo freaxnx01/quotes \
  --title "bench: <SHAPE> [<MODEL_SHORT> run <K>]" --body-file body.tmp.md \
  --label agent:opencode --label <MODEL_LABEL>)
echo "ISSUE=$N"; rm -f body.tmp.md'
```

Expected: prints an issue URL. Record the number as `ISSUE_N`.

- [ ] **Step 2: Trigger it (add `ai-implement` last)**

```bash
direnv exec /home/admin/repos/github/freaxnx01 bash -c '
GH_TOKEN="${GH_TOKEN}" gh issue edit <ISSUE_N> --repo freaxnx01/quotes --add-label ai-implement'
```

- [ ] **Step 3: Poll the run to completion (blocks until done)**

```bash
direnv exec /home/admin/repos/github/freaxnx01 bash -c '
RID=$(GH_TOKEN="${GH_TOKEN}" gh run list --repo freaxnx01/quotes --workflow claude.yml \
  --limit 1 --json databaseId --jq ".[0].databaseId")
for i in $(seq 1 40); do
  s=$(GH_TOKEN="${GH_TOKEN}" gh run view "$RID" --repo freaxnx01/quotes --json status --jq .status)
  echo "poll $i: $s"; [ "$s" = "completed" ] && break; sleep 30
done'
```

Expected: ends with `completed`. **Do not start the next run until this prints `completed`**
(guardrail: no concurrent runs).

- [ ] **Step 4: Capture outcome (model, PR, cost)**

```bash
direnv exec /home/admin/repos/github/freaxnx01 bash -c '
GH_TOKEN="${GH_TOKEN}" gh issue view <ISSUE_N> --repo freaxnx01/quotes --json labels \
  --jq "[.labels[].name]|join(\" \")"
GH_TOKEN="${GH_TOKEN}" gh issue view <ISSUE_N> --repo freaxnx01/quotes --comments \
  --json comments --jq ".comments[-1].body" | grep -E "Outcome|Model|Cost|Turns"'
```

Expected: `ai:done` label and a run report showing **Model: <the intended slug>** (if it shows
`claude-*`, the label didn't resolve — stop and re-check the pin). Note the PR number the run
opened (`gh pr list --repo freaxnx01/quotes --state open`).

---

### Task 3: Shape A (bugfix) — dispatch 6 runs

**Files:** uses `scratchpad/bench-bugfix.md`.

- [ ] **Step 1: Run qwen3-27b ×3, staggered.** For `K` in 1,2,3: execute Task 2 with
  `<MODEL_LABEL>=model:qwen3-27b`, `<MODEL_SHORT>=qwen3-27b`, `<SHAPE>=bugfix`,
  `<BODY_FILE>=scratchpad/bench-bugfix.md`. Wait for `completed` between each.

- [ ] **Step 2: Run gpt-oss-120b ×3, staggered.** Same as Step 1 with
  `<MODEL_LABEL>=model:gpt-oss-120b`, `<MODEL_SHORT>=gpt-oss-120b`.

- [ ] **Step 3: Record the 6 (issue, PR, cost) tuples** in a scratch table for scoring.

Expected: 6 draft PRs open on `quotes`, 3 per model.

---

### Task 4: Shape A — score, aggregate, record Round 4

**Files:**
- Modify: `docs/model-comparison.md` (append `## Round 4`)

- [ ] **Step 1: Fetch each PR diff and the post-fix file**

```bash
direnv exec /home/admin/repos/github/freaxnx01 bash -c '
GH_TOKEN="${GH_TOKEN}" gh pr diff <PR> --repo freaxnx01/quotes'
```

- [ ] **Step 2: Score each run against the rubric.** For each of the 6 PRs, record:
  - **Gate 1 — compiles:** no missing `;`, no duplicate `using`s, method well-formed. (fail → 0)
  - **Gate 2 — endpoints intact:** `GetAll`/`Search`/`GetById` untouched; no route deleted. (fail → 0)
  - **AC points (0–4):** last quote reachable; empty-table graceful; single-quote shape kept; compiles/clean.
  - **Tiebreak:** idiom (e.g. shared `Random`, guard clause vs exception, minimal diff).

- [ ] **Step 3: Aggregate per model** — pass-rate = (# of the 3 runs clean through both gates
  + all 4 AC) and mean score (mean AC points across 3 runs).

- [ ] **Step 4: Append `## Round 4 — .NET bugfix (GET /Api/random off-by-one)`** to
  `docs/model-comparison.md`, newest-first (above Round 3), in the existing Round format:
  date, provenance (issue/PR numbers), a per-run table (Model · slug · run · clean? · AC · cost),
  the pass-rate + mean summary, and 2–3 findings. Long table rows are fine (`MD013` disabled).

- [ ] **Step 5: Close the 6 benchmark issues + PRs as artifacts**

```bash
direnv exec /home/admin/repos/github/freaxnx01 bash -c '
for n in <ISSUE_LIST>; do GH_TOKEN="${GH_TOKEN}" gh issue close $n --repo freaxnx01/quotes --comment "Round 4 benchmark artifact — recorded in agent-pipeline docs/model-comparison.md."; done
for p in <PR_LIST>;   do GH_TOKEN="${GH_TOKEN}" gh pr close   $p --repo freaxnx01/quotes --comment "Round 4 benchmark artifact."; done'
```

- [ ] **Step 6: Commit Round 4** on branch `docs/model-comparison-round4`, push, open PR to
  `agent-pipeline` main (use `--body-file` to avoid heredoc-quoting issues with backticks/apostrophes).

- [ ] **Step 7: Tick the "bugfix shape" box on issue #114.**

---

### Task 5: Shape B (refactor) — dispatch 6 runs

**Files:** uses `scratchpad/bench-refactor.md`.

- [ ] **Step 1: Run qwen3-27b ×3, staggered** (Task 2, `<SHAPE>=refactor`, refactor body).
- [ ] **Step 2: Run gpt-oss-120b ×3, staggered.**
- [ ] **Step 3: Record the 6 (issue, PR, cost) tuples.**

Expected: 6 more draft PRs, 3 per model.

---

### Task 6: Shape B — score, aggregate, record Round 5

**Files:**
- Modify: `docs/model-comparison.md` (append `## Round 5`)

- [ ] **Step 1: Fetch each PR diff** (as Task 4 Step 1).
- [ ] **Step 2: Score each run.** Gates as before; **AC points (0–3):** duplication extracted
  into one helper used by both filters; `/Api/search` behavior identical (behavior-preserving,
  still EF-translatable); no endpoint altered + compiles. Tiebreak: helper design (extension vs
  private method, naming, minimal diff). **Behavior-preserving check:** confirm the helper still
  emits `EF.Functions.Like` (not client-side `.Contains`) so the query stays translatable.
- [ ] **Step 3: Aggregate per model** — pass-rate + mean score.
- [ ] **Step 4: Append `## Round 5 — .NET refactor (extract Search Like-filter)`** to
  `docs/model-comparison.md`, same format.
- [ ] **Step 5: Close the 6 issues + PRs as artifacts** (as Task 4 Step 5).
- [ ] **Step 6: Commit Round 5**, push, open PR to agent-pipeline main.
- [ ] **Step 7: Tick the "refactor shape" box on issue #114.**

---

### Task 7: Decision gate + close-out

**Files:**
- Modify (only on a **promote** verdict): `docs/model-comparison.md` (selection-policy table),
  `~/.claude/commands/gh/route.md` **and** its source
  `~/repos/github/freaxnx01/public/config/claude/commands/gh/route.md` (Step 4b table).

- [ ] **Step 1: Apply the decision rule** from the spec. Promote **iff** qwen3-27b is
  **≥ gpt-oss-120b on pass-rate for both shapes AND wins mean-quality on ≥1 shape**. Otherwise
  keep selectable-only.

- [ ] **Step 2a (promote):** add qwen3-27b as a **quality-leaning endpoint option** (not the
  default) to the `gh:route` Step 4b table and the `model-comparison.md` selection-policy table.
  Note the ~15× cost premium in the "Why" column. Commit both the command source and the doc;
  re-link the user command if needed. Open a PR.

- [ ] **Step 2b (do not promote):** add a one-line note to the `model-comparison.md` selection
  policy that qwen3-27b was benchmarked across bugfix + refactor and stays selectable-only
  (with the round numbers), so the question is settled. Commit + PR.

- [ ] **Step 3: Close issue #114** with a summary comment linking Rounds 4 & 5 and stating the
  verdict.

---

## Self-review

- **Spec coverage:** execution model (runbook, no `ai-implement`) → Tasks 0–7 + header;
  run matrix 2×2×3 → Tasks 3 & 5; the two named tasks → Task 1 bodies; scoring rubric →
  Tasks 4/6 Step 2–3; decision gate → Task 7; recording → Tasks 4/6 Step 4 + Task 7;
  guardrails (stagger, token, draft-only) → Global Constraints + Task 2 Step 3. All covered.
- **Placeholder scan:** `<MODEL_LABEL>`/`<PR>`/`<ISSUE_LIST>` etc. are **intentional
  per-run substitutions**, not gaps — each is defined in Global Constraints / Task 2. No TBDs.
- **Consistency:** label→slug (`model:qwen3-27b`, `model:gpt-oss-120b`), pin SHA `38875ee`,
  and the AC counts (bugfix 4, refactor 3) match the spec throughout.
