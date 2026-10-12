# Pipeline Credit/Key-Limit Alarm — Implementation Plan

> Spec: `docs/superpowers/specs/2026-10-12-pipeline-credit-alarm-design.md` (issue #517).

**Goal:** An exhausted OpenRouter key/credit balance is classified `out_of_credits`, pauses the pipeline (no agent runs, issues stay queued, no attempt counted), raises one alarm issue + one ntfy push per pause, and a daily check warns before the limit is hit. Works for every consumer repo.

**Architecture:** pause-class table (`scripts/lib/pause-reasons.sh`) -> classifier -> `## ai-implement paused` report -> `pipeline-pause.sh` (alarm issue = state) -> `check-pipeline-pause.sh` gate at the top of the implement job. `notify-ntfy.sh` and `check-openrouter-budget.sh` are standalone; `pipeline-health.yml` schedules the latter.

## Global Constraints

- Bash, `set -euo pipefail`, `IFS=$'\n\t'`, header comment per script (match `scripts/check-attempt-cap.sh`). GitHub forge only; other forges skip the alarm.
- Layer-1 tests are hermetic: use `tests/mocks/gh` (`GH_MOCK_LOG`, `GH_MOCK_STDOUT_MAP`) and `tests/mocks/curl` (`CURL_MOCK_FIXTURE`, `CURL_MOCK_LOG`, `CURL_MOCK_BODY_LOG`). New tests go in a new `tests/run-pipeline-alarm-tests.sh` (auto-discovered by `tests/run-all.sh`) copying the helper block (`pass/fail/assert_contains/assert_not_contains/assert_equals`, the `unset` list) from `tests/run-script-tests.sh:20-95`.
- Never print, log or put an API key / `NTFY_TOKEN` on argv. Credentials go to curl via `-K -` config on stdin (see `tests/mocks/curl`). No `set -x`.
- The push must never fail a run: `notify-ntfy.sh` always exits 0.
- Do not implement #518's preflight. `pause-reasons.sh` must make a second reason a one-row addition.
- Run `bash tests/run-all.sh` and `shellcheck scripts/*.sh` (as `just lint`/CI does) after every task. Exact texts under test:
  - `Key limit exceeded (monthly limit). ... $10.09 of $10.00 used; resets 2026-11-01` (HTTP 403)
  - `This request would exceed your available credits` (HTTP 402)
  - `Insufficient credits. Add more using https://openrouter.ai/settings/credits`

### Task 1: Classify `out_of_credits` and stop retrying it

**Files:**
- Create: `scripts/lib/pause-reasons.sh`, `tests/run-pipeline-alarm-tests.sh`
- Modify: `scripts/classify-failure.sh`, `scripts/retry-dispatch.sh`

**Interfaces:**
- Produces: `pause_reason_for_class <class>` (prints reason id, exit 1 if not a pause class), `pause_title <reason>`, `pause_hint <reason>`; class `out_of_credits`; `is_pause_class <class>`.

- [ ] **Step 1: Write the failing tests** (in `tests/run-pipeline-alarm-tests.sh`)

```bash
classify_text() { # <text> -> class
  local f; f="$(mktemp --suffix=.json)"
  jq -n --arg t "$1" '{is_error:true,subtype:"error_during_execution",num_turns:3,result:$t}' > "$f"
  RESULT_FILE="$f" bash "$ROOT/scripts/classify-failure.sh" | sed -n 's/^class=//p'; rm -f "$f"
}
section "classify-failure — out_of_credits"
assert_equals "$(classify_text 'HTTP 403: Key limit exceeded (monthly limit). $10.09 of $10.00 used; resets 2026-11-01')" out_of_credits "403 key limit"
assert_equals "$(classify_text 'API Error 402: This request would exceed your available credits')" out_of_credits "402 credits"
assert_equals "$(classify_text 'Insufficient credits. Add more using https://openrouter.ai/settings/credits')" out_of_credits "insufficient credits"
assert_equals "$(classify_text '429 rate_limit_error: exceed your account rate limit')" rate_limit "plain 429 stays rate_limit"
assert_equals "$(classify_text '401 invalid api key')" api_auth "401 stays api_auth"

section "retry-dispatch — pause class never retries"
out="$(CLASS=out_of_credits ATTEMPT=1 ISSUE_NUMBER=1 REPO=o/r DRY_RUN=1 bash "$ROOT/scripts/retry-dispatch.sh")"
assert_contains "$out" 'decision=stop' "out_of_credits -> stop"
assert_contains "$out" 'delay-seconds=0' "no delay"
```

- [ ] **Step 2:** Run `bash tests/run-pipeline-alarm-tests.sh`; expect FAIL (class is `api_auth`/`rate_limit`).
- [ ] **Step 3: Implement.** `scripts/lib/pause-reasons.sh`:

```bash
#!/usr/bin/env bash
# pause-reasons.sh — failure classes that PAUSE the pipeline instead of failing
# the issue. One row per reason; #518 adds model_unavailable here.
# class|reason-id|alarm title|operator hint
PAUSE_REASONS=(
  'out_of_credits|out_of_credits|OpenRouter key limit / credits exhausted|Top up credits or raise the key limit at https://openrouter.ai/settings/keys, then resume.'
)
_pause_row() { local r; for r in "${PAUSE_REASONS[@]}"; do [[ "${r%%|*}" == "$1" || "$(cut -d'|' -f2 <<<"$r")" == "$1" ]] && { printf '%s' "$r"; return 0; }; done; return 1; }
is_pause_class()     { _pause_row "$1" >/dev/null; }
pause_reason_for_class() { _pause_row "$1" | cut -d'|' -f2; }
pause_title()        { _pause_row "$1" | cut -d'|' -f3; }
pause_hint()         { _pause_row "$1" | cut -d'|' -f4; }
```

In `classify-failure.sh` insert a new first branch after the success branch:
`elif printf '%s' "$result_text" | grep -qiE 'key.limit.exceeded|exceeds? your available credits|insufficient.credits|add.credits|requires more credits|payment.required'; then class=out_of_credits`, remove `insufficient.credits` from the `rate_limit` regex and rewrite its comment, add `out_of_credits` to the header class list. In `retry-dispatch.sh` add `out_of_credits` to the `api_auth|bug` stop arm (comment: pause class, operator action).

- [ ] **Step 4:** Run the tests; expect PASS. `bash tests/run-all.sh` green.
- [ ] **Step 5:** Commit `feat(pipeline): classify out_of_credits and never retry it (#517)`.

### Task 2: A paused run is not an attempt

**Files:**
- Modify: `scripts/post-run-report.sh`, `scripts/lib/ai-stats.sh` (only if it must skip the new heading), `.github/workflows/agent-implement.yml` (pass `FAILURE_CLASS` to `Post run report`)
- Test: `tests/run-pipeline-alarm-tests.sh`

**Interfaces:**
- Consumes: `is_pause_class` (Task 1). Env `FAILURE_CLASS` on `post-run-report.sh`.
- Produces: comment heading `## ai-implement paused` and no `ai:*` status label for pause classes.

- [ ] **Step 1: Write the failing tests.** (a) Render a failed run with `RENDER_ONLY=1 FAILURE_CLASS=out_of_credits RESULT_FILE=<fixture with is_error true>`: output starts with `## ai-implement paused`, does not contain `ai:failed`. (b) With `FAILURE_CLASS` unset the heading is `## ai-implement run` (unchanged). (c) `check-attempt-cap.sh` with `ISSUE_COMMENTS_JSON='[{"body":"## ai-implement paused\n**Turns:** 7 ..."}]' DRY_RUN=1` emits `attempt=1` and `non-starts=0`. (d) `ATTEMPT=1 ... classify-agent.sh` with `ISSUE_LABELS=''` and `DEFAULT_AGENT=opencode` still chooses `opencode` after a paused report (attempt 1 -> no escalation).
- [ ] **Step 2:** Run; expect (a) FAIL, (c)/(d) already pass (they pin the contract).
- [ ] **Step 3: Implement.** In `post-run-report.sh`, source `lib/pause-reasons.sh`; when `is_pause_class "${FAILURE_CLASS:-}"`: heading `## ai-implement paused` (replace line 341's literal via a `HEADING` variable), `STATUS_TEXT="paused: $(pause_title ...)"`, `STATUS_LABEL=''` and skip the label edit when empty (guard the `for stale_label` loop at line 393 and the add-label call). Keep all other body fields so `check-attempt-cap.sh` regexes stay valid. Add `FAILURE_CLASS: ${{ steps.classify_failure.outputs.class }}` to the `Post run report` env.
- [ ] **Step 4:** Run tests + `run-all.sh`; PASS.
- [ ] **Step 5:** Commit `feat(pipeline): paused runs are not attempts (#517)`.

### Task 3: `notify-ntfy.sh`

**Files:**
- Create: `scripts/notify-ntfy.sh`
- Test: `tests/run-pipeline-alarm-tests.sh`

**Interfaces:**
- Produces: `notify-ntfy.sh` reading env `NTFY_URL`, `NTFY_TOPIC`, `NTFY_TOKEN` (optional), `NTFY_TITLE`, `NTFY_MESSAGE`, `NTFY_PRIORITY` (default `default`; `urgent|high|default|low|min`), `NTFY_CLICK`, `NTFY_TAGS`. Always exit 0.

- [ ] **Step 1: Write the failing tests** with `PATH="$MOCKS:$PATH"` (curl mock): (a) no `NTFY_URL` -> exit 0, `CURL_MOCK_LOG` empty/absent; (b) full config -> the logged argv contains `ntfy.home.freaxnx01.ch`, the `-d`/`--data` body (`CURL_MOCK_BODY_LOG` or stdin-capture) parses with `jq` to `topic=pipeline-alerts, priority=5`... use ntfy JSON `priority` ints (urgent=5, high=4, default=3, low=2, min=1); (c) `NTFY_TOKEN=s3cret`: the string `s3cret` appears in no argv line and not in stdout (token only via stdin config); (d) a curl mock failing (`CURL_MOCK_FAIL=1`, add this seam to `tests/mocks/curl`: exit 22) -> script still exits 0 and prints a `warning:` line on stderr.
- [ ] **Step 2:** Run; expect FAIL (script missing).
- [ ] **Step 3: Implement.**

```bash
#!/usr/bin/env bash
# notify-ntfy.sh — publish one ntfy message. Never fails the caller.
set -uo pipefail
IFS=$'\n\t'
: "${NTFY_URL:=}" "${NTFY_TOPIC:=}"
if [[ -z "$NTFY_URL" || -z "$NTFY_TOPIC" ]]; then echo "ntfy: not configured — skipping push"; exit 0; fi
case "${NTFY_PRIORITY:-default}" in urgent) p=5;; high) p=4;; low) p=2;; min) p=1;; *) p=3;; esac
body="$(jq -n --arg t "$NTFY_TOPIC" --arg ti "${NTFY_TITLE:-pipeline}" --arg m "${NTFY_MESSAGE:-}" \
  --arg c "${NTFY_CLICK:-}" --arg tags "${NTFY_TAGS:-}" --argjson p "$p" \
  '{topic:$t,title:$ti,message:$m,priority:$p}
   + (if $c != "" then {click:$c} else {} end)
   + (if $tags != "" then {tags:($tags|split(","))} else {} end)')"
cfg="url = \"${NTFY_URL%/}\"\n"
[[ -n "${NTFY_TOKEN:-}" ]] && cfg+="header = \"Authorization: Bearer ${NTFY_TOKEN}\"\n"
if printf '%b' "$cfg" | curl -sS -f --max-time 10 -K - -X POST -H 'Content-Type: application/json' -d "$body" >/dev/null 2>/tmp/ntfy.err; then
  echo "ntfy: sent '${NTFY_TITLE:-}' to topic ${NTFY_TOPIC}"
else
  echo "warning: ntfy push failed ($(head -c 200 /tmp/ntfy.err)) — continuing" >&2
fi
exit 0
```

(Use `mktemp` for the err file and `trap` cleanup in the real script; the sketch shows intent. Keep the token out of the stderr text.)
- [ ] **Step 4:** PASS; `shellcheck`.
- [ ] **Step 5:** Commit `feat(pipeline): notify-ntfy.sh, a push that never fails the run (#517)`.

### Task 4: `pipeline-pause.sh` — one alarm issue per pause

**Files:**
- Create: `scripts/pipeline-pause.sh`
- Modify: `scripts/ensure-issue-labels.sh` (add label `pipeline-paused`, color `B60205`, description "Pipeline paused — an open issue with this label stops new dispatches"; extend the header comment), `tests/mocks/gh` only if a needed seam is missing
- Test: `tests/run-pipeline-alarm-tests.sh`

**Interfaces:**
- Consumes: `lib/pause-reasons.sh`, `notify-ntfy.sh`. Env: `REASON` (reason id), `REPO`, `ISSUE_NUMBER` (the failed issue, may be empty from the health check), `ERROR_TEXT`, `GH_TOKEN`, `NTFY_*`.
- Produces: stdout/`GITHUB_OUTPUT` `alarm-issue=<n>`, `created=true|false`. Body marker block `<!-- paused-issues -->#12 #34<!-- /paused-issues -->`.

- [ ] **Step 1: Write the failing tests** (gh mock with `GH_MOCK_STDOUT_MAP`): (a) no open `pipeline-paused` issue -> a `gh issue create` call with title containing `Pipeline paused`, label `pipeline-paused`, body containing the error text and `https://openrouter.ai/settings/keys`, and ntfy invoked once (priority `urgent`, `click` = alarm URL); (b) an open alarm exists -> no `issue create`, a `gh issue edit` whose body contains the new issue number in the marker block, no ntfy call; (c) second issue appended without duplicating an already-listed number; (d) race: after create, list shows a lower-numbered alarm -> own issue closed as duplicate, no ntfy; (e) `NTFY_*` unset -> still exits 0; (f) `ERROR_TEXT` containing a `sk-or-v1-...` token is redacted (`sk-or-[A-Za-z0-9_-]+` -> `sk-or-***`) before it is posted.
- [ ] **Step 2:** Run; FAIL.
- [ ] **Step 3: Implement.** Steps in the script: source pause-reasons; redact; `gh issue list --label pipeline-paused --state open --json number,body`; if found -> merge issue number into marker block, `gh issue edit --body-file`; else create (`gh issue create --title "🚨 Pipeline paused: $(pause_title)" --label pipeline-paused --body-file`), then re-list, keep the lowest number (close own with `gh issue close --comment "duplicate of #N"` and exit 0 without pushing), `gh issue pin` best-effort (`|| true`), then `notify-ntfy.sh` with `NTFY_PRIORITY=urgent NTFY_TAGS=rotating_light`, message one line + reason, `NTFY_CLICK` = issue URL. Body sections: error text (fenced), key-management link (extracted with `grep -oE 'https://openrouter\.ai/[^ )"]+' | head -1`, default `https://openrouter.ai/settings/keys`), paused issues list, "How to resume": close this issue, then `bash scripts/pipeline-resume.sh <repo>` (Task 6) or the `pipeline-resume` dispatch.
- [ ] **Step 4:** PASS; `shellcheck`.
- [ ] **Step 5:** Commit `feat(pipeline): alarm issue and ntfy push on pipeline pause (#517)`.

### Task 5: Gate new dispatches and wire the implement job

**Files:**
- Create: `scripts/check-pipeline-pause.sh`
- Modify: `.github/workflows/agent-implement.yml`, `.github/workflows/agent.yml`
- Test: `tests/run-pipeline-alarm-tests.sh`, plus the act suite stub if cheap (`.github/workflows/agent-implement.test.yml`)

**Interfaces:**
- Consumes: Task 4 alarm label. Env: `REPO`, `ISSUE_NUMBER`, `AGENT_PAUSED_VAR` (from `vars.AGENT_PAUSED`).
- Produces: outputs `paused=true|false`, `alarm-issue`, and on pause one dedup'd issue comment `pipeline paused: <reason>, see #<alarm>` (dedup: skip when an identical comment exists).

- [ ] **Step 1: Write the failing tests:** open alarm -> `paused=true`, `alarm-issue=<n>`, one `gh issue comment` call; second run with that comment already in `ISSUE_COMMENTS_JSON` -> no new comment; no alarm and empty var -> `paused=false`, no comment; var `out_of_credits 2026-10-12T01:43Z` with no alarm -> `paused=true`; the issue's `ai-implement` label is never removed (assert no `--remove-label` in the gh log).
- [ ] **Step 2:** FAIL.
- [ ] **Step 3: Implement the script**, then wire the workflow:
  - new step `Check pipeline pause` (id `pause_gate`, `if: ${{ !inputs.stub-claude }}`) right after `Fetch issue context`, before `Check attempt cap`; env `AGENT_PAUSED_VAR: ${{ vars.AGENT_PAUSED }}`.
  - add `&& steps.pause_gate.outputs.paused != 'true'` to the `if:` of `Check attempt cap`, `Run Claude Code`, `Run OpenCode`.
  - new step `Raise pipeline alarm` after `Classify failure`: `if: always() && steps.classify_failure.outputs.class == 'out_of_credits'` (generic: use `contains(fromJSON('["out_of_credits"]'), ...)` so #518 extends one list), `continue-on-error: true`, running `scripts/pipeline-pause.sh` with `REASON`, `ERROR_TEXT=$(jq -r .result "$RESULT_FILE")`, `GH_TOKEN`, `NTFY_URL: ${{ vars.NTFY_URL }}`, `NTFY_TOPIC: ${{ vars.NTFY_TOPIC }}`, `NTFY_TOKEN: ${{ secrets.NTFY_TOKEN }}`.
  - `on.workflow_call.secrets`: add optional `NTFY_TOKEN`.
  - `Fail the job...` step: when the class is a pause class print `::warning::` (pipeline paused) instead of `::error`; keep `exit 1` (run stays red, no `ai:failed`).
  - `agent.yml` (dogfood stub): forward `NTFY_TOKEN`.
- [ ] **Step 4:** PASS; `actionlint`-clean if available (`just lint`); `bash tests/run-all.sh`.
- [ ] **Step 5:** Commit `feat(pipeline): circuit breaker — paused repo skips agent runs (#517)`.

### Task 6: Resume script

**Files:**
- Create: `scripts/pipeline-resume.sh`
- Test: `tests/run-pipeline-alarm-tests.sh`

**Interfaces:**
- Consumes: alarm body marker block (Task 4). Env `REPO`, `CONSUMER_WORKFLOW` (default `agent.yml`), `DRY_RUN`.
- Produces: closes open `pipeline-paused` issue(s) with a resume comment, then `gh workflow run $CONSUMER_WORKFLOW -f issue-number=N` for each listed issue that is still open and still carries `ai-implement` (no `attempt` input -> attempt 1).

- [ ] **Step 1: Failing tests:** alarm body lists `#12 #34`, #34 closed -> exactly one `gh workflow run ... issue-number=12` and no `attempt=` flag; alarm closed with comment; no alarm -> exit 0 with "nothing to resume"; `AGENT_PAUSED` var set -> prints a warning that the variable still pauses.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS.
- [ ] **Step 5:** Commit `feat(pipeline): pipeline-resume re-dispatches paused issues (#517)`.

### Task 7: Early warning — `check-openrouter-budget.sh`

**Files:**
- Create: `scripts/check-openrouter-budget.sh`, `tests/fixtures/openrouter-key-ok.json`, `openrouter-key-low.json`, `openrouter-key-nolimit.json`, `openrouter-credits-low.json`
- Test: `tests/run-pipeline-alarm-tests.sh`

**Interfaces:**
- Consumes: env `OPENROUTER_API_KEY` (required, exit 2 if unset), thresholds `WARN_KEY_PCT=20`, `WARN_KEY_USD=3`, `WARN_ACCOUNT_USD=10`; curl seam `OPENROUTER_API_BASE` (default `https://openrouter.ai/api/v1`).
- Produces: `verdict=ok|warn|exhausted`, `message=<one line>` on stdout and `GITHUB_OUTPUT`.

- [ ] **Step 1: Write the failing tests** using the curl mock with fixtures `{"data":{"limit":10,"limit_remaining":1.5,"usage_daily":0.4}}`: low remaining (15 %) -> `warn`; `limit_remaining` 8 of 10 -> `ok`; `limit: null` -> `ok` (no key warning); `limit_remaining` 0 -> `exhausted`; $2.80 left of $50 -> `warn` (absolute floor); credits fixture `{"data":{"total_credits":100,"total_usage":95}}` -> `warn` (account $5 < $10); credits endpoint HTTP 403 (`CURL_MOCK_FAIL=1` for that call or second fixture) -> tolerated, verdict from key alone; the key string is absent from stdout and the curl argv log.
- [ ] **Step 2:** FAIL. **Step 3: Implement** with `jq` arithmetic (`bc` is not guaranteed on runners): compare `remaining*100 < limit*pct` and `remaining < usd`. Key via `-K -` config on stdin as in Task 3.
- [ ] **Step 4:** PASS. **Step 5:** Commit `feat(pipeline): OpenRouter budget early-warning check (#517)`.

### Task 8: `pipeline-health.yml`, ntfy probe, consumer onboarding

**Files:**
- Create: `.github/workflows/pipeline-health.yml`, `.github/workflows/pipeline-ntfy-probe.yml`
- Modify: `scripts/onboard-consumer.sh` (stub emits `NTFY_TOKEN` forwarding and a `pipeline-health.yml` consumer stub), `tests/run-onboard-stub-tests.sh`

**Interfaces:**
- Consumes: Tasks 3, 4, 7.
- Produces: reusable workflow (`workflow_call`, optional secrets `OPENROUTER_API_KEY`, `NTFY_TOKEN`, input `pipeline-ref`) and the self-hosted schedule `cron: '17 6 * * *'` + `workflow_dispatch`.

- [ ] **Step 1: Write the failing tests** in `run-onboard-stub-tests.sh`: the generated `agent.yml` stub contains `NTFY_TOKEN: ${{ secrets.NTFY_TOKEN }}`; a health stub is generated that `uses: .../pipeline-health.yml@<ref>`.
- [ ] **Step 2:** FAIL. **Step 3: Implement.**
  - `pipeline-health.yml`: checkout scripts (same pattern as agent-implement `Checkout agent-workflow scripts`), run `check-openrouter-budget.sh`; `warn` -> `notify-ntfy.sh` priority `high`, title `OpenRouter budget low (<repo>)`; `exhausted` -> `pipeline-pause.sh` with `REASON=out_of_credits`; `ok` and an open alarm exists and the key is healthy -> comment on the alarm "key healthy again — close this issue to resume". Skip entirely (green) when `OPENROUTER_API_KEY` is empty. `permissions: issues: write, contents: read`. Never echo the key.
  - `pipeline-ntfy-probe.yml`: `workflow_dispatch`; sends a `min`-priority "probe" with `notify-ntfy.sh` and additionally prints `curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$NTFY_URL/v1/health"`; documents the verdict in the step summary (reachable / unreachable -> use ntfy.sh fallback).
- [ ] **Step 4:** PASS; lint.
- [ ] **Step 5:** Commit `feat(pipeline): daily budget health check, ntfy probe, onboarding (#517)`.

### Task 9: Operator docs, ADR, and the live reachability check

**Files:**
- Modify: `docs/CONSUMER-SETUP.md` (secrets/vars table: `NTFY_TOKEN`, `NTFY_URL`, `NTFY_TOPIC`, `AGENT_PAUSED`; health stub; forwarding gotcha), `docs/DECISIONS.md` (ADR-018: alarm issue as pause state; pause-class table; paused heading), `docs/glossary.md` (pause class), `CHANGELOG.md` if the repo keeps one
- Create: `docs/ALARMS.md` (what pauses the pipeline, how to resume, thresholds, ntfy setup incl. user `pipeline` with write access to topic `pipeline-alerts`, fallback to ntfy.sh with a private topic, how #518 adds a reason)

- [ ] **Step 1:** Write docs; a doc test is not needed beyond `just lint` markdown rules.
- [ ] **Step 2: Live check (manual, after merge, not part of CI):** set repo vars/secret on agent-workflow, run `pipeline-ntfy-probe` via `gh workflow run pipeline-ntfy-probe.yml`, record reachable/unreachable in `docs/ALARMS.md`; if unreachable switch `NTFY_URL` to `https://ntfy.sh` with a private topic and note it.
- [ ] **Step 3:** Run `bash tests/run-all.sh` one last time.
- [ ] **Step 4:** Commit `docs(pipeline): alarm operator guide and ADR-018 (#517)`.
