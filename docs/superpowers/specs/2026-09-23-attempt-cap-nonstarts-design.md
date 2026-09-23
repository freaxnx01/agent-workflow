# Stop counting runs that never started as attempts

**Issue:** [#393](https://github.com/freaxnx01/agent-workflow/issues/393)
**Date:** 2026-09-23
**Status:** Approved

## Problem

`check-attempt-cap.sh:75-76` counts every `## ai-implement run` comment as an
attempt:

```bash
prior_attempts="$(comments_json \
  | jq '[.[] | select(.body | startswith("## ai-implement run"))] | length')"
```

Not every such comment describes an attempt at the work. Observed on #302:

| Attempt | Agent | Turns | Cost | Evidence about the plan |
|---|---|---|---|---|
| 1 | opencode / glm-5.2 | **0** | **$0.00** | none — it never started |
| 2 | claude-opus-5 | 104 | $7.28 | ran out of budget without pushing |

Attempt 1 was an infrastructure failure. It executed no step of the plan and
spent nothing, yet consumed half the issue's lifetime dispatch budget. The
issue was then parked after a single real attempt, and unparking it re-parked
it immediately — the count does not change when the label does.

The cap's premise, stated in its own header, is measured: *"issues that took
more than one dispatch ship at roughly the same rate as those that shipped on
the first"*. That is a statement about **attempts at the work**. A run that
fails before the agent executes is not one, so counting it imports a conclusion
the data does not support.

### A second, quieter consequence

`classify-agent.sh` escalates to Claude from attempt 2 (ADR-001 stage 2). On
#302 attempt 1 was the opencode non-start, so the escalation was spent on a run
that never happened — the mechanism designed to rescue a struggling cheap model
was consumed by a run the cheap model never began.

## Decisions

| # | Decision | Rejected alternative |
|---|---|---|
| D1 | A non-start is `turns == 0` **and** `cost == 0` | Either alone. A run that burned turns but cost nothing, or vice versa, did something; the `&&` stops this quietly excusing genuine failures |
| D2 | Parse both fields from the report body, reusing `ai-stats.sh:190-191`'s regexes | Having `post-run-report.sh` emit a machine-readable marker. Cleaner in the abstract, but it changes the record `/ai-stats` already parses, and the cap's header promises it "counts exactly what the statistics count" |
| D3 | Non-starts get their own higher ceiling (`MAX_NON_STARTS`, default 5) | Not bounding them at all — a broken secret would produce `$0.00` runs forever and never park. A single total-dispatch backstop was also rejected: it cannot tell "the plan keeps failing" from "the runner is broken", which is the distinction this issue exists to draw |
| D4 | The two ceilings produce **different park messages** | One shared message. Today's text says the issue "usually needs re-enrichment", which was actively wrong for #302 — the plan was fine and the agent selection was not |

## Design

### Counting

`prior_attempts` splits into two counts over the same comment set:

```
attempts   = reports where turns > 0 OR cost > 0
non_starts = reports where turns == 0 AND cost == 0
```

Extraction uses the same regexes as `scripts/lib/ai-stats.sh:190-191`:

```
Turns:\*\* (?<t>[0-9]+)
Cost:\*\* \$(?<c>[0-9.]+)
```

**but deliberately not its `// 0` fallbacks.** `ai-stats` defaults a missing
field to 0 because it is aggregating; here that same default would make a
malformed or reformatted report parse as `turns=0, cost=0` — a non-start — and
fail open in the expensive direction.

So the predicate is positive, not defaulted: a report is a non-start only when
**both captures succeed and both yield 0**. A report missing either field, or
whose heading format has drifted, counts as a real attempt.

```jq
def nonstart:
  (.body | capture("Turns:\\*\\* (?<t>[0-9]+)") | .t | tonumber) as $t
  | (.body | capture("Cost:\\*\\* \\$(?<c>[0-9.]+)") | .c | tonumber) as $c
  | ($t == 0 and $c == 0);
```

`capture` returns no output when the pattern does not match, so such a report
falls through to the real-attempt count rather than being excused — which is
the failing-closed behaviour the acceptance criteria pin.

### Two ceilings

| Condition | Env var | Default | Park reason |
|---|---|---|---|
| `attempts >= MAX_ATTEMPTS` | `MAX_ATTEMPTS` | 2 | unchanged wording |
| `non_starts >= MAX_NON_STARTS` | `MAX_NON_STARTS` | 5 | names it as infrastructure |

Both are env-overridable, matching the existing `MAX_ATTEMPTS` seam. The
attempts ceiling is evaluated first: an issue that has hit both is more
usefully described as failing at the work than as failing to start.

### Park messages

The existing message is unchanged for the attempts ceiling.

The non-start ceiling gets its own, because the remedy is different. It states
that N dispatches ended with zero turns and zero cost, that this indicates the
run never reached the agent, and points at the causes in the order they occur
in practice: a missing or invalid credential for the selected agent, an agent
override (`agent:opencode`) whose provider key is absent, or a runner toolchain
failure. It explicitly does **not** suggest re-enrichment — the plan was never
read.

### Outputs

`attempt=<N>` continues to mean the attempt number **at the work**, now counting
only real attempts. This is what fixes the escalation bug above: on an issue
whose first dispatch was a non-start, the next real run is attempt 1, not 2, and
`classify-agent.sh`'s escalate-on-retry is still available when it is needed.

A new `non-starts=<N>` output is emitted for the run report and for debugging.
`max-attempts=<N>` is unchanged; `max-non-starts=<N>` is added alongside it.

## Testing

The script already takes `ISSUE_COMMENTS_JSON`, so every case is a fixture —
no network, no GitHub.

| Case | Asserts |
|---|---|
| 2 real reports | parks; attempts wording |
| 1 real + 3 non-starts | proceeds; `attempt=2` |
| 5 non-starts, 0 real | parks; infrastructure wording; not the re-enrichment text |
| `turns=5, cost=$0.00` | counts as real — one half-zero is not a non-start |
| `turns=0, cost=$1.20` | counts as real |
| report with no parseable Turns/Cost | counts as real (fails closed) |
| mixed set | `attempt=` and `non-starts=` both correct |
| `DRY_RUN=1` at either ceiling | decides and reports, writes nothing |

**Regression guard:** the existing `check-attempt-cap` cases must pass
unmodified. The only behaviour that may change is which comments count, so any
existing case built from reports with real turns and cost must be unaffected.

## Acceptance criteria

- [ ] A `## ai-implement run` report with `turns == 0` and `cost == 0` does not
      count toward `MAX_ATTEMPTS`
- [ ] A report with only one of the two at zero **does** count
- [ ] A report whose Turns/Cost cannot be parsed **does** count
- [ ] `non_starts >= MAX_NON_STARTS` (default 5) parks the issue
- [ ] The two ceilings produce different park comments, and the non-start one
      does not suggest re-enrichment
- [ ] `attempt=` counts only real attempts; `non-starts=` and
      `max-non-starts=` are emitted
- [ ] Existing `check-attempt-cap` tests pass unmodified
- [ ] `shellcheck -x` clean; full Layer-1 suite green in <5s

## Out of scope

- **Finding 2 of #393** — a run reporting `ai:done` while silently skipping
  planned steps. Root cause unknown; turn budget and token permissions are ruled
  out. Needs an investigation of the `claude-raw-output` artifacts before it can
  be planned.
- **Finding 3 of #393** — corrected on the issue as not-a-bug: `worktree_dirty`
  uses `git status --porcelain`, which reports untracked files, and salvage runs
  `git add -A`. Never-committed work is already rescued.
- **Finding 4 of #393** — re-dispatch restarting rather than resuming. The
  resume instruction was a comment, so #398 should have fixed it; untested.
- Changing what `post-run-report.sh` writes (D2).
