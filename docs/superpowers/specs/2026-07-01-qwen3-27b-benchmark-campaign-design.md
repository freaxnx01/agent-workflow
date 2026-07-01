# Design — qwen3.6-27b benchmarking campaign

**Issue:** [#114](https://github.com/freaxnx01/agent-pipeline/issues/114) ·
**Date:** 2026-07-01 · **Status:** Approved design

## Purpose

Decide, on defensible evidence, whether **`qwen3.6-27b`** (`qwen/qwen3.6-27b`, added
to the roster in #112) should be **promoted into the `gh:route` selection policy** or
stay a **selectable-only** roster entry. This resolves the two limitations Round 3
(`docs/model-comparison.md`) left open:

- **Single run per model** — variance was indistinguishable from signal.
- **One task shape** — only query endpoints (search, authors) were exercised.

## Execution model

This is a **human/assistant-run campaign, not an autonomous code task.**

- Issue #114 is a **campaign tracker**: it stays open and is **never labeled
  `ai-implement`**. Labeling it would hand a benchmarking campaign to a single coding
  agent, which cannot dispatch cross-repo paid runs or rank draft PRs by judgement.
- The agent-pipeline is exercised only on the **consumer repo** (`freaxnx01/quotes`),
  one benchmark issue per model per run. A human/assistant dispatches each round,
  scores the resulting draft PRs with the rubric below, and records the outcome.

## Run matrix (12 runs)

| Axis | Value |
|---|---|
| Shapes | **Bugfix** + **Small refactor** (both new shapes beyond Round 3) |
| Models | `qwen3-27b` vs `gpt-oss-120b`, both `agent:opencode` |
| Runs | **3 per model per shape**, identical spec within a shape |
| Total | 2 × 2 × 3 = **12 runs** |

`gemini-flash` and a UI shape are explicitly **out of scope** for this campaign (YAGNI —
add later only if the bugfix/refactor evidence is inconclusive).

## The two concrete tasks

Both target `WebApplication/Controllers/QuotesApiController.cs` on `freaxnx01/quotes`,
touch no unrelated code, and carry the Round-2 anti-blind-spot criteria (compiles
cleanly; do not delete/alter unrelated endpoints).

### Shape A — Bugfix: `GET /Api/random` off-by-one

Current code:

```csharp
var ids = _context.Quote.Select(q => q.ID).ToList();
int randomIndex = new Random().Next(0, ids.Count - 1);
return GetById(ids[randomIndex]);
```

Two defects:

1. **Off-by-one** — `Random.Next(min, max)` has an *exclusive* upper bound, so
   `ids.Count - 1` never selects the last (highest-`ID`) quote.
2. **Empty-table crash** — when `ids.Count == 0`, `Next(0, -1)` throws
   `ArgumentOutOfRangeException`.

**Acceptance criteria (identical spec to both models):**

- [ ] Every quote, **including the highest-`ID` one**, can be returned by `/Api/random`.
- [ ] An empty `Quote` table returns a graceful result (e.g. `404`/empty), never a `500`.
- [ ] `/Api/random` still returns a single quote in the existing response shape.
- [ ] No other endpoint (`GetAll`, `Search`, `GetById`) is altered; compiles cleanly.

**Oracle:** existing random behavior minus the two defects. Reproducible and unambiguous.

### Shape B — Refactor: extract the duplicated case-insensitive `Like` filter

In `Search`, the case-insensitive substring filter is built inline twice:

```csharp
var authorPattern = $"%{author.ToLower()}%";
query = query.Where(qt => EF.Functions.Like(qt.Author.ToLower(), authorPattern));
// ...
var textPattern = $"%{q.ToLower()}%";
query = query.Where(qt => EF.Functions.Like(qt.QuoteText.ToLower(), textPattern));
```

**Acceptance criteria (identical spec to both models):**

- [ ] The duplicated pattern is extracted into a single reusable helper (extension
      method or private method) used by both the `author` and `q` filters.
- [ ] `/Api/search` returns **identical** results and validation behavior before/after
      (behavior-preserving) — same EF-translatable SQL semantics (`EF.Functions.Like`).
- [ ] No endpoint is deleted or altered in observable behavior; compiles cleanly.

**Oracle:** existing `/Api/search` behavior.

## Scoring rubric

Score **each run** independently:

1. **Hard gates** (any failure → run scores **0** and is "not clean"):
   - Compiles cleanly (no missing `;`, no duplicate `using`s).
   - Existing endpoints/behavior intact (nothing unrelated deleted or broken).
2. **Points** — one per acceptance criterion met.
3. **Tiebreak** — idiom/quality: async correctness, EF-translatability, minimal diff,
   sensible naming/DTOs.

**Aggregate per model per shape:**

- **Pass-rate** — how many of the 3 runs are *clean* (through both gates + all AC), e.g.
  `3/3`. This is the primary variance signal.
- **Mean score** — average points across the 3 runs (tiebreak on quality).

## Decision gate

qwen3-27b costs **~15× more** than gpt-oss-120b ($0.15 vs $0.01 in Round 3;
Gemini-Flash-tier pricing). It must clearly earn the premium:

- **Promote** — offer qwen3-27b in `gh:route` as a **quality-leaning** endpoint option
  (*not* the default) **only if** it is **≥ gpt-oss-120b on pass-rate for both shapes**
  **and** wins **mean-quality on ≥1 shape**.
- **Otherwise** — keep it **selectable-only**; record the negative result so the question
  is settled. `gpt-oss-120b` remains the `gh:route` default unless it is clearly beaten.

## Recording

- Each shape → a new **Round N** appended to `docs/model-comparison.md` in the existing
  Round format (task, per-run table, pass-rate, findings), newest-first.
- Tick the #114 checklist as rounds land; post a short summary comment per shape.
- **On a promote verdict only:** edit `gh:route` Step 4b and the selection-policy table
  in `docs/model-comparison.md` to add qwen3-27b as the quality-leaning endpoint option.

## Guardrails

- **Stagger paired runs** — never trigger two runs concurrently (avoids race #100:
  concurrent runs can report `ai:done` yet open no PR). Trigger model A, wait for its
  PR, then model B.
- **Credentials** — the active `gh` account (`anim-bossinfo-ch`) is pull-only on
  `freaxnx01`; use the `freaxnx01` token via the allowed `.envrc` for all writes.
- **Safety envelope** — GitHub-hosted runners only; draft PRs only; close each benchmark
  PR + issue as an artifact after ranking (as done for Round 3: #37/#38, #40/#41).

## Out of scope (YAGNI)

- Automating the harness (a benchmark-runner script + machine-scorable rubric) — only if
  the manual campaign proves worth repeating often.
- `gemini-flash`, a UI-change shape, and non-.NET stacks.
