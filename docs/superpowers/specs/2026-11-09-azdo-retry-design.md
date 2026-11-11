# Azure DevOps ai-implement retry and attempt cap — Design (gap item a)

**Issue:** #573 · **Date:** 2026-11-09 · **Status:** draft, written unattended under
the maintainer's go-ahead of 2026-11-06. Calls marked *(my call)* were made by the
author, not the maintainer.

## Intent

Today a transient failure, a rate limit or one bad agent attempt ends the Azure
DevOps run, and a human has to re-tag the work item. On GitHub,
`retry-dispatch.sh` re-dispatches the workflow according to the failure class,
and `check-attempt-cap.sh` stops an item that keeps failing. This item brings
the same behaviour to Azure DevOps **without weakening the trust gate**.

## Why in-job retry, not a re-queue

The obvious port is to re-queue the pipeline with `workItemId`. That collides
with the guard:

- The guard consumes the `ai-implement` tag, so a re-queued run finds no tag →
  exit 64 → a green skip, and no retry happens.
- If the build service re-adds the tag, the build service becomes the tagger.
  It is not on the allowlist, so the run stops at exit 65.
- A variable or parameter that skips the guard is exactly what
  `azdo-pipeline-run.sh` forbids. Every pipeline variable is an environment
  variable, so it would be a bypass.

A real re-queue would need a trust token the guard can verify, plus *Queue
builds* for the build service. So **retry happens inside the one guarded job**.
The guard has already judged this tag and this tagger, and the retry loop only
repeats the agent step. No queueing, no new trust question.

## Goals

1. **G1:** inside one run, a failed agent attempt is retried per the **same
   policy** as GitHub. `rate_limit` and `transient` up to 3 attempts, with the
   same delays. `task_failure` once. Everything else stops.
2. **G2:** an **attempt cap across runs**. A human re-tag counts toward the
   same cap (`MAX_ATTEMPTS`, default 2 real attempts, as on GitHub). Past the
   cap, the item is parked with a comment instead of running.
3. **G3:** each attempt starts from a clean workspace on the default branch.
4. **G4:** each attempt posts its own report comment, with a heading the cap
   counts (`## ai-implement run …`).
5. **G5:** the "no retry on this forge" header, banner and report text in
   `implement-azdo.sh` are updated to say what is true now.

## Non-goals

- Re-queueing the pipeline, or any change to the guard.
- Escalation to a different agent or model on retry. The Azure DevOps path runs
  Claude only, and `ESCALATE_MODEL` equals its default model, so escalation is
  a no-op here. Pass `ATTEMPT` through anyway so the classifiers stay
  consistent.
- The OpenRouter budget check (`out_of_credits` cannot occur on this path,
  #521 A9).

## Anti-goals

- **A second copy of the retry policy.** If Azure DevOps and GitHub can
  disagree on which classes retry, they will.
- A retry loop that can outlive the job silently. The job timeout must cover
  the worst case, and the guide says so.

## Decisions

### A1 — One policy, two callers *(my call)*

Extract the decision table from `retry-dispatch.sh` (class + attempt →
decision + delay) into `scripts/lib/retry-policy.sh`, for example
`retry_policy <class> <attempt>`, which prints `decision` and `delay`. The
existing knobs keep their names and defaults:

- `MAX_RETRIES_RATE`
- `MAX_RETRIES_TRANS`
- `MAX_RETRIES_TASK`
- `DELAY_OVERRIDE_SEC`

`retry-dispatch.sh` sources it, and its existing tests must stay green
unchanged. `implement-azdo.sh` sources it too.

### A2 — Loop shape in `implement-azdo.sh`

1. **Before the first attempt,** run `check-attempt-cap.sh`. It already reads
   `ISSUE_COMMENTS_JSON` (filled by `forge_export_issue`) and parks through
   forge verbs. Over the cap → it parks the item and the run exits 0 with a
   message. Under the cap → it returns the starting `ATTEMPT`.
2. **Each attempt:**
   - build the prompt;
   - run the agent;
   - classify;
   - post the report.
3. **On `decision=retry`:**
   - sleep the delay;
   - reset the workspace (A3);
   - `ATTEMPT+1`;
   - loop.
4. **Success** → open the PR, as today. **Stop on failure** → exit 1, and the
   pipeline's `azdo-report-failure.sh` step comments, as today.

Keep the functions small. The current script is already a long straight line,
so the loop must not become a 200-line block.

### A3 — Workspace reset between attempts

```text
git checkout --force <default>
git reset --hard origin/<default>
git clean -ffdx
```

Then delete the local branch the attempt created. A remote branch that a failed
attempt pushed is left alone and named in the report. The next attempt
branches fresh. If its branch name collides, the push path reports that,
because the agent picks the branch name.

The pipeline-side `agent-workflow` clone lives in `$(Agent.TempDirectory)`, not
in the checkout, so `git clean` does not touch it. Verify this.

### A2a — Two counters, as on GitHub *(my call, from the builder check)*

GitHub keeps two counters:

- **The retry counter** (`inputs.attempt`) feeds the retry policy. It starts at
  1 for every run a human triggers.
- **The cap counter** (prior real reports + 1) feeds the cap.

The Azure DevOps loop keeps them apart in the same way:

- `RUN_ATTEMPT` starts at 1 in each run and feeds `retry_policy`.
- `check-attempt-cap.sh` runs **before every attempt**, as GitHub re-checks it
  on every re-dispatch, and can park the item mid-run.

Then a re-tag after one failure still gets its in-run `task_failure` retry,
unless the cap parks it first, which is exactly the GitHub behaviour.

### A4 — Report heading

The per-attempt report heading becomes:

```text
## ai-implement run (pipeline, Azure DevOps) — attempt N
```

`check-attempt-cap.sh` counts comments whose body starts with `## ai-implement
run`. Today's `## implement run (…)` does not match, so today nothing would be
counted. Include `Turns:**` and `Cost:**` lines in the same shape as
`post-run-report.sh`, so the non-start detection works. If the cost is unknown,
write it so that a real attempt is never mistaken for a non-start.

### A4a — Azure DevOps comments are HTML *(my call, from the builder check)*

The work-item comments API returns HTML (see
`tests/fixtures/azdo-comments-locked.json`), so a `startswith("## ai-implement
run")` check never matches. The azdo branch of `forge_export_issue` turns each
comment body into plain text before it fills `ISSUE_COMMENTS_JSON`:

- strip tags;
- unescape entities;
- turn `<br>` and `</div>`/`</p>` into newlines.

The prompt builder benefits from the same text. The github branch and
`check-attempt-cap.sh` are unchanged. **Verify the real format live** by
fetching a posted report comment back, and add that payload as a fixture.

### A5 — Parking on Azure DevOps

`check-attempt-cap.sh` parks with a label, which becomes a tag on Azure DevOps.
The cap counts append-only reports, so there is no per-item reset. GitHub's
documented workaround is to raise `max-attempts` (#321,
`docs/COMMAND-CHEATSHEET.md`). Azure DevOps mirrors it with a pipeline variable,
`MAX_ATTEMPTS`, with *settable at queue time* **off**. It can only be changed by
whoever can edit the pipeline, who can already change everything else.

The guide's "unpark" note says: remove the park tag (read its exact name from
`check-attempt-cap.sh`), raise `MAX_ATTEMPTS` if the cap is the reason, then
re-tag *(my call)*.

### A6 — Job timeout

Budget per phase *(my call)*:

- up to 3 implement attempts × 45 min;
- plus 10 min of delays;
- plus review and self-fix (item b): 2 × (fix 20 + review 10).

That is about 205 min. The pipeline sets `timeoutInMinutes: 240`.

Each agent call is wrapped in `timeout` with its own budget
(`IMPLEMENT_TIMEOUT_MIN=45`). A hung attempt is then classified as a transient
failure instead of eating the whole job. The guide states the breakdown.

## Tests

- **Layer 1:**
  - `retry-policy` unit cases, one per class × attempt boundary.
  - `implement-azdo` loop cases with the agent stub returning a scripted class
    sequence:
    - transient → success: 2 attempts, PR opened;
    - task_failure → task_failure: stop after 2, exit 1;
    - api_auth: no retry;
    - cap reached at start: parked, no agent call.

    Assert the report count and heading. Use `DELAY_OVERRIDE_SEC=0`.
- **Live (sandbox):** force one failure. For example, run the first attempt
  with an invalid model name through a test-only variable that the guard cannot
  turn into a bypass, or with a stub agent command. Show attempt 1 fail,
  attempt 2 succeed, and two report comments. Then re-tag an item already at
  the cap and show that it is parked. The builder picks the failure-injection
  method and records it in the run note.

## Left to the builder

- How `ATTEMPT` and the cap result are read from `check-attempt-cap.sh` (its
  output contract).
- The failure-injection method for the live test. It must not add a production
  bypass.
