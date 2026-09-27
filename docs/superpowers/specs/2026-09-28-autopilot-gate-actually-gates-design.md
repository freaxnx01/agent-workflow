# Make the autopilot's test gate verify that the gate gates

**Issue:** [#381](https://github.com/freaxnx01/agent-workflow/issues/381)
**Satisfies:** [#263](https://github.com/freaxnx01/agent-workflow/issues/263) — no auto-merge on an unrun gate
**Date:** 2026-09-28
**Status:** Approved

## Problem

`repo_eligible` in `scripts/lib/autopilot-eligible.sh` checks that the named
gate workflow **exists and has at least one completed run on the default
branch**. That is not the same as the workflow gating anything.

Observed on `freaxnx01/agent-action-sandbox`, which passed the check while:

- the gate file's own header read *"Manual only. … Not part of the agent
  pipeline"*,
- its sole trigger was `workflow_dispatch`,
- and `main` had no branch protection at all.

The lane would have auto-merged behind a workflow explicitly declared not to be
a gate, in a repo where nothing blocked a merge. The condition is satisfiable by
any workflow that has ever been dispatched once.

This is the last condition between the lane and merging unreviewed code. For a
flow whose premise is that a machine merges without a human, *"some workflow ran
once"* is weaker than the criterion intends.

### The #364 constraint is lifted

The enrichment-input comment on #381 warned that landing a
required-status-checks condition while #364 was open would make a repo
"eligible for AI-merge and still never merge an AI-written PR — correct and
inert."

**#364 and #430 are both closed and the fix is live on `main`** (one tokened
consumer checkout; three jobs minting). Verified empirically: an App-authored PR
ran 68 checks without manual approval on 2026-09-27. The condition can now be
satisfied by an agent-opened PR, so it may land as written.

## Decisions

| # | Decision | Rejected alternative |
|---|---|---|
| D1 | Require protection with ≥1 required status check, **and** that the gate has actually run on a pull request | Requiring the gate to *be* one of the required contexts. `contexts` holds job/check names while the gate is a filename — see *Known gap* |
| D2 | Establish the trigger by querying `runs?event=pull_request`, not by reading the workflow file | Grepping the raw YAML for a `pull_request` trigger (fragile: must dodge `pull_request_target`, comments, nested keys, inside the check guarding auto-merge); or `python3` + PyYAML, which is **not** in `docs/RUNNER-REQUIREMENTS.md`'s toolchain and would add an undeclared runtime dependency to a safety check |
| D3 | A non-404 API failure **refuses**; only a 404 signature means "no protection" | Treating any failure as absence. That is the conflation the `agent.yml` check in this same file already exists to avoid |
| D4 | Fix check 2's identical conflation while here | Leaving it. Shipping two checks that distinguish outage from absence beside one that does not invites the next reader to copy the wrong one |

## Design

### The condition becomes four checks

`repo_eligible` keeps its shape and signature. Order is cheapest-and-most-likely-to-fail first.

| # | Check | Refusal reason |
|---|---|---|
| 1 | `agent.yml` sets `ai-review-ai-merge: true` | unchanged |
| 2 | gate has a completed run on the default branch | unchanged wording, error handling fixed (D4) |
| 3 | **gate has a completed run with `event=pull_request`** | `test gate <g> has never run on a pull request` |
| 4 | **default branch has protection with ≥1 required status check** | `<branch> has no required status checks` |

Check 3 is evidence rather than inference. A `workflow_dispatch`-only workflow
has zero such runs, which is exactly the `dind-smoke.yml` case that slipped
through. It proves the gate *gated a pull request*, not merely that a trigger is
declared.

**Check 3 must not carry a `branch=` filter.** Check 2 filters on the default
branch because it asks "has this gate ever completed there". Check 3 asks a
different question, and pull-request runs happen on *feature* branches — adding
`branch=<default>` would return zero for every repo and refuse all of them. The
two queries differ by more than one parameter:

```
check 2:  runs?branch=<default>&status=completed&per_page=1
check 3:  runs?event=pull_request&status=completed&per_page=1
```

**A consequence worth stating:** a correctly-configured gate that has never yet
seen a pull request is refused. That is deliberate and consistent with check 2's
existing philosophy — the lane requires demonstrated behaviour, not declared
intent. The refusal reason says so plainly, so an operator reading it knows to
open one PR rather than to go hunting for a misconfiguration.

### Error handling: 404 is not the only way to fail

`branches/<branch>/protection` returns 404 **both** when the branch is
unprotected and when the token lacks scope to read protection. The file already
solves this shape for `agent.yml`: capture stderr, grep the 404 signature, and
treat anything else as a failure.

```
404 signature      → "no branch protection on <branch>"        refuse
any other failure  → "eligibility check failed (protection)"   refuse
```

Both refuse. The distinction is not whether the lane proceeds — it never does —
but what the operator reads at 3am. Reporting an outage as "no protection" sends
them to configure something that is already configured.

**Check 2 gets the same treatment (D4).** Today its `runs=` extraction uses
`2>/dev/null` and reports an empty result as `test gate <g> not found`, so a
`gh` outage is indistinguishable from a missing workflow — the very conflation
the `agent.yml` check was written to avoid, sitting three lines below it.

### An open question that is already answered

#381 asks whether requiring protection excludes legitimate repos, and suggests
scoping the requirement to the `ai-review-ai-merge` flow.

**It is already scoped.** `repo_eligible` reaches check 2 only after check 1
confirms `ai-review-ai-merge: true`; a human-merge repo never runs this code.
Recorded here so the question is not reopened during implementation.

### Known gap — deliberately not closed

The spec does **not** verify that the named gate is among the required status
check contexts.

`required_status_checks.contexts` holds job/check names, not workflow filenames.
On this repository it reads `["gate-selftest","test"]`, where `gate-selftest`
coincides with its filename but `test` is a job inside `lint.yml`. Mapping a
filename to a context means listing a recent run's jobs and matching names —
which breaks on a job rename, on a multi-job workflow, and when no recent run
exists. That fragility inside the one check standing between the lane and an
unreviewed merge costs more than it buys.

So the guarantee is: *the gate has run on a pull request, and the branch
requires at least one check*. Not: *this gate is that check*. `docs/AUTOPILOT.md`
must say both halves.

## Testing

`autopilot-eligible.sh` is already fixture-driven through the `gh` mock's
`GH_MOCK_STDOUT_MAP` and `GH_MOCK_FAIL_MAP` seams, so every case is a fixture —
no network.

| Case | Asserts |
|---|---|
| PR runs present + protection with contexts | eligible |
| zero `event=pull_request` runs | refuse; reason names the pull request |
| protection 404 | refuse; `no branch protection` |
| protection fails non-404 | refuse; `eligibility check failed` — **not** "no protection" |
| protection present, `contexts: []` | refuse; `no required status checks` |
| gate runs query fails non-404 (D4) | refuse; not `test gate not found` |

Each refusal is asserted on **its own reason string**, per the issue's AC — a
test that only checks the exit code cannot tell these apart, and telling them
apart is most of the point.

**Regression guard:** the existing `autopilot-eligible` cases must pass
unmodified except where a fixture genuinely lacks the new API responses; those
get the responses added, not the assertions weakened.

## Acceptance criteria

- [ ] A repo whose named gate is `workflow_dispatch`-only is not eligible
- [ ] A repo whose default branch has no required status checks is not eligible
- [ ] An API failure reading protection is distinguished from "no protection"
      and refuses
- [ ] A `gh` failure reading the gate's runs is likewise not reported as
      "gate not found"
- [ ] `docs/AUTOPILOT.md` states what the gate condition guarantees **and** the
      known gap
- [ ] Tests cover each refusal with its own reason string
- [ ] `shellcheck -x` clean; full Layer-1 suite green

## Out of scope

- Verifying the gate is among the required contexts (*Known gap*).
- Changing `autopilot.conf`'s allowlist format to name a check context.
- **#388** — headless enrich dispatching despite an assumption flagging this
  gate problem. Related, separately tracked.
