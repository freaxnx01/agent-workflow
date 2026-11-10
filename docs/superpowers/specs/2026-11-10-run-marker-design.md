# Machine-readable run marker in the run report — design (#585)

## Why

bridge is becoming an issue-centric dispatcher: an inbox of "needs you" cards per
issue, one row per run underneath (freaxnx01/bridge#368), and a retry model that
takes the pipeline as the single source of truth (freaxnx01/bridge#367). The run
report comment `post-run-report.sh` leaves on the issue is the natural run record —
it lives on the issue and survives the session — but it is human-readable only:

- `check-attempt-cap.sh` and `/ai-stats` parse the visible Markdown with regexes.
  D2 of `docs/superpowers/specs/2026-09-23-attempt-cap-nonstarts-design.md`
  deliberately kept it that way.
- Facts a consumer needs are not in the comment at all: the attempt number, the
  failure class as its own field, the retry decision, the PR number, and whether
  this run counts as an attempt.

## Goal

Append **one hidden HTML comment** — the run marker — to every run report the
GitHub pipeline posts, carrying those facts as JSON. Everything a human sees, and
every byte the existing regexes read, stays exactly as it is today.

## Non-goals

- Changing `check-attempt-cap.sh` or `/ai-stats` to read the marker. They keep
  parsing the visible report (D2 stands). Moving them is a later, separate choice.
- Fixing #532 (`Plan: none` on an enriched issue), #559 (context window / cost),
  #567 (a timed-out run posts no report). They are related; see *Related*.
- Any bridge change. bridge consumes the marker in #367 / #368.
- An Azure DevOps marker (see *Azure DevOps*).

## Anti-goals (would be a failure even if it "works")

- Any visible change to the report — a moved blank line counts.
- A marker a third party can forge into driving pipeline or bridge behaviour
  (ADR-019).
- A second attempt counter that can disagree with the one that parks issues.

## The marker

Last line of the rendered comment, after `[View workflow run](…)`, separated from
it by exactly one newline:

```text
[View workflow run](https://github.com/o/r/actions/runs/1)
<!-- ai-run: {"v":1,"attempt":2,"counts":true,"retry_attempt":1,"class":"task_failure","decision":"stop","status":"ai:failed","subtype":"error_max_turns","agent":"claude","model":"claude-sonnet-5","turns":40,"max_turns":40,"cost_usd":1.23,"duration_ms":123456,"pr":42,"run_url":"https://github.com/o/r/actions/runs/1","plan_coverage":"complete"} -->
```

The prefix is exactly `<!-- ai-run: ` and the suffix exactly ` -->`; the JSON in
between is a single compact object on one line.

### Fields

| Field | Type | Source (workflow step → env) | Present when |
|---|---|---|---|
| `v` | int | constant `1` | always |
| `attempt` | int | `steps.attempt_cap.outputs.attempt` → `ATTEMPT` | the cap step ran **and** `counts` is `true` |
| `counts` | bool | derived in the script (see below) | always |
| `retry_attempt` | int | `inputs.attempt` → `RETRY_ATTEMPT` | always on GitHub (input defaults to 1) |
| `class` | string | `steps.classify_failure.outputs.class` → `FAILURE_CLASS` (exists) | classifier ran |
| `decision` | `"retry"`\|`"stop"` | `steps.retry.outputs.decision` → `RETRY_DECISION` | `Plan retry` ran (not on success) |
| `status` | string | `$STATUS_LABEL` (`ai:done`/`ai:failed`/`ai:partial`) | non-empty; omitted for a pause |
| `subtype` | string | result JSON `.subtype` | always (`"unknown"` fallback as today) |
| `agent` | string | `AGENT` (exists) | set |
| `model` | string | `MODEL` (exists) | set |
| `turns` | int | result JSON `.num_turns` | always |
| `max_turns` | int | `MAX_TURNS` (exists) | set |
| `cost_usd` | number | result JSON `.total_cost_usd` | always |
| `duration_ms` | int | result JSON `.duration_ms` | always |
| `pr` | int | `steps.verify_pr.outputs.pr-number` → `PR_NUMBER` | non-empty |
| `run_url` | string | `WORKFLOW_RUN_URL` (exists) | always |
| `plan_coverage` | string | `PLAN_COVERAGE` (exists) | non-empty |

Rules:

- **Omitted, never faked.** A field whose source is empty is left out of the
  object. No `null`, no `0` stand-ins. (Issue text, kept.)
- **No free text.** No field carries `.result`, an error message, the issue title
  or anything else an issue author or the agent can write. Every string is an
  enum the pipeline produces (`class`, `decision`, `status`, `subtype`,
  `agent`, `plan_coverage`), a model id from triage, or the run URL.
  `has_plan` is deliberately **not** in v1 — it would inherit the #532 bug.
- **Numbers are numbers.** `attempt`, `retry_attempt`, `turns`, `max_turns`,
  `duration_ms`, `pr` are emitted with `--argjson` only when they match
  `^[0-9]+$`; otherwise omitted. `cost_usd` only when it matches a JSON number.

### `attempt` vs `retry_attempt` vs `counts` — one truth

There are two counters in the pipeline today, and they mean different things:

- `inputs.attempt` — position in the **automatic retry chain** started by one
  dispatch. `retry-dispatch.sh` passes `attempt+1` on re-dispatch; a fresh label
  dispatch starts at 1 again. It drives the retry-policy caps.
- `steps.attempt_cap.outputs.attempt` — the **lifetime attempt number** at the
  work, counted from prior `## ai-implement run` reports, excluding non-starts and
  pause reports. This is what parks the issue.

`attempt` in the marker is the **cap's number**, because that is the one with
consequences, and because #367 makes the pipeline the single truth for "how often
was this tried". The chain position goes in `retry_attempt` under its own name, so
nobody mistakes it for the lifetime count. *(Decided by the user, 2026-11-10.)*

`counts` says whether this run itself is counted as an attempt by
`check-attempt-cap.sh`'s rule, so consumers do not re-implement it:

- `false` for a pause report (heading `## ai-implement paused`),
- `false` for a non-start (`turns == 0` **and** `cost_usd == 0`, the cap's rule),
- `true` otherwise.

`attempt` is omitted when `counts` is `false`. The cap computes `attempt` before
the agent runs, so a non-start or a pause would otherwise carry the same number as
the next real run; omitting it means every attempt number appears on exactly one
marker. *(Decided by the user, 2026-11-10.)*

`attempt` is also omitted when the cap step did not run (stub runs,
`max-attempts: 0`, a pause gate). Consumers then fall back to counting reports.

### Where the retry decision comes from

The issue assumed the report step might run before `Plan retry`. It does not:
in `.github/workflows/agent-implement.yml` on main, `Plan retry` (`id: retry`,
`:1042`) runs before `Post run report` (`:1122`), and both are `if: always()`.
`steps.retry.outputs.decision` is therefore available to the report step as plain
env — no reordering and no follow-up edit of the comment.

`decision` is absent when `Plan retry` was skipped (class empty or `success`).

### Encoding (ADR-019 — run text is never state)

The marker is built with `jq -nc` from `--arg` / `--argjson` values, then every
`<` and `>` in the compact JSON is replaced with the JSON escapes `\u003c` / `\u003e`. Compact JSON
has no `<`/`>` outside string values, so the substitution is lossless, and the
result can never contain `-->` (which would close the HTML comment and expose
or inject content). `jq` alone escapes quotes and control characters but not
`<` / `>`.

### Trust rule for consumers (goes into DECISIONS.md; decided by the user, 2026-11-10)

A marker is only as trustworthy as the comment it sits in, and on a public repo
anyone can comment. Consumers MUST:

1. Read markers only from comments whose author is the pipeline's report
   identity. `Post run report` runs with `GH_TOKEN: ${{ github.token }}`, so that
   is `github-actions[bot]` on GitHub. (If the step ever switches to the App token,
   the author becomes the App bot and this rule must be updated with it.)
2. Take the marker from the **last** line of the comment only, and only one per
   comment.
3. Treat an unknown `v` as "no marker" and fall back to the visible report.
4. Use the marker to **display and to decide not to act**, and treat any action
   it would trigger (a re-dispatch) as bounded by the same caps as a manual one.

Known gap, inherited from ADR-019: the agent runs with a token that may be able
to post as `github-actions[bot]`, so the author filter holds against third
parties, not against the agent (#535).

Discovery, not fixed here: `check-attempt-cap.sh` counts any comment that starts
with `## ai-implement run`, regardless of author. A forged one can only *raise*
the count (park sooner), so it fails safe; recorded for a later look.

## Visible report stays byte-identical

Today's tests use `assert_contains` only, so they cannot prove "byte-identical".
The plan therefore first captures **golden files** from the unmodified script and
only then adds the marker:

- Golden renders (`RENDER_ONLY=1`, full stdout including the `LABELS:` trailer)
  for: success, failed (max-turns), partial (`PLAN_COVERAGE=partial`), paused
  (`FAILURE_CLASS=out_of_credits`), model_not_found (preflight variant), plus
  checks-blocked and salvaged so every block that touches the tail is covered.
- After the change, the test deletes the single marker line and asserts exact
  equality with the golden file (`diff`, not `assert_contains`).
- The marker sits inside `render_comment`, after the run link, before the
  `---` / `LABELS:` trailer `RENDER_ONLY` adds.

Note on what "visible" means on GitHub: the rendered comment is unchanged because
an HTML comment does not render. The raw body gains one trailing line. Every
existing parser matches by prefix (`startswith("## ai-implement run")`) or by
pattern within the body, so a trailing line is invisible to them as well.

## Azure DevOps

`implement-azdo.sh` does not use `post-run-report.sh`. It writes its own short
`## implement run (…, Azure DevOps)` comment only on success, exits before
reporting on failure (`azdo-report-failure.sh` posts one sentence from the
Azure Pipelines YAML), has no retry and no attempt cap. The discussion field is
HTML and Azure DevOps sanitizes stored HTML; whether an HTML comment survives is
unverified.

**v1 does not emit the marker on Azure DevOps**, and DECISIONS.md says so
explicitly, with the reasons above. A consumer reading an ADO work item finds no
marker and falls back to "no run record". Follow-up issue to be filed when a
consumer actually needs ADO runs. *(Decided by the user, 2026-11-10.)*

## Relation to D2 (attempt-cap-nonstarts)

D2 rejected "have `post-run-report.sh` emit a machine-readable marker" because it
would change the record `/ai-stats` parses and break the cap's promise to count
"exactly what the statistics count". This design keeps both: the visible record
is untouched, the cap and `/ai-stats` keep parsing it, and the marker is
additive. The amendment is recorded in two places:

- a new ADR in `docs/DECISIONS.md` (*Run marker*: schema, versioning, trust rule,
  ADO non-emission, relation to D2 and ADR-019);
- a one-line "Amended by ADR-0xx (#585)" note under D2 in the 2026-09-23 spec.

## Versioning

- Adding an optional field is **not** a version bump; consumers ignore unknown
  fields. (#559's context/cost fields land this way.)
- Renaming, removing, or changing the type or meaning of a field bumps `v`.
- Consumers treat an unknown `v` as "no marker".

## Consequences

- The report step already runs after `retry-dispatch.sh` has slept and dispatched
  the next run. With a 10 s transient delay the next run's cap check can read the
  comments before this report is posted and undercount by one. This is today's
  behaviour, not introduced here; the marker inherits it.
- `decision: "retry"` means the policy chose to retry. If the re-dispatch itself
  failed (`gh workflow run` 403), `Plan retry` exits 1 after writing its output,
  so the marker still says `retry`. The run's job log carries the error.
- A run that posts no report (#567, timeout) has no marker. Consumers must treat
  "no marker for this run" as normal.
- The raw comment body grows by ~400 bytes per run.

## Related

- #559 — extends the marker with context window / compaction / cost fields
  (additive, no `v` bump).
- #567 — a timeout posts no report, hence no marker.
- #532 — `Plan: none` bug; the reason `has_plan` is not in the marker.
- #535 — isolating the pipeline from the agent; the trust rule's known gap.
- Consumers: freaxnx01/bridge#367, freaxnx01/bridge#368.
