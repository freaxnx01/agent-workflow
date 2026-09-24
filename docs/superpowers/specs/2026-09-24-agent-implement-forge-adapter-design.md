# A forge adapter for `agent-implement.yml` (#253)

**Date:** 2026-09-24
**Issue:** [#253](https://github.com/freaxnx01/agent-workflow/issues/253)
**Status:** spec — the audit the issue asks for as step 1, plus the design it implies

## The audit changes the premise

#253 states:

> Only three operations differ per forge: read work item, open PR, post status back.

The audit does not support that. `agent-implement.yml` is **1,594 lines / 4 jobs /
70 steps**; its `implement` job alone runs **32 steps** invoking **12 pipeline
scripts**. Of those twelve, **eleven are forge-bound** — only
`classify-failure.sh` is not:

| Script | Forge-bound? | What it needs the forge for |
|---|---|---|
| `ensure-toolchain.sh` | yes | one `gh` call |
| `check-attempt-cap.sh` | yes | read labels, add label, comment |
| `classify-agent.sh` | yes | **read labels** |
| `classify-task.sh` | yes | **read labels** |
| `classify-turns.sh` | yes | **read labels + issue body** |
| `check-merge-envelope.sh` | yes | 23 calls — PR state, checks, reviews |
| `build-agent-prompt.sh` | yes | **read issue body** |
| `classify-failure.sh` | **no** | — |
| `retry-dispatch.sh` | yes | **re-dispatch the workflow** |
| `ensure-issue-labels.sh` | yes | create labels |
| `verify-or-recover-pr.sh` | yes | create draft PR |
| `post-run-report.sh` | yes | comment, add/remove labels |

**The three named operations are real but are not the hard part.** The hard part
is that **labels are the pipeline's control plane**: which agent runs, which
model, how many turns, whether the attempt cap is blown, which merge policy
applies, and what the outcome was are *all* expressed as labels on the issue.
That is why eleven of twelve scripts touch the forge.

Any adapter that abstracts only "read work item / open PR / post status" leaves
the classifiers, the merge envelope and the retry path still GitHub-only — which
is most of the job.

## The actual adapter surface

The `gh` usage across the implement job reduces to **seven verbs**:

| # | Verb | Used by | Azure DevOps equivalent |
|---|---|---|---|
| 1 | read issue: labels + body | 5 scripts | `az boards work-item show` → tags + `System.Description` |
| 2 | add / remove a label | 3 scripts | **`azdo_set_tags`** — `--fields` appends and cannot clear |
| 3 | post a comment | 2 scripts | `az boards work-item update --discussion` |
| 4 | ensure a label exists | 1 script | no-op — ADO tags are created on first use |
| 5 | create a draft PR | 1 script | `az repos pr create --draft --work-items <id>` |
| 6 | read PR state + checks | `check-merge-envelope.sh` | partial — see below |
| 7 | re-dispatch the run | `retry-dispatch.sh` | **no equivalent** |

Verbs 1–5 are already solved: `scripts/lib/azdo.sh` covers the reads and
`azdo_set_tags` the writes, both verified against a live organization (#286).

### Verb 7 has no equivalent, and that is load-bearing

`retry-dispatch.sh` calls `gh workflow run` to re-dispatch the consumer workflow.
**Azure DevOps has no equivalent trigger in this design** — the issue anticipates
half of this ("the label-and-walk-away trigger is lost") but does not connect it
to retry.

Consequences, which must be stated rather than discovered later:

- **No automatic retry on a transient failure.** On GitHub, `classify-failure`
  → `retry-dispatch` recovers a rate-limit or a flake without a human. On ADO the
  run simply ends.
- **No `escalate-on-retry`.** The cheap-model-then-escalate strategy is a
  GitHub-only capability.

### Verb 6 is partial

`check-merge-envelope.sh` is the largest single consumer at 23 calls, and it
reasons about GitHub-specific concepts: required status checks, review decisions,
mergeable state. Azure DevOps has policies and reviewer votes with genuinely
different semantics (see `/prs`' vote table). **This verb should be out of scope
for a first adapter**: the ADO path opens a draft PR and stops, leaving review
and merge to a human.

## Most of step 1 already exists

The classifiers were built with an **injection seam** for their own Layer-1 tests,
and nobody appears to have connected it to forge portability:

```bash
if [[ -z "${ISSUE_LABELS:-}" ]]; then
  ISSUE_LABELS="$(gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json labels --jq '.labels[].name')"
fi
```

They read `ISSUE_LABELS` / `ISSUE_BODY` when set and only call `gh` as a
**fallback**. Measured across the five read-only scripts:

| Script | Has the seam? |
|---|---|
| `classify-agent.sh` | **yes** |
| `classify-task.sh` | **yes** |
| `classify-turns.sh` | **yes** |
| `build-agent-prompt.sh` | no — calls `gh` unconditionally |
| `check-attempt-cap.sh` | no — calls `gh` unconditionally |

So three of the five need **no code change whatsoever**. Populate `ISSUE_LABELS`
and `ISSUE_BODY` once, per forge, before they run, and they are already portable.

This changes the shape of step 1 and lowers its risk sharply. Rather than
rewriting every call site to a `forge_issue_read` verb, the adapter's job is to
**fill the two variables the scripts already prefer**, and the only code change is
adding the same seam to the two scripts that lack it — matching a convention the
repo already uses rather than introducing one.

It also means the "provable no-op" bar is close to free: with the variables
populated, the `gh` fallback is simply never reached, and the existing fixture
tests already drive these scripts through exactly that path.

## Design

### Shape: a shell adapter, not a skill

The issue proposes "a skill". The audit argues against it for the first cut. The
logic is already **twelve shell scripts driven by environment variables** — the
seam is a function table, not a prompt. A `scripts/lib/forge.sh` dispatching to
`forge-github.sh` / `forge-azdo.sh` matches how `detect-forge.sh` and `azdo.sh`
are already built, and keeps the whole thing unit-testable with the existing mock
harness.

A skill remains the right wrapper *later*, for invoking the pipeline conversationally
on ADO. It is not the right mechanism for swapping seven verbs.

```text
scripts/lib/forge.sh          # dispatch on detect_forge, defines the 7 verbs
scripts/lib/forge-github.sh   # today's gh calls, moved verbatim
scripts/lib/forge-azdo.sh     # az + azdo.sh
```

Each verb keeps its current contract — same stdout, same exit codes — so the
callers change from `gh issue view …` to `forge_issue_read "$N"` and nothing else.

### Sequencing

Follows the issue's own order, with the audit's correction:

1. **`scripts/lib/forge.sh` + `forge-github.sh`**, populating `ISSUE_LABELS` and
   `ISSUE_BODY` once per run. Add the same seam to `build-agent-prompt.sh` and
   `check-attempt-cap.sh`; the other three classifiers need no change. Fixture
   tests prove byte-identical behaviour on GitHub. **No ADO yet** — this step
   must be a provable no-op.
2. **Migrate the write scripts** (`post-run-report`, `ensure-issue-labels`,
   `verify-or-recover-pr`, `check-attempt-cap`'s write half). Same bar.
3. **`forge-azdo.sh`** implementing verbs 1–5 on top of `azdo.sh`.
4. **An ADO entry point** that runs the implement sequence locally, skipping
   verbs 6–7 and saying so.

Steps 1–2 carry all the regression risk and none of the new capability. They are
worth doing on their own merits even if the ADO path never ships, because they
make the classifiers testable without a GitHub fixture.

## Acceptance criteria

- [ ] `scripts/lib/forge.sh` defines the seven verbs and dispatches on `detect_forge`
- [ ] Every migrated script calls a verb, never `gh` directly
- [ ] `classify-failure.sh` is untouched — it is already forge-agnostic
- [ ] Layer-1 fixture tests cover each verb on both forges, `gh` and `az` mocked
- [ ] Steps 1–2 are a **provable no-op on GitHub**: the existing suite passes unchanged, and a real dispatch behaves identically
- [ ] `forge-azdo.sh` implements verbs 1–5 and **fails loudly** on 6–7 rather than silently no-op'ing
- [ ] The ADO entry point states up front that retry and auto-merge are unavailable
- [ ] `docs/DESIGN.md` records the seven-verb surface

## Out of scope

- **Verb 6** — the merge envelope. GitHub checks and ADO policies differ enough
  to need their own design.
- **Verb 7** — re-dispatch. No ADO equivalent exists; the ADO path is
  invoke-explicitly.
- **Self-hosted runners (#248).** The issue is right that this de-prioritises them.
- Porting the twelve interactive commands — that was **#286**, complete.

## Risks

- **Steps 1–2 touch every classifier at once.** A regression there breaks every
  consumer, not just ADO ones. Hence the no-op bar, and hence doing the read-only
  scripts first.
- **`check-merge-envelope.sh` is 23 calls of GitHub-specific reasoning.** Leaving
  it unabstracted is deliberate; pretending otherwise would be the expensive
  mistake.
