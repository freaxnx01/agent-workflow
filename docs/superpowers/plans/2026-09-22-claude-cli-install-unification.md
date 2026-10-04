# Claude Code CLI Install Unification — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the review and self-fix jobs install the Claude Code CLI the same way the implement job does — via the native installer, with no npm — and make a toolchain failure announce itself instead of dying silently.

**Architecture:** One new script (`install-claude-cli.sh`) becomes the single place the CLI is acquired outside `claude-code-base-action`; it fetches upstream's `install.sh`, verifies a pinned SHA-256, and executes it at a pinned version. A second new script (`post-runner-block.sh`) stamps a new `ai:runner-blocked` label and comments when that install fails, so "the reviewer never started" is distinguishable from `ai:review-blocked`'s "the reviewer ran and refused".

**Tech Stack:** Bash 5 (`set -euo pipefail`, `IFS=$'\n\t'`), GitHub Actions reusable workflow YAML, `gh` CLI, fixture-driven Layer-1 bash tests with PATH-shadowed mocks, `actionlint` + `shellcheck -x`.

**Spec:** `docs/superpowers/specs/2026-09-22-claude-cli-install-unification-design.md`

## Global Constraints

- Every script starts with `#!/usr/bin/env bash`, then `set -euo pipefail`, then `IFS=$'\n\t'`.
- Quote every variable expansion. `[[ ... ]]` over `[ ... ]`. `$(...)` over backticks. No `eval`.
- `printf` over `echo` for anything formatted.
- Temp files via `mktemp`, cleaned up with `trap ... EXIT`.
- Exit codes are part of the API and are documented in each script's header block.
- Env-driven, not flag-driven — these are CI scripts invoked from `env:` blocks.
- Pinned CLI version is **`2.1.270`**, matching `anthropics/claude-code-base-action` at `.github/workflows/agent-implement.yml:665`.
- No `curl | bash`. Anything fetched over the network is checksum-verified before execution.
- Layer-1 tests are hermetic: no network, no GitHub, no Docker; whole suite under 5 seconds.
- Test runners are auto-discovered by `tests/run-all.sh` via `find -maxdepth 1 -name 'run-*-tests.sh'` — a new runner needs **no** registration in `run-all.sh` or the justfile.
- Conventional Commits for every commit; scope `runners` for script/workflow work, `docs` for doc-only.

---

### Task 1: The installer script

**Files:**
- Create: `scripts/install-claude-cli.sh`
- Create: `tests/run-install-claude-cli-tests.sh`
- Create: `tests/mocks/curl-installer-ok`
- Modify: `docs/RUNNER-REQUIREMENTS.md` (add the `curl` / `sha256sum` rows)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `scripts/install-claude-cli.sh`, invoked as `bash .claude-pipeline/scripts/install-claude-cli.sh` with no arguments. Reads env `CLAUDE_CLI_VERSION`, `INSTALLER_URL`, `INSTALLER_SHA256`, `DRY_RUN`, `GITHUB_PATH`. Exit codes `0` / `64` / `65` / `66`. On success, appends the directory containing `claude` to `$GITHUB_PATH`. Task 3 wires it into the workflow.

- [ ] **Step 1: Write the failing test**

Create `tests/run-install-claude-cli-tests.sh`:

```bash
#!/usr/bin/env bash
#
# run-install-claude-cli-tests.sh — Layer-1 tests for scripts/install-claude-cli.sh.
#
# Hermetic by construction: the script runs with a PATH built of symlinks to
# exactly the tools a given case should be able to see, so "curl is missing" is
# a real absence rather than a mocked one. The network is never touched — the
# curl stand-in writes a fixture payload and the REAL sha256sum hashes it, so
# the checksum path is exercised for true rather than stubbed.
#
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/install-claude-cli.sh"

PASS=0; FAIL=0; FAIL_NAMES=()

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
  [[ -n "${2:-}" ]] && printf '    %s%s%s\n' "$C_DIM" "$2" "$C_OFF"
}
assert_contains() {
  local hay="$1" needle="$2" name="$3"
  if [[ "$hay" == *"$needle"* ]]; then pass "$name"
  else fail "$name" "expected substring not found: $needle"; fi
}
assert_not_contains() {
  local hay="$1" needle="$2" name="$3"
  if [[ "$hay" != *"$needle"* ]]; then pass "$name"
  else fail "$name" "unexpected substring present: $needle"; fi
}
assert_equals() {
  if [[ "$1" == "$2" ]]; then pass "$3"
  else fail "$3" "expected '$2' got '$1'"; fi
}

# The payload the curl stand-in "downloads". Executing it must create a
# `claude` binary, so the success path is observable without a real install.
INSTALLER_PAYLOAD='#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$FAKE_INSTALL_BIN"
printf "#!/usr/bin/env bash\necho 2.1.270\n" > "$FAKE_INSTALL_BIN/claude"
chmod +x "$FAKE_INSTALL_BIN/claude"
'

# Build a PATH directory holding symlinks to exactly $@ (resolved from the real
# PATH), plus a curl stand-in unless "no-curl" is among the names.
make_bin() {
  local dir="$1"; shift
  mkdir -p "$dir"
  local t
  for t in "$@"; do
    [[ "$t" == "curl" ]] && continue
    ln -sf "$(command -v "$t")" "$dir/$t"
  done
  for t in "$@"; do
    if [[ "$t" == "curl" ]]; then
      cat > "$dir/curl" <<CURL
#!/usr/bin/env bash
set -euo pipefail
# Parse just enough of curl's argv to find "-o <path>".
out=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o) out="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s' "\$INSTALLER_PAYLOAD" > "\$out"
CURL
      chmod +x "$dir/curl"
    fi
  done
}

run_script() {
  # Usage: run_script <bindir> [env assignments...]
  local bindir="$1"; shift
  env -u CLAUDE_CLI_VERSION PATH="$bindir" INSTALLER_PAYLOAD="$INSTALLER_PAYLOAD" \
    "$@" bash "$SCRIPT" 2>&1
}

TOOLS=(mktemp cut rm sha256sum chmod mkdir bash curl)

section "prerequisite guards"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# --- curl absent -> exit 64, names curl and the doc
bin_nocurl="$tmp/bin-nocurl"
make_bin "$bin_nocurl" mktemp cut rm sha256sum chmod mkdir bash
ec=0
gh_out="$tmp/gh_output"; : > "$gh_out"
out="$(run_script "$bin_nocurl" HOME="$tmp/home" GITHUB_OUTPUT="$gh_out" || ec=$?)"
assert_equals "$ec" "64"                            "curl absent → exit 64"
assert_contains "$(cat "$gh_out")" "exit-code=64"   "curl absent → publishes exit-code output"
assert_contains "$out" "curl"                       "curl absent → names curl"
assert_contains "$out" "docs/RUNNER-REQUIREMENTS.md" "curl absent → names the doc"
assert_not_contains "$out" "command not found"      "curl absent → not a bare command-not-found"

# --- sha256sum absent -> exit 64, names sha256sum
bin_nosum="$tmp/bin-nosum"
make_bin "$bin_nosum" mktemp cut rm chmod mkdir bash curl
ec=0
out="$(run_script "$bin_nosum" HOME="$tmp/home" || ec=$?)"
assert_equals "$ec" "64"                             "sha256sum absent → exit 64"
assert_contains "$out" "sha256sum"                   "sha256sum absent → names sha256sum"
assert_contains "$out" "docs/RUNNER-REQUIREMENTS.md" "sha256sum absent → names the doc"

section "checksum verification"

bin_ok="$tmp/bin-ok"
make_bin "$bin_ok" "${TOOLS[@]}"
GOOD_SHA="$(printf '%s' "$INSTALLER_PAYLOAD" | sha256sum | cut -d' ' -f1)"

# --- mismatch -> exit 65 and the installer must NOT have run
marker="$tmp/should-not-exist"
ec=0
out="$(run_script "$bin_ok" \
  HOME="$tmp/home" \
  FAKE_INSTALL_BIN="$marker" \
  INSTALLER_SHA256=0000000000000000000000000000000000000000000000000000000000000000 \
  || ec=$?)"
assert_equals "$ec" "65"                    "checksum mismatch → exit 65"
assert_contains "$out" "checksum"           "checksum mismatch → says checksum"
if [[ ! -e "$marker/claude" ]]; then pass "checksum mismatch → installer not executed"
else fail "checksum mismatch → installer not executed" "marker was created"; fi

section "happy path"

gh_path="$tmp/github_path"; : > "$gh_path"
install_bin="$tmp/installed"
ec=0
out="$(run_script "$bin_ok" \
  HOME="$tmp/home" \
  FAKE_INSTALL_BIN="$install_bin" \
  INSTALLER_SHA256="$GOOD_SHA" \
  GITHUB_PATH="$gh_path" \
  || ec=$?)"
assert_equals "$ec" "0"                                  "happy path → exit 0"
assert_contains "$(cat "$gh_path")" "$install_bin"       "happy path → bin dir appended to GITHUB_PATH"
assert_contains "$out" "2.1.270"                         "happy path → reports the pinned version"

section "installer ran but produced no binary"

ec=0
out="$(run_script "$bin_ok" \
  HOME="$tmp/home" \
  FAKE_INSTALL_BIN="$tmp/elsewhere" \
  CLAUDE_BIN_CANDIDATES="$tmp/nowhere" \
  INSTALLER_SHA256="$GOOD_SHA" \
  || ec=$?)"
assert_equals "$ec" "66"                             "no binary → exit 66"
assert_contains "$out" "docs/RUNNER-REQUIREMENTS.md" "no binary → names the doc"

section "DRY_RUN"

ec=0
out="$(run_script "$bin_ok" HOME="$tmp/home" DRY_RUN=1 || ec=$?)"
assert_equals "$ec" "0"                    "DRY_RUN → exit 0"
assert_contains "$out" "DRY_RUN"           "DRY_RUN → says so"
assert_not_contains "$out" "2.1.270"       "DRY_RUN → no install performed"

# --- summary ---------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'failed:\n'; printf '  - %s\n' "${FAIL_NAMES[@]}"
  exit 1
fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run-install-claude-cli-tests.sh`
Expected: FAIL — `scripts/install-claude-cli.sh` does not exist, so every case errors.

- [ ] **Step 3: Write minimal implementation**

Create `scripts/install-claude-cli.sh`:

```bash
#!/usr/bin/env bash
#
# install-claude-cli.sh — Put the Claude Code CLI on PATH for jobs that do not
# use anthropics/claude-code-base-action (the review and self-fix jobs).
#
# Uses the NATIVE installer, not npm. npm was the wrong shape here twice:
#   - `npm install -g` resolves to the shared `npm config get prefix`
#     (/usr/local), which on a persistent self-hosted runner is shared across
#     every job and run. Once written as root, a later install as the runner
#     user cannot rename the package dir and dies with EACCES (#302).
#   - A runner with no Node.js at all fails with a bare `npm: command not
#     found`, exit 127, naming no requirement (#384).
# The implement job never hit either, because the base action installs the CLI
# itself. One dependency now has one mechanism.
#
# The installer is fetched and CHECKSUM-VERIFIED before it is executed. A bare
# `curl | bash` is forbidden by this repo's CI stack overlay, and the pin is
# what makes the fetch reviewable.
#
# Optional environment variables:
#   CLAUDE_CLI_VERSION  Version to install. Default below; keep it equal to the
#                       CLI the base action installs (agent-implement.yml:665).
#   INSTALLER_URL       Where to fetch install.sh. Default below.
#   INSTALLER_SHA256    Expected SHA-256 of install.sh. Default below.
#   CLAUDE_BIN_CANDIDATES
#                       Colon-separated dirs to search for the installed
#                       binary, ahead of the defaults. Exists for tests.
#   DRY_RUN             "1" → run the prerequisite guards, then stop. No
#                       network, no install. Used by Layer-1 tests.
#   GITHUB_PATH         When set, the dir holding `claude` is appended to it.
#   GITHUB_OUTPUT       When set, the exit code is published as `exit-code`
#                       before a non-zero exit, so the workflow's failure-path
#                       step can pass it to post-runner-block.sh.
#
# Exit codes:
#   0   claude on PATH at CLAUDE_CLI_VERSION
#   64  a prerequisite is absent — names it and the doc
#   65  installer checksum mismatch — refuses to execute
#   66  installer ran but `claude` is still not on PATH
set -euo pipefail
IFS=$'\n\t'

# Keep in lockstep with anthropics/claude-code-base-action in
# .github/workflows/agent-implement.yml:665 — the reviewer and the implementer
# should be running the same CLI. Bump both in the same commit.
CLAUDE_CLI_VERSION="${CLAUDE_CLI_VERSION:-2.1.270}"
INSTALLER_URL="${INSTALLER_URL:-https://claude.ai/install.sh}"

# SHA-256 of the installer as fetched on 2026-09-22. Refreshing this is a
# deliberate commit, reviewed like any other dependency bump: fetch the script,
# read the diff, then record the new hash here.
INSTALLER_SHA256="${INSTALLER_SHA256:-REPLACE_WITH_PINNED_SHA256}"

DOC='docs/RUNNER-REQUIREMENTS.md'

# Publish the exit code as a step output before dying. The workflow's
# failure-path step reads `steps.install_cli.outputs.exit-code` to pick the
# right reason in post-runner-block.sh; without this it would always be empty
# and every failure would get the generic wording.
die() {
  local code="$1"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf 'exit-code=%s\n' "$code" >> "$GITHUB_OUTPUT"
  fi
  exit "$code"
}

require_tool() {
  local tool="$1"
  command -v "$tool" >/dev/null 2>&1 && return 0
  printf 'error: required tool %q is not present on this runner.\n' "$tool" >&2
  printf '       It is needed to install the Claude Code CLI for the review job.\n' >&2
  printf '       Unmet runner requirement — see %s\n' "$DOC" >&2
  die 64
}

require_tool curl
require_tool sha256sum

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  printf 'prerequisites present; install skipped (DRY_RUN)\n'
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

printf 'fetching installer from %s\n' "$INSTALLER_URL"
curl -fsSL -o "$WORK/install.sh" "$INSTALLER_URL"

actual_sha="$(sha256sum "$WORK/install.sh" | cut -d' ' -f1)"
if [[ "$actual_sha" != "$INSTALLER_SHA256" ]]; then
  printf 'error: installer checksum mismatch — refusing to execute.\n' >&2
  printf '       expected %s\n' "$INSTALLER_SHA256" >&2
  printf '       actual   %s\n' "$actual_sha" >&2
  printf '       Either upstream changed install.sh (bump the pin in this script\n' >&2
  printf '       after reviewing the diff) or the download was tampered with.\n' >&2
  die 65
fi

printf 'installing Claude Code CLI %s\n' "$CLAUDE_CLI_VERSION"
bash "$WORK/install.sh" "$CLAUDE_CLI_VERSION"

# Locate the installed binary. The native installer targets ~/.local/bin; the
# candidates list keeps this from being a single hardcoded guess.
CANDIDATES="${CLAUDE_BIN_CANDIDATES:-}"
CANDIDATES="${CANDIDATES:+$CANDIDATES:}$HOME/.local/bin:$HOME/.claude/bin"

claude_dir=''
IFS=':' read -ra cand_dirs <<< "$CANDIDATES"
for d in "${cand_dirs[@]}"; do
  if [[ -n "$d" && -x "$d/claude" ]]; then
    claude_dir="$d"
    break
  fi
done

if [[ -z "$claude_dir" ]]; then
  # Fall back to whatever the installer may already have put on PATH.
  if command -v claude >/dev/null 2>&1; then
    claude_dir="$(dirname "$(command -v claude)")"
  fi
fi

if [[ -z "$claude_dir" ]]; then
  printf 'error: installer completed but no `claude` binary was found.\n' >&2
  printf '       Searched: %s\n' "$CANDIDATES" >&2
  printf '       Unmet runner requirement — see %s\n' "$DOC" >&2
  die 66
fi

if [[ -n "${GITHUB_PATH:-}" ]]; then
  printf '%s\n' "$claude_dir" >> "$GITHUB_PATH"
fi

PATH="$claude_dir:$PATH"
export PATH
printf 'claude installed at %s (version: %s)\n' "$claude_dir/claude" "$("$claude_dir/claude" --version 2>/dev/null || printf 'unknown')"
```

- [ ] **Step 4: Pin the real checksum**

The literal `REPLACE_WITH_PINNED_SHA256` above is the one value that cannot be
written ahead of time. Fetch the installer once, read it, then record its hash:

```bash
curl -fsSL -o /tmp/claude-install.sh https://claude.ai/install.sh
less /tmp/claude-install.sh          # review before trusting it
sha256sum /tmp/claude-install.sh
```

Replace `REPLACE_WITH_PINNED_SHA256` with that hash. Leave the `2026-09-22`
capture-date comment above it accurate — update the date to the day you fetched.

Verify no placeholder survives:

```bash
grep -n 'REPLACE_WITH_PINNED_SHA256' scripts/install-claude-cli.sh && exit 1 || echo "pin recorded"
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash tests/run-install-claude-cli-tests.sh`
Expected: PASS — all cases green, suite well under a second.

- [ ] **Step 6: Lint**

Run: `shellcheck -x scripts/install-claude-cli.sh tests/run-install-claude-cli-tests.sh`
Expected: no findings. If `SC2046`/`SC2086` fire, quote the expansion rather than suppressing.

- [ ] **Step 7: Add the runner requirement rows**

In `docs/RUNNER-REQUIREMENTS.md`, under **Always required**, add two rows to the
existing table (keep the existing `rg` / `jq` / `gh` rows unchanged):

```markdown
| `curl` | apt: `curl` | Fetches the Claude Code CLI installer in the review / self-fix jobs (`scripts/install-claude-cli.sh`) |
| `sha256sum` | apt: `coreutils` | Verifies the pinned checksum of that installer before it is executed |
```

- [ ] **Step 8: Commit**

```bash
git add scripts/install-claude-cli.sh tests/run-install-claude-cli-tests.sh docs/RUNNER-REQUIREMENTS.md
git commit -m "feat(runners): install the Claude Code CLI via the native installer

Adds scripts/install-claude-cli.sh: fetches upstream install.sh, verifies a
pinned SHA-256 before executing it, installs the version the implement job's
base action provides, and puts the binary on GITHUB_PATH.

Prerequisite guards name the missing tool and docs/RUNNER-REQUIREMENTS.md
rather than dying with a bare command-not-found (#384).

Refs #302, #384"
```

---

### Task 2: Surfacing a toolchain failure

**Files:**
- Create: `scripts/post-runner-block.sh`
- Create: `tests/run-post-runner-block-tests.sh`
- Modify: `scripts/ensure-issue-labels.sh` (add `ai:runner-blocked` beside `ai:review-blocked`, ~line 85)

**Interfaces:**
- Consumes: nothing from Task 1 at runtime; it is the failure path Task 3 wires to Task 1's non-zero exits.
- Produces: `scripts/post-runner-block.sh`, invoked as `bash .claude-pipeline/scripts/post-runner-block.sh`. Required env `REPO`, `ISSUE_NUMBER`; optional `PR_NUMBER`, `EXIT_CODE`, `JOB_NAME`, `GH_TOKEN`. Exit `0` on success, `2` on missing required env. Applies the label `ai:runner-blocked`.

- [ ] **Step 1: Write the failing test**

Create `tests/run-post-runner-block-tests.sh`:

```bash
#!/usr/bin/env bash
#
# run-post-runner-block-tests.sh — Layer-1 tests for scripts/post-runner-block.sh.
#
# Drives the script against the shared `gh` mock (tests/mocks/gh), which logs
# each invocation's argv to $GH_MOCK_LOG. Assertions are on that log: which
# object got the comment, and which label was applied.
#
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/post-runner-block.sh"
MOCKS="$HERE/mocks"

PASS=0; FAIL=0; FAIL_NAMES=()

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
  [[ -n "${2:-}" ]] && printf '    %s%s%s\n' "$C_DIM" "$2" "$C_OFF"
}
assert_contains() {
  local hay="$1" needle="$2" name="$3"
  if [[ "$hay" == *"$needle"* ]]; then pass "$name"
  else fail "$name" "expected substring not found: $needle"; fi
}
assert_not_contains() {
  local hay="$1" needle="$2" name="$3"
  if [[ "$hay" != *"$needle"* ]]; then pass "$name"
  else fail "$name" "unexpected substring present: $needle"; fi
}
assert_equals() {
  if [[ "$1" == "$2" ]]; then pass "$3"
  else fail "$3" "expected '$2' got '$1'"; fi
}

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

run_block() {
  # Usage: run_block <logfile> [env assignments...]
  local log="$1"; shift
  : > "$log"
  env PATH="$MOCKS:$PATH" GH_MOCK_LOG="$log" "$@" bash "$SCRIPT" 2>&1
}

section "required env"

ec=0
out="$(run_block "$tmp/l0" ISSUE_NUMBER=42 || ec=$?)"
assert_equals "$ec" "2"              "missing REPO → exit 2"
assert_contains "$out" "REPO"        "missing REPO → names REPO"

ec=0
out="$(run_block "$tmp/l1" REPO=o/r || ec=$?)"
assert_equals "$ec" "2"                    "missing ISSUE_NUMBER → exit 2"
assert_contains "$out" "ISSUE_NUMBER"      "missing ISSUE_NUMBER → names ISSUE_NUMBER"

section "comment target"

log="$tmp/l2"
run_block "$log" REPO=o/r ISSUE_NUMBER=42 PR_NUMBER=7 EXIT_CODE=64 >/dev/null
logtext="$(cat "$log")"
assert_contains "$logtext" "pr comment 7"            "PR known → comments on the PR"
assert_not_contains "$logtext" "issue comment 42"    "PR known → does not also comment on the issue"

log="$tmp/l3"
run_block "$log" REPO=o/r ISSUE_NUMBER=42 EXIT_CODE=64 >/dev/null
logtext="$(cat "$log")"
assert_contains "$logtext" "issue comment 42"        "no PR → comments on the issue"

section "comment content"

assert_contains "$logtext" "Review did not run"             "comment → says the review did not run"
assert_contains "$logtext" "docs/RUNNER-REQUIREMENTS.md"    "comment → names the doc"
assert_not_contains "$logtext" "](../"                      "comment → no relative markdown link"

section "labels"

assert_contains "$logtext" "--add-label ai:runner-blocked"     "labels → applies ai:runner-blocked"
assert_not_contains "$logtext" "--add-label ai:review-blocked" "labels → never applies ai:review-blocked"
assert_contains "$logtext" "label create ai:runner-blocked"    "labels → idempotently creates the label first"

section "exit-code wording"

log="$tmp/l4"
run_block "$log" REPO=o/r ISSUE_NUMBER=42 EXIT_CODE=65 >/dev/null
assert_contains "$(cat "$log")" "checksum"   "exit 65 → comment names the checksum failure"

log="$tmp/l5"
run_block "$log" REPO=o/r ISSUE_NUMBER=42 EXIT_CODE=66 >/dev/null
assert_contains "$(cat "$log")" "not found"  "exit 66 → comment names the missing binary"

# --- summary ---------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'failed:\n'; printf '  - %s\n' "${FAIL_NAMES[@]}"
  exit 1
fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run-post-runner-block-tests.sh`
Expected: FAIL — `scripts/post-runner-block.sh` does not exist.

- [ ] **Step 3: Write minimal implementation**

Create `scripts/post-runner-block.sh`:

```bash
#!/usr/bin/env bash
#
# post-runner-block.sh — Surface that the review never STARTED because the
# runner's toolchain is unmet, and stamp the issue with `ai:runner-blocked`.
#
# This is the sibling of post-auto-review-block.sh, and the distinction is the
# point (#384): `ai:review-blocked` means the reviewer ran and refused to
# promote; `ai:runner-blocked` means the reviewer never got to run. Before this
# existed the second case posted nothing at all — the job aborted and the
# "Mark issue blocked" step, which inherits the default `success()`, never
# fired. From the issue the two were indistinguishable.
#
# Required environment variables:
#   REPO          owner/repo
#   ISSUE_NUMBER  Originating issue
#
# Optional environment variables:
#   PR_NUMBER   If known, the comment goes on the PR; else on the issue.
#   EXIT_CODE   install-claude-cli.sh's exit code, used to pick the reason.
#   JOB_NAME    Job that failed, for the comment. Default: "review".
#   GH_TOKEN    (or ambient gh auth)
#
# Exit codes:
#   0  failure surfaced
#   2  required env missing
set -euo pipefail
IFS=$'\n\t'

for var in REPO ISSUE_NUMBER; do
  if [[ -z "${!var:-}" ]]; then
    printf 'error: %s must be set\n' "$var" >&2
    exit 2
  fi
done

PR_NUMBER="${PR_NUMBER:-}"
EXIT_CODE="${EXIT_CODE:-}"
JOB_NAME="${JOB_NAME:-review}"

# Map the installer's documented exit codes to a human reason. An unrecognised
# or absent code gets the generic line rather than a wrong specific one.
case "$EXIT_CODE" in
  64) reason='a required tool is not present on this runner' ;;
  65) reason='the installer checksum did not match the pinned value, so it was not executed' ;;
  66) reason='the installer ran but no `claude` binary was found afterwards' ;;
  *)  reason='the Claude Code CLI could not be installed' ;;
esac

# The doc is referenced as a plain path, NOT a relative markdown link: this
# comment renders in the CONSUMER repo, where a relative link would resolve
# against the wrong tree.
body="$(printf '**Review did not run** — the %s job could not start.\n\nReason: %s.\n\nThis is a runner-toolchain problem, not a review verdict: the reviewer never\nexamined the code, so nothing here says anything about the change itself.\nSee `docs/RUNNER-REQUIREMENTS.md` in the agent-workflow repo for the toolchain\ncontract, and the job log for the named diagnostic.' \
  "$JOB_NAME" "$reason")"

if [[ -n "$PR_NUMBER" ]]; then
  gh pr comment "$PR_NUMBER" --repo "$REPO" --body "$body"
else
  gh issue comment "$ISSUE_NUMBER" --repo "$REPO" --body "$body"
fi

# Label the issue so a watcher — and the autopilot lane — can route this to an
# operator rather than to a re-review. Created idempotently first, mirroring
# post-auto-review-block.sh: ensure-issue-labels.sh usually got there already,
# but a manually-deleted label must not break the --add-label call.
gh label create ai:runner-blocked --repo "$REPO" --color D73A4A \
  --description 'Review never started — runner toolchain unmet' \
  >/dev/null 2>&1 || true
gh issue edit "$ISSUE_NUMBER" --repo "$REPO" --add-label ai:runner-blocked
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run-post-runner-block-tests.sh`
Expected: PASS.

- [ ] **Step 5: Register the label**

In `scripts/ensure-issue-labels.sh`, directly below the existing
`create ai:review-blocked ...` line (~line 85), add:

```bash
# Two blocked states, deliberately distinct (#384):
#   ai:review-blocked  — the reviewer RAN and refused to promote the PR
#   ai:runner-blocked  — the reviewer NEVER STARTED; the runner toolchain is unmet
create ai:runner-blocked D73A4A 'Review never started — runner toolchain unmet'
```

- [ ] **Step 6: Run the full Layer-1 suite**

Run: `bash tests/run-all.sh`
Expected: every runner green, including the two new ones (auto-discovered — no registration needed). Total under 5 seconds.

- [ ] **Step 7: Lint**

Run: `shellcheck -x scripts/post-runner-block.sh scripts/ensure-issue-labels.sh tests/run-post-runner-block-tests.sh`
Expected: no findings.

- [ ] **Step 8: Commit**

```bash
git add scripts/post-runner-block.sh scripts/ensure-issue-labels.sh tests/run-post-runner-block-tests.sh
git commit -m "feat(runners): distinguish a runner-blocked review from a review-blocked PR

Adds ai:runner-blocked and post-runner-block.sh. A toolchain failure now
comments and labels instead of aborting the job silently, and is filterable
apart from ai:review-blocked, which means the reviewer ran and refused.

Refs #302, #384"
```

---

### Task 3: Wire it into the workflow

**Files:**
- Modify: `.github/workflows/agent-implement.yml:1091-1109` (review job install step)
- Modify: `.github/workflows/agent-implement.yml:1424-1432` (self-fix job install step)
- Modify: `docs/RUNNER-REQUIREMENTS.md` (narrow the npm promise, retarget the `AGENT=claude` row)
- Modify: `CHANGELOG.md` (`[Unreleased]`)

**Interfaces:**
- Consumes: `scripts/install-claude-cli.sh` (Task 1) and `scripts/post-runner-block.sh` (Task 2), both invoked via the `.claude-pipeline/scripts/` mirror path the other steps already use.
- Produces: no new interface; this is the wiring that makes Tasks 1–2 live.

- [ ] **Step 1: Replace the review job's install step**

In `.github/workflows/agent-implement.yml`, replace the whole `- name: Install
Claude Code CLI` step in the `ai_review_human_merge` job (the one whose `if:`
mentions `self_mod_guard`) with:

```yaml
      - name: Install Claude Code CLI
        # review-pr.sh's default AGENT_CMD invokes `claude`; this job doesn't
        # use anthropics/claude-code-base-action (which installs the CLI in the
        # implement job), so we install it here directly — via the SAME native
        # installer, not npm. See scripts/install-claude-cli.sh for why npm was
        # the wrong shape on a persistent runner (#302) and on a runner with no
        # Node.js at all (#384).
        # Skipped under stub-review-verdict — the stub step below
        # synthesizes the verdict.
        id: install_cli
        if: |
          steps.self_mod_guard.outputs.blocked != 'true'
          && steps.find_pr.outputs.found == 'true'
          && inputs.stub-review-verdict == ''
        run: bash .claude-pipeline/scripts/install-claude-cli.sh

      - name: Mark issue runner-blocked
        # The "Mark issue blocked" step below inherits the default success(),
        # so before this existed an install failure aborted the job and posted
        # NOTHING on the issue — indistinguishable from a review that ran and
        # blocked (#384).
        if: failure() && steps.install_cli.outcome == 'failure'
        env:
          GH_TOKEN: ${{ github.token }}
          REPO: ${{ github.repository }}
          ISSUE_NUMBER: ${{ inputs.issue-number }}
          PR_NUMBER: ${{ steps.find_pr.outputs.pr-number }}
          EXIT_CODE: ${{ steps.install_cli.outputs.exit-code }}
          JOB_NAME: AI review, human merge
        run: bash .claude-pipeline/scripts/post-runner-block.sh
```

- [ ] **Step 2: Replace the self-fix job's install step**

Replace the `- name: Install Claude Code CLI` step in the `ai_review_ai_merge`
job (the one whose `if:` has no `self_mod_guard` clause) with:

```yaml
      - name: Install Claude Code CLI
        # Native installer, not npm — see the note on the same step in the
        # ai_review_human_merge job above (#302, #384).
        id: install_cli
        if: |
          steps.find_pr.outputs.found == 'true'
          && inputs.stub-review-verdict == ''
        run: bash .claude-pipeline/scripts/install-claude-cli.sh

      - name: Mark issue runner-blocked
        if: failure() && steps.install_cli.outcome == 'failure'
        env:
          GH_TOKEN: ${{ github.token }}
          REPO: ${{ github.repository }}
          ISSUE_NUMBER: ${{ inputs.issue-number }}
          PR_NUMBER: ${{ steps.find_pr.outputs.pr-number }}
          EXIT_CODE: ${{ steps.install_cli.outputs.exit-code }}
          JOB_NAME: AI review, AI merge
        run: bash .claude-pipeline/scripts/post-runner-block.sh
```

- [ ] **Step 3: Verify no npm survives on the claude path**

```bash
grep -n 'npm install' .github/workflows/agent-implement.yml
```

Expected: **no output**. The only remaining `npm install` in the repo should be
`ensure_opencode`'s, in `scripts/ensure-toolchain.sh` — which Task 4 files as a
follow-up and this plan deliberately does not touch.

```bash
grep -rn 'npm install' scripts/ | grep -v ensure-toolchain.sh
```

Expected: no output.

- [ ] **Step 4: Lint the workflow**

Run: `actionlint .github/workflows/agent-implement.yml`
Expected: no findings. `steps.install_cli.outputs.exit-code` is written by
`install-claude-cli.sh`'s `die()` helper (Task 1), so the failure-path step
receives the real code and `post-runner-block.sh` picks the specific reason
rather than its generic fallback.

- [ ] **Step 5: Update the runner-requirements doc**

Two edits in `docs/RUNNER-REQUIREMENTS.md`:

Replace the `AGENT=claude` table row with:

```markdown
| `claude` (Claude Code CLI) | Installed by `anthropics/claude-code-base-action` in the `implement` job, and by `scripts/install-claude-cli.sh` (native installer — requires `curl` + `sha256sum`) in the review and self-fix jobs |
```

Narrow the npm promise. Replace:

> If `npm` is not on the runner (rare on `ubuntu-latest`), the script fails with a clear error. Self-hosted runners that intend to support `AGENT=opencode` must include Node.js / npm.

with:

> If `npm` is not on the runner (rare on `ubuntu-latest`), `ensure-toolchain.sh` fails with a clear error naming the requirement. **This promise covers the `AGENT=opencode` path only** — it is the only path that still uses npm. The `AGENT=claude` path installs via `scripts/install-claude-cli.sh` and needs no Node.js at all; its own prerequisites (`curl`, `sha256sum`) are guarded the same way.

And annotate the Ansible package list entry:

```yaml
  - nodejs   # opencode only; the claude path no longer needs npm
```

- [ ] **Step 6: Add the changelog entry**

Under `## [Unreleased]` in `CHANGELOG.md`:

```markdown
### Changed

- **runners:** the review and self-fix jobs install the Claude Code CLI via the
  native installer (checksum-pinned) instead of `npm`, matching how the
  implement job's base action acquires it. Removes the last `npm` dependency
  from the `AGENT=claude` path, which failed with `EACCES` on a persistent
  runner with a root-owned global prefix (#302) and with a bare
  `npm: command not found` on a runner with no Node.js (#384).

### Added

- **runners:** `ai:runner-blocked` — the review never started because the
  runner's toolchain is unmet, as distinct from `ai:review-blocked`, where the
  reviewer ran and refused to promote the PR. Previously a toolchain failure
  aborted the job and posted nothing at all (#384).
```

- [ ] **Step 7: Run the full quality gate**

```bash
just lint
just test
```

Expected: `actionlint` and `shellcheck` clean; every Layer-1 runner green.

- [ ] **Step 8: Commit**

```bash
git add .github/workflows/agent-implement.yml docs/RUNNER-REQUIREMENTS.md CHANGELOG.md
git commit -m "fix(runners): drop npm from the AGENT=claude install path

The review and self-fix jobs now call install-claude-cli.sh instead of
npm install --prefix, so one dependency has one mechanism. Each install step
gains a failure-path sibling that stamps ai:runner-blocked, because the
existing 'Mark issue blocked' step inherits success() and posted nothing when
the install died.

Narrows RUNNER-REQUIREMENTS.md's clear-error promise to the opencode path,
which is now the only npm consumer.

Closes #302
Closes #384"
```

---

### Task 4: File the parked follow-up

**Files:**
- No repo files. This task produces a GitHub issue.

**Interfaces:**
- Consumes: the root-cause analysis in #302, which applies unchanged to the opencode path.
- Produces: an open issue, referenced by the spec's "Out of scope" section.

- [ ] **Step 1: Confirm the hazard is still present**

```bash
grep -n 'npm install -g' scripts/ensure-toolchain.sh
```

Expected: one hit, `npm install -g "opencode-ai@${OPENCODE_VERSION}"`. If it is
gone, someone fixed it meanwhile — skip this task and say so.

- [ ] **Step 2: Open the issue**

```bash
gh issue create \
  --title 'fix(runners): ensure_opencode still installs into the shared npm global prefix' \
  --label needs-enrichment \
  --body 'Split out of #302, which fixed the `AGENT=claude` path only.

`scripts/ensure-toolchain.sh` (`ensure_opencode`) still runs:

```bash
npm install -g "opencode-ai@${OPENCODE_VERSION}"
```

`npm install -g` resolves to `npm config get prefix` — `/usr/local` on a typical
runner — which on a **persistent** self-hosted runner is shared across every job
and every run. Once that prefix has been written as root, a later install as the
runner user cannot rename the existing package directory and dies with
`EACCES / syscall rename`. That is the exact failure #302 documented, and it is
deterministic rather than intermittent.

The claude path no longer installs into a shared prefix at all (it uses the
native installer via `scripts/install-claude-cli.sh`). The opencode path still
does, so a consumer running `AGENT=opencode` on a persistent runner remains
exposed.

## Acceptance Criteria

- [ ] `ensure_opencode` no longer writes to the shared npm global prefix
- [ ] `opencode` is still on PATH at the pinned `OPENCODE_VERSION` afterwards
- [ ] Existing `ensure-toolchain.sh` tests still pass, with a case covering the
      new install location
- [ ] `docs/RUNNER-REQUIREMENTS.md` reflects whatever the new mechanism requires

Parked deliberately during #302 to keep that PR to one concern.'
```

- [ ] **Step 3: Record the issue number in the spec**

In `docs/superpowers/specs/2026-09-22-claude-cli-install-unification-design.md`,
under **Out of scope**, replace `(D5 — follow-up issue)` with
`(D5 — follow-up: #<N>)` using the number just created.

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-09-22-claude-cli-install-unification-design.md
git commit -m "docs(specs): link the parked opencode follow-up from the #302 spec"
```

---

## Verification

Before opening the PR, confirm each acceptance criterion with a command, not an impression:

```bash
# No npm on the claude path
grep -rn 'npm install' .github/workflows/agent-implement.yml          # expect: no output
grep -rn 'npm install' scripts/ | grep -v ensure-toolchain.sh          # expect: no output

# Version pin matches the base action
grep -n 'CLAUDE_CLI_VERSION' scripts/install-claude-cli.sh             # expect: 2.1.270
grep -n 'installs CLI' .github/workflows/agent-implement.yml           # expect: 2.1.270

# The checksum pin is real
grep -c 'REPLACE_WITH_PINNED_SHA256' scripts/install-claude-cli.sh     # expect: 0

# Both labels exist and are distinct
grep -n 'ai:review-blocked\|ai:runner-blocked' scripts/ensure-issue-labels.sh

# Quality gate
just lint
just test
```
