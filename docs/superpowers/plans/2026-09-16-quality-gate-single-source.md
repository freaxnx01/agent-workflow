# Implementation plan — one definition for the quality gate

**Issue:** [#354](https://github.com/freaxnx01/agent-workflow/issues/354)
(absorbs #353) · **Spec:**
[`2026-09-16-quality-gate-single-source-design.md`](../specs/2026-09-16-quality-gate-single-source-design.md)

## Goal

Each gate is defined once and every caller delegates to it: `pre-commit` defines
lint, `tests/run-all.sh` defines the test set. Local and CI cannot drift because
they run the same thing.

## Global constraints

- Bash prelude on every new script: `#!/usr/bin/env bash`, `set -euo pipefail`,
  `IFS=$'\n\t'`. Quote every expansion. `[[ ]]` over `[ ]`.
- Do **not** remove the five inline `disable=SC1091` comments. The spec proves
  `-x` alone fails without them.
- `just lint` and `just test` must both be green before the PR is opened.
- One PR. `main` is protected (`gate-selftest` required, `strict: true`), so this
  lands via PR, never a direct push.
- Discovery is by `find`, never a `**` glob or a hand-kept list.

## Task 1 — CI gains `-x` on shellcheck

**Files:** `.pre-commit-config.yaml`

**Interface:** none (config).

### Step 1.1 — Prove the gap exists

Reproduce CI's invocation (no args) and confirm it fails on a `lib/`-sourcing
script with its suppression stripped:

```bash
T=$(mktemp -d) && cp -r scripts tests "$T/"
sed -i 's/ disable=SC1091//' "$T/scripts/classify-task.sh"
docker run --rm -v "$T:/mnt" -w /mnt docker.io/koalaman/shellcheck:v0.11.0 \
  scripts/classify-task.sh
# expect: SC1091 on the `source "$HERE/lib/blocked-models.sh"` line
rm -rf "$T"
```

`verify:` the command above exits non-zero and names SC1091.

### Step 1.2 — Add the args

```yaml
  - repo: https://github.com/koalaman/shellcheck-precommit
    rev: v0.11.0
    hooks:
      - id: shellcheck
        # -x follows sourced files, so a `# shellcheck source=` directive is
        # verified rather than inert; without it a script that sources a lib/
        # helper is clean locally and fails CI (#350, #353).
        # -e SC1091 is still required: tests/run-ai-funnel-tests.sh and
        # tests/run-ai-stats-tests.sh do `source "$SCRIPT"`, a variable -x
        # cannot resolve. See the spec for the verification.
        args: [-x, -e, SC1091]
```

`verify:` `docker run --rm -v "$PWD:/mnt" -w /mnt
docker.io/koalaman/shellcheck:v0.11.0 -x -e SC1091 $(find scripts tests -name '*.sh' | sort)`
exits 0.

## Task 2 — `tests/run-all.sh` becomes the test definition

**Files:** `tests/run-all.sh` (new), `tests/run-all-discovery-tests.sh` (new)

**Interface:**

```text
tests/run-all.sh
  env  TESTS_DIR  directory to discover runners in (default: this script's dir)
  exit 0  every discovered runner passed
       1  at least one runner failed
       2  no runners discovered (a broken discovery must not look like success)
  stdout  one line per runner, then a summary
```

`TESTS_DIR` exists so this script's own test can point it at a fixture directory.
Without it the test would have to run against the real `tests/`, which contains a
runner that invokes `run-all.sh` — infinite recursion.

### Step 2.1 — Write the failing test

`tests/run-all-discovery-tests.sh`. Note the filename matches `run-*-tests.sh`, so
it is itself discovered and run like any other runner — that is intended.

```bash
#!/usr/bin/env bash
#
# run-all-discovery-tests.sh — Layer-1 tests for tests/run-all.sh.
# Drives it against fixture directories via TESTS_DIR, never the real tests/
# dir (which holds this file, which would recurse).
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN_ALL="$ROOT/tests/run-all.sh"

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
  if [[ "$actual" == "$expected" ]]; then pass "$name"
  else fail "$name" "expected: $expected | actual: $actual"; fi
}
assert_contains() {
  local haystack="$1" needle="$2" name="$3"
  if [[ "$haystack" == *"$needle"* ]]; then pass "$name"
  else fail "$name" "missing: $needle"; fi
}

# make_fixture_dir <spec>...  — each spec is "name:exitcode"
make_fixture_dir() {
  local dir spec name code
  dir="$(mktemp -d)"
  for spec in "$@"; do
    name="${spec%%:*}"; code="${spec##*:}"
    printf '#!/usr/bin/env bash\nexit %s\n' "$code" > "$dir/$name"
    chmod +x "$dir/$name"
  done
  printf '%s' "$dir"
}

run_all_ec() { TESTS_DIR="$1" bash "$RUN_ALL" >/dev/null 2>&1 && echo 0 || echo $?; }
run_all_out() { TESTS_DIR="$1" bash "$RUN_ALL" 2>&1 || true; }

section "discovery"

d="$(make_fixture_dir 'run-a-tests.sh:0' 'run-b-tests.sh:0')"
assert_eq "all runners pass → exit 0" 0 "$(run_all_ec "$d")"
assert_contains "$(run_all_out "$d")" 'run-a-tests.sh' "names each runner it ran"
assert_contains "$(run_all_out "$d")" 'run-b-tests.sh' "names the second runner"
rm -rf "$d"

d="$(make_fixture_dir 'run-a-tests.sh:0' 'run-b-tests.sh:1')"
assert_eq "one runner fails → exit 1" 1 "$(run_all_ec "$d")"
assert_contains "$(run_all_out "$d")" 'run-b-tests.sh' "names the failing runner"
rm -rf "$d"

# A runner failing must not stop the rest — a single break should not hide
# every later runner's result.
d="$(make_fixture_dir 'run-a-tests.sh:1' 'run-b-tests.sh:0')"
assert_contains "$(run_all_out "$d")" 'run-b-tests.sh' \
  "keeps going after a failure"
rm -rf "$d"

section "non-runners are ignored"

d="$(make_fixture_dir 'run-a-tests.sh:0')"
printf '#!/usr/bin/env bash\nexit 1\n' > "$d/helper.sh"; chmod +x "$d/helper.sh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$d/run-all.sh"; chmod +x "$d/run-all.sh"
printf 'not a script\n' > "$d/fixture.json"
assert_eq "ignores helper.sh, run-all.sh and non-scripts" 0 "$(run_all_ec "$d")"
rm -rf "$d"

section "an empty discovery is an error, not a pass"

d="$(mktemp -d)"
assert_eq "no runners found → exit 2" 2 "$(run_all_ec "$d")"
rm -rf "$d"

section "the real tests/ directory"

# Guards the recursion trap: run-all.sh must not discover itself.
listed="$(TESTS_DIR="$ROOT/tests" bash -c '
  find "$1" -maxdepth 1 -type f -name "run-*-tests.sh" -print0 | tr "\0" "\n"' _ "$ROOT/tests")"
assert_contains "$listed" 'run-script-tests.sh'          "discovers the main suite"
assert_contains "$listed" 'run-parse-enrich-args-tests.sh' "discovers the runner missing from the old list"
assert_contains "$listed" 'run-link-skills-tests.sh'     "discovers the other missing runner"
if [[ "$listed" == *"/run-all.sh"* ]]; then
  fail "run-all.sh is not discovered as a runner" "it matched its own pattern"
else
  pass "run-all.sh is not discovered as a runner"
fi

printf '\n%s─────%s\n' "$C_DIM" "$C_OFF"
printf '  %s%d passed%s' "$C_GREEN" "$PASS" "$C_OFF"
if [ "$FAIL" -gt 0 ]; then
  printf ', %s%d failed%s\n' "$C_RED" "$FAIL" "$C_OFF"
  printf '\nFailed:\n'
  for n in "${FAIL_NAMES[@]}"; do printf '  - %s\n' "$n"; done
  exit 1
fi
printf '\n'
exit 0
```

`verify:` `bash tests/run-all-discovery-tests.sh` fails because `tests/run-all.sh`
does not exist yet.

### Step 2.2 — Write `tests/run-all.sh`

```bash
#!/usr/bin/env bash
#
# run-all.sh — the definition of the Layer-1 test set.
#
# Discovers every `run-*-tests.sh` next to this file and runs it. Both
# `just test` and the CI `test` job call this, so the two cannot list
# different runners — which is exactly what they did before (#354: the recipe
# named 7 of 9, CI ran none).
#
# Discovery is by `find`, not a hand-kept list and not a `**` glob: a glob
# needs `globstar` to recurse and silently skips otherwise, and a list is the
# thing that drifted.
#
# Env:
#   TESTS_DIR  directory to discover runners in. Defaults to this script's own
#              directory. Exists so run-all-discovery-tests.sh can drive this
#              script against a fixture dir — pointing it at the real tests/
#              would re-enter this script through its own test and recurse.
#
# Exit codes:
#   0  every discovered runner passed
#   1  at least one runner failed
#   2  no runners discovered — a broken discovery must not look like success
set -euo pipefail
IFS=$'\n\t'

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="${TESTS_DIR:-$HERE}"

if [[ ! -d "$TESTS_DIR" ]]; then
  printf 'error: TESTS_DIR %q is not a directory\n' "$TESTS_DIR" >&2
  exit 2
fi

mapfile -t runners < <(
  find "$TESTS_DIR" -maxdepth 1 -type f -name 'run-*-tests.sh' | sort
)

if (( ${#runners[@]} == 0 )); then
  printf 'error: no run-*-tests.sh found in %q\n' "$TESTS_DIR" >&2
  exit 2
fi

failed=()
for runner in "${runners[@]}"; do
  name="$(basename "$runner")"
  printf '\n=== %s ===\n' "$name"
  # Deliberately not `set -e`-fatal: one broken runner must not hide the
  # results of every runner after it.
  if bash "$runner"; then
    printf '--- %s: OK\n' "$name"
  else
    printf '--- %s: FAILED\n' "$name"
    failed+=("$name")
  fi
done

printf '\n===============================\n'
printf 'runners: %d   failed: %d\n' "${#runners[@]}" "${#failed[@]}"
if (( ${#failed[@]} > 0 )); then
  printf 'failed:\n'
  for name in "${failed[@]}"; do printf '  - %s\n' "$name"; done
  exit 1
fi
exit 0
```

`verify:` `bash tests/run-all-discovery-tests.sh` passes, and
`bash tests/run-all.sh` runs all 10 runners (9 existing + the new discovery test)
and exits 0.

## Task 3 — `just test` and `just lint` delegate

**Files:** `justfile`

**Interface:** recipes `test`, `lint`, `lint-shell`.

### Step 3.1 — Point `test` at the definition

Replace the seven-line body:

```just
# Layer-1 fixture tests (no network, runs in seconds) — discovers every runner
test:
    bash tests/run-all.sh
```

`verify:` `just test` exits 0 and its output names
`run-parse-enrich-args-tests.sh` and `run-link-skills-tests.sh`, neither of which
the old recipe ran.

### Step 3.2 — Delegate `lint` to pre-commit

The comment must change with the body: this recipe is no longer "actionlint +
shellcheck", it is the whole gate.

```just
# The full polyglot gate — the exact command CI runs (pre-commit). Slower than
# lint-shell and needs Docker for the shellcheck/actionlint/hadolint hooks;
# use `just lint-shell` in the inner loop.
lint:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! command -v pre-commit >/dev/null; then
      echo "pre-commit is not installed — it defines this repo's lint gate." >&2
      echo "  pipx install pre-commit   (or: python -m pip install pre-commit)" >&2
      echo "Fast shell-only path meanwhile: just lint-shell" >&2
      exit 127
    fi
    pre-commit run --all-files

# Fast inner-loop lint: shell + workflows only, skipping the other nine hooks
lint-shell:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! command -v pre-commit >/dev/null; then
      echo "pre-commit is not installed — see 'just lint'." >&2
      exit 127
    fi
    pre-commit run shellcheck actionlint-docker --all-files
```

`verify:` with `pre-commit` installed, `just lint` exits 0; `just lint-shell`
exits 0 and its output mentions only the shellcheck and actionlint hooks. With
`pre-commit` absent (`PATH= just lint`), the message names the install command and
the exit code is 127, not a bare `command not found`.

## Task 4 — CI runs the Layer-1 suite

**Files:** `.github/workflows/lint.yml`

**Interface:** new job `test`.

### Step 4.1 — Add the job

`lint.yml` already triggers on `pull_request` and `push: [main]` with
`permissions: contents: read` and a concurrency group — the new job inherits all
of it. Add alongside the existing `pre-commit` job:

```yaml
  test:
    name: test
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - name: Checkout
        uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683  # v4.2.2

      - name: Run the Layer-1 suite
        # tests/run-all.sh discovers every run-*-tests.sh, so this job and
        # `just test` cannot diverge (#354). No network, no Docker, no secrets.
        run: bash tests/run-all.sh
```

Pin `actions/checkout` to the same SHA the file already uses — never a mutable
tag.

`verify:` `actionlint` exits 0. On the PR, a `test` check appears and passes.
Then, as a negative control, temporarily break one assertion, push, confirm
`test` goes red, and revert.

### Step 4.2 — Update the workflow header comment

The file's top comment describes a lint-only gate. Add that it now also runs the
Layer-1 suite, and note the job is not in `required_status_checks` yet.

`verify:` `yamllint .github/workflows/lint.yml` exits 0.

## Task 5 — Changelog

**Files:** `CHANGELOG.md`

Add to `[Unreleased]`, under `### Added` and `### Fixed` as appropriate: the
`test` CI job and `tests/run-all.sh`; `just lint` delegating to pre-commit plus
the new `lint-shell`; CI shellcheck gaining `-x`; and that the two orphaned
runners now run. Reference #354 and #353.

`verify:` `markdownlint-cli2 CHANGELOG.md` (or `just lint`) exits 0.

## Verification before the PR

```bash
just test                     # exits 0, 10 runners
just lint                     # exits 0 (needs pre-commit)
actionlint                    # exits 0
bash tests/run-all-discovery-tests.sh   # exits 0
```

Then branch, commit, and open a PR against `main`. Do not push to `main`.

## Manual step for the repo owner — not done by this PR

A red `test` job does not block merge until it is a required check.
`main`'s protection currently pins `contexts: ["gate-selftest"]`:

```bash
gh api -X PATCH repos/freaxnx01/agent-workflow/branches/main/protection/required_status_checks \
  -f 'contexts[]=gate-selftest' -f 'contexts[]=test'
```

Left to the owner deliberately: it changes repo settings, and `test` must have a
green run on `main` first or every subsequent PR blocks on a check that has never
reported.
