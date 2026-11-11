# Machine-readable review marker on the AI review comment — design (#593)

## Why

bridge's cockpit will offer **Merge** on agent PRs only when the AI review
verdict is `approve` for the PR's *current* head SHA (freaxnx01/bridge#382).
Today the verdict is prose: `review-pr.sh` posts a comment that starts with
`<!-- review-pr:<sha> -->` and has the line ``## Automated review — verdict: `approve` ``;
a separate comment from `post-auto-review-block.sh` says "Review held: self-fix
exhausted after N/M iteration(s)". bridge would have to regex both.

## Goal

Append **one hidden HTML comment**, the review marker, as the last line of every
GitHub review comment `review-pr.sh` posts. Same shape as ADR-021's `ai-run`
marker. Everything a human sees, and the existing idempotency marker
`<!-- review-pr:<sha> -->`, stay byte-identical.

## Non-goals

- Changing `post-auto-review-block.sh`, the merge envelope or any gate to read
  the marker. The marker is for display and for consumers deciding to *not* act.
- An Azure DevOps marker (see below).
- Any bridge change (bridge#382 consumes it).

## The marker

```text
<!-- ai-review: {"v":1,"verdict":"approve","head_sha":"5b669f4…","blocking":0,"nits":2,"self_fix":{"iterations":1,"max":2,"exhausted":false}} -->
```

Prefix exactly `<!-- ai-review: `, suffix exactly ` -->`, one compact JSON object
between. Last line of the comment, one `\n` after the `_Agent: … · head: …_` line.

| Field | Type | Source | Present when |
|---|---|---|---|
| `v` | int | constant `1` | always |
| `verdict` | string | the verdict passed to `finish` | always; one of `approve`, `request_changes`, `block`, `review_failed` |
| `head_sha` | string | `HEAD_SHA` | matches `^[0-9a-f]{7,64}$` |
| `blocking` | int | concerns with severity not `low` (so `high`, `medium`, and any unknown value, fail-closed) | the result JSON has a `concerns` array |
| `nits` | int | concerns with severity `low` | same |
| `self_fix.iterations` | int | `ITERATION` env (fix passes applied before this review; `0` on the first review) | `SELF_FIX_MAX` is an integer |
| `self_fix.max` | int | `SELF_FIX_MAX` env | same |
| `self_fix.exhausted` | bool | `verdict == request_changes` and `max > 0` and `iterations >= max` | same |

Omitted, never faked: a field whose source is empty or invalid is left out (no
`null`, no `0` stand-in); the `self_fix` object is omitted as a whole when `max`
is unknown. No free text: no summary, no concern message, nothing an agent or PR
author writes. The JSON is built with `jq -nc` from `--arg`/`--argjson`, then
every `<` and `>` is replaced by `<`/`>` (ADR-021 rule), so the line
can never hold a second `-->`.

## Design decisions

- **One marker per review comment, keyed by head SHA.** A re-review after a
  self-fix pass posts a new comment for the new head, so the *latest* marker whose
  `head_sha` equals the PR's current head is the verdict for that head. The
  marker therefore carries `head_sha` itself rather than relying on the visible
  `head:` text.
- **`exhausted` is derived from the final review's own state.** The status
  comment ("Review held: …") is posted later, by a different script, and is not
  marker-bearing. The last review on a head already knows `iterations` and `max`,
  so `exhausted` needs no later write.
- **`review-pr.sh` learns `SELF_FIX_MAX`.** It already receives `ITERATION` on
  re-reviews (`self-fix-loop.sh:174`) but not the cap. The workflow passes
  `SELF_FIX_MAX` to the first review step; `self-fix-loop.sh` forwards its own
  `MAX_ITERATIONS` as `SELF_FIX_MAX` on re-reviews.
- **GitHub only.** Gate on `FORGE == github`. Azure DevOps comments are stored as
  sanitized content whose HTML-comment round trip is unverified (ADR-021 item 9);
  ADO emits no review marker, and a consumer finds none.

## Assumptions

- **A1** [high] Implemented in `review-pr.sh`'s `render_comment`, not as a
  post-processing step. Rejected: appending in the workflow. `review-pr.sh:156-181`
  is the only place that builds the body and `finish` (`:208`) already has the
  verdict.
- **A2** [high] New ADR-022 rather than amending ADR-021. ADR-021 is the run
  report's contract (`docs/DECISIONS.md:1734`), entries are immutable; the review
  marker has its own fields and version line.
- **A3** [med] `blocking` = every concern whose severity is not `low`; `nits` =
  `low`. Rejected: `blocking` = `high` only. The prompt says `request_changes`
  needs "at least one `high` or `medium` concern" (`scripts/lib/review-prompt.md:77-78`)
  and `approve` may carry `low` nits (`:75-76`).
- **A4** [med] Marker field named `iterations` (as the issue's example), meaning
  fix passes applied before this review, not "passes used overall".
- **A5** [med] Trusted author. First-review comments come from
  `GH_TOKEN: github.token` (`agent-implement.yml:1400-1402`, `:1772-1782` (the `review` steps)) so the author is
  `github-actions[bot]`. Re-review comments come from `self-fix-loop.sh`, whose
  step uses `steps.app_token.outputs.token || github.token`
  (`agent-implement.yml:1471`, `:1837`), so with a GitHub App configured the author
  is the App bot. The ADR states: consumers trust the pipeline's report identities
  (`github-actions[bot]` and, when configured, the pipeline App's bot). Rejected:
  forcing `github.token` on re-reviews, which would change who the self-fix push
  is attributed to and is out of scope.
- **A6** [high] `verdict` passes `block` and `review_failed` through unchanged;
  only `approve` ever means Merge-eligible, consumers treat the rest as "not approved".

## Consequences

- A review comment grows by roughly 150 bytes; nothing visible changes.
- A self-fix loop that aborts (fix step failed, "re-review failed") leaves the
  last marker saying `exhausted:false` although the PR is held. Consumers must not
  read `exhausted` as "held"; `verdict != approve` is the merge gate.
- The same head SHA can only carry one review comment (idempotency skip,
  `review-pr.sh:192`), so a marker never changes after posting.
- Known gap inherited from ADR-019/ADR-021: the agent token may be able to post
  as the same bot, so the author filter holds against third parties, not against
  the agent (#535).

## Review Focus

1. Marker survives a hostile `HEAD_SHA`/severity (`-->`, `<`): stays one comment.
2. Visible body byte-identical with and without marker (golden diff).
3. ADO run emits no marker.
4. `SELF_FIX_MAX` unset, empty, `abc`: `self_fix` omitted, marker still valid JSON.
