# Pipeline alarms — what pauses the pipeline, and how to resume it

Some failures are not about the issue a run happened to pick up. An exhausted
API key fails *every* dispatch in the repo within minutes of the first. On
2026-10-12 five implement runs in `freaxnx01/game-rhyflitzer` failed that way,
each was graded `bug`, each burned turns, and nobody noticed for 15 hours
(#517).

A **pause class** is a failure class that stops the whole pipeline instead of
failing one issue. It does not retry, does not count as an attempt, and does
not stamp `ai:failed`.

## What pauses the pipeline

| Class | Recognised from | Raised by |
|---|---|---|
| `out_of_credits` | HTTP 403 `Key limit exceeded`, HTTP 402 `would exceed your available credits`, `Insufficient credits. Add more…` | `classify-failure.sh`, or `pipeline-health.yml` when the daily check finds the key already exhausted |

The table of record is [`scripts/lib/pause-reasons.sh`](../scripts/lib/pause-reasons.sh)
— one row per reason. Adding a reason is that row plus a branch in
`classify-failure.sh` and an entry in the implement job's class list.

## What happens on a pause

1. **The run reports `## ai-implement paused`.** No status label, so
   `check-attempt-cap.sh` counts it as neither an attempt nor a non-start —
   its counters key on `## ai-implement run`. The previous run's verdict stands.
2. **One alarm issue is raised** — `🚨 Pipeline paused: …`, labelled
   `pipeline-paused`, carrying the error text, the key-management link, the list
   of paused issues and the resume steps. A second pause in the same repo
   updates that issue instead of opening another; a creation that loses a race
   closes itself as a duplicate of the lower-numbered winner.
3. **One ntfy push goes out** — priority `urgent`, tapping it opens the alarm.
4. **Every later dispatch stops at the gate.** `check-pipeline-pause.sh` runs
   before the attempt cap and before either agent step: no agent is invoked, the
   issue keeps its `ai-implement` label, and it gets one notice comment.

The open alarm issue *is* the pause state — see ADR-018 in
[`DECISIONS.md`](DECISIONS.md). There is no variable to read; closing the issue
clears the pause.

## How to resume

```bash
# 1. Fix the cause: top up credits, or raise the key's monthly limit at
#    https://openrouter.ai/settings/keys

# 2. See what is queued behind the pause (writes nothing)
REPO=<owner>/<repo> DRY_RUN=1 bash scripts/pipeline-resume.sh

# 3. Close the alarm and re-dispatch the paused issues as attempt 1
REPO=<owner>/<repo> bash scripts/pipeline-resume.sh
```

`pipeline-resume.sh` closes the alarm **before** it re-dispatches: a dispatch
sent while the alarm is still open is stopped by the gate.

Issues that were closed or lost their `ai-implement` label in the meantime are
skipped. Nothing is dispatched with `-f attempt=`, so each one runs as attempt 1
on the default agent — a paused run did no work, and nothing was learned that
would justify escalating the next one.

### The manual switch

`AGENT_PAUSED` is a **repo variable an operator sets by hand** to pause a repo
for any reason. While it is non-empty the gate blocks every dispatch. No token
in the pipeline can write repo variables, so nothing here can set or clear it:

```bash
gh variable set    AGENT_PAUSED --repo <owner>/<repo> --body "maintenance 2026-10-12"
gh variable delete AGENT_PAUSED --repo <owner>/<repo>
```

## Early warning

`pipeline-health.yml` runs daily (the consumer owns the cron — a reusable
workflow cannot add a trigger to the repo that calls it) and reads the key's own
state:

| Condition | Verdict | Action |
|---|---|---|
| key remaining < 20 % of its limit **or** < $3 | `warn` | ntfy push, priority `high` |
| account balance < $10 | `warn` | ntfy push, priority `high` |
| key remaining = 0 | `exhausted` | raises the alarm, pausing the repo |
| key has no limit set | `ok` | nothing — an unlimited key has no budget to warn about |
| key healthy while an alarm is open | `ok` | comments "key healthy again" on the alarm |

Two thresholds, because a percentage alone is wrong at both ends: 20 % of a $10
key is $2, and 20 % of a $500 key is $100. Override per consumer with the
`warn-key-pct`, `warn-key-usd` and `warn-account-usd` inputs.

`GET /credits` needs a *management* key. A plain inference key gets HTTP 403,
which is the normal case and is reported as "not checked" — never as "nothing
left".

## ntfy setup

| Name | Kind | Value |
|---|---|---|
| `NTFY_URL` | repo/org **variable** | `https://ntfy.home.freaxnx01.ch` |
| `NTFY_TOPIC` | repo/org **variable** | `pipeline-alerts` |
| `NTFY_TOKEN` | repo/org **secret** | the `pipeline` publisher token (Passbolt: "ntfy – pipeline publisher token (topic pipeline-alerts)") |

The publisher user `pipeline` has write-only access to `pipeline-alerts`, so a
leaked token can publish noise and read nothing.

Missing any of the three → the push is skipped and the alarm issue is still
raised. A failed push never fails a run: `notify-ntfy.sh` always exits 0.

The token reaches `curl` only through a `-K -` config on stdin. Never put it on
argv — argv is world-readable in `/proc` and shows up in `ps`.

### Is the server reachable from GitHub's runners?

The home server is behind a residential line with public DNS, so this has to be
measured rather than assumed:

```bash
gh workflow run pipeline-ntfy-probe.yml --repo freaxnx01/agent-workflow
```

The run's step summary reports the `/v1/health` status and names the verdict.

> **Status: not yet measured.** The probe ships with this change; the live run
> is a post-merge step for the maintainer (the variables and the secret have to
> be set first). Record the result here.

**Fallback if it is unreachable:** set `NTFY_URL` to `https://ntfy.sh` and use
a long, unguessable topic name (`ntfy.sh` has no accounts on the free tier —
the topic name *is* the credential). Keep `NTFY_TOPIC` out of anything public.

## Alarms vs. the other blocked states

Four states, deliberately distinct:

- **`pipeline-paused`** — the repo's pipeline is stopped. Nothing ran.
- **`parked`** — *this issue* hit the attempt cap. Other issues are unaffected.
- **`ai:review-blocked`** — the reviewer ran and refused to promote the PR.
- **`ai:runner-blocked`** — the reviewer never started; runner toolchain unmet.

A stale alarm pauses the repo until it is closed. Every pause notice names the
alarm it is waiting on, so an issue that looks stuck says why in its own thread.

## Known limitation

Two pauses landing at the same moment each read the alarm body, add their issue
to the marker block and write it back. The later write wins, so one paused issue
can be missing from the list. The pause itself still holds, but `pipeline-resume.sh` re-dispatches only the
issues the alarm lists, so a dropped issue must be re-dispatched by hand
(re-apply `ai-implement`). Accepted for now; no code change.
