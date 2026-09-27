# Autopilot Gate — Verify It Gates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the autopilot lane treating "some workflow ran once" as proof that a repo's tests gate a merge.

**Architecture:** `repo_eligible` gains two checks — the gate must have completed a run with `event=pull_request`, and the default branch must have protection with at least one required status check. Both refuse on any API failure rather than reading a failure as absence, and check 2's existing version of that same conflation is fixed alongside.

**Tech Stack:** Bash 5 (`set -euo pipefail`, `IFS=$'\n\t'`), `gh` CLI + `jq`, fixture-driven Layer-1 tests through the `gh` mock's `GH_MOCK_STDOUT_MAP` / `GH_MOCK_FAIL_MAP` seams, `shellcheck`.

**Spec:** `docs/superpowers/specs/2026-09-28-autopilot-gate-actually-gates-design.md`

## Global Constraints

- `set -euo pipefail` + `IFS=$'\n\t'`; quote every expansion; `[[ ... ]]`; `printf` over `echo`; no `eval`.
- **Check 3 must NOT carry a `branch=` filter.** Check 2 filters on the default branch; check 3 asks a different question and pull-request runs happen on *feature* branches. Adding `branch=<default>` returns zero for every repo and refuses all of them — silently disabling the lane.
- **Every failure refuses.** A non-404 API failure must report `eligibility check failed …`, never "no protection" / "not found". Only a 404 signature in stderr means genuine absence.
- `repo_eligible` keeps its name, signature (`repo_eligible <owner/repo> <gate>`) and contract: prints a one-line reason, returns 0 eligible / 1 not.
- Each refusal gets **its own reason string**, and each is asserted on that string — an exit-code-only test cannot tell them apart, and telling them apart is most of the point.
- Layer-1 tests are hermetic: no network. Everything goes through the `gh` mock.
- Conventional Commits; scope `autopilot`.

**Line numbers are as of `origin/main` at writing.** Anchor on quoted text.

---

### Task 1: Teach the test harness to distinguish the two run queries

**Files:**
- Modify: `tests/run-autopilot-eligible-tests.sh` (the `write_map` helper, ~`:58-66`)
- Create: `tests/fixtures/autopilot/protection-required.json`
- Create: `tests/fixtures/autopilot/protection-no-contexts.json`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `write_map <agent_yml> <runs> <dest>` gains two optional trailing arguments — `<pr_runs>` and `<protection>` — defaulting to the values that keep every existing case passing. Tasks 2 and 3 call it.

**Why this comes first.** `write_map` currently maps the substring
`actions/workflows/` to a single fixture. After Task 2 there are **two** such
calls, and the mock returns the **first matching line in map order** — so
without a more specific key both queries get the same answer and the new check
is untestable.

- [ ] **Step 1: Confirm the existing suite is green**

Run: `bash tests/run-autopilot-eligible-tests.sh`
Expected: all pass. Note the count; Task 3 compares against it.

- [ ] **Step 2: Add the two protection fixtures**

`tests/fixtures/autopilot/protection-required.json` — a protected branch with a
required check:

```json
{"required_status_checks": {"strict": true, "contexts": ["ci"]}}
```

`tests/fixtures/autopilot/protection-no-contexts.json` — protection present but
requiring nothing:

```json
{"required_status_checks": {"strict": false, "contexts": []}}
```

- [ ] **Step 3: Widen `write_map`**

Replace the helper with:

```bash
# The gh calls repo_eligible makes, distinguished by these substrings.
#
# ORDER MATTERS: the mock returns the FIRST matching line, and both run queries
# contain `actions/workflows/`. The event=pull_request line must come first or
# it can never be reached — and the new check would silently read the branch
# query's fixture instead of its own.
write_map() {
  local agent_yml="$1" runs="$2" dest="$3"
  local pr_runs="${4:-$FIX/runs-one.json}"
  local protection="${5:-$FIX/protection-required.json}"
  {
    printf 'event=pull_request\t%s\n'                      "$pr_runs"
    printf 'contents/.github/workflows/agent.yml\t%s\n'    "$agent_yml"
    printf 'actions/workflows/\t%s\n'                      "$runs"
    printf 'branches/main/protection\t%s\n'                "$protection"
    printf 'repos/o/r\t%s\n'                               "$FIX/repo-meta.json"
  } > "$dest"
}
```

The two defaults are what keep every existing call site passing unchanged: a
repo that already satisfied the old checks now also has PR runs and protection.

- [ ] **Step 4: Run the suite — it must still pass**

Run: `bash tests/run-autopilot-eligible-tests.sh`
Expected: the same count as Step 1, all passing. The new map keys are inert
until Task 2 makes the calls.

If a case now fails, the ordering is wrong — fix the map, not the assertion.

- [ ] **Step 5: Commit**

```bash
git add tests/run-autopilot-eligible-tests.sh tests/fixtures/autopilot/protection-*.json
git commit -m "test(autopilot): let the eligibility harness answer two run queries

The incoming pull-request-event check makes a second call containing
actions/workflows/, and the gh mock returns the first matching map line.
Adds an event=pull_request key ahead of it, plus branch-protection fixtures,
with defaults that leave every existing case unchanged.

Refs #381"
```

---

### Task 2: The two new checks

**Files:**
- Modify: `scripts/lib/autopilot-eligible.sh` (header contract ~`:4-30`; the runs query `:74-83`; new checks after it)
- Modify: `tests/run-autopilot-eligible-tests.sh` (new cases)

**Interfaces:**
- Consumes: `write_map` from Task 1, including its `<pr_runs>` and `<protection>` arguments.
- Produces: `repo_eligible` unchanged in name, signature and contract. Four refusal reasons exist: the two prior ones, plus `test gate <g> has never run on a pull request` and `<branch> has no required status checks`, plus the failure forms `eligibility check failed (protection)` and `eligibility check failed (gate runs)`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/run-autopilot-eligible-tests.sh`, before its final summary:

```bash
section "gate has never run on a pull request (#381)"

# The condition exists to satisfy #263 — no auto-merge on an unrun gate. A
# workflow_dispatch-only workflow satisfies "has completed a run on the default
# branch" while gating nothing: observed on agent-action-sandbox, whose gate
# file's own header read "Manual only. Not part of the agent pipeline".
write_map "$FIX/agent-yml-good.yml" "$FIX/runs-one.json" "$TMPDIR_T/noprruns.map" \
  "$FIX/runs-none.json"
rc=0
reason="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/noprruns.map" repo_eligible o/r ci.yml)" || rc=$?
assert_eq "gate with no pull_request runs returns 1" "1" "$rc"
case "$reason" in
  *"pull request"*) pass "reason names the pull request" ;;
  *) fail "reason names the pull request" "reason was: $reason" ;;
esac

section "default branch has no required status checks (#381)"

write_map "$FIX/agent-yml-good.yml" "$FIX/runs-one.json" "$TMPDIR_T/nocontexts.map" \
  "$FIX/runs-one.json" "$FIX/protection-no-contexts.json"
rc=0
reason="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/nocontexts.map" repo_eligible o/r ci.yml)" || rc=$?
assert_eq "protection with empty contexts returns 1" "1" "$rc"
case "$reason" in
  *"required status checks"*) pass "reason names required status checks" ;;
  *) fail "reason names required status checks" "reason was: $reason" ;;
esac

section "branch protection absent vs unreadable (#381)"

# A genuine 404 means the branch is unprotected. Both refuse — the distinction
# is what the operator reads at 3am. Reporting an outage as "no protection"
# sends them to configure something already configured.
write_map "$FIX/agent-yml-good.yml" "$FIX/runs-one.json" "$TMPDIR_T/prot404.map"
printf 'branches/main/protection\tHTTP 404: Not Found\n' > "$TMPDIR_T/prot404.fail"
rc=0
reason="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/prot404.map" \
          GH_MOCK_FAIL_MAP="$TMPDIR_T/prot404.fail" repo_eligible o/r ci.yml)" || rc=$?
assert_eq "protection 404 returns 1" "1" "$rc"
case "$reason" in
  *"no branch protection"*) pass "404 reads as unprotected" ;;
  *) fail "404 reads as unprotected" "reason was: $reason" ;;
esac

# No stderr message at all — an opaque gh failure, i.e. an outage.
printf 'branches/main/protection\n' > "$TMPDIR_T/protdown.fail"
rc=0
reason="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/prot404.map" \
          GH_MOCK_FAIL_MAP="$TMPDIR_T/protdown.fail" repo_eligible o/r ci.yml)" || rc=$?
assert_eq "protection outage returns 1" "1" "$rc"
case "$reason" in
  *"check failed"*) pass "an outage reads as a failed check" ;;
  *) fail "an outage reads as a failed check" "reason was: $reason" ;;
esac
case "$reason" in
  *"no branch protection"*) fail "an outage is not reported as unprotected" "reason was: $reason" ;;
  *) pass "an outage is not reported as unprotected" ;;
esac

section "gate runs query unreadable is not 'gate not found' (#381)"

# The same conflation, three lines above the one the agent.yml check fixes.
printf 'actions/workflows/\n' > "$TMPDIR_T/runsdown.fail"
rc=0
reason="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/prot404.map" \
          GH_MOCK_FAIL_MAP="$TMPDIR_T/runsdown.fail" repo_eligible o/r ci.yml)" || rc=$?
assert_eq "gate runs outage returns 1" "1" "$rc"
case "$reason" in
  *"check failed"*) pass "a runs outage reads as a failed check" ;;
  *) fail "a runs outage reads as a failed check" "reason was: $reason" ;;
esac
case "$reason" in
  *"not found"*) fail "a runs outage is not reported as 'gate not found'" "reason was: $reason" ;;
  *) pass "a runs outage is not reported as 'gate not found'" ;;
esac
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/run-autopilot-eligible-tests.sh 2>&1 | grep -A2 '✗' | head -20`
Expected: FAIL — neither new check exists, and the outage cases currently
report "not found" / pass through.

- [ ] **Step 3: Fix check 2's error handling, then add checks 3 and 4**

Replace the runs query block (`:74-83`) with:

```bash
  # Errors are read the same way as the agent.yml check above: an exit code
  # alone cannot separate a genuine 404 from a `gh` outage, and reporting an
  # outage as "gate not found" sends an operator hunting for a workflow that
  # exists. Capture stderr and look for the 404 signature (#381).
  runs_err="$(mktemp)"
  # shellcheck disable=SC2064  # expand runs_err now, on function return
  trap "rm -f '$agent_yml_err' '$runs_err'" RETURN

  if ! runs_json="$(gh api \
        "repos/$repo/actions/workflows/$gate/runs?branch=$default_branch&status=completed&per_page=1" \
        2>"$runs_err")"; then
    if grep -qiE 'HTTP 404|Not Found' "$runs_err"; then
      printf 'test gate %s not found\n' "$gate"
      return 1
    fi
    printf 'eligibility check failed (gate runs)\n'
    return 1
  fi
  runs="$(printf '%s' "$runs_json" | jq -r '.total_count')"
  if [[ -z "$runs" || "$runs" == "null" ]]; then
    printf 'test gate %s not found\n' "$gate"
    return 1
  fi
  if (( runs == 0 )); then
    printf 'test gate %s has never completed a run on %s\n' "$gate" "$default_branch"
    return 1
  fi

  # #381: "has completed a run" is not "gates anything". A workflow_dispatch-only
  # workflow satisfies the check above while gating nothing — observed on
  # agent-action-sandbox, whose gate declared itself "Not part of the agent
  # pipeline". Ask for evidence instead: has this workflow ever completed a run
  # for a pull_request?
  #
  # NO branch= filter here. Pull-request runs happen on feature branches, so
  # filtering on the default branch returns zero for every repo and refuses all
  # of them.
  pr_runs_err="$(mktemp)"
  # shellcheck disable=SC2064  # expand pr_runs_err now, on function return
  trap "rm -f '$agent_yml_err' '$runs_err' '$pr_runs_err'" RETURN

  if ! pr_runs_json="$(gh api \
        "repos/$repo/actions/workflows/$gate/runs?event=pull_request&status=completed&per_page=1" \
        2>"$pr_runs_err")"; then
    printf 'eligibility check failed (gate pull-request runs)\n'
    return 1
  fi
  pr_runs="$(printf '%s' "$pr_runs_json" | jq -r '.total_count')"
  if [[ -z "$pr_runs" || "$pr_runs" == "null" || "$pr_runs" == 0 ]]; then
    printf 'test gate %s has never run on a pull request\n' "$gate"
    return 1
  fi

  # #381: and the branch must actually require a check. Without this the lane
  # would merge into a branch nothing blocks.
  #
  # This endpoint 404s BOTH when the branch is unprotected and when the token
  # lacks scope to read protection. Both refuse; the distinction is what the
  # operator reads. Same treatment as agent.yml above.
  prot_err="$(mktemp)"
  # shellcheck disable=SC2064  # expand prot_err now, on function return
  trap "rm -f '$agent_yml_err' '$runs_err' '$pr_runs_err' '$prot_err'" RETURN

  if ! prot_json="$(gh api "repos/$repo/branches/$default_branch/protection" \
        2>"$prot_err")"; then
    if grep -qiE 'HTTP 404|Not Found' "$prot_err"; then
      printf 'no branch protection on %s\n' "$default_branch"
      return 1
    fi
    printf 'eligibility check failed (protection)\n'
    return 1
  fi
  contexts="$(printf '%s' "$prot_json" \
    | jq -r '(.required_status_checks.contexts // []) | length')"
  if [[ -z "$contexts" || "$contexts" == "null" ]] || (( contexts == 0 )); then
    printf '%s has no required status checks\n' "$default_branch"
    return 1
  fi

  printf 'eligible (gate %s ran on a pull request; %s requires %s check(s))\n' \
    "$gate" "$default_branch" "$contexts"
  return 0
```

Delete the old final `printf 'eligible (gate %s, %s completed run(s) on %s)\n'`
line — the new success message replaces it.

**On the repeated `trap` lines:** each one **replaces** the previous, so every
trap must name every temp file created so far — including `agent_yml_err`,
which the function already created near the top. Bash has no "append to RETURN
trap". A trap naming only its own file silently leaks the ones before it, and
the first thing dropped would be the existing cleanup that was already there.

Verify after implementing:

```bash
grep -n "trap \"rm -f" scripts/lib/autopilot-eligible.sh
```

Each line must be a superset of the one above it, and the last must name all
four files.

- [ ] **Step 4: Update the function's header contract**

The header block lists the conditions. Extend condition 2's description:

```bash
# Condition 2 is #263: no auto-merge on a gate that has never run. The gate is
# named by the operator rather than this script guessing which workflow is
# "the tests" — a heuristic guarding auto-merge means a workflow rename
# silently widens what may merge.
#
# #381 strengthened it: "has completed a run" was satisfied by a
# workflow_dispatch-only workflow in a repo with no branch protection at all.
# The gate must now also have completed a run for a pull_request, and the
# default branch must require at least one status check.
#
# NOT checked: that the named gate IS one of those required checks.
# `required_status_checks.contexts` holds job/check names while the gate is a
# filename, and mapping one to the other means matching a recent run's job
# names — which breaks on a rename, on a multi-job workflow, and when no recent
# run exists. See docs/AUTOPILOT.md.
```

- [ ] **Step 5: Run the tests**

Run: `bash tests/run-autopilot-eligible-tests.sh 2>&1 | tail -3`
Expected: PASS, new cases green **and** every pre-existing case still green.

- [ ] **Step 6: Lint**

Run: `shellcheck -x -e SC1091 scripts/lib/autopilot-eligible.sh tests/run-autopilot-eligible-tests.sh`
Expected: no findings.

- [ ] **Step 7: Commit**

```bash
git add scripts/lib/autopilot-eligible.sh tests/run-autopilot-eligible-tests.sh
git commit -m "fix(autopilot): require the gate to have gated a pull request

'Has completed a run on the default branch' was satisfied by a
workflow_dispatch-only workflow whose own header read 'Not part of the agent
pipeline', in a repo with no branch protection at all — the lane would have
auto-merged behind a gate that gates nothing.

The gate must now also have completed a run for a pull_request (evidence, not
a YAML parse), and the default branch must require at least one status check.
A non-404 API failure refuses with a distinct reason rather than reading as
absence — including the gate-runs query, which had the same conflation the
agent.yml check three lines above it already avoided.

Closes #381"
```

---

### Task 3: Say what the gate guarantees

**Files:**
- Modify: `docs/AUTOPILOT.md`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: the behaviour from Task 2.
- Produces: no interface.

- [ ] **Step 1: State the guarantee and the gap**

In `docs/AUTOPILOT.md`, find the section describing the eligibility conditions
(search for `ai-review-ai-merge` or `gate`) and replace the gate condition's
description with:

```markdown
**3. The named test gate demonstrably gates.** Three things must hold:

- the gate workflow has completed a run on the default branch;
- it has completed a run for a **pull request** — proof it runs on PRs at all,
  not merely that a trigger is declared somewhere in its YAML;
- the default branch has protection requiring **at least one** status check.

**What this does not guarantee.** It does not verify that the named gate is one
of those required checks. `required_status_checks.contexts` holds job/check
names while the gate is named by its workflow filename, and mapping one to the
other means matching a recent run's job names — fragile on a rename, on a
multi-job workflow, and when no recent run exists. A repo could therefore
require check A while naming workflow B as its gate, and satisfy this condition.

**A correctly-configured gate that has never seen a pull request is refused.**
That is deliberate: the lane requires demonstrated behaviour, not declared
intent. Open one pull request and the condition is satisfied thereafter.
```

- [ ] **Step 2: Add the changelog entry**

Under `## [Unreleased]` in `CHANGELOG.md`, in the **existing** `### Fixed`
subsection — do not add a second one, `[Unreleased]` already has `Added`,
`Changed`, `Deprecated`, `Removed` and `Fixed`, and a duplicate heading trips
markdownlint MD024:

```markdown
- **autopilot:** the test-gate eligibility condition now verifies the gate
  gates. "Has completed a run on the default branch" was satisfied by a
  `workflow_dispatch`-only workflow documented as "not part of the agent
  pipeline", in a repo with no branch protection — the lane would have
  auto-merged behind a gate that gated nothing. The gate must now also have run
  for a pull request, and the default branch must require at least one status
  check; an API failure refuses with its own reason rather than reading as
  absence (#381, satisfying #263).
```

- [ ] **Step 3: Full gate**

```bash
bash tests/run-all.sh
shellcheck -x -e SC1091 scripts/lib/autopilot-eligible.sh
pre-commit run --all-files
```

Expected: every runner green; `shellcheck` clean; all hooks pass. Run
`pre-commit` locally rather than discovering `markdownlint` or `typos` findings
in CI.

- [ ] **Step 4: Commit**

```bash
git add docs/AUTOPILOT.md CHANGELOG.md
git commit -m "docs(autopilot): say what the test gate guarantees, and what it does not

Records that the condition does not verify the named gate is among the
required checks, and why: contexts are job names, the gate is a filename.

Refs #381"
```

---

## Verification

```bash
# The pull-request query carries no branch filter
grep -n 'event=pull_request' scripts/lib/autopilot-eligible.sh
grep -c 'event=pull_request.*branch=' scripts/lib/autopilot-eligible.sh   # expect: 0

# Every failure path refuses with its own reason
grep -c 'eligibility check failed' scripts/lib/autopilot-eligible.sh      # expect: 4

# An outage is never reported as absence
bash tests/run-autopilot-eligible-tests.sh 2>&1 | grep -E 'not reported as'

# The docs state the gap
grep -c 'does not guarantee' docs/AUTOPILOT.md

# Full gate
bash tests/run-all.sh
pre-commit run --all-files
```
