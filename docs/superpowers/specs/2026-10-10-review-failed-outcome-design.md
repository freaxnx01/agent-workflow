# Review failures are not `block` verdicts — design

**Issue:** #490 · **Date:** 2026-10-10 · **Status:** approved

## Problem

`scripts/review-pr.sh` turns every situation where it could not get a verdict
into `verdict=block`:

| Where | Situation |
|---|---|
| `review-pr.sh:184` | diff larger than `MAX_DIFF_BYTES` (320000) |
| `review-pr.sh:247` | agent invocation failed |
| `review-pr.sh:273` | agent output has no recoverable JSON object |
| `review-pr.sh:285` | agent returned a verdict outside `approve\|request_changes\|block` |

All four end as `ai:review-blocked`, which reads as "the code was rejected".
Both cases in #490 happened on `freaxnx01/game-rhyflitzer`:

- PR #122: `agent produced non-JSON output`. The raw output isn't logged, so we
  can't tell whether #72's salvage regressed or the agent produced a new output shape.
- PR #135: a +78/−5 change over 5 files became a 5.2 MB diff because
  `data/world_hochrhein.json` is one 2.6 MB minified line, so it went over the cap.

## Goal

A review that **could not happen** must be distinguishable from a review that
**said no**. Both keep the PR draft (fail closed). A data file stored on one
line must not make an otherwise small change unreviewable.

## Design

### 1. A fourth outcome: `review_failed`

`review-pr.sh` may emit `verdict=review_failed`, in addition to `approve`,
`request_changes` and `block`. `block` is reserved for a reviewer that read the
code and refused.

- **Retry once.** If the agent invocation fails, or its output yields no valid
  verdict (no JSON after the existing #72 salvage, or a verdict outside the
  three agent verdicts), run the agent **once more**. The retry prompt is the
  original prompt plus one line: `Your previous reply was not a single JSON
  object. Reply with only the JSON object.` A second unusable result ends in
  `review_failed`.
- **Log the raw output.** For each unusable attempt, print the first 4096
  bytes of the agent's output to stderr between delimiter lines
  (`--- review agent output (attempt N, first 4096 bytes) ---` /
  `--- end ---`), so the next PR #122 can be diagnosed from the run log.
- The agent itself may still only return `approve|request_changes|block`. An
  agent-emitted `review_failed` counts as an invalid verdict, because the
  outcome is the script's to give, not the reviewer's.
- Exit code stays `0` for every outcome. The script header's output and exit
  contract lists the new value.
- The result JSON for `review_failed` is
  `{"verdict":"review_failed","summary":"<reason>","concerns":[]}`.

### 2. Elide very long diff lines before the size cap

Before the size check, every diff line longer than `MAX_DIFF_LINE_CHARS`
(default **10000**) is replaced with:

```text
[elided by review-pr.sh: a <N>-character line in <file> — too long to review]
```

`<file>` is the path from the nearest preceding `+++ b/<path>` header (or
`--- a/<path>` for a deletion). The prompt template gets one sentence telling
the reviewer that elided lines are out of scope and must not count against
the change.

The `MAX_DIFF_BYTES` cap then applies to the **elided** diff. If it's still over
the cap, the outcome is `review_failed` with the reason
`diff size <bytes>B exceeds cap <cap>B after eliding long lines`. It is never
`block`.

On PR #135 this removes the two 2.6 MB lines (`-` and `+`) and the reviewer
sees the rest of the diff.

### 3. Downstream wiring

- **`post-auto-review-block.sh`**: when `VERDICT=review_failed`, label the
  issue **`ai:review-failed`** instead of `ai:review-blocked`. The comment says
  the review could not complete and gives the reason, rather than calling it a
  blocking verdict. Other verdicts are unchanged.
- **`ensure-issue-labels.sh`**: register
  `create ai:review-failed D73A4A 'Review could not run to a verdict; human look needed'`
  and add it to the "blocked states" comment block:
  `ai:review-failed — the reviewer ran but produced no usable verdict (#490)`.
- **`self-fix-loop.sh`**: a re-review returning `review_failed` stops the loop,
  exactly like `approve` and `block` (both the real loop and the stub-sequence
  path).
- **Unchanged:** only `approve` promotes or merges (`agent-implement.yml`
  conditions on `steps.final.outputs.verdict == 'approve'`); self-fix triggers on
  `request_changes` only. A `review_failed` PR stays draft, gets no self-fix,
  and reaches the blocked step through its existing `!= 'approve'` condition.

## Testing (Layer 1)

| Scenario | Expected |
|---|---|
| Agent output non-JSON, then valid JSON on retry | the retry's verdict; the agent ran twice |
| Non-JSON twice | `verdict=review_failed`; raw output delimited on stderr |
| Agent invocation fails twice | `review_failed` |
| Agent invocation fails once, then valid JSON | the retry's verdict |
| Agent returns `review_failed` itself | treated as invalid → retry → `review_failed` if repeated |
| Diff with a 20000-char line, otherwise small | line replaced by the elided marker; review runs |
| Diff still over the cap after eliding | `review_failed`, reason names the cap |
| Valid JSON first time | one agent call (no regression) |
| `post-auto-review-block.sh` with `VERDICT=review_failed` | `--add-label ai:review-failed`, not `ai:review-blocked` |
| `post-auto-review-block.sh` with `VERDICT=block` | still `ai:review-blocked` |
| `self-fix-loop.sh` stub sequence `request_changes,review_failed,approve` | stops at `review_failed` |

Existing review tests that assert `block` on non-JSON, crash, invalid verdict
or oversize change to assert `review_failed`. Those are the behaviour this issue
changes, so they're updated with it, not loosened.

## Out of scope

- Why PR #122's output wasn't salvageable. The new log lines make the next
  occurrence diagnosable; fixing the cause waits for that evidence.
- The 10-minute review-job timeout (#446 / #449 / #372).
- Respecting `linguist-generated` in `.gitattributes`.
