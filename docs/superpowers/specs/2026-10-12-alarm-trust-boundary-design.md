# Pipeline alarm trust boundary — design

**Issue:** #521 (follow-up to #517 / PR #520) · **Date:** 2026-10-12 · **Status:** approved (headless/quick)

**Landing order.** Lands after #518: both change scripts/classify-failure.sh; rebase on it. #518 adds a `model_not_found` class (matched before rate_limit/api_auth/transient) and removes the 0-turn `model not found` → transient branch; keep that branch order intact.

**Amended 2026-10-14** with the maintainer's answers C3 and C4 (key-check confirmation, 403 handling) and the landing order above, and again with C5 (a 403 needs `exhausted`; replaces A11).

## Problem

The security review of PR #520 left two trust-boundary bugs in the pause path.

1. **The paused-issues list is state stored inside text an attacker can reach.**
   `pipeline-pause.sh` writes the agent's error text into the alarm body and
   keeps the list of paused issues in the same body, between
   `<!-- paused-issues -->` markers (`scripts/pipeline-pause.sh:72-73,172`).
   `pipeline-resume.sh` reads that block back and dispatches every `#<n>` in it
   (`scripts/pipeline-resume.sh:64-68`). The only defence is a string strip
   (`scripts/pipeline-pause.sh:105-107`), and the body is also rewritten in
   place with `sed` on every later pause (`scripts/pipeline-pause.sh:202-204`).
   A second untrusted value reaches the body *outside* the code fence: the
   "key management" link is cut out of the error text
   (`scripts/pipeline-pause.sh:118-120`).
2. **`out_of_credits` is decided from text.** `classify-failure.sh:58` pauses a
   whole repo when `.api_error` matches a phrase, or when `.api_error_status`
   is 402. `.api_error` is every error event's *message*
   (`scripts/adapt-opencode-result.sh:114-116`) and the status is taken from
   any error event, whatever raised it (`scripts/adapt-opencode-result.sh:117`).
   A message can carry words an issue author or a tool output put there.

Impact today is low to medium (a dispatch needs a maintainer's label; the worst
case is a pause plus a push), but this is shared infrastructure for every
consumer.

## Design

### 1. The paused list is a label, not text

Each issue a pause stops gets the label **`ai:paused`**. That set of open
issues *is* the paused list. Nothing is parsed out of any issue body or
comment, and only the pipeline's token and people with triage rights can set a
label.

- New `scripts/lib/paused-issues.sh` owns the label name and three operations:
  `paused_issue_mark <n>` (creates the label if missing, then adds it),
  `paused_issue_clear <n>`, `paused_issues_open` (JSON from
  `gh issue list --label ai:paused --state open --json number,labels`).
- `pipeline-pause.sh` marks `$ISSUE_NUMBER` and no longer edits an existing
  alarm at all.
- `check-pipeline-pause.sh` marks the issue of every dispatch it stops, and
  clears the label when a dispatch proceeds.
- `pipeline-resume.sh` closes the open alarms, then lists the labelled issues.
  One that still carries `ai-implement` is re-dispatched as attempt 1 and loses
  `ai:paused`; one that lost `ai-implement` only loses `ai:paused`; one whose
  dispatch fails keeps `ai:paused`, so running the script again retries it. It
  also resumes when the operator already closed the alarm by hand.
- `ensure-issue-labels.sh` seeds `ai:paused`.

### 2. The alarm body is display-only

The body is built from trusted values only (repo, reason table, fixed URLs),
with one exception: the error text, rendered in a single fenced block that is
the **last** thing in the body. Backticks are removed from it (the only
characters that can close the fence), keys are redacted and it is truncated, as
today. The paused issues appear as a search link for the label, and the key
management link is the fixed `https://openrouter.ai/settings/keys`.

The one remaining reader of the alarm body is the gate's cosmetic reason lookup
(`scripts/check-pipeline-pause.sh:96-97`). Its result is now accepted only when
it is a known reason id in `scripts/lib/pause-reasons.sh`; anything else falls
back to "see the alarm".

### 3. `out_of_credits` needs provider evidence and a confirmation

Two conditions, both required:

1. **Provider-call evidence, structural only.** `adapt-opencode-result.sh`
   emits `api_error_status` and a new `api_error_host` from the first error
   event whose name is `APIError` and whose `statusCode` is a number. The host
   is the authority of `error.data.metadata.url`, accepted only for `https://`.
   `classify-failure.sh` treats a run as a *candidate* when the host is exactly
   `openrouter.ai` and the status is 402 or 403. No message text is read.
2. **The budget's own state.** For a candidate, `classify-failure.sh` runs
   `check-openrouter-budget.sh`, which reads the key limit (`GET /api/v1/key`)
   and, when the key may, the account balance (`GET /api/v1/credits`). The
   threshold depends on the status. A **402** is confirmed by verdict
   `exhausted` or `warn`, on either budget (C3). A **403** is confirmed by
   `exhausted` only — the key limit truly used up, OpenRouter's monthly
   key-limit 403 (C5); the account balance never reads `exhausted`
   (`scripts/check-openrouter-budget.sh:101-104`), so only the key can confirm
   a 403. Confirmed gives `out_of_credits`. Anything else — no key in the
   environment, an unreachable API, `ok`, `unknown`, or `warn` for a 403 —
   does not confirm: an unconfirmed **402** is `rate_limit` and retries after
   the delay (C2); an unconfirmed **403** is `api_auth`, no retry, operator
   ping, as before #517 (C4).

The implement job passes `OPENROUTER_API_KEY` to the `Classify failure` step.
`.api_error` stays in the result as display text for the alarm.

### 4. Tests

Layer-1, in `tests/run-pipeline-alarm-tests.sh`, with crafted payloads: marker
blocks, fence breakers, a forged reason id and a forged link in the error text;
a forged marker block in an alarm body; forged error events (wrong event name,
wrong host, userinfo host trick, text-only) against an exhausted key; a real
provider 402 and 403 against an exhausted key, a low key, a key with no limit
over an empty or a healthy account, a healthy key, an unreadable API and no
key — a 403 against a low key stays `api_auth` (C5).
`tests/mocks/gh` gains a generic "first call / later calls" fixture seam,
because the pause script now asks the same question twice.

## Out of scope

- Other forges: the alarm stays GitHub-only (#253).
- The `model_not_found` class and the 0-turn branch in `classify-failure.sh` — #518.
- Cross-repo dedup of alarms (ADR-018).

## Assumptions

- **C1** [confirmed] Paused issues are tracked by a label per issue. Question:
  "Where should the list of paused issues live, so untrusted error text can
  never alter it?" Answer: "Label per issue: each paused issue gets a label
  (e.g. `ai:paused`); resume lists issues by that label. No text is parsed at
  all, and only people with triage rights can set labels. The alarm body
  becomes display-only." The `<!-- paused-issues -->` marker block is no longer
  a source of state for `pipeline-resume.sh`.
- **C2** [confirmed, narrowed to 402 by C4] An unconfirmed provider refusal is `rate_limit`. Question:
  "The provider returns 402/403 on its own call, but `GET /api/v1/key` does not
  confirm the key is exhausted (or is unreachable). No pause — but how is the
  run classified?" Answer: "rate_limit, retry: treat it as a temporary provider
  refusal and retry after the delay, as before #517 (#514). A real exhaustion
  is then confirmed by the key check on the next run and pauses then."
- **C3** [confirmed] The key check confirms on `exhausted` **or** `warn`, from
  the key limit or the account balance. Question: "What counts as the key check
  confirming a 402, so the repo pauses?" Answer: "Exhausted or low: pause when
  the budget check reads `exhausted` or `warn`, on the key limit or the account
  balance. Keeps #517 working for the real case; a forged 402 can then only
  pause a repo whose money is in fact nearly gone." Replaces the former A8
  (`exhausted` only). Both budgets are already in the one verdict
  `check-openrouter-budget.sh` emits (`scripts/check-openrouter-budget.sh:112-116`).
- **C4** [confirmed] An unconfirmed 403 stays `api_auth`. Question: "A provider
  403 that the key check does not confirm: keep the plan's change to
  rate_limit?" Answer: "403 stays api_auth: only an unconfirmed 402 becomes
  rate_limit. An unconfirmed 403 keeps today's behaviour: no retry, operator
  ping." A 403 the key check does confirm (OpenRouter's key-limit 403) is still
  `out_of_credits`; C5 sets that threshold.
- **C5** [confirmed] A 403 is confirmed only by `exhausted`. Question: "Should
  a provider 403 pause the repo under the same rule as a 402 (budget check
  reads exhausted or low)?" Answer: "403 needs exhausted: a 403 pauses only
  when the key is truly used up (OpenRouter's monthly key-limit 403); a 402
  keeps exhausted-or-low. A moderation 403 in a low repo stays api_auth, so
  issue text can no longer trigger a pause." Replaces A11.
- **A1** [high] The label is named `ai:paused`. Rejected: `pipeline-paused-issue`.
  The pipeline's per-issue state labels all use the `ai:` prefix
  (`scripts/ensure-issue-labels.sh:95-98`), and `pipeline-paused` is already
  the alarm issue's own label (`scripts/ensure-issue-labels.sh:112`).
- **A2** [high] The trusted event is named `APIError` and carries the request
  URL at `error.data.metadata.url`. Rejected: matching `AI_APICallError`, the
  name the issue text uses. opencode wraps the AI SDK's `APICallError` before it
  reaches the event stream: at the pinned v1.15.13
  (`scripts/install-opencode.sh:41`), `session/message-v2.ts:46-53` declares
  `APIError` with `statusCode` and `metadata`, `provider/error.ts:208` fills
  `metadata = { url: error.url }`, and `cli/cmd/run.ts:724` emits it as
  `{type:"error", error}`. Read from the opencode source, not from a live run.
- **A3** [high] The alarm body no longer lists paused issues; it links to the
  label search, and an existing alarm is not edited on a later pause. Rejected:
  rendering a display copy of the list. A copy has to be rewritten on every
  pause, which is the read-modify-write that loses an entry under concurrency
  (`docs/ALARMS.md:144-150`) and overwrites the body
  (`scripts/pipeline-pause.sh:202-204`).
- **A4** [high] `pipeline-resume.sh` also resumes when no alarm is open but
  issues carry `ai:paused`. Rejected: exiting "nothing to resume" as today
  (`scripts/pipeline-resume.sh:55-58`). The alarm's own instructions tell the
  operator to close the issue first and run the script second
  (`scripts/pipeline-pause.sh:176-178`).
- **A5** [high] `OPENROUTER_API_KEY` is passed to the `Classify failure` step.
  The issue asks for the `GET /api/v1/key` confirmation, and the same job
  already hands the secret to the agent step
  (`.github/workflows/agent-implement.yml:801`). The key reaches `curl` only
  through `-K -` on stdin (`scripts/check-openrouter-budget.sh:49-52,63-66`).
- **A6** [med] The gate labels every dispatch it stops, not only the run that
  raised the alarm. Rejected: labelling only in `pipeline-pause.sh`. Today a
  gate-stopped issue is told it "is re-dispatched once the pause is cleared"
  (`scripts/check-pipeline-pause.sh:146-148`) but is on no list, so the resume
  never dispatches it (`scripts/pipeline-resume.sh:64-68`).
- **A7** [med] The gate removes `ai:paused` when a dispatch proceeds. Rejected:
  only `pipeline-resume.sh` removes it. An operator who closes the alarm and
  re-dispatches by hand would leave the label behind, and the next resume would
  dispatch that issue again.
- **A8** — withdrawn, replaced by C3.
- **A9** [med] Only the opencode path can produce `out_of_credits`. Rejected:
  keeping the bare `api_error_status == 402` rule for Claude results
  (`scripts/classify-failure.sh:58`). A Claude result has no request host, and
  the reason, title and hint are all about the OpenRouter key
  (`scripts/lib/pause-reasons.sh:25`).
- **A10** [med] The provider host is the constant `openrouter.ai`. Rejected:
  deriving it from `OPENROUTER_API_BASE`
  (`scripts/check-openrouter-budget.sh:47`). No consumer sets another base, and
  an env-derived allowlist is one more thing to get wrong.
- **A11** — withdrawn, replaced by C5.

## Consequences

- A repo whose budget reads `warn` (key below 20 % or $3, or account below
  $10) pauses on any provider 402, while some money is still left. A 403 in
  such a repo is `api_auth`: a moderation 403 an issue author provokes cannot
  pause it. A 403 pauses only once the key limit is used up.
- A key-limit 403 that arrives while the key still reads `warn` (some limit
  left, but not enough for the request) is `api_auth`: an operator ping, not a
  pause. It pauses once the limit reads used up.
- A key with no monthly limit over an empty account is confirmed only when the
  key may read `/credits` (a management key). With a plain inference key the
  account is not checked, so its 402 stays `rate_limit` and retries.
- An unconfirmed 402 now retries (`rate_limit`) and counts as an attempt; an
  unconfirmed 403 (including a 403 in a `warn` repo) is `api_auth` as before
  #517. A 401 is unchanged.
- An alarm raised before this lands lists its issues only in the body. The
  resume no longer reads that list: label those issues `ai:paused` by hand, or
  re-dispatch them by hand.
- Each failed run that is a candidate makes two extra API calls (`/key`,
  `/credits`); each dispatch makes one label write (remove on proceed) or two
  (create and add on a stop).
- The "two pauses at the same moment drop an issue" limitation is gone: adding
  a label is not a read-modify-write.
- A closed issue keeps a stale `ai:paused` label; the resume lists open issues
  only.
- Anyone with triage rights can add `ai:paused` to an issue, which queues it
  for the next resume. They can already add `ai-implement`.
