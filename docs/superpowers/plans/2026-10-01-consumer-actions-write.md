# Consumer Caller-Permissions Guard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make it impossible for a consumer stub this repo ships or documents to grant less than the reusable workflow it calls requests, and let the operator see which consumers in the fleet already do (#434).

**Architecture:** A small static checker, `scripts/check-caller-permissions.sh`, compares a caller workflow's effective `permissions:` against the union of the reusable workflow's per-job effective permissions, using GitHub's semantics (job block replaces workflow block, `write` ⊇ `read`, `read-all`/`write-all`). A new Layer-1 runner tests the checker on a synthetic fixture and then asserts the invariant over every shipped stub. `migrate-consumers.sh` reuses the checker to append a `perms:` verdict to each fleet line.

**Tech Stack:** Bash 5 (`set -euo pipefail`, `IFS=$'\n\t'`), awk, the `gh` mock's `GH_MOCK_STDOUT_MAP` seam, `shellcheck`. No `yq`/Python — the Layer-1 suite is hermetic and has no YAML tooling.

**Spec:** `docs/superpowers/specs/2026-10-01-consumer-actions-write-design.md`

## Global Constraints

- `set -euo pipefail` + `IFS=$'\n\t'`; quote every expansion; `[[ ... ]]`; `printf` over `echo`; no `eval`.
- **The template and onboard stub already grant `actions: write`** (`docs/CONSUMER-SETUP.md:159`, `scripts/onboard-consumer.sh:353`). Do not re-add or reword them — this plan adds the guard, not the fix.
- **Never derive the required scopes from a hard-coded list.** The invariant's whole value is that a new scope in a reusable job fails the suite on its own.
- **No vacuous pass.** Any loop over discovered stubs must also assert it found at least one.
- **Call `check` with `< <(...)`, never a pipe** — a piped call runs in a subshell and `OUT`/`RC` never reach the asserting shell. (This bit the prototype.)
- **Do not modify any other repository.** The 38 consumers missing `actions: write` are reported, not fixed (⛔ in the issue body).
- Layer-1 tests are hermetic: no network; everything through `tests/mocks/gh`.
- Conventional Commits; scope `consumer`; every subject ends in `(#434)`.

**Line numbers are as of `origin/main` at writing.** Anchor on quoted text.

---

### Task 1: The checker, test first

**Files:**
- Create: `tests/fixtures/caller-permissions/reusable.yml`
- Create: `tests/run-caller-permissions-tests.sh`
- Create: `scripts/check-caller-permissions.sh`

**Interfaces:**
- Produces: `check-caller-permissions.sh <caller.yml|-> <reusable.yml>` — stdout one line per gap, `<scope>: needs <level>, caller grants <level>`; exit 0 no gap, 1 gap, 2 bad args/unreadable. Tasks 2 and 3 consume it.

- [ ] **Step 1: Write the synthetic reusable fixture**

`tests/fixtures/caller-permissions/reusable.yml` — one job with its own block (including comments that must not end the block), one inheriting the workflow-level block:

```yaml
# Synthetic reusable workflow: one job with its own block, one inheriting the
# workflow-level block. Exercises "job-level REPLACES top-level".
on:
  workflow_call:

permissions:
  contents: read
  issues: read

jobs:
  implement:
    runs-on: ubuntu-latest
    permissions:
      contents: write
      # a comment inside the block must not end it
      actions: write   # trailing comment
    steps:
      - run: true
  report:
    runs-on: ubuntu-latest
    steps:
      - run: true
```

- [ ] **Step 2: Write the failing test runner**

`tests/run-caller-permissions-tests.sh` (`chmod +x`):

```bash
#!/usr/bin/env bash
#
# run-caller-permissions-tests.sh — Layer-1 tests for
# scripts/check-caller-permissions.sh, plus the invariant it exists for: every
# consumer stub this repo ships or documents grants every permission the
# reusable workflow it calls requests (#434).
#
# A caller that grants less makes GitHub refuse the run at `startup_failure`,
# with zero jobs and no logs. That shipped once already: agent-implement.yml
# gained `actions: write` (#351) and 38 consumer stubs did not.
#
# Usage: tests/run-caller-permissions-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$ROOT/scripts/check-caller-permissions.sh"
FIX="$ROOT/tests/fixtures/caller-permissions"

PASS=0
FAIL=0
FAIL_NAMES=()

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_GREEN=''; C_RED=''; C_DIM=''; C_OFF=''
fi

section() { printf '\n%s── %s ──%s\n' "$C_DIM" "$1" "$C_OFF"; }
pass() { PASS=$((PASS + 1)); printf '  %s✓%s %s\n' "$C_GREEN" "$C_OFF" "$1"; }
fail() {
  FAIL=$((FAIL + 1)); FAIL_NAMES+=("$1")
  printf '  %s✗%s %s\n' "$C_RED" "$C_OFF" "$1"
  [ $# -gt 1 ] && printf '      %s\n' "$2"
  return 0
}

# check <reusable> — caller on stdin; sets OUT and RC. Feed it with `< <(...)`,
# never a pipe: a piped call runs in a subshell and OUT/RC never reach us.
check() {
  RC=0
  OUT="$(bash "$CHECK" - "$1" 2>&1)" || RC=$?
}
assert_clean() {  # <name>
  if [[ "$RC" -eq 0 && -z "$OUT" ]]; then pass "$1"; else fail "$1" "rc=$RC out=$OUT"; fi
}
assert_gap() {  # <expected line> <name>
  if [[ "$RC" -eq 1 && "$OUT" == *"$1"* ]]; then pass "$2"; else fail "$2" "rc=$RC out=$OUT"; fi
}

# --- the checker --------------------------------------------------------

section "checker — semantics"

check "$FIX/reusable.yml" < <(printf 'permissions:\n  contents: write\n  issues: read\n  actions: write\n')
assert_clean "a caller granting every requested scope passes"

check "$FIX/reusable.yml" < <(printf 'permissions:\n  contents: write\n  issues: read\n')
assert_gap 'actions: needs write, caller grants none' "a missing scope is reported (the #434 shape)"

check "$FIX/reusable.yml" < <(printf 'permissions:\n  contents: read\n  issues: read\n  actions: write\n')
assert_gap 'contents: needs write, caller grants read' "read does not satisfy write"

check "$FIX/reusable.yml" < <(printf 'permissions:\n  contents: write\n  actions: write\n')
assert_gap 'issues: needs read, caller grants none' "a job without its own block inherits the workflow-level one"

check "$FIX/reusable.yml" < <(printf 'on: push\njobs:\n  c:\n    uses: x\n')
assert_gap 'contents: needs write, caller grants none' "no permissions block grants nothing"

check "$FIX/reusable.yml" < <(printf 'permissions: write-all\n')
assert_clean "write-all satisfies everything"

check "$FIX/reusable.yml" < <(printf 'permissions: read-all\n')
assert_gap 'actions: needs write, caller grants read' "read-all does not satisfy write"

check "$FIX/reusable.yml" < <(printf 'permissions:\n  contents: read\njobs:\n  c:\n    permissions:\n      contents: write\n      issues: write\n      actions: write\n    uses: x\n')
assert_clean "a caller's job-level block replaces its workflow-level one"

RC=0; bash "$CHECK" >/dev/null 2>&1 || RC=$?
if [[ "$RC" -eq 2 ]]; then pass "missing arguments exit 2"; else fail "missing arguments exit 2" "rc=$RC"; fi

# --- summary ------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'failed:\n'; printf '  - %s\n' "${FAIL_NAMES[@]}"
  exit 1
fi
```

- [ ] **Step 3: Run it to verify it fails**

Run: `bash tests/run-caller-permissions-tests.sh`
Expected: FAIL — every case reports `rc=127`-style errors / non-zero because `scripts/check-caller-permissions.sh` does not exist; summary shows failures, exit 1.

- [ ] **Step 4: Write the checker**

`scripts/check-caller-permissions.sh` (`chmod +x`):

```bash
#!/usr/bin/env bash
#
# check-caller-permissions.sh — Does a caller workflow grant every permission a
# reusable workflow's jobs request?
#
# A reusable workflow can never be granted more than its caller has. When a job
# in it asks for a scope the caller lacks, GitHub refuses the whole run at
# `startup_failure` — zero jobs, no logs (#434). This compares the two files
# statically so the gap is caught before a dispatch is.
#
# Usage: check-caller-permissions.sh <caller.yml|-> <reusable.yml>
#   '-' reads the caller from stdin.
#
# Semantics (GitHub's):
#   - A job's effective permissions are its own `permissions:` block if it has
#     one, else the workflow-level block. A job-level block REPLACES, it does
#     not merge.
#   - `read-all` / `write-all` grant that level on every scope.
#   - A scope absent from a block is `none`; `write` satisfies `read`.
#   - A caller with no block at all grants nothing we can rely on: the repo
#     default token is read-only on most repos, so every scope is reported.
#
# Output: one line per gap, `<scope>: needs <level>, caller grants <level>`.
# Exit codes: 0 no gap; 1 at least one gap; 2 bad arguments / unreadable file.
set -euo pipefail
IFS=$'\n\t'

usage_error() { printf 'error: %s\n' "$1" >&2; exit 2; }

# permission_entries <file> — `<context>\t<scope>\t<level>` per entry.
# context is `top` or `job:<name>`; scope `@` marks a job, `-` marks a block,
# `*` is read-all/write-all.
permission_entries() {
  awk '
    function indent(s) { match(s, /^ */); return RLENGTH }
    /^[[:space:]]*(#|$)/ { next }
    {
      ind = indent($0); line = $0
      sub(/[[:space:]]+#.*$/, "", line); sub(/^ +/, "", line)
      if (inblock && ind > blockind) {
        key = line; sub(/:.*/, "", key)
        val = line; sub(/^[^:]*:[[:space:]]*/, "", val)
        printf "%s\t%s\t%s\n", ctx, key, val; next
      }
      inblock = 0
      if (ind == 0) { injobs = (line == "jobs:"); ctx = "top" }
      if (injobs && ind == 2 && line ~ /^[A-Za-z0-9_-]+:$/) {
        ctx = "job:" substr(line, 1, length(line) - 1)
        printf "%s\t@\t\n", ctx
      }
      if (line ~ /^permissions:/ && (ind == 0 || (injobs && ind == 4))) {
        val = line; sub(/^permissions:[[:space:]]*/, "", val)
        printf "%s\t-\t\n", ctx
        if (val == "read-all" || val == "write-all") printf "%s\t*\t%s\n", ctx, substr(val, 1, index(val, "-") - 1)
        else if (val == "") { inblock = 1; blockind = ind }
      }
    }' "$1"
}

rank() { case "$1" in write) printf 2 ;; read) printf 1 ;; *) printf 0 ;; esac }

# effective_grants <file> — `<scope>\t<level>` the file's jobs run with, the
# highest level per scope across jobs.
effective_grants() {
  local entries ctx scope level
  entries="$(permission_entries "$1")"
  local -A has_block=() max=()
  local -a jobs=()
  while IFS=$'\t' read -r ctx scope level; do
    case "$scope" in
      @) jobs+=("$ctx") ;;
      -) has_block["$ctx"]=1 ;;
    esac
  done <<< "$entries"
  ((${#jobs[@]})) || jobs=(top)
  local job src
  for job in "${jobs[@]}"; do
    src="$job"; [[ -n "${has_block[$job]:-}" ]] || src=top
    while IFS=$'\t' read -r ctx scope level; do
      [[ "$ctx" == "$src" && "$scope" != @ && "$scope" != - ]] || continue
      if (( $(rank "$level") > $(rank "${max[$scope]:-none}") )); then max["$scope"]="$level"; fi
    done <<< "$entries"
  done
  for scope in "${!max[@]}"; do printf '%s\t%s\n' "$scope" "${max[$scope]}"; done
}

main() {
  [[ $# -eq 2 ]] || usage_error "usage: check-caller-permissions.sh <caller.yml|-> <reusable.yml>"
  local caller="$1" reusable="$2"
  [[ -r "$reusable" ]] || usage_error "cannot read $reusable"
  if [[ "$caller" == - ]]; then
    STDIN_COPY="$(mktemp)"; trap 'rm -f "$STDIN_COPY"' EXIT
    cat > "$STDIN_COPY"; caller="$STDIN_COPY"
  fi
  [[ -r "$caller" ]] || usage_error "cannot read $caller"

  local -A grant=()
  local scope level gaps=0 have
  while IFS=$'\t' read -r scope level; do
    [[ -n "$scope" ]] && grant["$scope"]="$level"
  done < <(effective_grants "$caller")

  while IFS=$'\t' read -r scope level; do
    [[ -n "$scope" ]] || continue
    have="${grant[$scope]:-${grant['*']:-none}}"
    if (( $(rank "$have") < $(rank "$level") )); then
      printf '%s: needs %s, caller grants %s\n' "$scope" "$level" "$have"
      gaps=$((gaps + 1))
    fi
  done < <(effective_grants "$reusable" | sort)
  (( gaps == 0 ))
}

main "$@"
```

- [ ] **Step 5: Run it to verify it passes**

Run: `bash tests/run-caller-permissions-tests.sh`
Expected: `9 passed, 0 failed`, exit 0.

Run: `shellcheck scripts/check-caller-permissions.sh tests/run-caller-permissions-tests.sh`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add scripts/check-caller-permissions.sh tests/run-caller-permissions-tests.sh tests/fixtures/caller-permissions/reusable.yml
git commit -m "fix(consumer): detect caller stubs that under-grant the reusable workflow (#434)"
```

---

### Task 2: The invariant over every shipped stub

**Files:**
- Modify: `tests/run-caller-permissions-tests.sh` (insert before `# --- summary`)

**Interfaces:**
- Consumes: the checker from Task 1, `build_agent_yml` / `build_chain_yml` in `scripts/onboard-consumer.sh`, the yaml fences in `docs/CONSUMER-SETUP.md` (`:149` agent stub, `:420` chain stub).
- Produces: nothing for later tasks.

**Why this is green on main and still TDD.** The stubs are already correct, so
the invariant passes the moment it is written. The red step is therefore a
**mutation check**: prove each assertion bites by breaking its input in a
scratch copy, then restore. An invariant nobody has seen fail is not known to
guard anything.

- [ ] **Step 1: Add the invariant section**

Insert before `# --- summary`:

```bash
IMPLEMENT="$ROOT/.github/workflows/agent-implement.yml"
CHAIN="$ROOT/.github/workflows/chain-dispatch.yml"

# yaml_fences <md> <uses-pattern> — every complete stub (a fence with both an
# `on:` trigger and a `uses:` of the pattern) in a doc, NUL-separated.
yaml_fences() {
  awk -v pat="$2" '
    /^```yaml/ { inside = 1; buf = ""; next }
    /^```/     { if (inside && buf ~ pat && buf ~ /(^|\n)on:/) printf "%s%c", buf, 0; inside = 0; next }
    inside     { buf = buf $0 "\n" }' "$1"
}

# onboard_stub <function> — what onboard-consumer.sh generates, extracted from
# the shipped script so the test cannot drift from it.
onboard_stub() {
  # shellcheck disable=SC2034
  (
    AGENT=claude MODEL=claude-sonnet-5 REF=v2 RUNNER_LABELS='["ubuntu-latest"]'
    PIPELINE_REPO=freaxnx01/agent-workflow AI_MERGE=false HUMAN_MERGE=true
    # shellcheck disable=SC1090
    source <(sed -n "/^$1()/,/^}/p" "$ROOT/scripts/onboard-consumer.sh")
    "$1"
  )
}

# --- the invariant ------------------------------------------------------

section "invariant — every shipped stub grants what its reusable workflow requests"

n=0
while IFS= read -r -d '' stub; do
  n=$((n + 1))
  check "$IMPLEMENT" < <(printf '%s' "$stub")
  assert_clean "CONSUMER-SETUP.md agent stub #$n ⊇ agent-implement.yml"
done < <(yaml_fences "$ROOT/docs/CONSUMER-SETUP.md" 'agent-implement\\.yml@')
# A vacuous pass is the failure mode to fear here: rename the fence and the
# loop above silently checks nothing.
if (( n >= 1 )); then pass "found the documented agent stub"; else fail "found the documented agent stub" "no fence matched"; fi

n=0
while IFS= read -r -d '' stub; do
  n=$((n + 1))
  check "$CHAIN" < <(printf '%s' "$stub")
  assert_clean "CONSUMER-SETUP.md chain stub #$n ⊇ chain-dispatch.yml"
done < <(yaml_fences "$ROOT/docs/CONSUMER-SETUP.md" 'chain-dispatch\\.yml@')
if (( n >= 1 )); then pass "found the documented chain stub"; else fail "found the documented chain stub" "no fence matched"; fi

check "$IMPLEMENT" < <(onboard_stub build_agent_yml)
assert_clean "onboard-consumer.sh agent stub ⊇ agent-implement.yml"

check "$CHAIN" < <(onboard_stub build_chain_yml)
assert_clean "onboard-consumer.sh chain stub ⊇ chain-dispatch.yml"

check "$IMPLEMENT" < "$ROOT/.github/workflows/agent.yml"
assert_clean "this repo's own agent.yml ⊇ agent-implement.yml"

```

- [ ] **Step 2: Run it — expect green**

Run: `bash tests/run-caller-permissions-tests.sh`
Expected: `16 passed, 0 failed`. In particular `found the documented agent stub` and `found the documented chain stub` pass (the fences matched).

- [ ] **Step 3: Mutation check — each assertion must bite (do NOT commit these edits)**

Run each, confirm the named assertion fails, then restore with `git checkout -- <file>`:

```bash
sed -i '0,/^  actions: write        # retry-dispatch/s//  # MUTANT/' docs/CONSUMER-SETUP.md
bash tests/run-caller-permissions-tests.sh   # expect FAIL: CONSUMER-SETUP.md agent stub #1
git checkout -- docs/CONSUMER-SETUP.md

sed -i '0,/^  actions: write        # retry-dispatch/s//  # MUTANT/' scripts/onboard-consumer.sh
bash tests/run-caller-permissions-tests.sh   # expect FAIL: onboard-consumer.sh agent stub
git checkout -- scripts/onboard-consumer.sh

sed -i 's/^  actions: write$/  # MUTANT/' .github/workflows/agent.yml
bash tests/run-caller-permissions-tests.sh   # expect FAIL: this repo's own agent.yml
git checkout -- .github/workflows/agent.yml

sed -i 's/^```yaml$/```yml/' docs/CONSUMER-SETUP.md
bash tests/run-caller-permissions-tests.sh   # expect FAIL: found the documented agent stub
git checkout -- docs/CONSUMER-SETUP.md
```

Run: `git status --porcelain` — expect only the Task-2 test file modified.

- [ ] **Step 4: Run the full suite**

Run: `just test`
Expected: every runner passes, including `run-caller-permissions-tests.sh` (discovered by `tests/run-all.sh`, no registration needed).

- [ ] **Step 5: Commit**

```bash
git add tests/run-caller-permissions-tests.sh
git commit -m "test(consumer): guard shipped stubs against permission drift (#434)"
```

---

### Task 3: Fleet inventory reports permission gaps

**Files:**
- Modify: `tests/run-script-tests.sh` (after the `migrate-consumers` section, ~`:1975`)
- Modify: `scripts/migrate-consumers.sh`

**Interfaces:**
- Consumes: `scripts/check-caller-permissions.sh` (Task 1).
- Produces: per-repo lines `<repo>  <ref>  <verdict>  perms:ok|perms:MISSING <scope>[,<scope>…]` for the `inventory`, `already on target` and `would migrate` verdicts. New env seam `REUSABLE` (defaults to this checkout's `agent-implement.yml`).

- [ ] **Step 1: Write the failing test**

Append after the last `migrate-consumers` assertion (`"a file with no pin passes through unchanged"`):

```bash
section "migrate-consumers — inventory flags stubs that under-grant (#434)"

mig_tmp="$(mktemp -d)"
printf 'deadbeef\n' > "$mig_tmp/sha"
stub_full=$'on:\n  issues:\n    types: [labeled]\npermissions:\n  contents: write\n  pull-requests: write\n  issues: write\n  actions: write\njobs:\n  claude:\n    uses: freaxnx01/agent-workflow/.github/workflows/agent-implement.yml@v2\n'
printf '%s' "$stub_full" | base64 -w0 > "$mig_tmp/ok.b64"
# game-sky-fury's agent.yml before game-sky-fury#7: everything but actions.
printf '%s' "$stub_full" | grep -v 'actions: write' | base64 -w0 > "$mig_tmp/stale.b64"
# ORDER MATTERS: the mock returns the first match, and only the sha call
# carries `.sha`.
printf '.sha\t%s\nrepos/o/stale/contents\t%s\nrepos/o/ok/contents\t%s\n' \
  "$mig_tmp/sha" "$mig_tmp/stale.b64" "$mig_tmp/ok.b64" > "$mig_tmp/map"

out="$(PATH="$MOCKS:$PATH" GH_MOCK_LOG="$mig_tmp/log" GH_MOCK_STDOUT_MAP="$mig_tmp/map" \
       CONSUMERS=$'o/stale\no/ok' bash "$MIGRATE")"
assert_contains "$out" 'o/stale  v2  inventory  perms:MISSING actions' "a stub without actions: write is flagged"
assert_contains "$out" 'o/ok  v2  inventory  perms:ok'                 "a complete stub reads perms:ok"

out="$(PATH="$MOCKS:$PATH" GH_MOCK_LOG="$mig_tmp/log" GH_MOCK_STDOUT_MAP="$mig_tmp/map" \
       CONSUMERS='o/stale' bash "$MIGRATE" --to v2)"
assert_contains "$out" 'already on target  perms:MISSING actions' "  → also when already on the target ref"

out="$(PATH="$MOCKS:$PATH" GH_MOCK_LOG="$mig_tmp/log" GH_MOCK_STDOUT_MAP="$mig_tmp/map" \
       CONSUMERS='o/stale' bash "$MIGRATE" --to v3)"
assert_contains "$out" 'would migrate → v3  perms:MISSING actions' "  → and in a dry-run migration"
rm -rf "$mig_tmp"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/run-script-tests.sh 2>&1 | tail -15`
Expected: FAIL on the four new assertions (lines end at `inventory` / `already on target` / `→ v3` with no `perms:` column).

- [ ] **Step 3: Implement**

In `scripts/migrate-consumers.sh`:

1. After `STUB_PATH='.github/workflows/agent.yml'` add:

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The workflow a stub's permissions are checked against. This checkout's copy:
# run the script from an up-to-date main, which is what @v<latest> points at.
REUSABLE="${REUSABLE:-$SCRIPT_DIR/../.github/workflows/agent-implement.yml}"
```

2. Immediately before `if [[ "${REWRITE_STDIN:-}" == "1" ]]; then` add:

```bash
# perms_verdict — stub on stdin; prints `perms:ok` or `perms:MISSING <scopes>`.
# A stub that grants less than agent-implement.yml's jobs request fails every
# dispatch at startup_failure with no logs (#434), so the inventory says so.
perms_verdict() {
  local gaps
  gaps="$(bash "$SCRIPT_DIR/check-caller-permissions.sh" - "$REUSABLE" \
            | sed 's/:.*//' | paste -sd, -)" || true
  if [[ -z "$gaps" ]]; then printf 'perms:ok'; else printf 'perms:MISSING %s' "$gaps"; fi
}
```

3. After `cur="${cur:--}"` add `perms="$(printf '%s' "$content" | perms_verdict)"`.

4. Append `  %s` / `"$perms"` to exactly three printf lines:

```bash
    printf '%s  %s  inventory  %s\n' "$repo" "$cur" "$perms"; continue
    printf '%s  %s  already on target  %s\n' "$repo" "$cur" "$perms"; skipped=$((skipped+1)); continue
    printf '%s  %s  would migrate → %s  %s\n' "$repo" "$cur" "$TARGET_REF" "$perms"
```

5. Update the header's `# Output:` paragraph:

```bash
# Output:
#   One line per repo: `<repo>  <current-ref>  <verdict>  perms:<ok|MISSING …>`.
#   perms:MISSING names scopes agent-implement.yml's jobs request that the stub
#   does not grant — that consumer fails every dispatch at startup_failure.
```

- [ ] **Step 4: Run it to verify it passes**

Run: `bash tests/run-script-tests.sh 2>&1 | tail -5`
Expected: 0 failed.

Run: `shellcheck scripts/migrate-consumers.sh tests/run-script-tests.sh`
Expected: no output.

- [ ] **Step 5: Commit**

```bash
git add scripts/migrate-consumers.sh tests/run-script-tests.sh
git commit -m "fix(consumer): flag permission gaps in the migrate-consumers inventory (#434)"
```

---

### Task 4: Document the column and the remedy

**Files:**
- Modify: `docs/CONSUMER-SETUP.md` (§ "Migrating to a new major line", ~`:519-545`)

- [ ] **Step 1: Update the inventory example and add the remedy**

Replace the inventory example block with:

```bash
bash scripts/migrate-consumers.sh --owner <owner>
# freaxnx01/flowhub              v2  inventory  perms:ok
# freaxnx01/game-tank-toys       v2  inventory  perms:MISSING actions
```

and add directly after it:

> **`perms:MISSING <scope>`** means the stub grants less than
> `agent-implement.yml`'s jobs request. A reusable workflow can't be granted
> more than its caller, so that repo fails **every** `ai-implement` dispatch at
> `startup_failure` (zero jobs, no logs). Add the named scopes to the stub's
> `permissions:` block — compare with the stub in §1. Most often this is
> `actions: write`, which `@v2` needs for retry re-dispatch (#351) and which
> stubs created before 2026-09-23 lack (#434).

- [ ] **Step 2: Verify the invariant still finds and passes the stubs**

Run: `just test`
Expected: all runners pass (the edit must not create a second matching agent fence that is incomplete).

- [ ] **Step 3: Commit**

```bash
git add docs/CONSUMER-SETUP.md
git commit -m "docs(consumer): explain the perms column in the fleet inventory (#434)"
```

---

### Task 5: Final verification

- [ ] **Step 1:** `just test` — all pass.
- [ ] **Step 2:** `just lint-shell` (or `shellcheck scripts/*.sh tests/*.sh` if pre-commit is unavailable) — clean.
- [ ] **Step 3 (read-only, optional):** `bash scripts/migrate-consumers.sh --owner freaxnx01 | grep MISSING` and paste the list into the PR body under "Fleet status". Expect ~38 `game-*` repos as of 2026-10-01. **Do not** run with `--apply`, and do not edit any consumer repo — the rollout is a separate, operator-approved step.
