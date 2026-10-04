# /enrich concurrency lock — design

## Problem

`/enrich` can be run against the same issue from two different sessions
concurrently (e.g. two Claude Code CLI sessions started before either has
finished). Both pass Step 1/2 (read issue, assess readiness) unaware of each
other, both invoke `superpowers:brainstorming` on the same issue, and the
result is duplicated brainstorming/plan work and a race on which session's
`git push` / issue-body edit lands last.

`/enrich` has no shared state today that would let a second session detect
this. `needs-enrichment` and `❓ to-be-defined` are readiness labels, not
in-progress markers, and neither carries a timestamp.

## Goals

- A second `/enrich` session on an issue already being enriched should detect
  this and hard-stop before starting brainstorming, rather than duplicating
  work.
- A session that died mid-enrichment (crash, closed terminal, abandoned) must
  not permanently block the issue — the lock has to expire and be
  recoverable.
- Applies to both forge sections of `commands/enrich.md` (GitHub and
  Forgejo) — the command already mirrors both, this stays symmetric.
- No new scripts or application code — `/enrich` is a markdown-instruction
  command; this is a `commands/enrich.md` change plus a
  `scripts/ensure-issue-labels.sh` addition.

## Non-goals

- `/enrich-phased` (the split-context variant) is out of scope. It has its
  own phase-boundary structure and deserves its own look — tracked as a
  follow-up, not bundled here.
- No cross-session messaging/locking beyond what the forge's issue API
  already offers (labels + comments). No external lock service.

## Design

### Lock representation

A boolean label `enrichment-ongoing` (visible in `/issues`, `/triage`, and
any other label-based filter, like the rest of the label vocabulary) plus an
issue comment carrying the acquisition timestamp:

```text
🔒 Enrichment lock acquired at 2026-08-04T14:32:00Z
```

The timestamp lives in a comment rather than being encoded into the label
name because:

- Encoding it in the label name would break the fixed-label idempotent
  creation pattern (`ensure-issue-labels.sh`, `/new`'s `needs-enrichment`
  handling) — those assume a small, static label vocabulary, not one
  instance per lock acquisition.
- `/enrich` Step 1 already fetches issue comments
  (`gh issue view --comments` / `tea api .../comments`), so detecting both
  "is it locked" and "since when" costs no new API call.
- GitHub's timeline API (`labeled` event timestamp) would avoid the extra
  comment, but Forgejo/tea's equivalent is inconsistent across versions —
  the comment approach is symmetric across both forges the command already
  supports.

Timestamp format: ISO 8601 UTC (`date -u +%Y-%m-%dT%H:%M:%SZ`), diffed
against the current UTC time, to avoid timezone-conversion bugs.

### Flow changes to `commands/enrich.md`

Both the GitHub and Forgejo sections get the same three additions:

**New Step 1.5 — Check for an existing lock** (immediately after Step 1,
before readiness assessment):

- If `enrichment-ongoing` is not present → continue to Step 2.
- If present, scan comments for the most recent
  `🔒 Enrichment lock (re-)acquired at …` line and compute its age against
  now.
  - No matching comment found (label applied manually, or the comment is
    missing) → treat as unknown age, same handling as stale below.
  - Age < 24 hours → **hard stop**. Tell the user the issue is already being
    enriched (show the age) and end the command. No readiness assessment,
    no brainstorming.
  - Age ≥ 24 hours → **stale**. Tell the user the lock looks abandoned (show
    age and the 24h threshold) and ask whether to take over.
    - No → stop.
    - Yes → continue to Step 2, and when Step 2.5 re-acquires the lock, note
      the takeover in the new comment (see below).

Step 2 (readiness assessment) is unchanged. If the issue turns out already
complete, the command stops there having never touched the lock — nothing to
release.

**New Step 2.5 — Acquire the lock**, immediately before Step 3
(brainstorming) — the last point before the expensive shared resource
(brainstorming + planning) starts:

- Create the `enrichment-ongoing` label if it doesn't exist yet (same
  idempotent create-or-ignore pattern as `needs-enrichment`):

  ```bash
  gh label create enrichment-ongoing --color FBCA04 \
    --description "Another /enrich session is actively enriching this issue — do not start a second one" \
    2>/dev/null || true
  ```

  Forgejo equivalent via `tea labels create --login git-home`.

- Post the lock comment **first**:
  - Fresh acquisition: `🔒 Enrichment lock acquired at <timestamp>`
  - Takeover of a stale lock:
    `🔒 Enrichment lock re-acquired at <timestamp> (previous lock stale, <Xh> old)`
- *Then* apply the label to the issue.
- Then re-read the comments and resolve any race (see below).

The comment-before-label ordering matters: the label is what Step 1.5 keys
on, and the comment is what gives it an age. Applying the label first leaves
a window in which the issue is labelled with no matching comment — which
Step 1.5 deliberately treats as *unknown age → stale* and offers to take
over, defeating the detection it exists for. Posting the comment first means
the label never appears without an age.

### Closing the detect/acquire race

Step 1.5 (detect) and Step 2.5 (acquire) are not atomic — Step 2 (an LLM
readiness assessment) and, on the takeover path, a user prompt sit between
them. Two sessions started close together can both pass Step 1.5 seeing no
lock, then both acquire and both brainstorm — exactly the duplicated work
this feature exists to prevent.

The forge API offers no compare-and-swap, so the race is resolved *after*
acquisition instead, using the lock comments as an ordered log:
immediately after posting its own lock comment, a session re-fetches the
comments and looks for any **other** lock comment that

- was **not** present when it read comments in Step 1.5 (i.e. a competitor
  that acquired during the gap — the pre-existing stale comment on the
  takeover path is therefore correctly ignored), and
- carries an **earlier** timestamp than its own (ties broken by comment ID,
  lowest wins — both forges hand out monotonically increasing IDs).

If such a comment exists, this session lost the race: it stands down and
stops, without brainstorming. Both sessions run the same check against the
same ordered log, so exactly one of them wins.

The loser does **not** remove the `enrichment-ongoing` label. The label is a
single boolean shared by both sessions — the winner needs it, so removing it
would unlock an issue that is actively being enriched, re-opening the very
hole this closes. The loser instead posts

```text
🔓 Enrichment lock released at <timestamp> (lost race to the lock acquired at <winner timestamp>)
```

so the stand-down is explicit in the audit trail, and the winner's lock and
its Step 6 release are untouched. `🔓` is a distinct marker from `🔒`, so
Step 1.5's scan never mistakes a stand-down for an acquisition.

### Releasing the lock

**Step 6** (already clears `needs-enrichment` / `❓ to-be-defined` on
success): also remove `enrichment-ongoing` here, same
`--remove-label ... 2>/dev/null || true` pattern for GitHub, and the
existing label-PUT rewrite (already reads-modifies-writes the full label set
to drop the other two) extended to also drop `enrichment-ongoing` for
Forgejo.

Step 6 only covers the success path, but Step 2.5 is followed by two steps
that can legitimately stop the command: the brainstorming approval gate in
Step 3 (the user declines) and Step 5's "verify the push succeeded" stop.
Aborting there without releasing would leave a lock nobody is holding for the
full 24h staleness window. So the release is not Step-6-specific: **any
user-initiated abort after Step 2.5 removes `enrichment-ongoing` before the
command ends**, using the same commands Step 6 uses. Only a hard crash (which
staleness expiry already covers) leaves the lock behind.

No comment cleanup on release — the lock comments stay as an audit trail on
the issue.

### Crash recovery

If a session dies after Step 2.5 but before Step 6, the lock (label +
comment) simply persists. Either:

- The same person resumes `/enrich` on the same issue — Step 1.5 finds the
  lock, but since no *other* session is racing, this is a self-collision.
  This design does not special-case "is it me" (the forge API doesn't cheaply
  tell us that) — the resuming person just answers "yes, take over" once the
  lock crosses the 24h staleness threshold, or waits it out. This is an
  accepted rough edge, not solved here.
- A different session hits the stale-lock path after 24 hours and takes over.

No explicit crash-cleanup step is needed — staleness expiry is the entire
recovery mechanism.

### Threshold

24 hours, shared with `/enrich-phased`'s lock (`docs/superpowers/specs/2026-08-04-enrich-phased-lock-design.md`).
The lock comment doesn't record which command acquired it, so `/enrich` and
`/enrich-phased` must agree on a single threshold for either one to correctly
judge a lock the other command holds — a value here that only made sense for
`/enrich`'s own single-sitting use would cause `/enrich`'s Step 1.5 to treat
an `/enrich-phased` run's ordinary overnight pause between `/clear` boundaries
as abandoned and offer it up for takeover, defeating the lock in exactly the
scenario cross-command detection exists to cover. 24 hours absorbs that normal
pause while still recovering a genuinely abandoned single-sitting `/enrich`
run within a day. It's a plain constant in the command doc — easy to retune
later if it proves too tight or too loose in practice, but retune both
commands together.

## Testing / verification

`/enrich` is a markdown-instruction command with no automated test suite.
Verification is a manual dry run against a scratch issue:

1. Simulate a second session by pre-applying `enrichment-ongoing` + a
   fresh lock comment on a test issue, then run `/enrich <issue>` — confirm
   it hard-stops at Step 1.5 without starting brainstorming.
2. Manually backdate the lock comment (edit its text to an older timestamp,
   past 24h) and re-run — confirm the stale/takeover prompt fires, and that
   answering yes proceeds while answering no stops.
3. Run `/enrich` end-to-end on an unlocked issue — confirm the lock label
   and comment appear before brainstorming starts (Step 2.5), and that both
   are cleared at Step 6 while the comment itself remains.
4. Simulate losing the race: between Step 2.5's comment post and its
   re-check, add a second lock comment with an *earlier* timestamp by hand —
   confirm the session stands down (posts the `🔓 … lost race …` comment,
   leaves the label alone, does not brainstorm).
5. Abort at Step 3's approval gate (decline the spec) — confirm
   `enrichment-ongoing` is removed before the command ends, without reaching
   Step 6.

## Follow-ups (out of scope here)

- ~~Apply the same lock mechanism to `/enrich-phased`.~~ **Done** — see
  `docs/superpowers/specs/2026-08-04-enrich-phased-lock-design.md` (issue
  #237). `/enrich-phased` now detects, acquires and releases the same
  `enrichment-ongoing` lock. Both commands share the same 24h staleness
  threshold (`/enrich`'s own threshold was raised from 4h to match — see
  *Threshold* above): the lock comment doesn't record which command acquired
  it, so a lock set by either command is now correctly respected by the
  other in both directions, not just detected.
- Consider whether the "same person resuming" self-collision case is worth
  special-casing later (e.g. embedding a session/host identifier in the lock
  comment) if it proves annoying in practice.
