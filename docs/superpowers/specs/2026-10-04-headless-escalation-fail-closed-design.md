# Headless escalation fails closed

**Issue:** [#458](https://github.com/freaxnx01/agent-workflow/issues/458) (split out of #455)
**Date:** 2026-10-04
**Status:** Approved (interactive enrichment)

## Problem

The auto lane's only brake is `needs-human`: when headless `/enrich` cannot
decide, it applies `needs-human` and the driver withholds `ai-implement`.
#455 (`game-rhyflitzer`, 2026-10-02/03) showed two ways that brake can fail:
the label did not exist, so the one `gh issue edit` that applies it failed
whole; and a headless subagent waited for hours on what was most likely an
unseen permission prompt.

## What is already on `main`

Verified against `7ab913b` before this spec was written. These parts of
#458's original acceptance criteria hold **inside the autopilot lane** and
need no change:

| Original criterion | Already covered by |
|---|---|
| Per-issue wall-clock cap that releases the lock on expiry | `scripts/autopilot.sh:186` wraps every enrich in `timeout "$AUTOPILOT_ENRICH_TIMEOUT"` (default 1800s); exit 124 escalates with `--add-label needs-human --remove-label enrichment-ongoing` in one call (`:199-206`). Tested at `tests/run-autopilot-driver-tests.sh:431`. |
| `needs-human` exists before escalation | `autopilot.sh:335` runs `scripts/ensure-issue-labels.sh` (which creates `needs-human`, `:113`) once per repo before any enrich (#380). |
| No `ai-implement` without a successful escalation | Headless `/enrich` never applies `ai-implement`. Only the driver does, and only on positive evidence: `needs-human` absent, `needs-enrichment` gone, `parked` absent (`autopilot.sh:229-252`), default-closed. |

The #455 incident ran headless `/enrich` from an interactive batch of
subagents — **outside** `autopilot.sh` — so none of the above applied there.

## Constraint that shapes the design

The nested session is `claude --print`. Its exit status is the CLI's, not a
value the model chooses: an instruction in `commands/enrich.md` to "exit
non-zero" cannot change it. The contract between session and driver is
therefore **issue label state**, which is what the driver already reads
(`autopilot.sh:216-227`). Prompt rules reduce how often the session leaves
an ambiguous state; the driver is what makes an ambiguous state fail closed.

## Gaps and design

### G1 — `/enrich --headless` creates `needs-human` before applying it

`commands/enrich.md`'s headless escalation edit (`gh issue edit … --add-label
needs-human --remove-label enrichment-ongoing`) runs with no guarantee the
label exists. Outside the lane — a manual `/enrich --headless`, a subagent
batch, the planned `/enrich-batch` (#453) — nothing creates it.

- Before the escalation edit, the headless block runs
  `gh label create needs-human --color D93F0B --description '<same text as ensure-issue-labels.sh:113>' 2>/dev/null || true`,
  the same idempotent pattern Step 2.5 uses for `enrichment-ongoing`.
- After the edit, the session reads the labels back
  (`gh issue view <n> --json labels`). If `needs-human` is not on the issue,
  it reports the exact error and stops — it does not retry with variations
  and does not continue to any later step.
- Calling `scripts/ensure-issue-labels.sh` from the session was rejected: the
  session runs in the consumer's clone, where that script does not exist.

Color and description must match `ensure-issue-labels.sh`, so a later
pipeline run's `create()` (which keeps an existing label unchanged) and this
path agree on what the label looks like.

### G2 — the driver escalates a session that neither enriched nor escalated

Today, when the session returns 0 with `needs-enrichment` still present and
`needs-human` absent, the driver logs
`skipped (enrich did not complete — needs-enrichment still present)` and
returns (`autopilot.sh:241`). Dispatch is correctly withheld, but nothing
flags a human and `enrichment-ongoing` (set by `/enrich` Step 2.5) may stay
set. The candidate query excludes issues carrying it, so the issue drops out
of the lane silently — `docs/AUTOPILOT.md` "When something is wedged"
documents exactly this.

This is the state G1's failure and G3's stop both leave behind, so it is the
backstop for both.

- That branch escalates the same way the crash branch does: one
  `with_backoff gh issue edit <n> --repo <repo> --add-label needs-human --remove-label enrichment-ongoing`.
- The crash branch's escalation (write + both log variants) is extracted into
  one helper, `escalate_issue <repo> <n> <reason>`, called by both branches,
  so the two cannot drift.
- Log lines, following the crash branch's convention (the reason alone means
  "escalated"; `docs/AUTOPILOT.md`'s table says so):
  - success: `failed (enrich did not complete)`
  - escalation write fails:
    `failed (enrich did not complete); ESCALATION FAILED: needs-human not applied, enrichment-ongoing may still be set`
- The crash branch's existing log text is unchanged.

Rejected alternatives:

- **Release only the lock and let the next run retry.** A poison issue would
  then spend a paid nested session on every run.
- **Leave it and document it.** That is the gap.

### G3 — a never-wait rule for headless mode

`commands/enrich.md`'s headless section forbids prompting but says nothing
about a failed or denied tool call. Add a rule: on any failed or denied call
that the step cannot proceed without —

1. do not retry it with variations,
2. release the `enrichment-ongoing` lock (best effort),
3. state the exact error as the final output and stop.

The rule names the driver's label check (G2) as what makes this fail closed,
and states that the session's exit status is not part of the contract.

### Docs

`docs/AUTOPILOT.md`:

- the log table: replace the `skipped (enrich did not complete …)` row
  (`:121`) with a `failed (enrich did not complete)` row, and widen the
  `ESCALATION FAILED` row from "the crash above" to every escalation;
- "When something is wedged": the stuck-`enrichment-ongoing` bullet now
  applies only when the escalation write itself failed (the `ESCALATION
  FAILED` log line), not to every incomplete enrich.

## Testing

TDD in `tests/run-autopilot-driver-tests.sh`:

- The existing "rc==0 with needs-enrichment still present" case changes
  expectation: from `skipped (…)` and *no* `issue edit` at all, to the
  escalation log line and **exactly one** `issue edit` carrying both
  `--add-label needs-human` and `--remove-label enrichment-ongoing`, and no
  `ai-implement`. This is a deliberate behaviour change specified here, not
  a test bent to pass.
- New case: the same state with the escalation write failing →
  `ESCALATION FAILED` log line, no `ai-implement`.
- The crash and timeout cases still pass unchanged (regression for the
  helper extraction).
- New doc test: in `commands/enrich.md`'s headless section, a
  `gh label create needs-human` line appears before the escalation
  `gh issue edit`, and its color equals the one in
  `scripts/ensure-issue-labels.sh`'s `create needs-human` line.

## Acceptance criteria

- [ ] Headless `/enrich` creates `needs-human` (color/description matching `ensure-issue-labels.sh`) before applying it, and stops with the error if the label is not on the issue afterwards
- [ ] `commands/enrich.md` headless mode states the never-wait rule and that label state, not exit status, is the contract
- [ ] `autopilot.sh` escalates a session that returned without enriching or escalating: `needs-human` added and `enrichment-ongoing` removed in one call, no `ai-implement`
- [ ] A failed escalation write in that branch logs `ESCALATION FAILED`
- [ ] Crash and timeout escalation share one helper; their existing tests pass unchanged
- [ ] A doc test asserts the `needs-human` create precedes the escalation edit and its color matches `ensure-issue-labels.sh`
- [ ] `docs/AUTOPILOT.md` log table and "wedged" section match the new behaviour
- [ ] Full suite, `shellcheck`, `actionlint`, `markdownlint` clean

## Out of scope

The rest of #455 (permission classifier on direct push, `❓ to-be-defined`
noise, sandbox rule constraints, `--comments` text mode, retry on label
calls, shared scratchpad, headless resume) stays there.
