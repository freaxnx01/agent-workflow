# find-pipeline-pr.sh false-positive matching — design

**Tracking:** [freaxnx01/agent-workflow#343](https://github.com/freaxnx01/agent-workflow/issues/343)

## Problem

`find-pipeline-pr.sh` locates the pipeline-opened draft PR for an issue with a
GitHub **search** query and then treats every result as a genuine match:

```bash
gh pr list --repo "$REPO" --state open \
  --search "closes #${ISSUE_NUMBER} in:body" \
  --json number,isDraft,headRefOid,headRefName,author --limit 10
```

GitHub's search has no phrase semantics here. It tokenises the query, `#11`
reduces to `11`, and the result set contains **every** open PR whose body
mentions that number anywhere. `select_from_json` then filters on draft status
and author — never on whether the PR has anything to do with the issue — and
picks the highest-numbered survivor.

### Observed instance

`game-wipfelkratzer#11`, 2026-09-13, run
[34752877053](https://github.com/freaxnx01/game-wipfelkratzer/actions/runs/34752877053).
The agent self-blocked and pushed nothing: 59 of 80 turns, 17 minutes, $2.76,
no branch, no PR. `verify-or-recover-pr.sh` — whose entire purpose is to catch
exactly this — reported:

```
found=true pr-present=true recovered=false salvaged=false
```

Open at that moment were #26 (closes #16), #27 (#14), #28 (#13) and #29 (#12).
Nothing closed #11. The match was **#28**, whose body contains:

> - **After, tall** (`floors: 10`, chairs at cells 5 and **11** next to the
>   stair opening) …

A cell number. Reproducible today:

```console
$ gh pr list --repo freaxnx01/game-wipfelkratzer --state open \
    --search "closes #11 in:body" --json number,headRefName
[{"number":30,"headRefName":"feat/11-wandobjekte-wandwahl"},
 {"number":28,"headRefName":"fix/13-liegestuhl"}]
```

### Why it matters

The false hit disables the salvage path. `verify-or-recover-pr.sh` documents
"run completed but no PR was opened" as the largest measured failure mode in
the fleet — 24 of 48 failures — and salvage exists to turn it into a reviewable
draft PR instead of discarded work. A wrong match short-circuits that: the run
ends `success` with `ai:done` and nothing to show, indistinguishable from a real
success in the run report and in `/ai-stats`.

Probability scales with the number of open PRs sharing the repo, because each
one is another body that might contain the digits. During a fan-out across
several issues — the pipeline's intended mode — collision is the normal case,
not the exception.

The two-digit range is the worst: `#11` matches any body mentioning 11, and
plans routinely cite line numbers, cell indices, viewport sizes and version
fragments.

### Relationship to #249

[#249](https://github.com/freaxnx01/agent-workflow/issues/249) fixed the mirror
image — a **false negative** from GitHub's eventually-consistent search index,
solved with a retry loop
(`docs/superpowers/specs/2026-08-12-find-pipeline-pr-retry-design.md`).

The two interact badly. The retry loop stops as soon as a selection is made, so
a false positive on the first attempt ends the retry immediately and is never
reconsidered. The mechanism built to make lookup more reliable makes a wrong
answer stickier.

## Approach

Demote the search to a **prefilter** and verify each candidate before accepting
it. Two independent signals, checked in order:

1. **`closingIssuesReferences` contains the issue** — GitHub's own computed
   linkage, in this repo. Definitive.
2. **The body carries a closing keyword for the issue** —
   `(?i)\b(close[sd]?|fix(es|ed)?|resolve[sd]?)\s+#N\b` — GitHub's own keyword set, case-insensitive. A fallback for the
   window where the linkage has not been computed yet, and for shapes GitHub
   does not link.

A candidate satisfying neither is discarded.

`gh pr list --json` accepts both `body` and `closingIssuesReferences`, so this
costs **no extra API calls** — the existing single request just returns two more
fields. Verified:

```console
$ gh pr list --repo freaxnx01/game-wipfelkratzer --state all --limit 1 \
    --json number,closingIssuesReferences
[{"number":31,"closingIssuesReferences":[{"number":10,"repository":{"name":"game-wipfelkratzer","owner":{"login":"freaxnx01"}},…}]}]
```

`closingIssuesReferences` carries `repository.owner.login` and
`repository.name`, so a link pointing at the same number in a *different* repo
is excluded too.

### Why both signals rather than the linkage alone

Requiring the linkage alone is cleaner — it uses GitHub's semantics instead of
re-deriving them — but it converts a linkage-computation delay into a false
negative, which is what #249 exists to prevent. The costs are not symmetric
across the two call sites:

- In `verify-or-recover-pr.sh`, a false negative is self-correcting: the recover
  path opens the PR, and if one already exists `open_draft_pr` classifies it
  `exists`.
- In the `auto_review` / `pre_preview` jobs, a false negative stamps
  `ai:review-blocked` and the PR is never reviewed — #249's original complaint.

The body regex covers the gap at no cost. A PR that neither links the issue nor
names it with a closing keyword is not this run's PR under any reading.

### Rejected alternatives

- **Per-candidate `gh pr view --json closingIssuesReferences`.** Same
  information, one API call per candidate, and a second seam for the tests to
  fake. The list call already carries the field.
- **Body regex alone.** Would need only `body`, but re-implements GitHub's
  keyword and cross-repo semantics by hand when the computed answer is free in
  the same response.
- **Tightening the search query** (quoting, `in:body` variants). The search
  index does not support the phrase semantics this needs, and the failure would
  stay silent when it did not.

## Interaction with the retry loop

Unchanged, deliberately. The loop retries while no selection is made. Because
verification now discards fuzzy hits, a result set that is entirely fuzzy
produces no selection, the loop continues, and it eventually reports
`found=false`. That is the correct terminal state: it is what lets salvage run.

## Test fixtures must change

The existing cases in `tests/run-script-tests.sh` pass `PIPELINE_PRS_JSON`
objects carrying only `number`, `isDraft`, `headRefOid`, `headRefName` and
`author`. Under the new predicate every one of them is discarded.

They are extended to carry the linkage, rather than the predicate being
loosened to let a candidate with neither field through. A fixture that omits
what the API returns is not testing the code that runs in production — and a
"both fields absent → accept" escape hatch would reinstate exactly the
behaviour this change removes.

## Acceptance criteria

- A candidate whose body merely contains the bare number, with no closing
  keyword and no linkage, is discarded. The regression case uses PR #28's real
  text ("chairs at cells 5 and 11 next to the stair opening") against issue 11.
- A candidate whose `closingIssuesReferences` contains the issue in this repo is
  accepted.
- A candidate with no linkage whose body says `Closes #N` is accepted;
  `Fixes #N`, `Fixed #N`, `Resolves #N`, `Resolved #N`, `Close #N` likewise.
- A candidate linked to a *different* issue number is discarded.
- A candidate linked to the same number in a *different* repository is
  discarded.
- A body containing `#N` with no closing keyword is discarded.
- The draft-status and author-allowlist filters keep their current behaviour,
  and the highest-numbered survivor still wins among several valid candidates.
- The retry loop's behaviour is unchanged: no valid candidate means retry, then
  `found=false`.
- No additional API calls per invocation.
- `tests/run-script-tests.sh` passes.

## Out of scope

- The silent-success reporting itself — a run that pushes nothing should
  arguably not be `ai:done` regardless of PR lookup. Separate concern.
- `#250` (salvage on `error_max_turns`) and `#322` (a ready-for-review PR gets
  no review). Both assume the PR↔issue mapping is right; this is that mapping.
