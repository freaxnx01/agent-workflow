# Pipeline credit/key-limit alarm — design

**Issue:** #517 (folds in #514; mechanism reusable by #518) · **Date:** 2026-10-12 · **Status:** approved (headless/quick)

## Problem

On 2026-10-12 five implement runs in game-rhyflitzer died on
`Key limit exceeded (monthly limit)` (HTTP 403); on 2026-10-11 the same root cause
showed as HTTP 402 `would exceed your available credits`. Both were bucketed
wrongly (`api_auth`, `rate_limit`, or `bug` — `classify-failure.sh:55-77`), burned
runs, counted as attempts, and nobody noticed for ~15 h. An exhausted key is a
pipeline-wide show-stopper, not a per-issue failure.

## Design

### 1. A "pause class" mechanism (reusable by #518)

`scripts/lib/pause-reasons.sh` is the single table of failure classes that
**pause the pipeline instead of failing the issue**. One row per reason:
`class | reason-id | alarm title | operator hint`. v1 has one row, `out_of_credits`.
#518 adds `model_unavailable` by adding a row plus its classifier branch; it needs
no other change. A pause class (a) is never retried, (b) is never an attempt,
(c) never gets `ai:failed`, (d) raises/updates the alarm, (e) pauses new dispatches.

### 2. Recognise: `out_of_credits` in `classify-failure.sh`

Matched **before** `rate_limit` and `api_auth` (first match wins, and the 403 text
contains `403`, the 402 text contains `credits`):
`key limit exceeded`, `exceed(s) your available credits`, `insufficient.credits`,
`add.credits`, `requires more credits`, `payment required`. The `insufficient.credits`
alternative moves out of the `rate_limit` branch (its comment there is rewritten).
Not matched: Claude's own usage-limit text (stays `rate_limit`).

### 3. Never an attempt

`check-attempt-cap.sh` counts comments starting `## ai-implement run`. A run
classified as a pause class posts `## ai-implement paused` instead (same body
fields, no `ai:failed`/`ai:*` status label, issue keeps `ai-implement`). Result:
it is neither an attempt nor a non-start, `ATTEMPT` stays 1 after resume, and
`classify-agent.sh` keeps the default agent. `retry-dispatch.sh` returns `stop`
for pause classes. `classify-agent.sh` itself needs no change (pinned by a test).

### 4. Circuit breaker — the alarm issue is the state

State store = **one open issue labelled `pipeline-paused`** in the affected repo
(issues:write is all the job has; `GITHUB_TOKEN` cannot write repo variables).
`scripts/check-pipeline-pause.sh` runs first in the implement job (before the
attempt cap) and emits `paused=true|false` and `alarm-issue=<n>`. Paused when
either an open `pipeline-paused` issue exists **or** `vars.AGENT_PAUSED` is
non-empty (manual kill switch, settable at org level; read-only for the pipeline).
When paused the agent steps are skipped (`paused != 'true'` added to the Claude
and OpenCode step conditions; every downstream step already keys on a result file
and skips), one dedup'd comment `pipeline paused: <reason>, see #<alarm>` is
posted on the issue, the issue stays queued. Resume = close the alarm issue (or
unset the var), then `scripts/pipeline-resume.sh <repo>` re-dispatches the paused
issues (listed in the alarm body) with `gh workflow run agent.yml -f issue-number=N`.

### 5. Alert

`scripts/pipeline-pause.sh <reason-id>` (called from the implement job when the
class is a pause class): finds the open alarm issue for the reason; if none,
creates it (`🚨 Pipeline paused: <title>`, label `pipeline-paused`, pinned via
`gh issue pin` best-effort) with error text, the key-management link extracted
from the error, resume instructions; if one exists, edits the *paused issues* list
in its body (marker block `<!-- paused-issues -->`) — updated, not duplicated.
Concurrent runs can both create: after creating, the script lists open alarm
issues and, if its own is not the lowest-numbered, closes it as a duplicate and
does **not** push. Exactly the winner pushes one ntfy message.

`scripts/notify-ntfy.sh` publishes via ntfy's JSON API (`POST $NTFY_URL` with
`{topic,title,message,priority,click,tags}` — UTF-8/emoji safe, no header
quoting). Auth `Authorization: Bearer $NTFY_TOKEN` when set. `NTFY_URL` or
`NTFY_TOPIC` empty → skip silently; any curl/HTTP failure → warning on stderr,
exit 0. The token is passed only via a curl config on stdin, never argv or logs.

### 6. Early warning

`scripts/check-openrouter-budget.sh` reads `GET /api/v1/key`
(`data.limit`, `limit_remaining`, `usage_daily`) and, best-effort,
`GET /api/v1/credits` (`data.total_credits - data.total_usage`; HTTP 403 for a
non-management key is tolerated and skipped). Verdict:
`warn` when key `limit` is non-null and (`remaining/limit < 20 %` or
`remaining < $3`), or account remaining `< $10`; `exhausted` when key remaining
`<= 0`; else `ok`. Thresholds are env-tunable (`WARN_KEY_PCT`, `WARN_KEY_USD`,
`WARN_ACCOUNT_USD`). No limit → no key warning. The key never reaches stdout/argv.
`.github/workflows/pipeline-health.yml` runs it daily (reusable via
`workflow_call`, plus `schedule` for agent-workflow itself): `warn` → ntfy
priority `high`; `exhausted` → raises the same alarm as a failed run (pause before
any run dies).

### 7. Every consumer repo

Everything lives in the shared reusable workflow and scripts. Per-repo or per-org
config is only: secrets `OPENROUTER_API_KEY`, `NTFY_TOKEN`; vars `NTFY_URL`,
`NTFY_TOPIC`, optional `AGENT_PAUSED`. `NTFY_TOKEN` is a new optional
`workflow_call` secret; consumers forward it like `OPENROUTER_API_KEY`
(`onboard-consumer.sh` stub emits it; existing consumers use `secrets: inherit` or
add the line — documented). The health check needs a small consumer stub
(`onboard-consumer.sh` emits `pipeline-health.yml`).

### 8. Reachability of ntfy from GitHub-hosted runners (unverified)

`ntfy.home.freaxnx01.ch` points at the home line; GitHub runners may not reach it
(firewall/NAT, or tunnel). Plan includes `pipeline-ntfy-probe` (workflow_dispatch):
publishes a `min`-priority test message and prints the HTTP code. Fallback
documented: a private high-entropy topic on `https://ntfy.sh` (anonymous publish,
no token), set via the same vars. Never fails a run either way.

## Assumptions

- **A1** [high] Pause state is an open labelled alarm issue, not a repo variable.
  Rejected: `AGENT_PAUSED` variable written by the job. `agent-implement.yml:375-396`
  grants `issues: write`/`actions: write` only; `GITHUB_TOKEN` has no variables
  write scope. The variable stays as a read-only manual switch.
- **A2** [high] Paused runs post `## ai-implement paused`, not `## ai-implement run`.
  Rejected: filtering in `check-attempt-cap.sh`. It counts by `startswith("## ai-implement run")`
  (`check-attempt-cap.sh:94`); a different heading excludes the report from attempts
  and non-starts without touching the counter.
- **A3** [high] `out_of_credits` is matched before `rate_limit`/`api_auth`.
  Evidence `classify-failure.sh:55-77` (first-match chain; `403` and `insufficient.credits`
  are already claimed there).
- **A4** [med] No existing test pins `insufficient credits -> rate_limit` (`grep -n insufficient tests/` is empty); the comment at `classify-failure.sh:56-58` is rewritten instead.
- **A5** [med] Resume is a script plus closing the alarm issue, not an automatic
  event. A reusable workflow cannot add triggers to consumers, and auto-resume on
  `issues: closed` would need a new consumer stub. The daily health workflow
  comments "key healthy again — close the alarm to resume" when the key recovers.
- **A6** [med] Alarm/ntfy/health are GitHub-forge only; other forges skip the
  alarm and fail as today (the Forgejo/ADO paths have no `gh`).
- **A7** [med] Several repos sharing one key each raise their own alarm and push
  once. Rejected: cross-repo dedup (needs a shared store).

## Consequences

- Shared-key setups get N alarms/pushes for one root cause.
- After the paused-heading change `/ai-stats` no longer counts paused runs as runs
  (correct: they did no work).
- A stale alarm issue pauses a repo until closed; the pause comment names it.

## Needs maintainer (recommended defaults)

1. ntfy reachability from GitHub runners — run the probe; default: if it fails,
   use ntfy.sh with a private topic.
2. Org-level secrets/vars vs per-repo — default: org-level `NTFY_TOKEN`,
   `NTFY_URL`, `NTFY_TOPIC`, `OPENROUTER_API_KEY`.
3. Whether the pipeline key may read `/credits` (needs a management key) —
   default: skip the account check when 403.
4. Pin the alarm issue (needs a token with that right) — default: best-effort,
   label alone is authoritative.
