# Attempt Cap — Exclude Non-Starts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop `check-attempt-cap.sh` counting a run that never reached the agent as an attempt at the work, without letting a broken credential re-dispatch forever.

**Architecture:** One script changes. `prior_attempts` splits into `attempts` and `non_starts` by parsing Turns and Cost out of each `## ai-implement run` comment. Non-starts get their own higher ceiling and their own park message, because the remedy for "the runner is broken" is not the remedy for "the plan keeps failing".

**Tech Stack:** Bash 5 (`set -euo pipefail`, `IFS=$'\n\t'`), `jq`, `gh` CLI, fixture-driven Layer-1 tests via the existing `ISSUE_COMMENTS_JSON` seam, `shellcheck`.

**Spec:** `docs/superpowers/specs/2026-09-23-attempt-cap-nonstarts-design.md`

## Global Constraints

- `set -euo pipefail` + `IFS=$'\n\t'` prelude; quote every expansion; `[[ ... ]]`; `printf` over `echo`; no `eval`.
- **A non-start is `turns == 0` AND `cost == 0`.** Either alone is a real attempt.
- **Fail closed.** Use `capture` without `// 0` fallbacks: a report is a non-start only when **both captures succeed and both yield 0**. A report missing either field, or whose format has drifted, counts as a real attempt. `ai-stats.sh` defaults missing fields to 0 because it aggregates; copying that here would make a malformed report excuse itself.
- Defaults: `MAX_ATTEMPTS=2` (unchanged), `MAX_NON_STARTS=5` (new). Both env-overridable.
- The **attempts** ceiling is evaluated first when both are exceeded.
- `attempt=<N>` means the attempt number *at the work* — real attempts only.
- Layer-1 tests are hermetic: no network, no GitHub. The `ISSUE_COMMENTS_JSON` seam already provides this.
- Existing `check-attempt-cap` tests must pass **unmodified**.
- Conventional Commits; scope `pipeline`.

---

### Task 1: Split the count, add the non-start ceiling

**Files:**
- Modify: `scripts/check-attempt-cap.sh` — header env docs (~`:20-30`), the count at `:75-77`, the emit/decide block at `:79-93`, the park body at `:98-108`
- Modify: `tests/run-script-tests.sh` — the `check-attempt-cap` section beginning at `:3311`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `check-attempt-cap.sh` emits `proceed`, `attempt`, `max-attempts` (all unchanged in meaning except that `attempt` now counts real attempts only), plus new `non-starts=<N>` and `max-non-starts=<N>`. Exit codes unchanged.

**Why one task.** The counting split and the ceiling must land together: the split alone removes the only thing stopping an infinitely re-dispatching broken credential. A reviewer cannot sensibly accept one without the other.

- [ ] **Step 1: Confirm the existing guard is green before touching anything**

Run: `bash tests/run-script-tests.sh 2>&1 | grep -c '✓'`
Then: `bash tests/run-script-tests.sh 2>&1 | tail -3`

Expected: the suite passes. Note the pass count — Step 6 compares against it.

**Read `tests/run-script-tests.sh:3322` before you start:**

```bash
run_report='{"body":"## ai-implement run\n\n**Outcome:** :x: failed"}'
```

That fixture has **no Turns and no Cost**. Under the fail-closed predicate both
captures fail, so it stays a real attempt and every existing assertion holds.
If any existing `check-attempt-cap` assertion breaks, you have used `// 0`
fallbacks somewhere — fix the predicate, not the test.

- [ ] **Step 2: Write the failing tests**

Append to `tests/run-script-tests.sh`, immediately after the existing
`check-attempt-cap` section (after its `DRY_RUN` assertions, before the next
`section` line):

```bash
# --- non-starts (#393) ------------------------------------------------------
# A run that reported 0 turns and $0.00 never reached the agent: it executed no
# step of the plan and spent nothing. Counting it as an attempt parked #302
# after a single real attempt, and also spent classify-agent.sh's
# escalate-on-retry on a run that never happened.

real_report='{"body":"## ai-implement run\n\n**Outcome:** :x: failed\n**Duration:** 11m 26s · **Turns:** 104 / cap 120 · **Cost:** $7.28"}'
nonstart_report='{"body":"## ai-implement run\n\n**Outcome:** :x: failed\n**Duration:** 0s · **Turns:** 0 / cap 120 · **Cost:** $0.00"}'
turns_only='{"body":"## ai-implement run\n\n**Outcome:** :x: failed\n**Duration:** 2m · **Turns:** 5 / cap 120 · **Cost:** $0.00"}'
cost_only='{"body":"## ai-implement run\n\n**Outcome:** :x: failed\n**Duration:** 2m · **Turns:** 0 / cap 120 · **Cost:** $1.20"}'

# Two non-starts plus one real attempt is ONE attempt at the work.
out="$(cap_run env ISSUE_NUMBER=42 REPO=o/r \
        ISSUE_COMMENTS_JSON="[$nonstart_report,$real_report,$nonstart_report]")"
assert_contains "$out" 'proceed=true'   "non-starts do not consume attempts"
assert_contains "$out" 'attempt=2'      "attempt counts only runs that ran"
assert_contains "$out" 'non-starts=2'   "non-starts are reported separately"

# Two real attempts still park, exactly as before.
out="$(cap_run env ISSUE_NUMBER=42 REPO=o/r \
        ISSUE_COMMENTS_JSON="[$real_report,$real_report]")"
assert_contains "$out" 'proceed=false'  "two real attempts → park"

# Half-zero is not a non-start: the run did something.
out="$(cap_run env ISSUE_NUMBER=42 REPO=o/r \
        ISSUE_COMMENTS_JSON="[$turns_only,$turns_only]")"
assert_contains "$out" 'proceed=false'  "turns>0 with zero cost counts as a real attempt"

out="$(cap_run env ISSUE_NUMBER=42 REPO=o/r \
        ISSUE_COMMENTS_JSON="[$cost_only,$cost_only]")"
assert_contains "$out" 'proceed=false'  "cost>0 with zero turns counts as a real attempt"

# Fail closed: a report whose fields cannot be parsed is a real attempt.
unparseable='{"body":"## ai-implement run\n\n**Outcome:** :x: failed"}'
out="$(cap_run env ISSUE_NUMBER=42 REPO=o/r \
        ISSUE_COMMENTS_JSON="[$unparseable,$unparseable]")"
assert_contains "$out" 'proceed=false'  "unparseable report counts as a real attempt"
assert_contains "$out" 'non-starts=0'   "unparseable report is not a non-start"

# The non-start ceiling still stops a broken credential looping forever.
five_nonstarts="[$nonstart_report,$nonstart_report,$nonstart_report,$nonstart_report,$nonstart_report]"
out="$(cap_run env ISSUE_NUMBER=42 REPO=o/r ISSUE_COMMENTS_JSON="$five_nonstarts")"
assert_contains "$out" 'proceed=false'      "five non-starts → park"
assert_contains "$out" 'non-starts=5'       "five non-starts → reported"
assert_contains "$out" 'max-non-starts=5'   "the non-start ceiling is reported"
assert_contains "$out" 'issue comment'      "non-start park → explains itself"

# Four non-starts is still under the ceiling.
four_nonstarts="[$nonstart_report,$nonstart_report,$nonstart_report,$nonstart_report]"
out="$(cap_run env ISSUE_NUMBER=42 REPO=o/r ISSUE_COMMENTS_JSON="$four_nonstarts")"
assert_contains "$out" 'proceed=true'   "four non-starts → still under the ceiling"
assert_contains "$out" 'attempt=1'      "non-starts never advance the attempt number"

# MAX_NON_STARTS is configurable, like MAX_ATTEMPTS.
out="$(cap_run env ISSUE_NUMBER=42 REPO=o/r MAX_NON_STARTS=2 \
        ISSUE_COMMENTS_JSON="[$nonstart_report,$nonstart_report]")"
assert_contains "$out" 'proceed=false'      "a lowered MAX_NON_STARTS parks sooner"
assert_contains "$out" 'max-non-starts=2'   "reports the configured non-start ceiling"

# DRY_RUN decides without writing, on the non-start path too.
out="$(cap_run env ISSUE_NUMBER=42 REPO=o/r DRY_RUN=1 ISSUE_COMMENTS_JSON="$five_nonstarts")"
assert_contains "$out" 'proceed=false'   "DRY_RUN decides on the non-start ceiling"
assert_not_contains "$out" 'issue edit'  "DRY_RUN makes no label writes on the non-start path"
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `bash tests/run-script-tests.sh 2>&1 | grep -A2 '✗' | head -20`
Expected: FAIL — `non-starts=` appears nowhere, and non-start reports are still
counted as attempts.

- [ ] **Step 4: Write the implementation**

**4a.** Document the new env var. In the header's optional-environment block,
directly below the `MAX_ATTEMPTS` entry:

```bash
#   MAX_NON_STARTS     Non-start reports tolerated before parking. Default 5.
#                      A non-start is a run report stating 0 turns AND $0.00 —
#                      it never reached the agent, so it is not an attempt at
#                      the work (#393). They still need a ceiling: a missing or
#                      invalid credential produces them indefinitely.
```

And extend the Output block:

```bash
#   proceed=true|false
#   attempt=<N>            the attempt this run would be (1-based), counting
#                          only runs that actually ran
#   max-attempts=<N>
#   non-starts=<N>         prior reports that never reached the agent
#   max-non-starts=<N>
```

**4b.** Add the default beside `MAX_ATTEMPTS`:

```bash
MAX_NON_STARTS="${MAX_NON_STARTS:-5}"
```

**4c.** Replace the count at `:75-77`. This `jq` was verified against all four
report shapes before the plan was written — `104 turns/$7.28` → attempt,
`0/$0.00` → non-start, `5 turns/$0.00` → attempt, and a bare report with
neither field → attempt:

```bash
# Split prior run reports by whether the run actually ran. A report stating
# 0 turns AND $0.00 never reached the agent — it executed no step of the plan
# and spent nothing, so it is not evidence about the plan (#393).
#
# Fail closed: `capture` yields no output when the pattern does not match, so a
# report missing either field — or whose format has drifted — falls through to
# the real-attempt count. ai-stats.sh defaults these to 0 because it aggregates;
# doing that here would let a malformed report excuse itself.
count_reports() {
  comments_json | jq --argjson want_nonstart "$1" '
    def nonstart:
      ( [ (.body | capture("Turns:\\*\\* (?<t>[0-9]+)") | .t | tonumber) ] ) as $t
      | ( [ (.body | capture("Cost:\\*\\* \\$(?<c>[0-9.]+)") | .c | tonumber) ] ) as $c
      | ( ($t | length) == 1 and ($c | length) == 1
          and $t[0] == 0 and $c[0] == 0 );
    [ .[]
      | select(.body | startswith("## ai-implement run"))
      | select((nonstart) == ($want_nonstart | . == 1)) ]
    | length' 2>/dev/null || printf 0
}

prior_attempts="$(count_reports 0)"
non_starts="$(count_reports 1)"
attempt=$(( prior_attempts + 1 ))
```

**4d.** Replace the emit/decide block at `:79-93`:

```bash
emit attempt        "$attempt"
emit max-attempts   "$MAX_ATTEMPTS"
emit non-starts     "$non_starts"
emit max-non-starts "$MAX_NON_STARTS"

# Attempts first: an issue that has hit both ceilings is more usefully
# described as failing at the work than as failing to start.
park_reason=''
if (( prior_attempts >= MAX_ATTEMPTS )); then
  park_reason=attempts
elif (( non_starts >= MAX_NON_STARTS )); then
  park_reason=non-starts
fi

if [[ -z "$park_reason" ]]; then
  emit proceed true
  printf 'attempt %d of %d (%d non-start(s) ignored) — proceeding\n' \
    "$attempt" "$MAX_ATTEMPTS" "$non_starts"
  exit 0
fi
```

**4e.** Replace the park block's header and body (`:95-108`). The existing
`printf` and `park_body` become reason-dependent:

```bash
emit proceed false

if [[ "$park_reason" == attempts ]]; then
  printf 'attempt cap reached (%d prior attempts, max %d) — parking issue #%s\n' \
    "$prior_attempts" "$MAX_ATTEMPTS" "$ISSUE_NUMBER"
else
  printf 'non-start cap reached (%d non-starts, max %d) — parking issue #%s\n' \
    "$non_starts" "$MAX_NON_STARTS" "$ISSUE_NUMBER"
fi

if [[ "$DRY_RUN" == "1" ]]; then
  exit 0
fi

if [[ "$park_reason" == attempts ]]; then
  park_body="$(cat <<PARK
## ai-implement parked

This issue has been dispatched **${prior_attempts} times** without shipping, which is
the configured cap (\`MAX_ATTEMPTS=${MAX_ATTEMPTS}\`). Further redispatches are not
worth the spend — across the fleet, extra attempts do not improve the odds.

Parked for a human. Unpark it once the underlying problem is addressed — usually the
issue needs re-enrichment (a sharper spec or plan) rather than another run.
PARK
)"
else
  park_body="$(cat <<PARK
## ai-implement parked — the run never started

**${non_starts} dispatches** ended with 0 turns and \$0.00, which is the configured
cap (\`MAX_NON_STARTS=${MAX_NON_STARTS}\`). A run that spends nothing never reached the
agent, so this is not a problem with the issue.

**Do not re-enrich.** The plan was never read. Check, in the order these
actually occur:

1. The credential for the selected agent — \`CLAUDE_CODE_OAUTH_TOKEN\`, or
   \`OPENROUTER_API_KEY\` when the run resolves to opencode.
2. An \`agent:\` override on this issue pointing at an agent whose key is absent.
3. The runner toolchain — see \`docs/RUNNER-REQUIREMENTS.md\`.

The run reports above record which agent and model each attempt resolved to.
PARK
)"
fi
```

The rest of the park block — `gh label create`, `gh issue comment`,
`gh issue edit` — is unchanged and applies to both reasons.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bash tests/run-script-tests.sh 2>&1 | tail -3`
Expected: PASS, with the new assertions green **and** every pre-existing
`check-attempt-cap` assertion still green.

- [ ] **Step 6: Confirm the existing tests were not weakened**

```bash
git diff --stat origin/main -- tests/run-script-tests.sh
```

The diff must be **additions only** inside the `check-attempt-cap` section. If
an existing line changed, the predicate is wrong — revert the test edit and fix
`check-attempt-cap.sh` instead.

- [ ] **Step 7: Lint**

```bash
shellcheck -x -e SC1091 scripts/check-attempt-cap.sh tests/run-script-tests.sh
```

Expected: no findings.

- [ ] **Step 8: Full gate**

```bash
bash tests/run-all.sh
pre-commit run --all-files
```

Expected: every runner green; all hooks pass. Run `pre-commit` locally rather
than discovering `markdownlint` or `typos` findings in CI.

- [ ] **Step 9: Add the changelog entry**

Under `## [Unreleased]` in `CHANGELOG.md`, in the **existing** `### Fixed`
subsection — do not create a second one, `[Unreleased]` already has `Added`,
`Changed`, `Deprecated`, `Removed` and `Fixed`, and a duplicate heading trips
markdownlint MD024:

```markdown
- **pipeline:** the attempt cap no longer counts a run that never started. A
  report stating 0 turns and `$0.00` never reached the agent, so it is not an
  attempt at the work — on #302 one such run consumed half the issue's dispatch
  budget and also spent `classify-agent.sh`'s escalate-on-retry on a run that
  never happened. Non-starts now have their own higher ceiling
  (`MAX_NON_STARTS`, default 5) so a missing credential still parks eventually,
  with a park message naming the credential rather than advising
  re-enrichment (#393).
```

- [ ] **Step 10: Commit**

```bash
git add scripts/check-attempt-cap.sh tests/run-script-tests.sh CHANGELOG.md
git commit -m "fix(pipeline): stop counting runs that never started as attempts

A report stating 0 turns and \$0.00 never reached the agent: it executed no
step of the plan and spent nothing, so it is not evidence about the plan.
On #302 such a run consumed half the issue's dispatch budget and parked it
after a single real attempt, and it also spent classify-agent.sh's
escalate-on-retry on a run that never happened.

Non-starts get their own higher ceiling so a missing credential still parks
eventually, and their own park message: the existing one advises
re-enrichment, which is wrong when the plan was never read.

Fails closed — a report missing Turns or Cost, or whose format has drifted,
counts as a real attempt. The existing fixtures carry neither field, which
is why they pass unmodified.

Closes #393"
```

---

## Verification

```bash
# Non-starts are excluded, half-zeros are not
bash tests/run-script-tests.sh 2>&1 | grep -E 'non-starts do not consume|half|counts as a real attempt'

# The runaway guard exists
bash tests/run-script-tests.sh 2>&1 | grep 'five non-starts'

# Existing tests unmodified — additions only
git diff origin/main -- tests/run-script-tests.sh | grep -c '^-[^-]'   # expect: 0

# Both ceilings reported
grep -n 'max-non-starts\|MAX_NON_STARTS' scripts/check-attempt-cap.sh

# The non-start park message does not advise re-enrichment
grep -A3 'never started' scripts/check-attempt-cap.sh | grep -c 'Do not re-enrich'

# Full gate
bash tests/run-all.sh
pre-commit run --all-files
```
