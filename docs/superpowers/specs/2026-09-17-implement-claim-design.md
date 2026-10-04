# Implement claim: stop a session and the pipeline implementing the same issue

**Issue:** [#366](https://github.com/freaxnx01/agent-workflow/issues/366)
**Date:** 2026-09-17
**Status:** approved

## Problem

`agent-implement.yml:378` already serialises **pipeline against pipeline**:

```yaml
concurrency:
  group: claude-implement-${{ github.repository }}-${{ inputs.issue-number }}
  cancel-in-progress: true
```

That key is invisible outside GitHub Actions. Nothing stops a local session — a
person, or a Claude Code session running `/work` — from implementing an issue while
a pipeline run is live, or from dispatching while someone is mid-implementation.

Observed on `freaxnx01/flowhub#93`: a session recovered the agent's work from a closed
PR's `refs/pull/99/head`, fixed it, ran the suite green and opened a PR; concurrently
the attempt cap was raised and the issue redispatched. A run started ~80 seconds after
that merge and began a second, competing implementation. Both reactions were
legitimate. Neither party could see the other. Cost: a wasted run (~$2), two PRs
closing one issue, manual reconciliation.

The `/enrich` lock does not cover this. It is implemented **client-side**, in
`~/.claude/commands/enrich.md`; agent-workflow contributes only the label definition.
An implement claim has to be taken by the pipeline itself, because the pipeline is one
of the two colliding parties.

## Design decisions

Four forks were open on the issue. All four are settled here.

### 1. The claim is a label **plus** a comment

```text
labels: ai-implement, ai-implementing

comment:
  🔒 Implement claim by run 34263247853
  https://github.com/freaxnx01/agent-workflow/actions/runs/34263247853
  claimed 2026-09-17T09:12:03Z
```

The label is the boolean: greppable from an issue list, one API call to test, and it
mirrors the enrich lock so there is one mental model for both. The comment carries the
**run reference**, which is what staleness is actually judged from — a label alone
cannot hold it, and that would force staleness back onto the time heuristic this issue
exists to improve on.

### 2. A local session that finds a live claim **refuses**, and names the holder

Hard stop, printing the holding run's URL and its live state. This matches how
`/gh:implement` already hard-stops on `needs-enrichment`, and it never destroys
someone else's in-flight work. Not a warn-and-continue: that is precisely the
flowhub#93 behaviour and would not have prevented it.

Cancelling the holder stays a deliberate, manual act (`gh run cancel <id>`) — the
refusal message may name the command, but the tooling does not run it, because
cancelling a mid-implementation run discards its uncommitted work.

### 3. The claim is released at run end, in an `always()` step

Released on success, failure and cancellation.

**This is a deliberate trade, and it leaves a gap — see Residual gap below.**

### 4. An unresolvable run reference means **stale — take over**

If `gh run view <id>` cannot resolve the run (deleted, expired, API error), the claim
is dead: an unresolvable run cannot be in progress. Failing open guarantees the AC
"a crashed run does not block the issue indefinitely" without a time heuristic. The
cost is a possible false takeover during a GitHub API outage, which is strictly better
than a wedged issue.

Staleness is therefore answered by **asking GitHub about the run**, never by elapsed
time. An implement run is ~10–15 minutes, so a time rule would have to be either
uselessly long or prone to false takeovers.

## Why the release step is the risky part

`cancel-in-progress: true` means a second dispatch **cancels** the first. So the
common path to a released claim is a cancellation, not a clean exit. GitHub runs
`always()` steps during the cancellation grace period, but a hard timeout can still
kill the job before the release lands.

The design does not try to make the release bulletproof. It makes the *stale* path
cheap instead: a claim whose run is no longer in progress is takeable by anyone, with
no waiting. The release step is an optimisation that keeps the common case tidy; the
run-state check is what makes the system correct.

## Residual gap (accepted, not solved here)

Releasing at run end does **not** fully close the flowhub#93 scenario.

The claim protects a local session that checks *after* a run has started. It does not
protect a local session that started *first*, while no claim was held — the pipeline
then claims, and that session never re-checks. The claim is one-directional: the
pipeline claims and local tooling reads.

Making it symmetric — local sessions taking the same claim — needs a claim identity
that is not a run id, and staleness for it would fall back to the time heuristic
decision 4 rejects. That is a separate design.

Likewise, a PR left in `ai:review-blocked` is unclaimed once its run ends, so it is
open for anyone to pick up. That was the state flowhub#93's collision happened in.

**Both are follow-ups, filed separately. This change closes the dispatch-side half.**

## Acceptance criteria

- [ ] The implement job claims the issue before the agent runs, recording the run id and URL
- [ ] The claim is released on success, failure and cancellation
- [ ] A dispatch that finds a live claim is refused, and the refusal names the holding run and its URL
- [ ] A local session can detect the claim from the issue alone, with no Actions access
- [ ] Staleness is decided by the referenced run's actual state, never by elapsed time
- [ ] An unresolvable run reference is treated as stale and taken over
- [ ] A crashed run does not block the issue indefinitely
- [ ] Acquire re-checks after claiming and stands down if it lost a race
- [ ] `ai-implementing` is created by `ensure-issue-labels.sh` — `gh issue edit --add-label` fails outright on a label that does not exist
- [ ] Claim logic lives in `scripts/`, not inline in YAML, with fixture tests covering every branch

## Consequences

- One extra label on the repo, and a comment per implement run. The comments
  accumulate on a much-redispatched issue; they are the audit trail of who ran when,
  which is the same reason the enrich lock keeps its comments.
- The implement job gains two steps and two `gh` round-trips before the agent starts.
- During a GitHub API outage a live claim may be misread as stale, allowing a double
  implementation — the same outage would also break dispatch, so the window is narrow.
