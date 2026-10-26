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
| `out_of_credits` | The provider refuses its own call with HTTP 402 or 403 (status and request host from opencode's `APIError` event — never message text) **and** the budget check confirms it: for a 402 the key limit (`GET /api/v1/key`) or the account balance (`GET /api/v1/credits`) reads exhausted or low (`warn`); for a 403 the key limit reads exhausted | `classify-failure.sh`, or `pipeline-health.yml` when the daily check finds the key already exhausted |

The table of record is [`scripts/lib/pause-reasons.sh`](../scripts/lib/pause-reasons.sh)
— one row per reason. Adding a reason is that row plus a branch in
`classify-failure.sh` and an entry in the implement job's class list.

A provider refusal the budget check does **not** confirm (healthy budget,
unreadable API, no key in the job — and, for a 403, a budget that is only low)
pauses nothing: a 402 is a `rate_limit` and retries after the delay; a 403 is
`api_auth` — no retry, operator ping. Only the opencode path can raise
`out_of_credits`: a Claude result carries no provider request host.

## What happens on a pause

1. **The run reports `## ai-implement paused`.** No status label, so
   `check-attempt-cap.sh` counts it as neither an attempt nor a non-start —
   its counters key on `## ai-implement run`. The previous run's verdict stands.
2. **One alarm issue is raised** — `🚨 Pipeline paused: …`, labelled
   `pipeline-paused`, carrying the key-management link, a link to the paused
   issues, the resume steps and — last, in a fenced block — the error text. A
   second pause in the same repo leaves that issue as it is; a creation that
   loses a race closes itself as a duplicate of the lower-numbered winner.
3. **One ntfy push goes out** — priority `urgent`, tapping it opens the alarm.
4. **Every later dispatch stops at the gate.** `check-pipeline-pause.sh` runs
   before the attempt cap and before either agent step: no agent is invoked, the
   issue keeps its `ai-implement` label, and it gets one notice comment.
5. **Every stopped issue is labelled `ai:paused`** — the run that raised the
   alarm and each dispatch the gate stopped. That label is the paused list. A
   dispatch the gate lets through removes it again. If the label cannot be
   written, the issue is named in the job's step summary and, on a new alarm,
   in the alarm itself — re-dispatch that one by hand.

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

The script re-dispatches the **open issues labelled `ai:paused`**. For each one
it removes the label **first** and dispatches second, so an issue that is in
flight is never still on the list a later resume reads (#536). If the label
cannot be removed, the issue is not dispatched this time and the script says
so — run it again. If the dispatch fails, the label is put back, so running the
script again retries it; if even that fails, the script names the issue so it
can be re-dispatched by hand. One that lost its `ai-implement` label in the
meantime is not dispatched and only loses `ai:paused`. Closing the alarm by
hand first is fine — the script still finds the labelled issues. Nothing is
dispatched with `-f attempt=`, so each one runs as attempt 1 on the default
agent — a paused run did no work, and nothing was learned that would justify
escalating the next one.

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

## Trust boundary

The error text in the alarm comes from the agent's run and is **untrusted**.
Two rules keep it from steering the pipeline (#521, ADR-019):

- **It is shown, never read.** It appears once, in the fenced block that ends
  the alarm body. The paused list is the `ai:paused` label, not text; nothing
  is parsed out of the alarm except the reason id, and that is accepted only
  when it is a known reason.
- **It cannot pause a repo.** `out_of_credits` needs the provider's own HTTP
  status on the provider's own host, and then the budget's own state: for a
  402 the key limit or account balance exhausted or low, for a 403 the key
  limit exhausted.

Both rules guard against **text**. They do not stop the agent itself: it runs
as the same user as these steps and can write to their input files and
scripts. That gap is tracked in #535.

An alarm raised before this change lists its issues only in its body. The
resume no longer reads that list: add `ai:paused` to those issues by hand
before running `pipeline-resume.sh`, or re-dispatch them by hand.
