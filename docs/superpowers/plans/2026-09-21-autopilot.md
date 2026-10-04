# /autopilot — Unattended Enrich Lane Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An unattended lane that, on a systemd timer, quick-enriches
`needs-enrichment` issues in allowlisted repos and dispatches them with
`ai-implement` + `ai-review-ai-merge`, escalating anything it cannot decide to
`needs-human`.

**Architecture:** A shell driver (`scripts/autopilot.sh`) owns all writes; config
parsing, repo eligibility and candidate selection are query-only sourced libs
under `scripts/lib/` so they are fixture-testable with no network. Each issue is
enriched by its own nested `claude --print "/enrich N --quick --headless"`
session, run inside a managed clone of the target repo.

**Tech Stack:** Bash 5 (`set -euo pipefail`, `IFS=$'\n\t'`), `gh`, `jq`, `git`,
`flock`, `timeout`, systemd `--user` units. Tests are fixture-driven bash with
`tests/mocks/gh` on `PATH`.

**Spec:** [`docs/superpowers/specs/2026-09-21-autopilot-design.md`](../specs/2026-09-21-autopilot-design.md)

> **Amendment (2026-09-22):** This plan describes the pre-implementation
> design. In particular, every step below that has the consumer's
> `.github/workflows/agent.yml` declare an `autopilot-test-gate:` key is
> **not what was built** — that key is not a declared input on the reusable
> workflow, and an operator who adds it breaks every `ai-implement` run in
> that repo. As shipped, the test gate is named in the host-local autopilot
> config instead (`repo=<owner/name>:<test-gate workflow file>`). See
> [`docs/AUTOPILOT.md`](../../AUTOPILOT.md) for current behaviour and
> Amendment 1 in the spec's [`## Amendments`](../specs/2026-09-21-autopilot-design.md#amendments)
> section for the full rationale. The rest of this plan is left as the
> historical record it is.

## Global Constraints

- Every script starts with `#!/usr/bin/env bash`, `set -euo pipefail`, `IFS=$'\n\t'`.
- Quote every variable expansion. `[[ ... ]]` over `[ ... ]`. `$(...)` over backticks. No `eval`.
- `printf` over `echo` for anything formatted.
- Exit codes are API: `0` success, `2` usage error, `3` missing dependency, `4` config invalid/unreadable.
- Layer-1 tests are hermetic: no network, no GitHub, no Docker, no real `claude` process.
- `shellcheck -x -e SC1091` must pass on every new and modified script.
- Commit messages follow Conventional Commits, subject ≤72 chars, imperative, no period.
- The driver **never** applies `enrichment-ongoing` — `/enrich` owns that lock.
- `ai-implement` and `ai-review-ai-merge` are applied in **one** `gh issue edit` call (#365).
- `max_per_run` is a **global** cap across all repos, default `3`.
- Default `enrich_timeout` is `1800` seconds.
- Clone cache root: `${AUTOPILOT_CACHE_DIR:-$HOME/.cache/agent-workflow/autopilot}`.
- Config path: `${AUTOPILOT_CONFIG:-$HOME/.config/agent-workflow/autopilot.conf}`.
- Disable flag: `${AUTOPILOT_DISABLE_FLAG:-$HOME/.config/agent-workflow/autopilot.disabled}`.
- Every env var above exists so tests can redirect it; never hardcode a `$HOME` path in a function body.

---

### Task 1: Verify nested slash-command expansion, and record the finding

The entire design rests on `claude --print` resolving a **custom** slash command
rather than treating `/enrich …` as literal prose. Verify before building
anything that depends on it. Everything downstream of Task 9 changes shape if
this fails, so this task gates the plan.

**Files:**
- Modify: `docs/DECISIONS.md` (append a new ADR at the end of the file)

**Interfaces:**
- Consumes: nothing.
- Produces: the recorded decision that Task 9 reads to pick its prompt strategy.

- [ ] **Step 1: Probe whether `--print` expands a custom slash command**

Run this from the repo root. `/commands` is a real user-level command in this
install, so a successful expansion produces a command listing; a failure
produces the model talking *about* a slash command.

```bash
printf '/commands\n' | timeout 180 claude --print 2>&1 | head -30
```

Expected on success: a listing of slash commands.
Expected on failure: prose such as "I don't have the ability to run slash commands" or the literal text echoed back.

- [ ] **Step 2: Probe the real target command in a harmless form**

```bash
printf '/enrich\n' | timeout 180 claude --print 2>&1 | head -30
```

`/enrich` with no argument hits its own usage error path
(`Issue number is required. Usage: /enrich <issue-number> [--quick]`). Seeing
that string is positive proof the command body executed. Seeing the model
describe what `/enrich` does is proof it did not.

- [ ] **Step 3: Record the outcome as ADR-015**

Append to `docs/DECISIONS.md`. Fill the bracketed verdict with what Step 1–2
actually showed — this is the one place in the plan whose content is determined
by an observation rather than fixed in advance.

```markdown
## ADR-015 — The unattended lane drives `/enrich` through a nested `claude --print` session (2026-09-21)

**Context.** `/autopilot` (#373) runs from a systemd timer. A timer runs a
process, not a slash command, so the driver is `scripts/autopilot.sh`. The
per-issue enrichment still has to be `/enrich`, because that command is where
the whole spec/plan/issue-body contract lives — reimplementing it in bash would
fork it.

**Decision.** Each issue gets its own nested `claude --print` session, invoked
with the prompt `/enrich <n> --quick --headless` on stdin and the working
directory set to that repo's managed clone. One session per issue, not one per
run: a single long-lived session would share one context across N enrichments,
and a mid-run context exhaustion would lose the whole batch.

**Verified.** On 2026-09-21, `printf '/enrich\n' | claude --print` [EXPANDED the
custom command, reaching its usage-error path | DID NOT expand the custom
command]. [If it did not: the wrapper therefore inlines `commands/enrich.md`
into the prompt ahead of the arguments, as described in Task 9's fallback.]

**Consequences.** The nested session inherits the wrapper's `--allowedTools`
list rather than an interactive permission prompt, so the tool set the headless
enrich may use is fixed at the wrapper. The driver learns the outcome by
re-reading the issue's labels, not from the session's exit code — see the spec's
"Dispatch" section.
```

- [ ] **Step 4: Commit**

```bash
git add docs/DECISIONS.md
git commit -m "docs(adr): record how the unattended lane drives /enrich (#373)"
```

---

### Task 2: `--headless` in the enrich argument parser

**Files:**
- Modify: `scripts/lib/parse-enrich-args.sh`
- Test: `tests/run-parse-enrich-args-tests.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `parse_enrich_args <args>` gains a third output line
  `HEADLESS=yes|no`, on both the success and the failure path. `HEADLESS=yes`
  forces `QUICK=yes`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/run-parse-enrich-args-tests.sh`, immediately before the final
summary block that prints the pass/fail counts. The file's existing helpers
(`section`, `assert_eq`, `pass`, `fail`) are already in scope.

```bash
section "--headless"

out="$(parse_enrich_args "373")"
assert_eq "no flags -> HEADLESS=no" "HEADLESS=no" "$(printf '%s\n' "$out" | sed -n 's/^HEADLESS=/HEADLESS=/p')"

out="$(parse_enrich_args "373 --headless")"
assert_eq "--headless -> HEADLESS=yes" "HEADLESS=yes" "$(printf '%s\n' "$out" | grep '^HEADLESS=')"
assert_eq "--headless implies QUICK=yes" "QUICK=yes" "$(printf '%s\n' "$out" | grep '^QUICK=')"
assert_eq "--headless keeps the issue number" "ISSUE=373" "$(printf '%s\n' "$out" | grep '^ISSUE=')"

out="$(parse_enrich_args "373 --quick --headless")"
assert_eq "--quick --headless -> QUICK=yes" "QUICK=yes" "$(printf '%s\n' "$out" | grep '^QUICK=')"
assert_eq "--quick --headless -> HEADLESS=yes" "HEADLESS=yes" "$(printf '%s\n' "$out" | grep '^HEADLESS=')"

out="$(parse_enrich_args "--headless 373")"
assert_eq "flag before issue still parses" "ISSUE=373" "$(printf '%s\n' "$out" | grep '^ISSUE=')"

out="$(parse_enrich_args "373 --quick")"
assert_eq "--quick alone leaves HEADLESS=no" "HEADLESS=no" "$(printf '%s\n' "$out" | grep '^HEADLESS=')"

# The failure path must still emit all three lines, on stderr, and return 1.
err="$(parse_enrich_args "--headless" 2>&1 1>/dev/null || true)"
assert_eq "missing issue still reports HEADLESS" "HEADLESS=yes" "$(printf '%s\n' "$err" | grep '^HEADLESS=')"
rc=0; parse_enrich_args "--headless" >/dev/null 2>&1 || rc=$?
assert_eq "missing issue returns 1" "1" "$rc"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `tests/run-parse-enrich-args-tests.sh`
Expected: FAIL — the `HEADLESS=` assertions get an empty actual, because the
function emits only `ISSUE=` and `QUICK=`.

- [ ] **Step 3: Write the minimal implementation**

Replace the body of `parse_enrich_args` in `scripts/lib/parse-enrich-args.sh`
with this. Note the `--quick` detection is left exactly as it was — only the
headless lines are new.

```bash
parse_enrich_args() {
  local args="$1"
  local issue quick headless

  # Extract issue number: remove flags, strip leading #
  issue=$(echo "$args" | tr ' ' '\n' | grep -v '^--' | tr -d '#' | head -1)

  # Check for --quick flag
  quick=$(echo "$args" | grep -q -- '--quick' && echo yes || echo no)

  # Check for --headless flag
  headless=$(echo "$args" | grep -q -- '--headless' && echo yes || echo no)

  # --headless implies --quick. Headless cannot answer the approval gate, so
  # the non-quick combination would block forever with nobody there to unblock
  # it; making it unrepresentable is cheaper than detecting it later.
  [[ "$headless" == yes ]] && quick=yes

  # Validate issue is numeric
  if [[ -z "$issue" ]] || ! [[ "$issue" =~ ^[0-9]+$ ]]; then
    echo "ISSUE=" >&2
    echo "QUICK=$quick" >&2
    echo "HEADLESS=$headless" >&2
    return 1
  fi

  echo "ISSUE=$issue"
  echo "QUICK=$quick"
  echo "HEADLESS=$headless"
}
```

Also update the file's header comment block:

```bash
#   parse_enrich_args <arguments>
#   Parses: <issue-number> [--quick] [--headless]
#   Outputs: "ISSUE=<n>", "QUICK=yes|no" and "HEADLESS=yes|no" on separate lines.
#   --headless implies --quick.
#   Returns 1 if issue number is missing or non-numeric; 0 on success.
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `tests/run-parse-enrich-args-tests.sh`
Expected: PASS, including every pre-existing assertion — the two original output
lines are unchanged in both content and order.

- [ ] **Step 5: Lint**

Run: `shellcheck -x -e SC1091 scripts/lib/parse-enrich-args.sh tests/run-parse-enrich-args-tests.sh`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/parse-enrich-args.sh tests/run-parse-enrich-args-tests.sh
git commit -m "feat(enrich): parse --headless, which implies --quick (#373)"
```

---

### Task 3: Document `--headless` in the enrich command

Prose only, but load-bearing prose: this is the actual specification the nested
session executes.

**Files:**
- Modify: `commands/enrich.md`

**Interfaces:**
- Consumes: `HEADLESS=yes|no` from Task 2.
- Produces: the headless contract Task 11 relies on — specifically that a
  headless enrich applies `needs-human` itself and releases its own lock.

- [ ] **Step 1: Extend the argument-parsing block**

In the `## Argument parsing` section, the sentence describing what may accompany
the issue number currently reads:

```markdown
`$ARGUMENTS` may carry `--quick` alongside the issue number. Parse it in this block:
```

Replace it with:

```markdown
`$ARGUMENTS` may carry `--quick` and/or `--headless` alongside the issue number.
`--headless` implies `--quick`. Parse them in this block:
```

Then, in the same block, add `HEADLESS` to the extracted variables, after the
`QUICK=` line:

```bash
HEADLESS=$(echo "$parsed" | sed -n 's/^HEADLESS=//p')
```

And extend the sentence about variables not persisting so it names all three:
`$ISSUE`, `$QUICK` and `$HEADLESS`.

- [ ] **Step 2: Add the headless-mode section**

Insert a new section immediately after the existing `## Quick mode` section and
before the `## GitHub` section.

````markdown
## Headless mode

`--headless` is quick mode with nobody there to ask. It implies `--quick`, and
adds one absolute rule: **never prompt.** `AskUserQuestion` is forbidden. There
is no approval gate, no clarifying question, and no "tell me which you'd
prefer" — a blocked run must terminate with the block recorded, not wait.

Quick mode's escape hatch is to stop and ask on a
[one-way door](#one-way-door). Headless cannot. So on **any** of:

- a one-way door,
- a ⛔ Blocked entry in the Assumptions block,
- **any `[low]`-confidence assumption**,

the run does all of the following and then stops:

1. Writes the `## Assumptions` block into the issue body as usual, ⛔ items
   included — the whole point is that the human arrives to a stated open
   decision rather than a silent stall.
2. Pushes whatever spec exists. If brainstorming never got far enough to have a
   plan, there is no plan; say so in the issue body instead of inventing one.
3. Applies `needs-human`.
4. Releases the `enrichment-ongoing` lock.
5. Does **not** apply `ai-implement`.
6. Exits 0 — the caller is a loop over several issues, and one issue needing a
   human is a normal outcome, not a failure that should abort the batch.

`[low]` routing to a human follows #252: confidence is "how likely is the human
to disagree", so `[low]` is precisely the set of decisions worth a human's
attention, and until async review of an assumptions block is proven workable a
low-confidence guess gets a person.

Apply steps 3 and 4 in a **single** `gh issue edit` call — two calls against the
same issue race, which is the lesson of #365:

```bash
gh issue edit $ISSUE --add-label needs-human --remove-label enrichment-ongoing
```

Headless mode changes nothing else. Every other step of the GitHub section
below still runs: the lock, the spec, the plan, the push verification, the issue
body.
````

- [ ] **Step 3: Reference headless from the Quick mode section**

At the end of the `## Quick mode` section, after the Consequences example, add:

```markdown
When `--headless` is also set, the one-way-door escalation cannot be a question.
See [Headless mode](#headless-mode) — the door gets recorded and handed to a
human via `needs-human` instead.
```

- [ ] **Step 4: Update the one-way-door section**

The `## One-way door` section ends by saying quick-mode "stops and asks the user
to decide". Append:

```markdown
In **headless** mode there is no user to ask: the door is recorded as a ⛔
Blocked item and the issue is handed over with `needs-human`. See
[Headless mode](#headless-mode).
```

- [ ] **Step 5: Verify the flag reaches the command's own parser**

Run: `source scripts/lib/parse-enrich-args.sh && parse_enrich_args "373 --headless"`
Expected: three lines — `ISSUE=373`, `QUICK=yes`, `HEADLESS=yes`.

- [ ] **Step 6: Commit**

```bash
git add commands/enrich.md
git commit -m "docs(enrich): specify headless mode and its needs-human exit (#373)"
```

---

### Task 4: Config loading

**Files:**
- Create: `scripts/lib/autopilot-config.sh`
- Create: `setup/autopilot.conf.example`
- Create: `tests/run-autopilot-config-tests.sh`
- Create: `tests/fixtures/autopilot/config-valid.conf`
- Create: `tests/fixtures/autopilot/config-unknown-key.conf`
- Create: `tests/fixtures/autopilot/config-bad-max.conf`
- Create: `tests/fixtures/autopilot/config-bad-repo.conf`
- Create: `tests/fixtures/autopilot/config-no-repos.conf`

**Interfaces:**
- Consumes: nothing.
- Produces: `load_autopilot_config [file]` — returns 0 and sets
  `AUTOPILOT_MAX_PER_RUN` (int), `AUTOPILOT_ENRICH_TIMEOUT` (int) and
  `AUTOPILOT_REPOS` (array of `owner/name`); returns 1 with `error: …` on
  stderr otherwise. With no argument it reads
  `${AUTOPILOT_CONFIG:-$HOME/.config/agent-workflow/autopilot.conf}`.

- [ ] **Step 1: Write the fixtures**

`tests/fixtures/autopilot/config-valid.conf`:

```conf
# maximum issues enriched per run, across all repos
max_per_run=2

# per-issue timeout for the nested enrich session, in seconds
enrich_timeout=900

# allowlisted repos, one line each
repo=freaxnx01/agent-action-sandbox
repo=freaxnx01/game-tschau-sepp   # trailing comment
```

`tests/fixtures/autopilot/config-unknown-key.conf`:

```conf
repo=freaxnx01/agent-action-sandbox
max_per_runs=3
```

`tests/fixtures/autopilot/config-bad-max.conf`:

```conf
repo=freaxnx01/agent-action-sandbox
max_per_run=zero
```

`tests/fixtures/autopilot/config-bad-repo.conf`:

```conf
repo=agent-action-sandbox
```

`tests/fixtures/autopilot/config-no-repos.conf`:

```conf
max_per_run=3
```

- [ ] **Step 2: Write the failing test runner**

Create `tests/run-autopilot-config-tests.sh`. The harness block (colours,
`section`, `pass`, `fail`, `assert_eq`, summary) is copied from
`tests/run-parse-enrich-args-tests.sh` — that duplication is the established
convention in this suite, where each runner is self-contained.

```bash
#!/usr/bin/env bash
#
# run-autopilot-config-tests.sh — Layer-1 fixture tests for
# scripts/lib/autopilot-config.sh (no network). Sources the lib and asserts
# what load_autopilot_config sets, and what it refuses.
#
# Usage: tests/run-autopilot-config-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/scripts/lib/autopilot-config.sh"
FIX="$ROOT/tests/fixtures/autopilot"

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

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    pass "$name"
  else
    fail "$name" "expected: $expected | actual: $actual"
  fi
}

# shellcheck source=scripts/lib/autopilot-config.sh disable=SC1091
source "$LIB"

section "valid config"

rc=0; load_autopilot_config "$FIX/config-valid.conf" >/dev/null 2>&1 || rc=$?
assert_eq "valid config returns 0" "0" "$rc"
assert_eq "max_per_run parsed" "2" "$AUTOPILOT_MAX_PER_RUN"
assert_eq "enrich_timeout parsed" "900" "$AUTOPILOT_ENRICH_TIMEOUT"
assert_eq "two repos parsed" "2" "${#AUTOPILOT_REPOS[@]}"
assert_eq "first repo" "freaxnx01/agent-action-sandbox" "${AUTOPILOT_REPOS[0]}"
assert_eq "trailing comment stripped" "freaxnx01/game-tschau-sepp" "${AUTOPILOT_REPOS[1]}"

section "defaults"

printf 'repo=freaxnx01/agent-action-sandbox\n' > "$TMPDIR_T/minimal.conf"
rc=0; load_autopilot_config "$TMPDIR_T/minimal.conf" >/dev/null 2>&1 || rc=$?
assert_eq "minimal config returns 0" "0" "$rc"
assert_eq "max_per_run defaults to 3" "3" "$AUTOPILOT_MAX_PER_RUN"
assert_eq "enrich_timeout defaults to 1800" "1800" "$AUTOPILOT_ENRICH_TIMEOUT"

section "refusals"

for case_name in unknown-key bad-max bad-repo no-repos; do
  rc=0; load_autopilot_config "$FIX/config-$case_name.conf" >/dev/null 2>&1 || rc=$?
  assert_eq "$case_name returns 1" "1" "$rc"
done

rc=0; load_autopilot_config "$FIX/does-not-exist.conf" >/dev/null 2>&1 || rc=$?
assert_eq "missing file returns 1" "1" "$rc"

err="$(load_autopilot_config "$FIX/config-unknown-key.conf" 2>&1 >/dev/null || true)"
case "$err" in
  *"unknown key"*) pass "unknown key names the problem" ;;
  *) fail "unknown key names the problem" "stderr was: $err" ;;
esac

section "AUTOPILOT_CONFIG env default"

rc=0
AUTOPILOT_CONFIG="$FIX/config-valid.conf" load_autopilot_config >/dev/null 2>&1 || rc=$?
assert_eq "reads AUTOPILOT_CONFIG when given no argument" "0" "$rc"

printf '\n%s──────────%s\n' "$C_DIM" "$C_OFF"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'failed:\n'
  for n in "${FAIL_NAMES[@]}"; do printf -- '  - %s\n' "$n"; done
  exit 1
fi
exit 0
```

The runner needs a scratch dir for the `defaults` section. Add this right after
the `FIX=` assignment, so the `trap` is registered before anything can fail:

```bash
TMPDIR_T="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_T"' EXIT
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `tests/run-autopilot-config-tests.sh`
Expected: FAIL immediately — `source` cannot find
`scripts/lib/autopilot-config.sh`, which does not exist yet.

- [ ] **Step 4: Write the implementation**

Create `scripts/lib/autopilot-config.sh`:

```bash
#!/usr/bin/env bash
#
# autopilot-config.sh — sourced, not executed.
#   load_autopilot_config [file]
#
# Reads the autopilot config and sets:
#   AUTOPILOT_MAX_PER_RUN     global cap on issues enriched per run (default 3)
#   AUTOPILOT_ENRICH_TIMEOUT  per-issue timeout in seconds (default 1800)
#   AUTOPILOT_REPOS           array of allowlisted owner/name repos
#
# With no argument, reads $AUTOPILOT_CONFIG, else
# ~/.config/agent-workflow/autopilot.conf. The real file is host-local and not
# in git: the allowlist is host policy ("which repos do I let merge AI PRs
# unattended"), and agent-workflow is a public repo. setup/autopilot.conf.example
# documents the shape.
#
# Validation is fail-fast on purpose. A silently-defaulted allowlist is the one
# failure mode that could aim an unattended lane at a repo nobody approved, so
# an unknown key, a bad value or a missing file is an error — never a default.
#
# Returns 0 on success; prints 'error: <file>:<line>: …' to stderr and returns 1
# otherwise.
set -euo pipefail
IFS=$'\n\t'

load_autopilot_config() {
  local file="${1:-${AUTOPILOT_CONFIG:-$HOME/.config/agent-workflow/autopilot.conf}}"
  local line key value lineno=0

  AUTOPILOT_MAX_PER_RUN=3
  AUTOPILOT_ENRICH_TIMEOUT=1800
  AUTOPILOT_REPOS=()

  if [[ ! -r "$file" ]]; then
    printf 'error: config not readable: %s\n' "$file" >&2
    return 1
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    line="${line%%#*}"                              # strip comments
    line="${line#"${line%%[![:space:]]*}"}"         # ltrim
    line="${line%"${line##*[![:space:]]}"}"         # rtrim
    [[ -z "$line" ]] && continue

    if [[ "$line" != *=* ]]; then
      printf 'error: %s:%d: not a key=value line: %s\n' "$file" "$lineno" "$line" >&2
      return 1
    fi

    key="${line%%=*}"
    value="${line#*=}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"

    case "$key" in
      max_per_run)
        if ! [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
          printf 'error: %s:%d: max_per_run must be a positive integer: %s\n' "$file" "$lineno" "$value" >&2
          return 1
        fi
        AUTOPILOT_MAX_PER_RUN="$value"
        ;;
      enrich_timeout)
        if ! [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
          printf 'error: %s:%d: enrich_timeout must be a positive integer: %s\n' "$file" "$lineno" "$value" >&2
          return 1
        fi
        AUTOPILOT_ENRICH_TIMEOUT="$value"
        ;;
      repo)
        if ! [[ "$value" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
          printf 'error: %s:%d: repo must be owner/name: %s\n' "$file" "$lineno" "$value" >&2
          return 1
        fi
        AUTOPILOT_REPOS+=("$value")
        ;;
      *)
        printf 'error: %s:%d: unknown key: %s\n' "$file" "$lineno" "$key" >&2
        return 1
        ;;
    esac
  done < "$file"

  if (( ${#AUTOPILOT_REPOS[@]} == 0 )); then
    printf 'error: %s: no repo= lines — an empty allowlist would do nothing\n' "$file" >&2
    return 1
  fi

  return 0
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `tests/run-autopilot-config-tests.sh`
Expected: PASS, all assertions.

- [ ] **Step 6: Write the committed example config**

Create `setup/autopilot.conf.example`:

```conf
# autopilot.conf — host-local config for the unattended enrich lane (/autopilot).
#
# Copy to ~/.config/agent-workflow/autopilot.conf and edit. This file is the
# documented shape; the real one is NOT in git, because the allowlist is host
# policy rather than library content and agent-workflow is a public repo.
#
# Syntax: key=value, one per line. '#' starts a comment. Unknown keys, bad
# values and an empty allowlist are all hard errors — never silent defaults.

# Global cap on issues enriched per run, across every repo below.
# Each one costs a nested Claude session, so this is the cost ceiling.
max_per_run=3

# Per-issue timeout for the nested enrich session, in seconds.
enrich_timeout=1800

# Allowlisted repos, one line each. This is the outer gate: a repo not listed
# here is never touched, no matter what its own agent.yml says. A repo also
# needs `ai-review-ai-merge: true` and an `autopilot-test-gate:` that has
# actually run — see docs/AUTOPILOT.md.
#
# Start with the sandbox. Add a real repo only after an end-to-end run.
repo=freaxnx01/agent-action-sandbox
```

- [ ] **Step 7: Lint**

Run: `shellcheck -x -e SC1091 scripts/lib/autopilot-config.sh tests/run-autopilot-config-tests.sh`
Expected: no output.

- [ ] **Step 8: Commit**

```bash
git add scripts/lib/autopilot-config.sh setup/autopilot.conf.example \
        tests/run-autopilot-config-tests.sh tests/fixtures/autopilot/
git commit -m "feat(autopilot): load and validate the host-local config (#373)"
```

---

### Task 5: A response seam for the `gh` mock

The existing mock logs argv and exits 0. Autopilot's libs need `gh` to *return*
JSON, so the mock needs a way to serve canned responses. Two generic seams, not
per-command branches, so later tasks add fixtures rather than mock code.

**Files:**
- Modify: `tests/mocks/gh`
- Create: `tests/run-gh-mock-tests.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: two env seams on `tests/mocks/gh`:
  - `GH_MOCK_FAIL_MAP` — a file of substrings, one per line; if any occurs in
    the joined argv, the mock exits 1 with no stdout.
  - `GH_MOCK_STDOUT_MAP` — a file of `<substring><TAB><fixture-path>` lines;
    the **first** line whose substring occurs in the joined argv makes the mock
    `cat` that fixture and exit 0.
  `GH_MOCK_FAIL_MAP` is consulted first, so a test can make a call fail even
  when a broader stdout pattern would also have matched.

- [ ] **Step 1: Write the failing test**

Create `tests/run-gh-mock-tests.sh` with the same harness header as Task 4's
runner (copy the block from `TMPDIR_T` down through `assert_eq`), then:

```bash
export PATH="$ROOT/tests/mocks:$PATH"
export GH_MOCK_LOG="$TMPDIR_T/gh.log"
: > "$GH_MOCK_LOG"

section "argv logging still works"

gh issue list --repo o/r >/dev/null
assert_eq "argv logged" "issue list --repo o/r" "$(tail -1 "$GH_MOCK_LOG")"

section "GH_MOCK_STDOUT_MAP"

printf '{"ok":true}\n' > "$TMPDIR_T/body.json"
printf 'issue list\t%s\n' "$TMPDIR_T/body.json" > "$TMPDIR_T/stdout.map"

out="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/stdout.map" gh issue list --repo o/r)"
assert_eq "matching pattern serves the fixture" '{"ok":true}' "$out"

out="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/stdout.map" gh pr list --repo o/r)"
assert_eq "non-matching pattern serves nothing" "" "$out"

printf 'issue list\t%s\nissue\t/dev/null\n' "$TMPDIR_T/body.json" > "$TMPDIR_T/first.map"
out="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/first.map" gh issue list --repo o/r)"
assert_eq "first matching line wins" '{"ok":true}' "$out"

section "GH_MOCK_FAIL_MAP"

printf 'actions/workflows\n' > "$TMPDIR_T/fail.map"
rc=0
GH_MOCK_FAIL_MAP="$TMPDIR_T/fail.map" gh api repos/o/r/actions/workflows/ci.yml/runs >/dev/null 2>&1 || rc=$?
assert_eq "matching fail pattern exits 1" "1" "$rc"

rc=0
GH_MOCK_FAIL_MAP="$TMPDIR_T/fail.map" gh api repos/o/r >/dev/null 2>&1 || rc=$?
assert_eq "non-matching fail pattern exits 0" "0" "$rc"

rc=0
GH_MOCK_FAIL_MAP="$TMPDIR_T/fail.map" GH_MOCK_STDOUT_MAP="$TMPDIR_T/stdout.map" \
  gh api repos/o/r/actions/workflows/ci.yml/runs >/dev/null 2>&1 || rc=$?
assert_eq "fail map is consulted before stdout map" "1" "$rc"
```

Close with the same summary block as Task 4's runner.

- [ ] **Step 2: Run the test to verify it fails**

Run: `tests/run-gh-mock-tests.sh`
Expected: FAIL — the fixture-serving assertions get `""`, because the mock has
no stdout map yet.

- [ ] **Step 3: Implement the seams**

In `tests/mocks/gh`, extend the header comment's seam list:

```bash
#   GH_MOCK_STDOUT_MAP            file of "<substring>\t<fixture>" lines; first
#                                 substring found in argv is cat'd to stdout
#   GH_MOCK_FAIL_MAP              file of substrings, one per line; a match in
#                                 argv exits 1 with no stdout (checked first)
```

Then, immediately after the existing argv-logging line and before the
`gh auth token` branch, insert:

```bash
argv="$*"

# Response seams. These are generic on purpose: a new test adds a fixture and a
# pattern line, never a branch here.
if [[ -n "${GH_MOCK_FAIL_MAP:-}" && -r "${GH_MOCK_FAIL_MAP}" ]]; then
  while IFS= read -r pattern || [[ -n "$pattern" ]]; do
    [[ -z "$pattern" ]] && continue
    [[ "$argv" == *"$pattern"* ]] && exit 1
  done < "$GH_MOCK_FAIL_MAP"
fi

if [[ -n "${GH_MOCK_STDOUT_MAP:-}" && -r "${GH_MOCK_STDOUT_MAP}" ]]; then
  while IFS=$'\t' read -r pattern fixture || [[ -n "$pattern" ]]; do
    [[ -z "$pattern" ]] && continue
    if [[ "$argv" == *"$pattern"* ]]; then
      cat "$fixture"
      exit 0
    fi
  done < "$GH_MOCK_STDOUT_MAP"
fi
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `tests/run-gh-mock-tests.sh`
Expected: PASS.

- [ ] **Step 5: Verify no existing suite regressed**

Run: `tests/run-all.sh`
Expected: every runner OK. The seams are inert when the env vars are unset, so
every suite that already used the mock must be unaffected — this is the
assertion that matters in this step.

- [ ] **Step 6: Lint and commit**

```bash
shellcheck -x -e SC1091 tests/mocks/gh tests/run-gh-mock-tests.sh
git add tests/mocks/gh tests/run-gh-mock-tests.sh
git commit -m "test(mocks): let the gh mock serve canned responses (#373)"
```

---

### Task 6: Candidate selection

**Files:**
- Create: `scripts/lib/autopilot-candidates.sh`
- Create: `tests/run-autopilot-candidates-tests.sh`
- Create: `tests/fixtures/autopilot/issues-mixed.json`
- Create: `tests/fixtures/autopilot/issues-empty.json`

**Interfaces:**
- Consumes: the `GH_MOCK_STDOUT_MAP` seam from Task 5.
- Produces: `autopilot_candidates <owner/repo> <limit>` — writes candidate issue
  numbers to stdout, one per line, oldest `createdAt` first, at most `<limit>`
  of them. Returns non-zero if the `gh` call fails. Writes nothing else.

- [ ] **Step 1: Write the fixtures**

`tests/fixtures/autopilot/issues-mixed.json` — one issue per exclusion rule,
deliberately out of chronological order so the sort is actually tested. The
shape matches `gh issue list --json number,body,createdAt,labels`.

```json
[
  {
    "number": 50,
    "body": "newer but fine",
    "createdAt": "2026-09-10T00:00:00Z",
    "labels": [{"name": "needs-enrichment"}]
  },
  {
    "number": 41,
    "body": "oldest eligible",
    "createdAt": "2026-09-01T00:00:00Z",
    "labels": [{"name": "needs-enrichment"}, {"name": "bug"}]
  },
  {
    "number": 42,
    "body": "parked",
    "createdAt": "2026-09-02T00:00:00Z",
    "labels": [{"name": "needs-enrichment"}, {"name": "🧊 parked"}]
  },
  {
    "number": 43,
    "body": "already being enriched",
    "createdAt": "2026-09-03T00:00:00Z",
    "labels": [{"name": "needs-enrichment"}, {"name": "enrichment-ongoing"}]
  },
  {
    "number": 44,
    "body": "handed to a human already",
    "createdAt": "2026-09-04T00:00:00Z",
    "labels": [{"name": "needs-enrichment"}, {"name": "needs-human"}]
  },
  {
    "number": 45,
    "body": "already dispatched",
    "createdAt": "2026-09-05T00:00:00Z",
    "labels": [{"name": "needs-enrichment"}, {"name": "ai-implement"}]
  },
  {
    "number": 46,
    "body": "",
    "createdAt": "2026-09-06T00:00:00Z",
    "labels": [{"name": "needs-enrichment"}]
  },
  {
    "number": 47,
    "body": "   \n\t  ",
    "createdAt": "2026-09-07T00:00:00Z",
    "labels": [{"name": "needs-enrichment"}]
  },
  {
    "number": 48,
    "body": null,
    "createdAt": "2026-09-08T00:00:00Z",
    "labels": [{"name": "needs-enrichment"}]
  },
  {
    "number": 49,
    "body": "second oldest eligible",
    "createdAt": "2026-09-09T00:00:00Z",
    "labels": [{"name": "needs-enrichment"}]
  }
]
```

Eligible set, oldest first: `41`, `49`, `50`.

`tests/fixtures/autopilot/issues-empty.json`:

```json
[]
```

- [ ] **Step 2: Write the failing tests**

Create `tests/run-autopilot-candidates-tests.sh` with the Task 4 harness header,
then:

```bash
export PATH="$ROOT/tests/mocks:$PATH"
export GH_MOCK_LOG="$TMPDIR_T/gh.log"
: > "$GH_MOCK_LOG"

# shellcheck source=scripts/lib/autopilot-candidates.sh disable=SC1091
source "$ROOT/scripts/lib/autopilot-candidates.sh"

printf 'issue list\t%s\n' "$FIX/issues-mixed.json" > "$TMPDIR_T/mixed.map"
printf 'issue list\t%s\n' "$FIX/issues-empty.json" > "$TMPDIR_T/empty.map"

section "selection and ordering"

out="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/mixed.map" autopilot_candidates o/r 10 | tr '\n' ' ')"
assert_eq "eligible issues, oldest first" "41 49 50 " "$out"

section "the limit"

out="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/mixed.map" autopilot_candidates o/r 2 | tr '\n' ' ')"
assert_eq "limit truncates, keeping the oldest" "41 49 " "$out"

out="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/mixed.map" autopilot_candidates o/r 1 | tr '\n' ' ')"
assert_eq "limit of 1 yields the oldest" "41 " "$out"

section "exclusions"

# Each of these numbers is in the fixture and must never be selected.
out="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/mixed.map" autopilot_candidates o/r 10)"
for n in 42 43 44 45 46 47 48; do
  if printf '%s\n' "$out" | grep -qx "$n"; then
    fail "issue $n excluded" "it was selected"
  else
    pass "issue $n excluded"
  fi
done

section "empty result"

out="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/empty.map" autopilot_candidates o/r 10)"
assert_eq "no issues yields no output" "" "$out"

section "the query"

: > "$GH_MOCK_LOG"
GH_MOCK_STDOUT_MAP="$TMPDIR_T/mixed.map" autopilot_candidates o/r 10 >/dev/null
logged="$(tail -1 "$GH_MOCK_LOG")"
case "$logged" in
  *"--repo o/r"*) pass "queries the named repo" ;;
  *) fail "queries the named repo" "argv was: $logged" ;;
esac
case "$logged" in
  *"--label needs-enrichment"*) pass "filters needs-enrichment server-side" ;;
  *) fail "filters needs-enrichment server-side" "argv was: $logged" ;;
esac
case "$logged" in
  *"--state open"*) pass "asks for open issues only" ;;
  *) fail "asks for open issues only" "argv was: $logged" ;;
esac

section "gh failure"

printf 'issue list\n' > "$TMPDIR_T/fail.map"
rc=0
GH_MOCK_FAIL_MAP="$TMPDIR_T/fail.map" autopilot_candidates o/r 10 >/dev/null 2>&1 || rc=$?
if (( rc != 0 )); then pass "gh failure propagates"; else fail "gh failure propagates" "returned 0"; fi
```

Close with the summary block.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `tests/run-autopilot-candidates-tests.sh`
Expected: FAIL — `source` cannot find the lib.

- [ ] **Step 4: Write the implementation**

Create `scripts/lib/autopilot-candidates.sh`:

```bash
#!/usr/bin/env bash
#
# autopilot-candidates.sh — sourced, not executed.
#   autopilot_candidates <owner/repo> <limit>
#
# Writes the issue numbers the unattended lane may enrich, one per line, oldest
# first, at most <limit> of them. Query-only: reads GitHub and writes nothing.
#
# An issue is a candidate iff all of:
#   - open, and carries needs-enrichment              (both filtered server-side)
#   - carries none of: 🧊 parked, enrichment-ongoing, needs-human, ai-implement
#   - has a non-whitespace body
#
# enrichment-ongoing is an *exclusion only*. /enrich owns that lock and acquires
# it itself; a caller that pre-applied it would make every enrich session think
# it had lost a race. needs-human is what stops the lane re-enriching an issue a
# human has already been asked to decide on.
#
# Returns non-zero if the gh query fails. Requires: gh (authenticated), jq.
set -euo pipefail
IFS=$'\n\t'

autopilot_candidates() {
  local repo="$1" limit="$2" json

  json="$(gh issue list --repo "$repo" --state open --label needs-enrichment \
            --limit 100 --json number,body,createdAt,labels)" || return 1

  printf '%s' "$json" | jq -r --argjson limit "$limit" '
    [ .[]
      | select(((.body // "") | gsub("\\s"; "") | length) > 0)
      | select(
          [.labels[].name]
          | any(. == "🧊 parked"
                or . == "enrichment-ongoing"
                or . == "needs-human"
                or . == "ai-implement")
          | not
        )
    ]
    | sort_by(.createdAt)
    | .[:$limit]
    | .[].number
  '
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `tests/run-autopilot-candidates-tests.sh`
Expected: PASS, all assertions.

- [ ] **Step 6: Lint and commit**

```bash
shellcheck -x -e SC1091 scripts/lib/autopilot-candidates.sh tests/run-autopilot-candidates-tests.sh
git add scripts/lib/autopilot-candidates.sh tests/run-autopilot-candidates-tests.sh \
        tests/fixtures/autopilot/issues-mixed.json tests/fixtures/autopilot/issues-empty.json
git commit -m "feat(autopilot): select enrichable candidates, oldest first (#373)"
```

---

### Task 7: Repo eligibility

**Files:**
- Create: `scripts/lib/autopilot-eligible.sh`
- Create: `tests/run-autopilot-eligible-tests.sh`
- Create: `tests/fixtures/autopilot/agent-yml-good.yml`
- Create: `tests/fixtures/autopilot/agent-yml-no-merge.yml`
- Create: `tests/fixtures/autopilot/agent-yml-no-gate.yml`
- Create: `tests/fixtures/autopilot/repo-meta.json`
- Create: `tests/fixtures/autopilot/runs-one.json`
- Create: `tests/fixtures/autopilot/runs-none.json`

**Interfaces:**
- Consumes: the `GH_MOCK_STDOUT_MAP` / `GH_MOCK_FAIL_MAP` seams from Task 5.
- Produces: `repo_eligible <owner/repo>` — returns 0 if the repo may be
  auto-laned, 1 otherwise, and writes a one-line human-readable reason to
  stdout in **both** cases. The driver logs that reason verbatim.

- [ ] **Step 1: Write the fixtures**

`tests/fixtures/autopilot/agent-yml-good.yml` — a consumer stub declaring both
required keys:

```yaml
name: Agent
on:
  issues:
    types: [labeled]
jobs:
  agent:
    uses: freaxnx01/agent-workflow/.github/workflows/agent.yml@v3
    with:
      ai-review-ai-merge: true
      autopilot-test-gate: ci.yml
    secrets: inherit
```

`tests/fixtures/autopilot/agent-yml-no-merge.yml` — same, but
`ai-review-ai-merge: false`.

`tests/fixtures/autopilot/agent-yml-no-gate.yml` — same as good, with the
`autopilot-test-gate:` line removed.

`tests/fixtures/autopilot/repo-meta.json`:

```json
{"default_branch": "main"}
```

`tests/fixtures/autopilot/runs-one.json`:

```json
{"total_count": 1}
```

`tests/fixtures/autopilot/runs-none.json`:

```json
{"total_count": 0}
```

- [ ] **Step 2: Write the failing tests**

Create `tests/run-autopilot-eligible-tests.sh` with the Task 4 harness header,
then:

```bash
export PATH="$ROOT/tests/mocks:$PATH"
export GH_MOCK_LOG="$TMPDIR_T/gh.log"
: > "$GH_MOCK_LOG"

# shellcheck source=scripts/lib/autopilot-eligible.sh disable=SC1091
source "$ROOT/scripts/lib/autopilot-eligible.sh"

# The three gh calls repo_eligible makes are distinguished by these substrings:
#   contents/.github/workflows/agent.yml   → the consumer stub
#   actions/workflows/                     → the test gate's runs
#   repos/o/r --jq .default_branch         → the default branch
write_map() {
  local agent_yml="$1" runs="$2" dest="$3"
  {
    printf 'contents/.github/workflows/agent.yml\t%s\n' "$agent_yml"
    printf 'actions/workflows/\t%s\n' "$runs"
    printf 'repos/o/r\t%s\n' "$FIX/repo-meta.json"
  } > "$dest"
}

section "eligible"

write_map "$FIX/agent-yml-good.yml" "$FIX/runs-one.json" "$TMPDIR_T/good.map"
rc=0
reason="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/good.map" repo_eligible o/r)" || rc=$?
assert_eq "all conditions met returns 0" "0" "$rc"
case "$reason" in
  *eligible*) pass "reason says eligible" ;;
  *) fail "reason says eligible" "reason was: $reason" ;;
esac
case "$reason" in
  *ci.yml*) pass "reason names the gate" ;;
  *) fail "reason names the gate" "reason was: $reason" ;;
esac

section "ai-review-ai-merge not set"

write_map "$FIX/agent-yml-no-merge.yml" "$FIX/runs-one.json" "$TMPDIR_T/nomerge.map"
rc=0
reason="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/nomerge.map" repo_eligible o/r)" || rc=$?
assert_eq "ai-review-ai-merge false returns 1" "1" "$rc"
case "$reason" in
  *ai-review-ai-merge*) pass "reason names ai-review-ai-merge" ;;
  *) fail "reason names ai-review-ai-merge" "reason was: $reason" ;;
esac

section "no test gate declared"

write_map "$FIX/agent-yml-no-gate.yml" "$FIX/runs-one.json" "$TMPDIR_T/nogate.map"
rc=0
reason="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/nogate.map" repo_eligible o/r)" || rc=$?
assert_eq "missing autopilot-test-gate returns 1" "1" "$rc"
case "$reason" in
  *autopilot-test-gate*) pass "reason names autopilot-test-gate" ;;
  *) fail "reason names autopilot-test-gate" "reason was: $reason" ;;
esac

section "test gate has never run"

write_map "$FIX/agent-yml-good.yml" "$FIX/runs-none.json" "$TMPDIR_T/noruns.map"
rc=0
reason="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/noruns.map" repo_eligible o/r)" || rc=$?
assert_eq "zero completed runs returns 1" "1" "$rc"
case "$reason" in
  *"never completed"*) pass "reason says the gate never ran" ;;
  *) fail "reason says the gate never ran" "reason was: $reason" ;;
esac

section "test gate does not exist"

write_map "$FIX/agent-yml-good.yml" "$FIX/runs-one.json" "$TMPDIR_T/gate404.map"
printf 'actions/workflows/\n' > "$TMPDIR_T/gate404.fail"
rc=0
reason="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/gate404.map" GH_MOCK_FAIL_MAP="$TMPDIR_T/gate404.fail" repo_eligible o/r)" || rc=$?
assert_eq "gate 404 returns 1" "1" "$rc"
case "$reason" in
  *"not found"*) pass "reason says the gate was not found" ;;
  *) fail "reason says the gate was not found" "reason was: $reason" ;;
esac

section "no agent.yml at all"

printf 'contents/.github/workflows/agent.yml\n' > "$TMPDIR_T/noyml.fail"
rc=0
reason="$(GH_MOCK_FAIL_MAP="$TMPDIR_T/noyml.fail" repo_eligible o/r)" || rc=$?
assert_eq "no agent.yml returns 1" "1" "$rc"
case "$reason" in
  *agent.yml*) pass "reason names the missing agent.yml" ;;
  *) fail "reason names the missing agent.yml" "reason was: $reason" ;;
esac
```

Close with the summary block.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `tests/run-autopilot-eligible-tests.sh`
Expected: FAIL — `source` cannot find the lib.

- [ ] **Step 4: Write the implementation**

Create `scripts/lib/autopilot-eligible.sh`:

```bash
#!/usr/bin/env bash
#
# autopilot-eligible.sh — sourced, not executed.
#   repo_eligible <owner/repo>
#
# Returns 0 if the repo may be auto-laned, 1 otherwise, and writes a one-line
# reason to stdout either way — the driver logs it verbatim, so the reason is
# the whole diagnostic.
#
# Two conditions, both required:
#   1. The consumer's .github/workflows/agent.yml declares BOTH
#      `ai-review-ai-merge: true` and `autopilot-test-gate: <workflow-file>`.
#   2. That workflow exists and has at least one COMPLETED run on the default
#      branch.
#
# (The allowlist is the third condition, enforced by the driver before this is
# called — an outer gate that cannot be flipped from inside a consumer repo.)
#
# Condition 2 is #263: no auto-merge on a gate that has never run. The repo
# names its own gate rather than this script guessing which workflow is "the
# tests" — a heuristic guarding auto-merge means a workflow rename silently
# changes eligibility.
#
# Query-only. Requires: gh (authenticated).
set -euo pipefail
IFS=$'\n\t'

repo_eligible() {
  local repo="$1" yaml gate default_branch runs

  yaml="$(gh api -H 'Accept: application/vnd.github.raw' \
            "repos/$repo/contents/.github/workflows/agent.yml" 2>/dev/null)" || yaml=''
  if [[ -z "$yaml" ]]; then
    printf 'no .github/workflows/agent.yml\n'
    return 1
  fi

  if ! grep -Eq '^[[:space:]]*ai-review-ai-merge:[[:space:]]*true[[:space:]]*$' <<< "$yaml"; then
    printf 'agent.yml does not set ai-review-ai-merge: true\n'
    return 1
  fi

  gate="$(grep -E '^[[:space:]]*autopilot-test-gate:' <<< "$yaml" \
            | head -1 \
            | sed -E 's/^[[:space:]]*autopilot-test-gate:[[:space:]]*//; s/[[:space:]]+$//; s/^["'\'']//; s/["'\'']$//')"
  if [[ -z "$gate" ]]; then
    printf 'agent.yml does not declare autopilot-test-gate\n'
    return 1
  fi

  default_branch="$(gh api "repos/$repo" --jq '.default_branch' 2>/dev/null)" || default_branch=''
  if [[ -z "$default_branch" ]]; then
    printf 'could not read the default branch\n'
    return 1
  fi

  runs="$(gh api "repos/$repo/actions/workflows/$gate/runs?branch=$default_branch&status=completed&per_page=1" \
            --jq '.total_count' 2>/dev/null)" || runs=''
  if [[ -z "$runs" ]]; then
    printf 'test gate %s not found\n' "$gate"
    return 1
  fi
  if (( runs == 0 )); then
    printf 'test gate %s has never completed a run on %s\n' "$gate" "$default_branch"
    return 1
  fi

  printf 'eligible (gate %s, %s completed run(s) on %s)\n' "$gate" "$runs" "$default_branch"
  return 0
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `tests/run-autopilot-eligible-tests.sh`
Expected: PASS, all assertions.

Note on the mock: `gh api --jq` is served by the stdout map as the raw fixture,
so `repo-meta.json` and `runs-*.json` are full objects and the `--jq` flag is
not actually applied by the mock. The implementation must therefore tolerate the
whole object where it expects a scalar — which is why `default_branch` and
`runs` are both extracted with `jq` **inside** the function rather than via
`gh --jq`. If Step 5 fails on `(( runs == 0 ))` with a syntax error, this is the
cause: change the two calls to pipe through `jq -r '.default_branch'` and
`jq -r '.total_count'` respectively and drop the `--jq` flags.

- [ ] **Step 6: Lint and commit**

```bash
shellcheck -x -e SC1091 scripts/lib/autopilot-eligible.sh tests/run-autopilot-eligible-tests.sh
git add scripts/lib/autopilot-eligible.sh tests/run-autopilot-eligible-tests.sh \
        tests/fixtures/autopilot/agent-yml-*.yml tests/fixtures/autopilot/repo-meta.json \
        tests/fixtures/autopilot/runs-*.json
git commit -m "feat(autopilot): gate repos on ai-review-ai-merge and a run test gate (#373)"
```

---

### Task 8: The managed clone cache

**Files:**
- Create: `scripts/lib/autopilot-clone.sh`
- Create: `tests/run-autopilot-clone-tests.sh`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `autopilot_clone_dir <owner/repo>` — **query**, prints the cache path for
    that repo (`<cache root>/<owner>__<name>`), touches nothing.
  - `sync_autopilot_clone <owner/repo>` — **command**, clones or refreshes that
    cache entry to a clean default branch. Returns 0 on success, 1 on failure,
    and prints nothing on success. Clone URL base is
    `${AUTOPILOT_CLONE_URL_BASE:-https://github.com}`, which is what lets the
    tests point at a local bare repo instead of the network.

The query/command split is deliberate: `sync_autopilot_clone` must not also
return the path, per this repo's command-query separation rule. Callers ask
`autopilot_clone_dir` for the path.

- [ ] **Step 1: Write the failing tests**

Create `tests/run-autopilot-clone-tests.sh` with the Task 4 harness header,
then:

```bash
# shellcheck source=scripts/lib/autopilot-clone.sh disable=SC1091
source "$ROOT/scripts/lib/autopilot-clone.sh"

export AUTOPILOT_CACHE_DIR="$TMPDIR_T/cache"
export AUTOPILOT_CLONE_URL_BASE="file://$TMPDIR_T/origins"

# A local bare origin with one commit on main. Hermetic: file:// is not network.
setup_origin() {
  local bare="$TMPDIR_T/origins/o/r.git" work="$TMPDIR_T/work"
  mkdir -p "$(dirname "$bare")"
  git init --quiet --bare --initial-branch=main "$bare"
  git init --quiet --initial-branch=main "$work"
  git -C "$work" -c user.email=t@t -c user.name=t commit --quiet --allow-empty -m "initial"
  printf 'hello\n' > "$work/README.md"
  git -C "$work" add README.md
  git -C "$work" -c user.email=t@t -c user.name=t commit --quiet -m "readme"
  git -C "$work" remote add origin "$bare"
  git -C "$work" push --quiet origin main
}
setup_origin

section "autopilot_clone_dir"

assert_eq "path mangles the slash" "$TMPDIR_T/cache/o__r" "$(autopilot_clone_dir o/r)"
if [[ -e "$TMPDIR_T/cache/o__r" ]]; then
  fail "the query creates nothing" "the directory exists"
else
  pass "the query creates nothing"
fi

section "first sync clones"

rc=0; sync_autopilot_clone o/r >/dev/null 2>&1 || rc=$?
assert_eq "first sync returns 0" "0" "$rc"
dir="$(autopilot_clone_dir o/r)"
if [[ -d "$dir/.git" ]]; then pass "clone exists"; else fail "clone exists" "$dir has no .git"; fi
assert_eq "checked out content" "hello" "$(cat "$dir/README.md")"
assert_eq "on the default branch" "main" "$(git -C "$dir" rev-parse --abbrev-ref HEAD)"

section "sync discards local mess"

printf 'tampered\n' > "$dir/README.md"
printf 'junk\n' > "$dir/untracked.txt"
git -C "$dir" -c user.email=t@t -c user.name=t commit --quiet -am "local junk commit"

rc=0; sync_autopilot_clone o/r >/dev/null 2>&1 || rc=$?
assert_eq "second sync returns 0" "0" "$rc"
assert_eq "tracked change discarded" "hello" "$(cat "$dir/README.md")"
if [[ -e "$dir/untracked.txt" ]]; then
  fail "untracked file cleaned" "untracked.txt survived"
else
  pass "untracked file cleaned"
fi
assert_eq "local commit discarded" "$(git -C "$dir" rev-parse origin/main)" "$(git -C "$dir" rev-parse HEAD)"

section "sync picks up new upstream commits"

work="$TMPDIR_T/work"
printf 'updated\n' > "$work/README.md"
git -C "$work" -c user.email=t@t -c user.name=t commit --quiet -am "update"
git -C "$work" push --quiet origin main

rc=0; sync_autopilot_clone o/r >/dev/null 2>&1 || rc=$?
assert_eq "third sync returns 0" "0" "$rc"
assert_eq "fast-forwarded to upstream" "updated" "$(cat "$dir/README.md")"

section "a missing origin fails"

rc=0; sync_autopilot_clone o/does-not-exist >/dev/null 2>&1 || rc=$?
if (( rc != 0 )); then pass "unknown repo returns non-zero"; else fail "unknown repo returns non-zero" "returned 0"; fi
```

Close with the summary block.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `tests/run-autopilot-clone-tests.sh`
Expected: FAIL — `source` cannot find the lib.

- [ ] **Step 3: Write the implementation**

Create `scripts/lib/autopilot-clone.sh`:

```bash
#!/usr/bin/env bash
#
# autopilot-clone.sh — sourced, not executed.
#   autopilot_clone_dir <owner/repo>      (query)   print the cache path
#   sync_autopilot_clone <owner/repo>      (command) clone or refresh it
#
# /enrich commits a spec and a plan and pushes them, so a headless enrich needs
# a checkout of the *target* repo. This keeps one clone per allowlisted repo
# under $AUTOPILOT_CACHE_DIR and resets it to a clean default branch before each
# use, so every enrich starts from a known state and nothing is carried between
# runs. A wedged clone is repaired by deleting the directory.
#
# This cache is deliberately NOT the operator's own working clones: an
# unattended timer running `reset --hard` in a directory a human also works in
# by hand is how a stray uncommitted change gets destroyed at 3am.
#
# Env:
#   AUTOPILOT_CACHE_DIR      cache root. Default ~/.cache/agent-workflow/autopilot
#   AUTOPILOT_CLONE_URL_BASE clone URL prefix. Default https://github.com
#                            Tests point this at a local file:// origin, which
#                            is what keeps the suite hermetic.
set -euo pipefail
IFS=$'\n\t'

autopilot_clone_dir() {
  local repo="$1"
  printf '%s/%s\n' \
    "${AUTOPILOT_CACHE_DIR:-$HOME/.cache/agent-workflow/autopilot}" \
    "${repo//\//__}"
}

sync_autopilot_clone() {
  local repo="$1" dir url branch
  dir="$(autopilot_clone_dir "$repo")"
  url="${AUTOPILOT_CLONE_URL_BASE:-https://github.com}/$repo.git"

  if [[ ! -d "$dir/.git" ]]; then
    mkdir -p "$(dirname "$dir")"
    if ! git clone --quiet "$url" "$dir"; then
      printf 'error: clone failed: %s\n' "$url" >&2
      return 1
    fi
  fi

  if ! git -C "$dir" fetch --quiet --prune origin; then
    printf 'error: fetch failed: %s\n' "$dir" >&2
    return 1
  fi

  # Ask the remote which branch is default rather than assuming main — a
  # consumer repo on master would otherwise silently fail every run.
  git -C "$dir" remote set-head origin --auto >/dev/null 2>&1 || true
  branch="$(git -C "$dir" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  branch="${branch#origin/}"
  [[ -n "$branch" ]] || branch=main

  if ! git -C "$dir" checkout --quiet -B "$branch" "origin/$branch"; then
    printf 'error: checkout %s failed: %s\n' "$branch" "$dir" >&2
    return 1
  fi
  if ! git -C "$dir" reset --quiet --hard "origin/$branch"; then
    printf 'error: reset failed: %s\n' "$dir" >&2
    return 1
  fi
  if ! git -C "$dir" clean -qfdx; then
    printf 'error: clean failed: %s\n' "$dir" >&2
    return 1
  fi

  return 0
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `tests/run-autopilot-clone-tests.sh`
Expected: PASS, all assertions.

- [ ] **Step 5: Lint and commit**

```bash
shellcheck -x -e SC1091 scripts/lib/autopilot-clone.sh tests/run-autopilot-clone-tests.sh
git add scripts/lib/autopilot-clone.sh tests/run-autopilot-clone-tests.sh
git commit -m "feat(autopilot): keep a clean managed clone per allowlisted repo (#373)"
```

---

### Task 9: The nested enrich wrapper

**Files:**
- Create: `scripts/lib/agent-cmd-enrich.sh`
- Create: `tests/run-agent-cmd-enrich-tests.sh`

**Interfaces:**
- Consumes: `allowed_model_or_fallback` from `scripts/lib/blocked-models.sh`;
  the ADR recorded in Task 1.
- Produces: an executable honouring the `ENRICH_CMD <issue-number>` contract —
  the same shape as the existing `AGENT_CMD` / `FIX_AGENT_CMD` wrappers. Runs
  with the working directory set by the caller to the target repo's clone.
  Exits with the nested session's exit status.

- [ ] **Step 1: Write the failing test**

Create `tests/run-agent-cmd-enrich-tests.sh` with the Task 4 harness header,
then:

```bash
WRAPPER="$ROOT/scripts/lib/agent-cmd-enrich.sh"

# A `claude` stub on PATH: records argv and stdin, exits with $STUB_RC.
mkdir -p "$TMPDIR_T/bin"
cat > "$TMPDIR_T/bin/claude" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
( IFS=' '; printf '%s\n' "$*" > "$CLAUDE_STUB_ARGV" )
cat > "$CLAUDE_STUB_STDIN"
exit "${STUB_RC:-0}"
STUB
chmod +x "$TMPDIR_T/bin/claude"
export PATH="$TMPDIR_T/bin:$PATH"
export CLAUDE_STUB_ARGV="$TMPDIR_T/argv"
export CLAUDE_STUB_STDIN="$TMPDIR_T/stdin"
export AUTOPILOT_LOG_DIR="$TMPDIR_T/logs"
mkdir -p "$AUTOPILOT_LOG_DIR"

section "the prompt"

rc=0; "$WRAPPER" 373 || rc=$?
assert_eq "wrapper returns 0 when the session succeeds" "0" "$rc"
assert_eq "prompt is the headless enrich command" "/enrich 373 --quick --headless" "$(cat "$TMPDIR_T/stdin")"

section "the flags"

argv="$(cat "$TMPDIR_T/argv")"
case "$argv" in
  *--print*) pass "runs in print mode" ;;
  *) fail "runs in print mode" "argv was: $argv" ;;
esac
case "$argv" in
  *--allowedTools*) pass "passes a tool allowlist" ;;
  *) fail "passes a tool allowlist" "argv was: $argv" ;;
esac
case "$argv" in
  *Bash*) pass "allowlist includes Bash" ;;
  *) fail "allowlist includes Bash" "argv was: $argv" ;;
esac

section "MODEL"

rc=0; MODEL=claude-opus-5 "$WRAPPER" 42 || rc=$?
argv="$(cat "$TMPDIR_T/argv")"
case "$argv" in
  *"--model claude-opus-5"*) pass "MODEL becomes --model" ;;
  *) fail "MODEL becomes --model" "argv was: $argv" ;;
esac

rc=0; "$WRAPPER" 42 || rc=$?
argv="$(cat "$TMPDIR_T/argv")"
case "$argv" in
  *--model*) fail "no MODEL means no --model flag" "argv was: $argv" ;;
  *) pass "no MODEL means no --model flag" ;;
esac

section "exit status and diagnostics"

rc=0; STUB_RC=7 "$WRAPPER" 99 || rc=$?
assert_eq "session failure propagates" "7" "$rc"
if [[ -s "$AUTOPILOT_LOG_DIR/enrich-99.log" ]] || [[ -e "$AUTOPILOT_LOG_DIR/enrich-99.log" ]]; then
  pass "a failed session leaves a log"
else
  fail "a failed session leaves a log" "no enrich-99.log in $AUTOPILOT_LOG_DIR"
fi

section "usage"

rc=0; "$WRAPPER" >/dev/null 2>&1 || rc=$?
assert_eq "missing issue number is a usage error" "2" "$rc"
rc=0; "$WRAPPER" not-a-number >/dev/null 2>&1 || rc=$?
assert_eq "non-numeric issue is a usage error" "2" "$rc"
```

Close with the summary block.

- [ ] **Step 2: Run the test to verify it fails**

Run: `tests/run-agent-cmd-enrich-tests.sh`
Expected: FAIL — the wrapper does not exist, so every invocation fails to exec.

- [ ] **Step 3: Write the implementation**

Create `scripts/lib/agent-cmd-enrich.sh` and `chmod +x` it:

```bash
#!/usr/bin/env bash
#
# agent-cmd-enrich.sh — autopilot.sh's default ENRICH_CMD wrapper.
#   Contract: ENRICH_CMD <issue-number>
#
# Runs ONE headless quick-mode enrichment of one issue in a nested Claude
# session. The caller (autopilot.sh) has already synced and cd'd into the target
# repo's managed clone, so this inherits the working directory — /enrich commits
# and pushes from there.
#
# Mirrors agent-cmd-claude-fix.sh: `claude --print` with a tool allowlist, the
# prompt on stdin, MODEL passed through the blocked-models denylist first. One
# nested session per issue, never one per run: a single long-lived session would
# share one context across every issue in the batch, and a mid-run context
# exhaustion would lose all of them. See ADR-015.
#
# CLAUDE_CODE_OAUTH_TOKEN must be in the environment (the CLI reads it
# directly). Under systemd that comes from the unit's EnvironmentFile, since a
# --user unit inherits nothing from an interactive shell.
#
# stdout/stderr go to $AUTOPILOT_LOG_DIR/enrich-<n>.log rather than being
# discarded, so a failed enrichment leaves a trace the driver's log line can
# point at. Diagnostics only — it does not change the exit-code contract.
#
# Exits with the nested session's status; 2 on usage error.
set -euo pipefail
IFS=$'\n\t'

# shellcheck source=scripts/lib/blocked-models.sh disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/blocked-models.sh"

issue="${1:-}"
if ! [[ "$issue" =~ ^[0-9]+$ ]]; then
  printf 'usage: %s <issue-number>\n' "$(basename "$0")" >&2
  exit 2
fi

MODEL="$(allowed_model_or_fallback "${MODEL:-}")"

args=(--print --allowedTools 'Edit,Write,Read,Glob,Grep,MultiEdit,TodoWrite,Bash')
[[ -n "${MODEL:-}" ]] && args+=(--model "$MODEL")

log_dir="${AUTOPILOT_LOG_DIR:-${TMPDIR:-/tmp}}"
mkdir -p "$log_dir"

printf '/enrich %s --quick --headless\n' "$issue" \
  | claude "${args[@]}" > "$log_dir/enrich-$issue.log" 2>&1
```

**Fallback, if Task 1 found that `--print` does not expand custom slash
commands.** Replace the final `printf | claude` pipeline with the following,
which inlines the command body ahead of the arguments. Nothing else in this
task changes.

```bash
enrich_md="${ENRICH_COMMAND_MD:-$HOME/.claude/commands/enrich.md}"
if [[ ! -r "$enrich_md" ]]; then
  printf 'error: cannot read the enrich command body: %s\n' "$enrich_md" >&2
  exit 3
fi
{
  printf 'Execute the following command definition verbatim.\n'
  printf 'Its $ARGUMENTS value is: %s --quick --headless\n\n' "$issue"
  cat "$enrich_md"
} | claude "${args[@]}" > "$log_dir/enrich-$issue.log" 2>&1
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `tests/run-agent-cmd-enrich-tests.sh`
Expected: PASS, all assertions.

- [ ] **Step 5: Lint and commit**

```bash
shellcheck -x -e SC1091 scripts/lib/agent-cmd-enrich.sh tests/run-agent-cmd-enrich-tests.sh
chmod +x scripts/lib/agent-cmd-enrich.sh
git add scripts/lib/agent-cmd-enrich.sh tests/run-agent-cmd-enrich-tests.sh
git commit -m "feat(autopilot): wrap one headless enrich per nested session (#373)"
```

---

### Task 10: The driver — guards, selection, and dry run

The read-only half of the driver: everything up to the point where it would
write. Split from Task 11 because "dry run writes nothing" is its own assertion
set and its own review gate.

**Files:**
- Create: `scripts/autopilot.sh`
- Create: `tests/run-autopilot-driver-tests.sh`

**Interfaces:**
- Consumes: `load_autopilot_config` (Task 4), `autopilot_candidates` (Task 6),
  `repo_eligible` (Task 7), `autopilot_clone_dir` / `sync_autopilot_clone`
  (Task 8).
- Produces: `scripts/autopilot.sh` with flags `--dry-run`, `--config <file>`,
  `--max <n>`, `-h|--help`; exit codes 0 / 2 / 3 / 4; and one log line per
  decision on stdout in the format
  `<ISO-8601 UTC> <owner/repo>#<n> <outcome>` (repo-level lines omit `#<n>`).
  Task 11 fills in `process_issue`'s write path.

- [ ] **Step 1: Write the failing tests**

Create `tests/run-autopilot-driver-tests.sh` with the Task 4 harness header,
then:

```bash
DRIVER="$ROOT/scripts/autopilot.sh"

export PATH="$ROOT/tests/mocks:$PATH"
export GH_MOCK_LOG="$TMPDIR_T/gh.log"
export AUTOPILOT_CACHE_DIR="$TMPDIR_T/cache"
export AUTOPILOT_DISABLE_FLAG="$TMPDIR_T/disabled"

# Config: one allowlisted repo.
printf 'max_per_run=2\nrepo=o/r\n' > "$TMPDIR_T/ap.conf"

# gh responses: an eligible repo and three enrichable issues.
{
  printf 'contents/.github/workflows/agent.yml\t%s\n' "$FIX/agent-yml-good.yml"
  printf 'actions/workflows/\t%s\n' "$FIX/runs-one.json"
  printf 'issue list\t%s\n' "$FIX/issues-mixed.json"
  printf 'repos/o/r\t%s\n' "$FIX/repo-meta.json"
} > "$TMPDIR_T/gh.map"
export GH_MOCK_STDOUT_MAP="$TMPDIR_T/gh.map"

section "usage and dependencies"

rc=0; "$DRIVER" --nonsense >/dev/null 2>&1 || rc=$?
assert_eq "unknown flag is a usage error" "2" "$rc"

rc=0; "$DRIVER" --config "$TMPDIR_T/nope.conf" >/dev/null 2>&1 || rc=$?
assert_eq "unreadable config exits 4" "4" "$rc"

out="$("$DRIVER" --help)"
case "$out" in
  *--dry-run*) pass "help documents --dry-run" ;;
  *) fail "help documents --dry-run" "help was: $out" ;;
esac

section "the disable flag"

: > "$AUTOPILOT_DISABLE_FLAG"
: > "$GH_MOCK_LOG"
rc=0; out="$("$DRIVER" --config "$TMPDIR_T/ap.conf" 2>&1)" || rc=$?
assert_eq "disabled exits 0" "0" "$rc"
case "$out" in
  *disabled*) pass "disabled is logged" ;;
  *) fail "disabled is logged" "output was: $out" ;;
esac
assert_eq "disabled makes no gh calls at all" "" "$(cat "$GH_MOCK_LOG")"
rm -f "$AUTOPILOT_DISABLE_FLAG"

section "dry run"

: > "$GH_MOCK_LOG"
out="$("$DRIVER" --config "$TMPDIR_T/ap.conf" --dry-run)"

case "$out" in
  *"o/r#41"*) pass "names the oldest candidate" ;;
  *) fail "names the oldest candidate" "output was: $out" ;;
esac
case "$out" in
  *would:*) pass "dry-run lines are marked 'would:'" ;;
  *) fail "dry-run lines are marked 'would:'" "output was: $out" ;;
esac
assert_eq "dry run honours the cap" "2" "$(printf '%s\n' "$out" | grep -c 'would:')"
case "$out" in
  *"o/r#50"*) fail "cap excludes the third candidate" "50 appeared" ;;
  *) pass "cap excludes the third candidate" ;;
esac

if grep -q 'issue edit' "$GH_MOCK_LOG"; then
  fail "dry run writes no labels" "$(grep 'issue edit' "$GH_MOCK_LOG")"
else
  pass "dry run writes no labels"
fi
if grep -q 'issue comment' "$GH_MOCK_LOG"; then
  fail "dry run posts no comments" "$(grep 'issue comment' "$GH_MOCK_LOG")"
else
  pass "dry run posts no comments"
fi
if [[ -d "$AUTOPILOT_CACHE_DIR" ]]; then
  fail "dry run syncs no clones" "$AUTOPILOT_CACHE_DIR was created"
else
  pass "dry run syncs no clones"
fi

section "--max overrides the config"

out="$("$DRIVER" --config "$TMPDIR_T/ap.conf" --dry-run --max 1)"
assert_eq "--max 1 yields one line" "1" "$(printf '%s\n' "$out" | grep -c 'would:')"

section "an ineligible repo is skipped with its reason"

{
  printf 'contents/.github/workflows/agent.yml\t%s\n' "$FIX/agent-yml-no-merge.yml"
  printf 'issue list\t%s\n' "$FIX/issues-mixed.json"
  printf 'repos/o/r\t%s\n' "$FIX/repo-meta.json"
} > "$TMPDIR_T/gh-noeligible.map"
out="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/gh-noeligible.map" "$DRIVER" --config "$TMPDIR_T/ap.conf" --dry-run)"
case "$out" in
  *"ai-review-ai-merge"*) pass "logs the eligibility reason verbatim" ;;
  *) fail "logs the eligibility reason verbatim" "output was: $out" ;;
esac
case "$out" in
  *would:*) fail "an ineligible repo yields no candidates" "output was: $out" ;;
  *) pass "an ineligible repo yields no candidates" ;;
esac

section "the run lock"

# Hold the lock, then confirm a second run stands down instead of piling on.
lock="$AUTOPILOT_CACHE_DIR/run.lock"
mkdir -p "$AUTOPILOT_CACHE_DIR"
exec 8>"$lock"
flock -n 8
rc=0; out="$("$DRIVER" --config "$TMPDIR_T/ap.conf" --dry-run 2>&1)" || rc=$?
exec 8>&-
assert_eq "a concurrent run exits 0" "0" "$rc"
case "$out" in
  *"already running"*) pass "a concurrent run says so" ;;
  *) fail "a concurrent run says so" "output was: $out" ;;
esac

section "the log line format"

rm -rf "$AUTOPILOT_CACHE_DIR"
out="$("$DRIVER" --config "$TMPDIR_T/ap.conf" --dry-run | head -1)"
if [[ "$out" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\  ]]; then
  pass "log lines start with an ISO-8601 UTC timestamp"
else
  fail "log lines start with an ISO-8601 UTC timestamp" "line was: $out"
fi
```

Close with the summary block.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `tests/run-autopilot-driver-tests.sh`
Expected: FAIL — `scripts/autopilot.sh` does not exist.

- [ ] **Step 3: Write the implementation**

Create `scripts/autopilot.sh` and `chmod +x` it. `process_issue` here has only
its dry-run branch; Task 11 adds the rest.

```bash
#!/usr/bin/env bash
#
# autopilot.sh — the unattended enrich lane (#373).
#
# Selects needs-enrichment issues in allowlisted repos, quick-enriches each in
# its own nested headless Claude session, and dispatches the ones that came out
# clean with ai-implement + ai-review-ai-merge. Anything it cannot decide gets
# needs-human and a human.
#
# A systemd timer runs a process, not a slash command, which is why the driver
# is a shell script and /autopilot is only a thin wrapper over its --dry-run.
#
# This script owns every write. Config parsing, eligibility and candidate
# selection are query-only libs so they stay fixture-testable with no network.
#
# Usage:
#   autopilot.sh                     # a real run
#   autopilot.sh --dry-run           # print what a real run would do
#   autopilot.sh --config path.conf  # an explicit config file
#   autopilot.sh --max 1             # override max_per_run
#
# Env:
#   AUTOPILOT_CONFIG        config path. Default ~/.config/agent-workflow/autopilot.conf
#   AUTOPILOT_CACHE_DIR     clone cache + run lock. Default ~/.cache/agent-workflow/autopilot
#   AUTOPILOT_DISABLE_FLAG  kill switch. Default ~/.config/agent-workflow/autopilot.disabled
#   AUTOPILOT_LOG_DIR       nested session logs. Default $AUTOPILOT_CACHE_DIR/logs
#   ENRICH_CMD              per-issue enrich command. Default scripts/lib/agent-cmd-enrich.sh
#   MODEL                   passed through to the nested session
#
# Exit codes:
#   0  ran (including "disabled" and "already running" — neither is an error)
#   2  usage error
#   3  missing dependency
#   4  config invalid or unreadable
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=scripts/lib/autopilot-config.sh disable=SC1091
source "$ROOT/scripts/lib/autopilot-config.sh"
# shellcheck source=scripts/lib/autopilot-eligible.sh disable=SC1091
source "$ROOT/scripts/lib/autopilot-eligible.sh"
# shellcheck source=scripts/lib/autopilot-candidates.sh disable=SC1091
source "$ROOT/scripts/lib/autopilot-candidates.sh"
# shellcheck source=scripts/lib/autopilot-clone.sh disable=SC1091
source "$ROOT/scripts/lib/autopilot-clone.sh"

DRY_RUN=0
CONFIG_FILE=''
MAX_OVERRIDE=''

CACHE_DIR="${AUTOPILOT_CACHE_DIR:-$HOME/.cache/agent-workflow/autopilot}"
DISABLE_FLAG="${AUTOPILOT_DISABLE_FLAG:-$HOME/.config/agent-workflow/autopilot.disabled}"
ENRICH_CMD="${ENRICH_CMD:-$ROOT/scripts/lib/agent-cmd-enrich.sh}"

die() { printf 'error: %s\n' "$1" >&2; exit "${2:-2}"; }

usage() { sed -n '3,40p' "$0" | sed 's/^# \{0,1\}//'; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)   DRY_RUN=1; shift ;;
      --config)    [[ $# -ge 2 ]] || die "--config needs a value"; CONFIG_FILE="$2"; shift 2 ;;
      --max)       [[ $# -ge 2 ]] || die "--max needs a value"; MAX_OVERRIDE="$2"; shift 2 ;;
      -h|--help)   usage; exit 0 ;;
      *)           die "unknown option: $1" ;;
    esac
  done
  if [[ -n "$MAX_OVERRIDE" ]] && ! [[ "$MAX_OVERRIDE" =~ ^[1-9][0-9]*$ ]]; then
    die "--max must be a positive integer (got: $MAX_OVERRIDE)"
  fi
}

require_tools() {
  local tool
  for tool in gh jq git flock timeout; do
    command -v "$tool" >/dev/null 2>&1 || die "missing dependency: $tool" 3
  done
}

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

log() { printf '%s %s\n' "$(now)" "$1"; }
log_repo() { printf '%s %s %s\n' "$(now)" "$1" "$2"; }
log_issue() { printf '%s %s#%s %s\n' "$(now)" "$1" "$2" "$3"; }

# Holds the lock for the life of the process via fd 9. In the driver rather
# than the unit on purpose: this protects a manual shell run as well as a timer
# run, and systemd knows nothing about the former.
acquire_run_lock() {
  mkdir -p "$CACHE_DIR"
  exec 9>"$CACHE_DIR/run.lock"
  flock -n 9
}

process_issue() {
  local repo="$1" n="$2" dir
  dir="$(autopilot_clone_dir "$repo")"

  if (( DRY_RUN )); then
    log_issue "$repo" "$n" "would: enrich headless, then dispatch (clone $dir)"
    return 0
  fi

  # Task 11 fills in the write path here.
  return 0
}

main() {
  parse_args "$@"
  require_tools

  if ! acquire_run_lock; then
    log "already running — exiting"
    exit 0
  fi

  if [[ -e "$DISABLE_FLAG" ]]; then
    log "disabled: $DISABLE_FLAG present"
    exit 0
  fi

  load_autopilot_config "$CONFIG_FILE" || exit 4
  [[ -n "$MAX_OVERRIDE" ]] && AUTOPILOT_MAX_PER_RUN="$MAX_OVERRIDE"

  export AUTOPILOT_LOG_DIR="${AUTOPILOT_LOG_DIR:-$CACHE_DIR/logs}"

  local remaining="$AUTOPILOT_MAX_PER_RUN"
  local repo reason issues n

  for repo in "${AUTOPILOT_REPOS[@]}"; do
    (( remaining > 0 )) || break

    reason=''
    if ! reason="$(repo_eligible "$repo")"; then
      log_repo "$repo" "skipped ($reason)"
      continue
    fi

    issues=()
    mapfile -t issues < <(autopilot_candidates "$repo" "$remaining" || true)
    if (( ${#issues[@]} == 0 )); then
      log_repo "$repo" "no candidates"
      continue
    fi

    for n in "${issues[@]}"; do
      [[ -n "$n" ]] || continue
      process_issue "$repo" "$n"
      # Every attempt costs a nested session, so every attempt spends budget —
      # including one that ends in needs-human or a failure.
      remaining=$((remaining - 1))
    done
  done
}

main "$@"
```

Note `load_autopilot_config "$CONFIG_FILE"` with an empty `CONFIG_FILE`: the
lib's `${1:-...}` default only applies when the argument is *unset*, not when it
is empty, so pass it conditionally:

```bash
  if [[ -n "$CONFIG_FILE" ]]; then
    load_autopilot_config "$CONFIG_FILE" || exit 4
  else
    load_autopilot_config || exit 4
  fi
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `tests/run-autopilot-driver-tests.sh`
Expected: PASS, all assertions.

- [ ] **Step 5: Lint and commit**

```bash
shellcheck -x -e SC1091 scripts/autopilot.sh tests/run-autopilot-driver-tests.sh
chmod +x scripts/autopilot.sh
git add scripts/autopilot.sh tests/run-autopilot-driver-tests.sh
git commit -m "feat(autopilot): add the driver with its guards and dry run (#373)"
```

---

### Task 11: The driver — the write path

**Files:**
- Modify: `scripts/autopilot.sh` (`process_issue`)
- Modify: `tests/run-autopilot-driver-tests.sh` (append a new section)

**Interfaces:**
- Consumes: everything Task 10 produced, plus the `ENRICH_CMD <n>` contract from
  Task 9 and `sync_autopilot_clone` from Task 8.
- Produces: the finished driver. No new public interface.

- [ ] **Step 1: Write the failing tests**

Append to `tests/run-autopilot-driver-tests.sh`, before the summary block. A
stub `ENRICH_CMD` stands in for the nested session, so no test ever spawns
`claude`.

```bash
section "the write path"

# A local origin so sync_autopilot_clone works without network.
mkdir -p "$TMPDIR_T/origins/o"
git init --quiet --bare --initial-branch=main "$TMPDIR_T/origins/o/r.git"
git init --quiet --initial-branch=main "$TMPDIR_T/seed"
git -C "$TMPDIR_T/seed" -c user.email=t@t -c user.name=t commit --quiet --allow-empty -m init
git -C "$TMPDIR_T/seed" remote add origin "$TMPDIR_T/origins/o/r.git"
git -C "$TMPDIR_T/seed" push --quiet origin main
export AUTOPILOT_CLONE_URL_BASE="file://$TMPDIR_T/origins"

# ENRICH_CMD stub: records the issues it was asked for, exits $ENRICH_RC.
cat > "$TMPDIR_T/enrich-stub.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$1" >> "$ENRICH_STUB_LOG"
exit "${ENRICH_RC:-0}"
STUB
chmod +x "$TMPDIR_T/enrich-stub.sh"
export ENRICH_CMD="$TMPDIR_T/enrich-stub.sh"
export ENRICH_STUB_LOG="$TMPDIR_T/enrich.log"

run_driver() {
  rm -rf "$AUTOPILOT_CACHE_DIR"
  : > "$GH_MOCK_LOG"
  : > "$ENRICH_STUB_LOG"
  "$DRIVER" --config "$TMPDIR_T/ap.conf" --max 1 "$@" 2>&1
}

# --- the happy path: enrich succeeds, no needs-human on the issue ---
printf '{"labels":[{"name":"needs-enrichment"}]}\n' > "$TMPDIR_T/labels-clean.json"
{
  printf 'contents/.github/workflows/agent.yml\t%s\n' "$FIX/agent-yml-good.yml"
  printf 'actions/workflows/\t%s\n' "$FIX/runs-one.json"
  printf 'issue list\t%s\n' "$FIX/issues-mixed.json"
  printf 'issue view\t%s\n' "$TMPDIR_T/labels-clean.json"
  printf 'repos/o/r\t%s\n' "$FIX/repo-meta.json"
} > "$TMPDIR_T/gh-clean.map"

out="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/gh-clean.map" run_driver)"
assert_eq "the enrich stub was asked for the oldest issue" "41" "$(cat "$ENRICH_STUB_LOG")"
case "$out" in
  *"o/r#41 enriched"*) pass "a clean enrich logs 'enriched'" ;;
  *) fail "a clean enrich logs 'enriched'" "output was: $out" ;;
esac

edits="$(grep 'issue edit' "$GH_MOCK_LOG" || true)"
assert_eq "exactly one label write" "1" "$(printf '%s\n' "$edits" | grep -c 'issue edit')"
case "$edits" in
  *"--add-label ai-implement,ai-review-ai-merge"*) pass "both labels in one call (#365)" ;;
  *) fail "both labels in one call (#365)" "edits were: $edits" ;;
esac
if grep -q 'enrichment-ongoing' "$GH_MOCK_LOG"; then
  fail "the driver never touches enrichment-ongoing on success" "$(grep enrichment-ongoing "$GH_MOCK_LOG")"
else
  pass "the driver never touches enrichment-ongoing on success"
fi

# --- needs-human: the enrich session labelled it itself ---
printf '{"labels":[{"name":"needs-enrichment"},{"name":"needs-human"}]}\n' > "$TMPDIR_T/labels-human.json"
{
  printf 'contents/.github/workflows/agent.yml\t%s\n' "$FIX/agent-yml-good.yml"
  printf 'actions/workflows/\t%s\n' "$FIX/runs-one.json"
  printf 'issue list\t%s\n' "$FIX/issues-mixed.json"
  printf 'issue view\t%s\n' "$TMPDIR_T/labels-human.json"
  printf 'repos/o/r\t%s\n' "$FIX/repo-meta.json"
} > "$TMPDIR_T/gh-human.map"

out="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/gh-human.map" run_driver)"
case "$out" in
  *"o/r#41 needs-human"*) pass "needs-human is logged" ;;
  *) fail "needs-human is logged" "output was: $out" ;;
esac
if grep -q 'ai-implement' "$GH_MOCK_LOG"; then
  fail "needs-human withholds ai-implement" "$(grep 'issue edit' "$GH_MOCK_LOG")"
else
  pass "needs-human withholds ai-implement"
fi

# --- a failed enrich session ---
out="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/gh-clean.map" ENRICH_RC=7 run_driver)"
case "$out" in
  *"failed (enrich exited 7)"*) pass "a failed session is logged with its status" ;;
  *) fail "a failed session is logged with its status" "output was: $out" ;;
esac
edits="$(grep 'issue edit' "$GH_MOCK_LOG" || true)"
case "$edits" in
  *"--add-label needs-human"*) pass "a failed session escalates to needs-human" ;;
  *) fail "a failed session escalates to needs-human" "edits were: $edits" ;;
esac
case "$edits" in
  *"--remove-label enrichment-ongoing"*) pass "a failed session releases the lock" ;;
  *) fail "a failed session releases the lock" "edits were: $edits" ;;
esac
assert_eq "the failure escalation is a single call" "1" "$(printf '%s\n' "$edits" | grep -c 'issue edit')"
if grep -q 'ai-implement' "$GH_MOCK_LOG"; then
  fail "a failed session withholds ai-implement" "$edits"
else
  pass "a failed session withholds ai-implement"
fi

# --- a timeout, which is exit 124 from `timeout` ---
out="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/gh-clean.map" ENRICH_RC=124 run_driver)"
case "$out" in
  *"timed out"*) pass "a timeout is logged as a timeout, not a bare exit code" ;;
  *) fail "a timeout is logged as a timeout, not a bare exit code" "output was: $out" ;;
esac

# --- a clone that cannot be synced ---
printf 'max_per_run=1\nrepo=o/missing\n' > "$TMPDIR_T/ap-missing.conf"
{
  printf 'contents/.github/workflows/agent.yml\t%s\n' "$FIX/agent-yml-good.yml"
  printf 'actions/workflows/\t%s\n' "$FIX/runs-one.json"
  printf 'issue list\t%s\n' "$FIX/issues-mixed.json"
  printf 'repos/o/missing\t%s\n' "$FIX/repo-meta.json"
} > "$TMPDIR_T/gh-missing.map"
rm -rf "$AUTOPILOT_CACHE_DIR"; : > "$GH_MOCK_LOG"; : > "$ENRICH_STUB_LOG"
out="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/gh-missing.map" "$DRIVER" --config "$TMPDIR_T/ap-missing.conf" --max 1 2>&1)"
case "$out" in
  *"failed (clone sync)"*) pass "a clone-sync failure is logged" ;;
  *) fail "a clone-sync failure is logged" "output was: $out" ;;
esac
assert_eq "a clone-sync failure runs no enrich" "" "$(cat "$ENRICH_STUB_LOG")"
if grep -q 'issue edit' "$GH_MOCK_LOG"; then
  fail "a clone-sync failure touches no labels" "$(grep 'issue edit' "$GH_MOCK_LOG")"
else
  pass "a clone-sync failure touches no labels"
fi
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `tests/run-autopilot-driver-tests.sh`
Expected: FAIL on the new section — `process_issue`'s non-dry-run branch is
still a bare `return 0`, so nothing is enriched and no label is written.

- [ ] **Step 3: Write the implementation**

Replace `process_issue` in `scripts/autopilot.sh` with:

```bash
# True iff the issue currently carries $3. The enrich session labels the issue
# itself, so the issue — not this script's memory, and not the session's exit
# code — is the source of truth. That also means a driver killed mid-run leaves
# the state where the next run can read it.
issue_has_label() {
  local repo="$1" n="$2" want="$3" out
  out="$(gh issue view "$n" --repo "$repo" --json labels 2>/dev/null)" || return 1
  printf '%s' "$out" | jq -e --arg want "$want" '[.labels[].name] | index($want) != null' >/dev/null
}

process_issue() {
  local repo="$1" n="$2" dir rc
  dir="$(autopilot_clone_dir "$repo")"

  if (( DRY_RUN )); then
    log_issue "$repo" "$n" "would: enrich headless, then dispatch (clone $dir)"
    return 0
  fi

  if ! sync_autopilot_clone "$repo"; then
    log_issue "$repo" "$n" "failed (clone sync)"
    return 0
  fi

  rc=0
  ( cd "$dir" && timeout "$AUTOPILOT_ENRICH_TIMEOUT" "$ENRICH_CMD" "$n" ) || rc=$?

  if (( rc != 0 )); then
    # A crash escalates to a human, not just to the log. Without this, an issue
    # that reliably kills the enrich session re-spawns a paid nested session on
    # every run, forever. One call, so a failure cannot release the lock while
    # leaving the issue unlabelled (#365).
    gh issue edit "$n" --repo "$repo" \
      --add-label needs-human --remove-label enrichment-ongoing >/dev/null 2>&1 || true
    if (( rc == 124 )); then
      log_issue "$repo" "$n" "failed (enrich timed out after ${AUTOPILOT_ENRICH_TIMEOUT}s)"
    else
      log_issue "$repo" "$n" "failed (enrich exited $rc)"
    fi
    return 0
  fi

  if issue_has_label "$repo" "$n" needs-human; then
    log_issue "$repo" "$n" "needs-human"
    return 0
  fi

  # Both labels in ONE call. Two calls spawn two workflow runs that race and can
  # cancel each other's review job (#365).
  if ! gh issue edit "$n" --repo "$repo" \
        --add-label ai-implement,ai-review-ai-merge >/dev/null 2>&1; then
    log_issue "$repo" "$n" "failed (dispatch labels not applied)"
    return 0
  fi

  log_issue "$repo" "$n" "enriched"
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `tests/run-autopilot-driver-tests.sh`
Expected: PASS, all assertions including Task 10's.

- [ ] **Step 5: Run the whole Layer-1 suite**

Run: `tests/run-all.sh`
Expected: every runner OK, and the new autopilot runners appear in the listing —
`run-all.sh` discovers them by `find`, so no registration was needed.

- [ ] **Step 6: Lint and commit**

```bash
shellcheck -x -e SC1091 scripts/autopilot.sh tests/run-autopilot-driver-tests.sh
git add scripts/autopilot.sh tests/run-autopilot-driver-tests.sh
git commit -m "feat(autopilot): dispatch clean enrichments, escalate the rest (#373)"
```

---

### Task 12: The `/autopilot` slash command

**Files:**
- Create: `commands/autopilot.md`
- Modify: `commands/README.md`
- Modify: `docs/COMMAND-CHEATSHEET.md`

**Interfaces:**
- Consumes: `scripts/autopilot.sh` from Tasks 10–11.
- Produces: an installed `/autopilot` command. No code interface.

- [ ] **Step 1: Read a sibling command's front-matter**

Run: `head -8 commands/ai-funnel.md`
Match its `---` front-matter keys and style exactly — `/commands` generates its
listing from the `description:` field, so a missing or reworded key shows up
there.

- [ ] **Step 2: Write the command**

Create `commands/autopilot.md`:

````markdown
---
description: Unattended enrich lane — show what the next timer run would do, or drive one now
---

Report what the unattended enrich lane would do, or drive a real run.

`$ARGUMENTS` may be empty (the default), or contain `--run`, `--max <n>`, or
`--config <path>`.

## Default: show, don't do

With no arguments, this is **read-only**. It prints the decisions a timer run
would make and writes nothing — no labels, no comments, no clone sync:

```bash
scripts/autopilot.sh --dry-run
```

That default is deliberate. The lane's real trigger is
`agent-autopilot.timer`; a slash command that started an unattended batch of
paid Claude sessions as its default behaviour is too easy to fire by accident
from a chat prompt.

Render the output as-is — one line per decision, already timestamped. Then say
in one line how many issues **would** be enriched, and how many repos were
skipped with why.

## `--run`: actually do it

Only when `$ARGUMENTS` contains `--run`, drop `--dry-run`:

```bash
scripts/autopilot.sh
```

Before doing so, state what it is about to do and confirm: a real run spends a
nested Claude session per issue and applies `ai-implement` +
`ai-review-ai-merge`, which starts the implement pipeline. Pass `--max <n>` and
`--config <path>` straight through if given.

## Exit codes

- `0` — ran (this includes "disabled" and "already running"; neither is an error)
- `2` — usage error
- `3` — a missing dependency (`gh`, `jq`, `git`, `flock`, `timeout`)
- `4` — the config is invalid or unreadable

On `4`, the script names the offending file and line. The most common cause on a
fresh host is that no config exists yet — point at
`setup/autopilot.conf.example` and `docs/AUTOPILOT.md`.

## When nothing happens

Two outcomes look like a no-op and are not failures:

- `disabled: …/autopilot.disabled present` — the kill switch is on. Remove the
  flag file to re-enable.
- `already running — exiting` — another run (timer or shell) holds the lock.

See [`docs/AUTOPILOT.md`](../docs/AUTOPILOT.md) for the lane's operating
instructions, the allowlist, and the kill switch.

---

If you run into blockers, find a solution and update this command for the future.
````

- [ ] **Step 3: List it alongside its siblings**

In `commands/README.md`, add `/autopilot` to the same group as `/enrich` and
`/gh:implement`, with a one-line description matching the front-matter.

In `docs/COMMAND-CHEATSHEET.md`, add a short subsection after the `## The path`
diagram explaining that `/autopilot` is the unattended version of the
`/enrich → /gh:implement` hop, gated on an allowlist, and that its default is a
dry run.

- [ ] **Step 4: Verify the command installs and runs read-only**

```bash
setup/link-commands.sh
test -e "$HOME/.claude/commands/autopilot.md" && printf 'installed\n'
scripts/autopilot.sh --help | head -5
```

Expected: `installed`, then the usage block.

- [ ] **Step 5: Commit**

```bash
git add commands/autopilot.md commands/README.md docs/COMMAND-CHEATSHEET.md
git commit -m "feat(commands): add /autopilot, dry-run by default (#373)"
```

---

### Task 13: systemd units and the operator doc

**Files:**
- Create: `setup/agent-autopilot.service`
- Create: `setup/agent-autopilot.timer`
- Create: `docs/AUTOPILOT.md`
- Modify: `README.md`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: `scripts/autopilot.sh`, `setup/autopilot.conf.example`.
- Produces: the installable unit pair and the operator's runbook. No code
  interface.

- [ ] **Step 1: Write the service unit**

Create `setup/agent-autopilot.service`:

```ini
# agent-autopilot.service — one run of the unattended enrich lane (#373).
#
# NOT installed by setup/bootstrap.sh. Enabling an unattended lane that opens
# PRs and merges them is a deliberate per-host act; see docs/AUTOPILOT.md.
#
# Install (as the user that owns the clone and the tokens — NOT root):
#   mkdir -p ~/.config/systemd/user
#   cp setup/agent-autopilot.{service,timer} ~/.config/systemd/user/
#   $EDITOR ~/.config/systemd/user/agent-autopilot.service   # fix the two paths
#   systemctl --user daemon-reload
#   systemctl --user enable --now agent-autopilot.timer
#
# Kill switch (either works):
#   touch ~/.config/agent-workflow/autopilot.disabled
#   systemctl --user disable --now agent-autopilot.timer

[Unit]
Description=agent-workflow unattended enrich lane (one run)
Documentation=https://github.com/freaxnx01/agent-workflow/blob/main/docs/AUTOPILOT.md
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot

# A --user unit inherits NOTHING from an interactive shell. Both tokens must
# come from here, or every run fails at the first gh call. Keep the file 0600 —
# it holds credentials.
#   CLAUDE_CODE_OAUTH_TOKEN=…
#   GH_TOKEN=…
EnvironmentFile=%h/.config/agent-workflow/autopilot.env

# Absolute path to this clone of agent-workflow. Edit after copying.
WorkingDirectory=%h/repos/github/freaxnx01/public/agent-workflow
ExecStart=%h/repos/github/freaxnx01/public/agent-workflow/scripts/autopilot.sh

# A run is several nested Claude sessions; generous, but never unbounded.
TimeoutStartSec=3h

# Journald keeps the one-line-per-decision log.
StandardOutput=journal
StandardError=journal
SyslogIdentifier=agent-autopilot
```

- [ ] **Step 2: Write the timer unit**

Create `setup/agent-autopilot.timer`:

```ini
# agent-autopilot.timer — schedule for the unattended enrich lane (#373).

[Unit]
Description=Run the agent-workflow unattended enrich lane hourly
Documentation=https://github.com/freaxnx01/agent-workflow/blob/main/docs/AUTOPILOT.md

[Timer]
OnCalendar=hourly

# Keeps the run off the exact top of the hour.
RandomizedDelaySec=300

# Deliberately false. A missed run must NOT fire a catch-up burst of
# enrichments the moment the host comes back up — hourly against a cap of 3 is
# a bounded rate only while every firing is a scheduled one.
Persistent=false

Unit=agent-autopilot.service

[Install]
WantedBy=timers.target
```

- [ ] **Step 3: Write the operator doc**

Create `docs/AUTOPILOT.md`:

````markdown
# The unattended enrich lane

`/autopilot` quick-enriches `needs-enrichment` issues in an allowlisted set of
repos and dispatches the ones that came out clean, on a timer, with nobody
watching. This page is how to run it, and how to stop it.

Design and rationale:
[`docs/superpowers/specs/2026-09-21-autopilot-design.md`](superpowers/specs/2026-09-21-autopilot-design.md).
The decision to drive `/enrich` through a nested session is ADR-015 in
[`DECISIONS.md`](DECISIONS.md).

## The kill switch

Two layers. The flag file is the panic button — one `touch`, no unit knowledge,
and it shows up in the log as the reason nothing happened:

```bash
touch ~/.config/agent-workflow/autopilot.disabled
```

It is checked at the top of every run, before a single issue is read, so it
takes effect from the next firing. Remove the file to re-enable.

To stop the schedule properly:

```bash
systemctl --user disable --now agent-autopilot.timer
```

A run already in flight is stopped with
`systemctl --user stop agent-autopilot.service`.

## What it takes for a repo to be touched

Three gates, all required. Failing any one is logged with its reason:

1. **The allowlist.** The repo has a `repo=` line in
   `~/.config/agent-workflow/autopilot.conf`. This is the outer gate and the
   only one that cannot be flipped from inside a consumer repo.
2. **`ai-review-ai-merge: true`** in the consumer's
   `.github/workflows/agent.yml`.
3. **A test gate that has actually run.** The same `agent.yml` declares
   `autopilot-test-gate: <workflow-file>`, that workflow exists, and it has at
   least one completed run on the default branch. No auto-merge on an unrun
   gate (#263).

And per issue: open, `needs-enrichment`, a non-empty body, and none of
`🧊 parked`, `enrichment-ongoing`, `needs-human`, `ai-implement`.

## Setup

1. **Config.** `cp setup/autopilot.conf.example ~/.config/agent-workflow/autopilot.conf`
   and edit. Start with `agent-action-sandbox` only.
2. **Credentials.** Create `~/.config/agent-workflow/autopilot.env`, mode
   `0600`, with `CLAUDE_CODE_OAUTH_TOKEN=` and `GH_TOKEN=`. A `--user` unit
   inherits nothing from a shell, so this file is not optional — both tokens
   missing is the most likely first-run failure.
3. **Dry run.** `scripts/autopilot.sh --dry-run`. Nothing is written. Read every
   line before going further.
4. **One real issue.** `scripts/autopilot.sh --max 1` against the sandbox.
5. **The units.** Follow the install block at the top of
   `setup/agent-autopilot.service`. Both paths in it need editing for your
   clone.
6. **Only then** add a real repo to the allowlist.

## Reading the log

```bash
journalctl --user -u agent-autopilot.service -n 50 --no-pager
```

One line per decision:

| Outcome | Meaning |
|---|---|
| `enriched` | Spec, plan and issue body written; `ai-implement` + `ai-review-ai-merge` applied |
| `needs-human` | The enrich session hit a one-way door or a `[low]` assumption and handed it over |
| `skipped (…)` | A gate refused, with the reason |
| `no candidates` | The repo is eligible; nothing was enrichable |
| `failed (…)` | The nested session crashed or timed out. `needs-human` applied, lock released |
| `disabled: …` | The kill switch is on |
| `already running — exiting` | Another run holds the lock |

A `failed` line points at `~/.cache/agent-workflow/autopilot/logs/enrich-<n>.log`
for the nested session's own output.

## When something is wedged

- **A clone is in a bad state.** Delete it:
  `rm -rf ~/.cache/agent-workflow/autopilot/<owner>__<name>`. The next run
  re-clones.
- **An issue is stuck with `enrichment-ongoing` and no run in flight.** The
  label is released automatically after 24h by `/enrich`'s own staleness check,
  or remove it by hand.
- **An issue keeps landing in `needs-human`.** That is the design working.
  Enrich it by hand with `/enrich <n>` and remove `needs-human`.

## Prerequisite for the game repos

Before any `game-*` repo is allowlisted it needs re-onboarding with
`onboard-consumer.sh --ai-review-ai-merge`. As of 2026-09-21 game-tschau-sepp is
pinned at `@v2` with a deprecated `pre-preview: true` and a stub still named
`name: Claude` / `jobs: claude`. Tracked under freaxnx01/bridge#218.
````

- [ ] **Step 4: Link it from the root README**

In `README.md`, add a line pointing at `docs/AUTOPILOT.md` wherever the other
`docs/` pages are listed, described as the unattended enrich lane and its kill
switch.

- [ ] **Step 5: Add the changelog entry**

Under `## [Unreleased]` in `CHANGELOG.md`, in an `### Added` section:

```markdown
- **autopilot:** unattended enrich lane — `/autopilot` and
  `scripts/autopilot.sh` quick-enrich `needs-enrichment` issues in allowlisted
  repos and dispatch the clean ones, on a systemd timer, escalating anything
  undecidable to `needs-human` (#373)
- **enrich:** `--headless` flag — quick mode with no prompts; a one-way door or
  a `[low]` assumption routes to `needs-human` instead of asking (#373)
```

- [ ] **Step 6: Verify the units parse**

```bash
systemd-analyze verify setup/agent-autopilot.service setup/agent-autopilot.timer
```

Expected: complaints about the two placeholder paths and the missing
`EnvironmentFile` are fine — these are templates. Any **syntax** error is not;
fix it.

- [ ] **Step 7: Commit**

```bash
git add setup/agent-autopilot.service setup/agent-autopilot.timer \
        docs/AUTOPILOT.md README.md CHANGELOG.md
git commit -m "feat(setup): ship the autopilot timer units and runbook (#373)"
```

---

### Task 14: End-to-end run against the sandbox

The last acceptance criterion, and the only one no fixture can satisfy. Nothing
here is a code change — it is the gate before a real repo is allowlisted.

**Files:**
- Modify: `docs/AUTOPILOT.md` (a short "verified" note)

**Interfaces:**
- Consumes: everything above.
- Produces: evidence, and a recorded result.

- [ ] **Step 1: Confirm the whole Layer-1 suite is green**

Run: `tests/run-all.sh`
Expected: `failed: 0`. Do not proceed past a red suite.

- [ ] **Step 2: Lint everything this plan touched**

```bash
mapfile -t files < <(find scripts tests -type f -name '*.sh' | sort)
shellcheck -x -e SC1091 "${files[@]}"
actionlint
```

Expected: no output from either.

- [ ] **Step 3: Prepare the sandbox**

Ensure `freaxnx01/agent-action-sandbox` has `ai-review-ai-merge: true` and an
`autopilot-test-gate:` naming a workflow with at least one completed run on its
default branch, and that one open issue there carries `needs-enrichment` with a
real body. Confirm the gates agree before running anything:

```bash
source scripts/lib/autopilot-eligible.sh
repo_eligible freaxnx01/agent-action-sandbox
source scripts/lib/autopilot-candidates.sh
autopilot_candidates freaxnx01/agent-action-sandbox 5
```

Expected: an `eligible (…)` line, and at least one issue number.

- [ ] **Step 4: Dry run**

Run: `scripts/autopilot.sh --config ~/.config/agent-workflow/autopilot.conf --dry-run`
Expected: `would:` lines naming the sandbox issues, and no writes. Confirm with
`gh issue view <n> --repo freaxnx01/agent-action-sandbox --json labels` that
nothing changed.

- [ ] **Step 5: One real issue**

Run: `scripts/autopilot.sh --config ~/.config/agent-workflow/autopilot.conf --max 1`

Then verify, in this order:

1. The log line says `enriched` or `needs-human` — not `failed`.
2. The issue body has `## Acceptance Criteria`, `## Assumptions`,
   `## Consequences` and `## Implementation Plan`.
3. The spec and plan files are on the sandbox's default branch.
4. `needs-enrichment` is gone, `enrichment-ongoing` is gone.
5. On `enriched`: both `ai-implement` and `ai-review-ai-merge` are present, and
   `gh run list` shows **one** triggering run, not two racing ones — this is the
   #365 assertion, and it can only be checked here.

- [ ] **Step 6: Exercise the kill switch**

```bash
touch ~/.config/agent-workflow/autopilot.disabled
scripts/autopilot.sh --config ~/.config/agent-workflow/autopilot.conf
rm ~/.config/agent-workflow/autopilot.disabled
```

Expected: one `disabled: …` line and nothing else. Confirm with
`gh issue list --repo freaxnx01/agent-action-sandbox --label needs-enrichment`
that no issue changed.

- [ ] **Step 7: Record the result**

Append to `docs/AUTOPILOT.md`, at the end:

```markdown
## Verified

End-to-end against `freaxnx01/agent-action-sandbox` on <date>: one issue
enriched and dispatched, both labels applied in a single call, one triggering
workflow run (not two), and the kill switch confirmed to stop a run before any
issue was read.
```

- [ ] **Step 8: Commit**

```bash
git add docs/AUTOPILOT.md
git commit -m "docs(autopilot): record the sandbox end-to-end run (#373)"
```

---

## Notes for the executor

- **Task 1 gates Task 9.** If `claude --print` does not expand custom slash
  commands, Task 9 takes its documented fallback. Do not start Task 9 before
  ADR-015 records which.
- **Do not switch the lane on for a `game-*` repo.** freaxnx01/bridge#303,
  which #373 declares itself blocked by, is still open. The sandbox run in
  Task 14 is the end of this plan's scope; allowlisting a real repo is a
  separate, deliberate act.
- **Never add `enrichment-ongoing` from the driver.** `/enrich` owns that lock.
  The driver only excludes issues carrying it, and removes it after a crash it
  caused.
- **One `gh issue edit` per issue per outcome.** Both the dispatch pair and the
  failure escalation are single calls. This is #365, and it is the one bug in
  this area that has already happened.
