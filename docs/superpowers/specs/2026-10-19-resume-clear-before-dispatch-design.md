# A resume never dispatches an issue it could not take off the paused list — design

**Issue:** #536 · **Date:** 2026-10-19 · **Status:** approved (quick + headless enrich)

## Problem

`scripts/pipeline-resume.sh` re-dispatches every open `ai:paused` issue that
still carries `ai-implement`. Its order per issue is (`pipeline-resume.sh:118-121`):

1. `gh workflow run … -f issue-number=<n>`
2. `paused_issue_clear <n>` — remove `ai:paused`

`paused_issue_clear` (`scripts/lib/paused-issues.sh:50-53`) swallows every error
(`>/dev/null 2>&1 || true`), so a failed clear is invisible. The issue then
keeps `ai:paused` while a run is already in flight. The dispatched run's own
gate (`check-pipeline-pause.sh:115`) clears the label too, but only once that
job starts, and that clear also swallows errors. A second resume before then,
or after both clears failed, dispatches the issue **again**: two implement runs
on one issue, racing for one branch and one PR.

Found in the independent review of PR #534 (#521). Low severity, no security
impact. It matters more now that the goal is an unattended lane where nobody
watches the resume output.

## Goal

A resume must never leave an issue both dispatched and still on the paused
list. When a label write fails, the operator must see it in the output, and the
worst case must be "not dispatched yet, still listed" (safe, retried by the
next resume), never "dispatched twice".

## Design

### 1. Clear first, then dispatch, re-mark on a failed dispatch

Per issue that still carries `ai-implement`:

1. `paused_issue_clear <n>`. **If it fails, do not dispatch.** Print
   `warning: could not remove ai:paused from #<n> — not dispatched, so a second resume cannot double-dispatch it; run this again`
   to stderr and go to the next issue. The label is still there, so the next
   resume retries it.
2. `gh workflow run …`. On success, print `re-dispatched #<n> as attempt 1` as today.
3. If the dispatch fails, put the label back with `paused_issue_mark <n>`. The
   existing warning (`could not re-dispatch #<n> — it keeps ai:paused; …`)
   stays. If the re-mark fails too, `paused_issue_mark` already warns on stderr
   and names the issue in `$GITHUB_STEP_SUMMARY` (`paused-issues.sh:33-48`),
   so the issue is not silently lost.

This closes the window structurally instead of reporting it: a run is only
ever dispatched for an issue that is already off the list.

### 2. `paused_issue_clear` reports failure

`paused_issue_clear` returns `1` when `gh issue edit --remove-label` fails, and
stays silent on stdout/stderr. The **callers** decide what a failure means:

| Caller | On a failed clear |
|---|---|
| `pipeline-resume.sh`, issue to dispatch | warn, skip the dispatch (above) |
| `pipeline-resume.sh`, issue without `ai-implement` (`:111-114`) | warn `could not remove ai:paused from #<n>`, continue. No dispatch happens on this path, so nothing can double |
| `check-pipeline-pause.sh:115` (run that proceeds) | `|| true`, unchanged behaviour. The label may not even exist in a repo that was never paused, and the gate's verdict must not depend on it |

The library header comment for `paused_issue_clear` changes from "a silent
no-op when absent" to "returns 1 when the label could not be removed; removing
a label the issue does not carry is not a failure".

### 3. Exit code unchanged

`pipeline-resume.sh` keeps exiting `0` when individual issues could not be
handled, as it does today for a failed dispatch. The per-issue warning is the
signal, and running the script again is the documented retry
(`docs/ALARMS.md:69-72`). Exit `1` stays reserved for "the list could not be
read, nothing was done".

## Out of scope

- Making the gate's own clear (`check-pipeline-pause.sh:115`) loud. A run that
  proceeds while its label could not be removed is harmless once the resume no
  longer dispatches labelled issues it could not clear.
- Retrying label writes with backoff.

## Testing

Layer-1, in `tests/run-pipeline-alarm-tests.sh`, gh mocked:

- The clear happens **before** the dispatch (log line order).
- A failed clear: no `workflow run` for that issue, a warning names it, exit 0.
- A failed dispatch: the issue is re-labelled `ai:paused` (the last `issue edit`
  for it is `--add-label ai:paused`), and the warning still says so.
- A failed dispatch **and** a failed re-mark: the `could not label` warning
  from `paused_issue_mark` appears.
- `paused_issue_clear` returns 1 on a gh failure, 0 on success.
- The gate still emits `paused=false` and exits 0 when its clear fails.

The existing assertion `failed dispatch -> the issue keeps ai:paused`
(`run-pipeline-alarm-tests.sh:883`) checks that no `issue edit 12` was made at
all. That encodes the old order, not the behaviour. It is replaced by an
assertion that the last `issue edit 12` puts the label back. The behaviour it
protects (the issue stays listed) is unchanged.

## Docs

`docs/ALARMS.md` (resume paragraph, `:69-76`): the label is removed **before**
each dispatch, a failed removal means the issue is not dispatched this time,
and a failed dispatch puts the label back.
