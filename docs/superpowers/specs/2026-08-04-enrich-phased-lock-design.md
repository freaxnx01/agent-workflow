# /enrich-phased concurrency lock — design

## Problem

`/enrich`'s concurrency lock (issue #229, merged in PR #233) prevents two
sessions from concurrently brainstorming/planning the same issue via an
`enrichment-ongoing` label + timestamped comment. It only covers
`commands/enrich.md` — `/enrich-phased` (`commands/enrich-phased.md`), the
split-context variant that runs spec → `/clear` → plan → `/clear` → issue
body as isolated phases, was explicitly out of scope for #229 and was never
touched.

Consequence: if a session acquires the lock via `/enrich` but the issue is
then finished off via `/enrich-phased` (or the reverse — started phased,
finished via plain `/enrich`), nothing on the `/enrich-phased` side ever
releases or even recognizes the lock in a way that matches its own longer
natural duration. Today `/enrich-phased` neither detects an existing lock
nor acquires one at all.

## Goals

- `/enrich-phased` gains the same detect/acquire/release lock behavior
  `/enrich` has, adapted to its phase/`/clear` structure.
- An issue locked by either command is correctly detected and respected by
  the other — achieved for free by reusing the identical label name and
  comment marker format `/enrich` already established.
- The staleness window accounts for `/enrich-phased`'s legitimately longer
  pauses between phases (hours to days). Since the lock comment doesn't
  record which command acquired it, `/enrich` and `/enrich-phased` must
  share one threshold for either to correctly judge a lock the other holds —
  so `/enrich`'s own threshold is raised from 4h to the same 24h value, not
  left at 4h alongside `/enrich-phased`'s 24h.
- Applies to both the GitHub and Forgejo sections of
  `commands/enrich-phased.md`, mirroring `/enrich`'s existing gh/tea
  symmetry.

## Non-goals

- No redesign of `/enrich`'s own lock (`commands/enrich.md`) — its flow and
  lock semantics are unchanged. This spec does touch `/enrich` in three
  narrow ways, backported so the two commands don't drift: the staleness
  threshold (see *Staleness threshold* below), surfacing
  `enrichment-ongoing` release failures instead of swallowing them, and
  guarding the Forgejo read-modify-PUT against wiping every label.
- No re-verification of the lock at every phase boundary (Phase `plan`,
  Phase `issue`) — see Design below for why a single acquisition in Phase
  `spec` is sufficient.
- No cross-session identity tracking (who owns a lock) — same accepted
  limitation as `/enrich`'s spec.

## Design

### Lock representation (reused, unchanged)

Same as `/enrich`: the `enrichment-ongoing` label plus an issue comment:

```text
🔒 Enrichment lock acquired at <ISO 8601 UTC timestamp>
```

or, on takeover of a stale lock:

```text
🔒 Enrichment lock re-acquired at <timestamp> (previous lock stale, <Xh> old)
```

Reusing the exact label name and comment format means an issue locked by
`/enrich` is transparently visible to `/enrich-phased`'s detection logic and
vice versa — no extra bridging code, no second label. This is the key
property that makes the two commands consistent with each other without
either needing to know the other exists beyond sharing a marker format.

### Staleness threshold: 24 hours, shared with `/enrich`

`/enrich-phased` exists specifically for topics large enough to span multiple
`/clear`'d sessions — a legitimate gap between Phase `spec` finishing and
Phase `plan` resuming could be hours or span into the next day. `/enrich`'s
original 4h threshold assumed a single continuous sitting and would let a
second session steal an actively-in-progress phased run's lock during an
ordinary pause.

The lock comment records a timestamp but not which command acquired it, so
the two commands can't each apply their own threshold to a lock they didn't
set — whichever command reads the lock must use the same number the
acquiring command used, or cross-command detection only holds in one
direction. Rather than track ownership (more mechanism, more surface for the
next review round), this spec raises `/enrich`'s own threshold to 24 hours
to match, backported into `commands/enrich.md` and
`docs/superpowers/specs/2026-08-04-enrich-lock-design.md` alongside this
feature. 24 hours absorbs a normal overnight gap for `/enrich-phased` while
still recovering a genuinely abandoned single-sitting `/enrich` run within a
day.

### Where the lock lives in the phase flow

All detect/acquire/release logic lives in **Phase `spec`** — the only point
in the phased flow equivalent to `/enrich`'s Step 1.5/2.5, and specifically
only on a **new run** (an issue number passed as an argument), never on a
state-file resume:

- A resume (`/enrich-phased` invoked with no argument, continuing from
  `.claude/enrich-phased.state`) is the *same* run continuing, not a second
  session — re-running detection there would be a spurious self-collision
  check against a lock the same run itself is holding.
- Phase `plan` and Phase `issue` do not re-verify the lock at all. This
  trusts that once Phase `spec` acquires it, it remains held until Phase
  `issue` releases it — the same trust model `/enrich` uses between its own
  Step 2.5 and Step 6, just stretched across `/clear` boundaries instead of
  within one context. No re-verification keeps the phase transitions simple
  and avoids adding a failure mode (e.g. "lock mysteriously missing at Phase
  `plan`, now what?") that the design doesn't have an answer for and that a
  legitimate run wouldn't hit anyway (nothing else touches this label absent
  another `/enrich`/`/enrich-phased` run or the 24h staleness path, and if a
  competing run *did* take over, that's exactly the race path already
  handled).

Concretely, within Phase `spec`'s existing steps
(`commands/enrich-phased.md`'s "Phase `spec`" section):

1. **New step, immediately after step 1** (read issue) **and gated on this
   being a new run** (issue number passed as an argument, not a resume):
   detect an existing lock exactly as `/enrich`'s Step 1.5 does, but using
   the 24h threshold. No `enrichment-ongoing` label → continue. Label
   present, comment found, age < 24h → hard stop, tell the user, do not
   start this run at all. Age ≥ 24h or no matching comment → offer takeover;
   no → stop; yes → continue, noting the takeover for the acquisition step
   below.
2. **New step, between the existing readiness-assessment step and the
   brainstorming-invocation step, gated on the same "new run" condition as
   the detection step**: acquire the lock — comment first (fresh-acquisition
   or takeover wording), then the label — then re-fetch comments and check
   for a competing lock comment that wasn't present during detection and has
   an earlier timestamp. If one exists, stand down (post a `🔓 … lost race …`
   comment, leave the label in place since the winner depends on it), tell
   the user, and end the command without starting brainstorming. Otherwise
   the lock is held — write the state file here (see *The state file is
   written only once the lock is held*) and continue to brainstorming as
   today.
3. **Releasing early**: if the run ends before Phase `issue` because the
   user declines brainstorming's approval gate within Phase `spec`, release
   the lock *and* delete the state file before stopping — that run is over,
   not paused. This is the only early release; see *Phase `plan`'s push
   failure does not release the lock* for the case deliberately left out.

**Phase `issue`**'s existing label-clearing step (which already removes
`needs-enrichment` / `❓ to-be-defined`) also removes `enrichment-ongoing`
there — the final release, matching `/enrich`'s Step 6. The readiness labels
clear **before** the lock, so a failing lock release can never be what leaves
the issue carrying `needs-enrichment` / `❓ to-be-defined`, which
`/gh:implement` treats as a hard stop regardless of body content.

Mirrored identically in the Forgejo section of `commands/enrich-phased.md`,
using the same `tea labels create` / read-filter-PUT pattern `/enrich`'s
Forgejo section and `/enrich-phased`'s existing Phase `issue` label-clearing
step already use.

### Both new steps are gated on "this is a new run"

Detection *and* acquisition carry the identical gate: an issue number was
passed as this invocation's argument. Gating only detection is a trap.
`phase=spec` remains the current phase for the whole of the brainstorming
step — the long, interactive, approval-gated one — so a session interrupted
there and resumed with no argument re-enters Phase `spec`, correctly skips
detection, and would then run acquisition a second time. It would post a
second lock comment, and the race re-check would find its *own* earlier
comment (with no detection pass this time, there's no baseline of
pre-existing comments to exclude it), conclude it lost the race to itself,
and dead-end. Permanently: every later resume repeats it, and starting fresh
with the issue number instead hard-stops on the run's own lock until the 24h
window expires.

On a resume both steps are skipped and the phase continues at brainstorming.
The lock is already held from the original acquisition — there is nothing to
redo.

### The state file is written only once the lock is held

`/enrich-phased`'s "On invocation" step originally wrote `issue=<N>` and
`phase=spec` to the state file the moment an issue argument was seen —
before Phase `spec`, and therefore before any lock check, ever runs. That
makes every "stop without starting" path above unreachable in effect: the
file already says `phase=spec`, and the documented resume gesture
(`/enrich-phased` with no argument) skips detection by design, so the next
resume walks straight into brainstorming on an issue another session holds a
fresh lock on — precisely the bypass this feature exists to prevent.

So a new run carries the issue number through the invocation *without*
touching the state file, and the acquisition step writes `issue=` and
`phase=spec` only after the race re-check confirms the lock is held. All
three stop paths — detection hard-stop, takeover declined, lost race — then
leave no state file behind, and there is nothing to resume into. The
*Between phases* protocol is unaffected: by the time it updates the file for
the next phase, the acquisition step has created it.

### Phase `plan`'s push failure does not release the lock

`/enrich` releases the lock when its push verification fails, because there
the command is simply over. `/enrich-phased` is a resumable state machine:
the documented recovery from a failed push is to fix it and resume with no
argument. Since a resume skips acquisition (above), releasing on push
failure would leave the remainder of the run — Phase `plan`, Phase `issue` —
holding no lock at all, free for a second session to acquire and enrich the
same issue concurrently. So Phase `plan` is left exactly as it was; the 24h
staleness window is the right backstop for a genuinely abandoned run.

### Release failures are surfaced, not swallowed

`--remove-label … 2>/dev/null || true` is the right pattern for
`needs-enrichment` / `❓ to-be-defined`, which a repo may legitimately not
define at all. It is the wrong pattern for `enrichment-ongoing`: this run
applied that label itself, so a failed removal is a real failure, and
swallowing it leaves the lock held for the full 24h with nobody behind it
and no signal to the user. Every `enrichment-ongoing` release therefore
checks its exit code and, on failure, tells the user the lock is still held
and names the command to run by hand.

The Forgejo read-modify-PUT releases need one more guard. If the
`tea api … | jq -r '[.labels[].name]'` read fails or comes back empty, the
computed label set is empty and the following `PUT` wipes *every* label on
the issue — `ai-implement`, `needs-enrichment`, milestone conventions, the
lot. Each such snippet asserts the read produced a non-empty, non-`null`
array before computing the new set and issuing the `PUT`.

### Crash recovery

Same model as `/enrich`: if a run dies (crash, abandoned session, user never
resumes) after acquiring the lock but before Phase `issue` releases it, the
label simply persists until a later run — same or different session — finds
it past the 24h threshold and offers takeover. No explicit crash-cleanup
step; staleness expiry is the entire recovery mechanism, same accepted
tradeoff as `/enrich`'s design.

## Testing / verification

`/enrich-phased` is a markdown-instruction command with no automated test
suite, same as `/enrich`. Verification is a manual dry run against a scratch
issue:

1. Pre-apply `enrichment-ongoing` + a fresh lock comment on a test issue.
   Run `/enrich-phased <issue>` (new run). Confirm it hard-stops in Phase
   `spec`'s new detection step, before readiness assessment or
   brainstorming, and never writes `.claude/enrich-phased.state`.
2. Backdate the lock comment past 24h. Re-run `/enrich-phased <issue>`.
   Confirm the stale/takeover prompt fires; "no" stops, "yes" proceeds.
3. Run `/enrich-phased <issue>` end-to-end on an unlocked issue across all
   three phases (with the `/clear` boundaries). Confirm the label and lock
   comment appear before brainstorming starts in Phase `spec`, persist
   through Phase `plan` untouched, and the label (not the comment) is gone
   after Phase `issue` completes.
4. Cross-command check: lock an issue via `/enrich` (Step 2.5), then run
   `/enrich-phased` on the same issue. Confirm Phase `spec`'s new detection
   step correctly sees `/enrich`'s lock and hard-stops. Repeat in reverse
   (lock via `/enrich-phased`, then run `/enrich`) to confirm `/enrich`'s
   existing Step 1.5 sees it too.
5. Resume check: start a run, let it stop at the Phase `spec` → `plan`
   boundary (normal handoff), `/clear`, resume with no argument. Confirm
   Phase `plan` does **not** re-run the detection step (no lock-related
   output) and simply proceeds.
6. Mid-phase resume check: start a run on an unlocked issue, let the
   acquisition step post the lock comment, then interrupt during (or just
   after) brainstorming — before the Phase `spec` → `plan` boundary —
   `/clear`, and resume with no argument. Confirm it goes straight to
   continuing/finishing brainstorming: neither the detection step nor the
   acquisition step re-runs, and **no second `🔒 Enrichment lock …` comment
   is posted** (a second one would make the race re-check find the run's own
   earlier lock and dead-end the run permanently).
7. Abandoned-resume release check: start a run, let it acquire the lock, then
   resume (with no argument) after the issue has since been closed, labeled
   `ai-implement`, or `🧊 parked` by someone else. Confirm step 1's early exit
   releases `enrichment-ongoing` before stopping — check the label is gone
   afterward. Repeat by making the issue "already complete" instead (so
   step 3's early exit fires) and confirm the same release happens there.

## Follow-ups (out of scope here)

- None currently identified beyond what #229's own spec already tracks.
