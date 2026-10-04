# Forge adapter — step 1 of 4 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Introduce `scripts/lib/forge.sh` and make the implement job's read path forge-agnostic, with **no behaviour change on GitHub**.

**Architecture:** The classifiers already prefer injected `ISSUE_LABELS` / `ISSUE_BODY` and fall back to `gh` only when those are unset. The adapter fills those two variables once per run, per forge, so three of five scripts need no change at all. The remaining two gain the same seam.

**Tech Stack:** Bash 5 (`set -euo pipefail`, `IFS=$'\n\t'`), `gh` and `az` mocked in `tests/mocks/`, `shellcheck -x`, `actionlint`.

**Spec:** `docs/superpowers/specs/2026-09-24-agent-implement-forge-adapter-design.md`

> **Scope note.** The spec sequences four steps. This plan covers **step 1 only**
> — the read path, GitHub-only, provably a no-op. Steps 2–4 (write verbs,
> `forge-azdo.sh`, the ADO entry point) each need their own plan; writing them now
> would guess at code this step has not yet shaped.

## Global Constraints

- **Step 1 ships no new capability.** Its entire value is that it changes nothing observable on GitHub. If a behaviour difference appears, it is a bug, not an improvement.
- `scripts/lib/forge.sh` is **sourced, not executed** — functions only, no side effects at source time, mirroring `detect-forge.sh` and `azdo.sh`.
- Quote every expansion, `[[ ]]` over `[ ]`, `$(…)` over backticks, no `eval`. Exit codes are API: `0` success, `1` error, `2` usage.
- **Do not touch `classify-failure.sh`** — already forge-agnostic, and the one script with nothing to gain.
- **Do not touch `check-merge-envelope.sh`** — verb 6, deliberately out of scope.
- Layer-1 tests only: no network, `gh`/`az` mocked, under 5 seconds. `tests/run-all.sh` discovers `run-*-tests.sh` by `find`.
- `shellcheck -x -e SC1091`, `actionlint` and `markdownlint` stay clean.

---

### Task 1: `scripts/lib/forge.sh` — the read verb, GitHub only

**Files:**
- Create: `scripts/lib/forge.sh`
- Create: `tests/run-forge-adapter-tests.sh`
- Create: `tests/fixtures/forge-issue-github.json`

**Interfaces:**
- Consumes: `detect_forge` from `scripts/lib/detect-forge.sh`.
- Produces:
  - `forge_issue_read <issue-number>` — echoes two lines: a `LABELS=` line with comma-separated label names, then a `BODY<<EOF` heredoc block. Exit `2` on an unsupported forge.
  - `forge_export_issue <issue-number>` — sets and exports `ISSUE_LABELS` (newline-separated) and `ISSUE_BODY` for the classifiers to consume.

- [ ] **Step 1: Write the failing tests**

Create `tests/run-forge-adapter-tests.sh`, following `tests/run-azdo-lib-tests.sh`'s harness:

```bash
#!/usr/bin/env bash
#
# run-forge-adapter-tests.sh — Layer-1 tests for scripts/lib/forge.sh.
# gh is mocked; no network.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/scripts/lib/forge.sh"
MOCKS="$ROOT/tests/mocks"
FIXTURES="$ROOT/tests/fixtures"

PASS=0; FAIL=0; FAIL_NAMES=()
section() { printf '\n── %s ──\n' "$1"; }
pass() { PASS=$((PASS + 1)); printf '  ✓ %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); FAIL_NAMES+=("$1"); printf '  ✗ %s\n      %s\n' "$1" "${2:-}"; return 0; }
assert_eq() { if [[ "$3" == "$2" ]]; then pass "$1"; else fail "$1" "expected: $2 | actual: $3"; fi; }

# run_forge <stdout-map-fixture> <function> [args...]
run_forge() {
  local fixture="$1"; shift
  (
    export PATH="$MOCKS:$PATH"
    export GH_MOCK_LOG="$(mktemp)"
    local map; map="$(mktemp)"
    printf 'issue view\t%s/%s\n' "$FIXTURES" "$fixture" > "$map"
    export GH_MOCK_STDOUT_MAP="$map"
    export REPO=o/r
    # shellcheck disable=SC1090
    source "$ROOT/scripts/lib/detect-forge.sh"
    # shellcheck disable=SC1090
    source "$LIB"
    "$@"
  )
}

section "forge_export_issue — fills what the classifiers already prefer"

assert_eq "labels arrive newline-separated" "$(printf 'ai-implement\nturns:80')" \
  "$(run_forge forge-issue-github.json bash -c 'forge_export_issue 42 >/dev/null; printf "%s" "$ISSUE_LABELS"')"

assert_eq "body is exported" "Implement the thing." \
  "$(run_forge forge-issue-github.json bash -c 'forge_export_issue 42 >/dev/null; printf "%s" "$ISSUE_BODY"')"

printf '\n  %d passed' "$PASS"
if [ "$FAIL" -gt 0 ]; then
  printf ', %d failed\n' "$FAIL"
  for n in "${FAIL_NAMES[@]}"; do printf '  - %s\n' "$n"; done
  exit 1
fi
printf '\n'; exit 0
```

Fixture `tests/fixtures/forge-issue-github.json` — a trimmed `gh issue view --json labels,title,body` response:

```json
{
  "labels": [{ "name": "ai-implement" }, { "name": "turns:80" }],
  "title": "Do the thing",
  "body": "Implement the thing."
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `tests/run-forge-adapter-tests.sh`

Expected: FAIL — `scripts/lib/forge.sh` does not exist, so sourcing it errors.

- [ ] **Step 3: Implement the adapter**

```bash
#!/usr/bin/env bash
#
# forge.sh — sourced, not executed.
#
# The forge-portable read path for the implement pipeline. The classifiers
# already prefer injected ISSUE_LABELS / ISSUE_BODY and only call `gh` as a
# fallback, so this does not rewrite their call sites -- it fills the two
# variables they already look for, per forge, once per run.
#
# Exit codes: 0 success; 1 error; 2 unsupported forge.
set -euo pipefail
IFS=$'\n\t'

# forge_export_issue <issue-number>  sets and exports ISSUE_LABELS (one name per
# line) and ISSUE_BODY (title + body) for whichever forge the remote is on.
forge_export_issue() {
  local n="${1:?forge_export_issue requires an issue number}"
  local forge; forge="$(detect_forge | awk '{print $1}')"

  case "$forge" in
    github)
      local json
      json="$(gh issue view "$n" --repo "$REPO" --json labels,title,body)"
      ISSUE_LABELS="$(printf '%s' "$json" | python3 -c '
import sys, json
for l in json.load(sys.stdin).get("labels", []):
    print(l["name"])')"
      ISSUE_BODY="$(printf '%s' "$json" | python3 -c '
import sys, json
print(json.load(sys.stdin).get("body", ""))')"
      ;;
    *)
      printf 'forge.sh: unsupported forge: %s\n' "$forge" >&2
      return 2
      ;;
  esac

  export ISSUE_LABELS ISSUE_BODY
}
```

Only `github` is implemented here. `forge-azdo.sh` is step 3 of the spec; an
unsupported forge must **return 2 loudly**, never fall through to an empty value
that a classifier would read as "no labels".

- [ ] **Step 4: Run the tests to verify they pass**

Run: `tests/run-forge-adapter-tests.sh`

Expected: PASS — both assertions.

- [ ] **Step 5: Prove the no-op on the existing suite**

Run: `tests/run-all.sh`

Expected: every pre-existing runner still passes, and the new one appears
(discovered by `find`). Nothing in this task changes an existing script, so a
failure here means the adapter leaked a global — most likely `ISSUE_LABELS`
exported into a test that did not expect it.

- [ ] **Step 6: Lint and commit**

```bash
shellcheck -x -e SC1091 scripts/lib/forge.sh tests/run-forge-adapter-tests.sh
git add scripts/lib/forge.sh tests/run-forge-adapter-tests.sh tests/fixtures/forge-issue-github.json
git commit -m "feat(forge): add the read-path adapter, GitHub only

The classifiers already prefer injected ISSUE_LABELS / ISSUE_BODY and fall back
to gh only when those are unset -- a seam built for their own Layer-1 tests that
nobody had connected to forge portability. This fills those two variables per
forge rather than rewriting the call sites.

GitHub only for now. An unsupported forge returns 2 loudly rather than leaving
the variables empty, which a classifier would read as \"no labels\" and quietly
triage it wrongly.

Refs #253"
```

---

### Task 2: Give the two scripts without a seam the same one

**Files:**
- Modify: `scripts/build-agent-prompt.sh`
- Modify: `scripts/check-attempt-cap.sh`
- Modify: `tests/run-script-tests.sh`

**Interfaces:**
- Consumes: `ISSUE_LABELS` / `ISSUE_BODY` as exported by Task 1.
- Produces: nothing new; both scripts keep their current contract exactly.

- [ ] **Step 1: Record current behaviour before changing it**

```bash
tests/run-script-tests.sh 2>&1 | tail -3
```

Expected: the suite passes. Note the count — Step 5 compares against it.

- [ ] **Step 2: Write a failing test for each**

Add to `tests/run-script-tests.sh`, in each script's existing section:

```bash
# The seam the classifiers already have: prefer an injected value, fall back to
# gh only when it is unset. Without it these two scripts cannot run on a forge
# gh does not speak.
# NOTE: the fixture body below deliberately avoids a literal task heading.
# classify-turns.sh counts those with a naive grep over the whole issue body, so
# an example heading inside a plan inflates that plan's own turn budget.
body='Implementation Plan

Step one: the thing'
out="$(ISSUE_BODY="$body" ISSUE_NUMBER=42 REPO=o/r bash "$ROOT/scripts/build-agent-prompt.sh" 2>&1)"
assert_contains "$out" 'the thing' "build-agent-prompt uses an injected ISSUE_BODY"
```

Drive `check-attempt-cap.sh` the same way with `ISSUE_LABELS`.

- [ ] **Step 3: Run to verify they fail**

Run: `tests/run-script-tests.sh`

Expected: the two new assertions fail — both scripts currently call `gh`
unconditionally and the mock has no fixture mapped, so they produce nothing useful.

- [ ] **Step 4: Add the seam**

In each script, wrap the existing `gh` call exactly as the classifiers do:

```bash
if [[ -z "${ISSUE_BODY:-}" ]]; then
  ISSUE_BODY="$(gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json title,body --jq '.title + "\n\n" + .body')"
fi
```

Match the surrounding style; do not restructure anything else in these files.
Document the new variable in each script's header comment block, as
`classify-turns.sh` does.

- [ ] **Step 5: Run the full suite**

Run: `tests/run-all.sh`

Expected: the two new assertions pass and the count from Step 1 is otherwise
unchanged. A pre-existing assertion that now fails means the fallback branch was
altered rather than merely guarded.

- [ ] **Step 6: Lint and commit**

```bash
shellcheck -x -e SC1091 scripts/build-agent-prompt.sh scripts/check-attempt-cap.sh
git add scripts/build-agent-prompt.sh scripts/check-attempt-cap.sh tests/run-script-tests.sh
git commit -m "refactor(scripts): give the last two read paths the injection seam

classify-agent, classify-task and classify-turns already prefer an injected
ISSUE_LABELS / ISSUE_BODY and call gh only as a fallback. build-agent-prompt and
check-attempt-cap called gh unconditionally, which is what stopped the read path
being forge-portable.

Same guard, same style, no other change: the fallback is untouched, so GitHub
behaviour is identical.

Refs #253"
```

---

### Task 3: Populate the variables once in the workflow

**Files:**
- Modify: `.github/workflows/agent-implement.yml` — the `implement` job, before `Check attempt cap` (~line 527)

**Interfaces:**
- Consumes: `forge_export_issue` from Task 1, and the seams from Task 2.
- Produces: `ISSUE_LABELS` / `ISSUE_BODY` in the job env, so every downstream classifier takes its injected path.

- [ ] **Step 1: Add the step**

Insert immediately after `Fetch issue context` and before `Check attempt cap`:

```yaml
      - name: Export issue context for the classifiers
        env:
          ISSUE_NUMBER: ${{ inputs.issue-number }}
          REPO: ${{ github.repository }}
          GH_TOKEN: ${{ steps.app_token.outputs.token || github.token }}
        run: |
          source .claude-pipeline/scripts/lib/detect-forge.sh
          source .claude-pipeline/scripts/lib/forge.sh
          forge_export_issue "$ISSUE_NUMBER"
          {
            printf 'ISSUE_BODY<<PIPELINE_EOF\n%s\nPIPELINE_EOF\n' "$ISSUE_BODY"
            printf 'ISSUE_LABELS<<PIPELINE_EOF\n%s\nPIPELINE_EOF\n' "$ISSUE_LABELS"
          } >> "$GITHUB_ENV"
```

Heredoc delimiters, not `KEY=value`: an issue body is multi-line and contains
arbitrary text, and a plain assignment would truncate it at the first newline.

- [ ] **Step 2: Verify the workflow still parses**

```bash
actionlint .github/workflows/agent-implement.yml
```

Expected: clean.

- [ ] **Step 3: Prove the no-op end to end**

Dispatch a real issue on this repo and compare its run report against the
previous one for the same issue shape: same agent, same model, same turn budget,
same labels applied.

**This is the acceptance test for the whole step.** The greps and unit tests show
the plumbing is connected; only a real run shows the classifiers reached the same
verdicts through the injected path that they previously reached through `gh`.

If the turn budget or model differs, stop: the injected `ISSUE_BODY` is not
byte-identical to what `gh issue view` produced — most likely the title is
prepended in one path and not the other.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/agent-implement.yml
git commit -m "ci(implement): export issue context once for the classifiers

Fills ISSUE_LABELS and ISSUE_BODY before the classifiers run, so they take their
injected path rather than each making its own gh call. Five scripts stop needing
the forge; the gh fallback stays for anything invoking them standalone.

Uses heredoc delimiters into GITHUB_ENV because an issue body is multi-line and a
plain KEY=value assignment truncates at the first newline.

Refs #253"
```

---

## Verification

```bash
tests/run-all.sh
shellcheck -x -e SC1091 scripts/lib/forge.sh scripts/build-agent-prompt.sh scripts/check-attempt-cap.sh
actionlint .github/workflows/agent-implement.yml
grep -c 'gh issue view' scripts/classify-*.sh    # unchanged — the fallback stays
```

Then dispatch one real issue and diff its run report against a prior one.

**Step 1's success condition is that nothing changed.** Every check above can pass
while the classifiers silently read an empty `ISSUE_LABELS` and wrongly triage every
issue — the run report is the only artefact that shows they reached the same
verdicts. Do not mark this step done on a green suite alone.
