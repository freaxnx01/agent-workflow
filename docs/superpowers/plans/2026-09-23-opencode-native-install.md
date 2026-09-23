# OpenCode Native Install Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Take opencode off the shared npm global prefix, removing the last `npm install -g` — and the last npm dependency — from the pipeline.

**Architecture:** The fetch-and-verify logic that `install-claude-cli.sh` already carries is extracted to a sourced helper in `scripts/lib/`, so the checksum comparison lives in one place. A new `install-opencode.sh` uses it and runs opencode's native installer pinned by `--version`, landing the binary in the per-user `$HOME/.opencode/bin` instead of a shared prefix. `ensure_opencode` keeps its gate, version check and dry-run seam and delegates only the install.

**Tech Stack:** Bash 5 (`set -euo pipefail`, `IFS=$'\n\t'`), `curl`, `sha256sum`, GitHub Actions, fixture-driven Layer-1 bash tests with PATH-shadowed tool sets, `shellcheck`.

**Spec:** `docs/superpowers/specs/2026-09-23-opencode-native-install-design.md`

## Global Constraints

- Every script starts with `#!/usr/bin/env bash`, then `set -euo pipefail`, then `IFS=$'\n\t'`. A **sourced** helper carries the shebang for editors but must not re-set `IFS` or `set -e` — it inherits the caller's.
- Quote every variable expansion. `[[ ... ]]` over `[ ... ]`. `$(...)` over backticks. No `eval`.
- `printf` over `echo` for anything formatted.
- Temp files via `mktemp`, cleaned up with `trap ... EXIT`.
- **Nothing fetched over the network is executed before its SHA-256 is verified.** A bare `curl | bash` is forbidden by this repo's CI stack overlay.
- **`fetch_verified_installer` returns its path on stdout. Every other message it prints goes to stderr** — otherwise the caller's `$(...)` captures the noise as part of the path.
- **The helper publishes `exit-code` to `$GITHUB_OUTPUT` before any non-zero exit**, exactly as `install-claude-cli.sh`'s `die()` does today. `post-runner-block.sh` reads `steps.install_cli.outputs.exit-code`; losing it silently regresses #302/#384.
- Pinned versions: `OPENCODE_VERSION=1.15.13`; opencode installer SHA-256 `fc3c1b2123f49b6df545a7622e5127d21cd794b15134fc3b66e1ca49f7fb297e` (captured 2026-09-23).
- Exit codes are the API: `0` ok, `64` prerequisite absent, `65` checksum mismatch, `66` installed but binary not found.
- Layer-1 tests are hermetic: no network, no GitHub, no Docker; whole suite under 5 seconds.
- Test runners are auto-discovered by `tests/run-all.sh` — a new runner needs **no** registration.
- Conventional Commits; scope `runners`.

---

### Task 1: The shared fetch-and-verify helper

**Files:**
- Create: `scripts/lib/fetch-verified-installer.sh`
- Create: `tests/run-fetch-verified-installer-tests.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: a sourced helper exposing two functions.
  - `publish_exit_code <code>` — appends `exit-code=<code>` to `$GITHUB_OUTPUT` when set.
  - `require_tool <name> <purpose>` — `command -v`; on absence prints `<name>`, `<purpose>` and `docs/RUNNER-REQUIREMENTS.md` to stderr, then exits `64`.
  - `fetch_verified_installer <url> <expected_sha256>` — echoes the path of the verified file on **stdout**; exits `65` on mismatch without executing anything. Progress to stderr. The caller owns the temp dir via `INSTALLER_WORKDIR`, which the helper sets and the caller traps.

- [ ] **Step 1: Write the failing test**

Create `tests/run-fetch-verified-installer-tests.sh`:

```bash
#!/usr/bin/env bash
#
# run-fetch-verified-installer-tests.sh — Layer-1 tests for
# scripts/lib/fetch-verified-installer.sh.
#
# Hermetic: the helper runs with a PATH built of symlinks to exactly the tools a
# case should see, so "curl is missing" is a real absence rather than a mock.
# The curl stand-in writes a payload and the REAL sha256sum hashes it, so the
# checksum path is exercised for true rather than stubbed.
#
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../scripts/lib/fetch-verified-installer.sh"

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

PAYLOAD='#!/usr/bin/env bash
printf "payload ran\n"
'

# Build a PATH dir with symlinks to exactly $@; "curl" becomes a stand-in that
# writes $PAYLOAD to the -o target.
make_bin() {
  local dir="$1"; shift
  mkdir -p "$dir"
  local t
  for t in "$@"; do
    if [[ "$t" == "curl" ]]; then
      cat > "$dir/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s' "$PAYLOAD" > "$out"
CURL
      chmod +x "$dir/curl"
    else
      ln -sf "$(command -v "$t")" "$dir/$t"
    fi
  done
}

# Drive the helper from a tiny caller script, because it is sourced.
CALLER='
. "$LIB"
require_tool curl "install the thing"
require_tool sha256sum "install the thing"
p="$(fetch_verified_installer "https://example.invalid/install" "$WANT_SHA")"
printf "PATH_RETURNED=%s\n" "$p"
printf "CONTENT=%s\n" "$(cat "$p")"
'

run_caller() {
  local bindir="$1"; shift
  env PATH="$bindir" LIB="$LIB" PAYLOAD="$PAYLOAD" "$@" bash -c "$CALLER" 2>&1
}

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
GOOD_SHA="$(printf '%s' "$PAYLOAD" | sha256sum | cut -d' ' -f1)"
TOOLS=(mktemp cut rm sha256sum chmod mkdir bash cat curl)

section "prerequisite guards"

bin_nocurl="$tmp/bin-nocurl"
make_bin "$bin_nocurl" mktemp cut rm sha256sum chmod mkdir bash cat
ec=0
gho="$tmp/gho1"; : > "$gho"
out="$(run_caller "$bin_nocurl" WANT_SHA="$GOOD_SHA" GITHUB_OUTPUT="$gho")" || ec=$?
assert_equals "$ec" "64"                             "curl absent → exit 64"
assert_contains "$out" "curl"                        "curl absent → names curl"
assert_contains "$out" "install the thing"           "curl absent → names the purpose"
assert_contains "$out" "docs/RUNNER-REQUIREMENTS.md" "curl absent → names the doc"
assert_contains "$(cat "$gho")" "exit-code=64"       "curl absent → publishes exit-code"

bin_nosum="$tmp/bin-nosum"
make_bin "$bin_nosum" mktemp cut rm chmod mkdir bash cat curl
ec=0
out="$(run_caller "$bin_nosum" WANT_SHA="$GOOD_SHA")" || ec=$?
assert_equals "$ec" "64"           "sha256sum absent → exit 64"
assert_contains "$out" "sha256sum" "sha256sum absent → names sha256sum"

section "checksum verification"

bin_ok="$tmp/bin-ok"
make_bin "$bin_ok" "${TOOLS[@]}"

ec=0
gho="$tmp/gho2"; : > "$gho"
out="$(run_caller "$bin_ok" WANT_SHA=0000000000000000000000000000000000000000000000000000000000000000 GITHUB_OUTPUT="$gho")" || ec=$?
assert_equals "$ec" "65"                        "mismatch → exit 65"
assert_contains "$out" "checksum"               "mismatch → says checksum"
assert_not_contains "$out" "PATH_RETURNED"      "mismatch → caller never receives a path"
assert_contains "$(cat "$gho")" "exit-code=65"  "mismatch → publishes exit-code"

section "happy path"

ec=0
out="$(run_caller "$bin_ok" WANT_SHA="$GOOD_SHA")" || ec=$?
assert_equals "$ec" "0"                     "match → exit 0"
assert_contains "$out" "PATH_RETURNED=/"    "match → a path is returned"
assert_contains "$out" "CONTENT=#!"         "match → the path holds the payload"

section "stdout discipline"

# The returned path must be the ONLY thing on stdout, or $(...) captures noise.
path_line="$(run_caller "$bin_ok" WANT_SHA="$GOOD_SHA" 2>/dev/null | grep '^PATH_RETURNED=')"
assert_not_contains "$path_line" " "        "returned path contains no progress text"
assert_not_contains "$path_line" "fetching" "progress went to stderr, not stdout"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'failed:\n'; printf '  - %s\n' "${FAIL_NAMES[@]}"
  exit 1
fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run-fetch-verified-installer-tests.sh`
Expected: FAIL — `scripts/lib/fetch-verified-installer.sh` does not exist.

- [ ] **Step 3: Write minimal implementation**

Create `scripts/lib/fetch-verified-installer.sh`:

```bash
#!/usr/bin/env bash
#
# fetch-verified-installer.sh — SOURCED helper. Fetch a third-party installer
# and verify its SHA-256 before anyone executes it.
#
# Extracted from install-claude-cli.sh (#302) when install-opencode.sh (#395)
# needed the same thing. The checksum comparison is the security-critical part
# of both; it should be fixable in one place.
#
# Sourced, not executed: `exit` here terminates the calling installer, which is
# intended — a failed fetch is terminal for both callers.
#
# Contract:
#   publish_exit_code <code>
#       Appends `exit-code=<code>` to $GITHUB_OUTPUT when set. The workflow's
#       failure-path step reads steps.install_cli.outputs.exit-code to pick a
#       reason in post-runner-block.sh; without it every failure gets the
#       generic wording (#302/#384).
#
#   require_tool <name> <purpose>
#       exits 64, naming the tool, the purpose and the doc.
#
#   fetch_verified_installer <url> <expected_sha256>
#       Echoes the verified file's path on STDOUT. Everything else it prints
#       goes to stderr — the caller reads the path with $(...), so a stray
#       stdout line would become part of the path.
#       Sets INSTALLER_WORKDIR and traps its own cleanup — the caller must
#       not, because on the exit-65 path the caller never runs again.
#       exits 65 on mismatch, without executing anything.
#
# No `set -euo pipefail` and no IFS here: a sourced file inherits the caller's,
# and re-setting them would silently change the caller's shell options.

FETCH_VERIFIED_INSTALLER_DOC='docs/RUNNER-REQUIREMENTS.md'

publish_exit_code() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf 'exit-code=%s\n' "$1" >> "$GITHUB_OUTPUT"
  fi
}

require_tool() {
  local tool="$1" purpose="${2:-run the pipeline}"
  command -v "$tool" >/dev/null 2>&1 && return 0
  printf 'error: required tool %q is not present on this runner.\n' "$tool" >&2
  printf '       It is needed to %s.\n' "$purpose" >&2
  printf '       Unmet runner requirement — see %s\n' \
    "$FETCH_VERIFIED_INSTALLER_DOC" >&2
  publish_exit_code 64
  exit 64
}

fetch_verified_installer() {
  local url="$1" expected="$2"

  INSTALLER_WORKDIR="$(mktemp -d)"
  # The helper owns the cleanup for the dir it created. Leaving it to the
  # caller leaks on the exit-65 path, because the caller never gets to set its
  # trap — fetch_verified_installer exits before returning.
  trap 'rm -rf "${INSTALLER_WORKDIR:-}"' EXIT
  local target="$INSTALLER_WORKDIR/installer.sh"

  printf 'fetching installer from %s\n' "$url" >&2
  curl -fsSL -o "$target" "$url"

  local actual
  actual="$(sha256sum "$target" | cut -d' ' -f1)"
  if [[ "$actual" != "$expected" ]]; then
    printf 'error: installer checksum mismatch — refusing to execute.\n' >&2
    printf '       expected %s\n' "$expected" >&2
    printf '       actual   %s\n' "$actual" >&2
    printf '       Either upstream changed the installer (bump the pin after\n' >&2
    printf '       reviewing the diff) or the download was tampered with.\n' >&2
    publish_exit_code 65
    exit 65
  fi

  printf '%s' "$target"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run-fetch-verified-installer-tests.sh`
Expected: PASS — all cases green.

- [ ] **Step 5: Lint**

Run: `shellcheck -x -e SC1091 scripts/lib/fetch-verified-installer.sh tests/run-fetch-verified-installer-tests.sh`
Expected: no findings.

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/fetch-verified-installer.sh tests/run-fetch-verified-installer-tests.sh
git commit -m "feat(runners): extract the verified-installer fetch to scripts/lib

Both the claude installer and the incoming opencode one need to fetch a
third-party script and verify its SHA-256 before executing it. That
comparison is the security-critical part of each; it belongs in one place.

Returns the path on stdout and sends progress to stderr, so the caller's
command substitution captures only the path.

Refs #395, #302"
```

---

### Task 2: Refactor the claude installer onto the helper

**Files:**
- Modify: `scripts/install-claude-cli.sh` (its `die`/`require_tool` definitions and its fetch/verify block)

**Interfaces:**
- Consumes: `publish_exit_code`, `require_tool`, `fetch_verified_installer` from Task 1.
- Produces: no interface change. Same env vars, same exit codes `0/64/65/66`, same messages.

**The regression guard is the point of this task.** `tests/run-install-claude-cli-tests.sh` has 19 cases and **must pass unmodified**. If a case fails, fix the refactor — do not touch the test.

- [ ] **Step 1: Confirm the guard is green before touching anything**

Run: `bash tests/run-install-claude-cli-tests.sh`
Expected: `19 passed, 0 failed`. This is the baseline.

- [ ] **Step 2: Source the helper and drop the local copies**

In `scripts/install-claude-cli.sh`, replace the `DOC=` line, the `die()` function and the `require_tool()` function with:

```bash
# shellcheck source=lib/fetch-verified-installer.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/fetch-verified-installer.sh"

# Kept as a thin alias: the exit paths below read as `die <code>`, and the
# helper owns publishing the step output.
die() {
  publish_exit_code "$1"
  exit "$1"
}
```

Then change the two guard calls to pass a purpose:

```bash
require_tool curl "install the Claude Code CLI for the review job"
require_tool sha256sum "install the Claude Code CLI for the review job"
```

- [ ] **Step 3: Replace the fetch and verify block**

Replace everything from `WORK="$(mktemp -d)"` down to **and including** the
original `printf 'installing Claude Code CLI …'` and
`bash "$WORK/install.sh" "$CLAUDE_CLI_VERSION"` lines — i.e. the whole fetch,
verify and execute run — with:

```bash
installer="$(fetch_verified_installer "$INSTALLER_URL" "$INSTALLER_SHA256")"

printf 'installing Claude Code CLI %s\n' "$CLAUDE_CLI_VERSION"
bash "$installer" "$CLAUDE_CLI_VERSION"
```

Then confirm no reference to `$WORK` survives:

```bash
grep -n 'WORK' scripts/install-claude-cli.sh   # expect: no output
```

- [ ] **Step 4: Run the guard — unmodified**

Run: `bash tests/run-install-claude-cli-tests.sh`
Expected: `19 passed, 0 failed`, identical to Step 1.

If the `exit-code=64` assertion fails, the helper's `publish_exit_code` is not
being reached — that is the #302/#384 regression the Global Constraints warn
about, and it is a bug in this task, not in the test.

- [ ] **Step 5: Lint**

Run: `shellcheck -x -e SC1091 scripts/install-claude-cli.sh`
Expected: no findings.

- [ ] **Step 6: Commit**

```bash
git add scripts/install-claude-cli.sh
git commit -m "refactor(runners): source the shared fetch-verified-installer

No behaviour change: same env vars, same exit codes, same messages. The 19
existing installer tests pass unmodified, which is the proof.

Refs #395"
```

---

### Task 3: The opencode installer

**Files:**
- Create: `scripts/install-opencode.sh`
- Create: `tests/run-install-opencode-tests.sh`

**Interfaces:**
- Consumes: `require_tool`, `fetch_verified_installer`, `publish_exit_code` (Task 1).
- Produces: `scripts/install-opencode.sh`. Optional env `OPENCODE_VERSION` (default `1.15.13`), `INSTALLER_URL`, `INSTALLER_SHA256`, `OPENCODE_BIN_CANDIDATES`, `DRY_RUN`, `GITHUB_PATH`, `GITHUB_OUTPUT`. Exit `0/64/65/66`. Task 4 calls it.

- [ ] **Step 1: Write the failing test**

Create `tests/run-install-opencode-tests.sh`:

```bash
#!/usr/bin/env bash
#
# run-install-opencode-tests.sh — Layer-1 tests for scripts/install-opencode.sh.
#
# Mirrors the claude installer's suite: a PATH built of symlinks to exactly the
# tools a case should see, a curl stand-in writing a payload, and the REAL
# sha256sum hashing it. No network.
#
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/install-opencode.sh"

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

# The payload records the args it was given, so the --version pin is provable,
# and creates the binary so the success path is observable.
# shellcheck disable=SC2016  # $FAKE_* stay literal: expanded when the payload runs.
INSTALLER_PAYLOAD='#!/usr/bin/env bash
set -euo pipefail
printf "%s\n" "$*" > "$FAKE_ARGS_FILE"
mkdir -p "$FAKE_INSTALL_BIN"
printf "#!/usr/bin/env bash\necho 1.15.13\n" > "$FAKE_INSTALL_BIN/opencode"
chmod +x "$FAKE_INSTALL_BIN/opencode"
'

make_bin() {
  local dir="$1"; shift
  mkdir -p "$dir"
  local t
  for t in "$@"; do
    if [[ "$t" == "curl" ]]; then
      cat > "$dir/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s' "$INSTALLER_PAYLOAD" > "$out"
CURL
      chmod +x "$dir/curl"
    else
      ln -sf "$(command -v "$t")" "$dir/$t"
    fi
  done
}

run_script() {
  local bindir="$1"; shift
  env -u OPENCODE_VERSION PATH="$bindir" INSTALLER_PAYLOAD="$INSTALLER_PAYLOAD" \
    "$@" bash "$SCRIPT" 2>&1
}

TOOLS=(mktemp cut rm sha256sum chmod mkdir bash dirname cat curl)
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
GOOD_SHA="$(printf '%s' "$INSTALLER_PAYLOAD" | sha256sum | cut -d' ' -f1)"

section "prerequisite guards"

bin_nocurl="$tmp/bin-nocurl"
make_bin "$bin_nocurl" mktemp cut rm sha256sum chmod mkdir bash dirname cat
ec=0
out="$(run_script "$bin_nocurl" HOME="$tmp/home")" || ec=$?
assert_equals "$ec" "64"                             "curl absent → exit 64"
assert_contains "$out" "curl"                        "curl absent → names curl"
assert_contains "$out" "opencode"                    "curl absent → names the purpose"
assert_contains "$out" "docs/RUNNER-REQUIREMENTS.md" "curl absent → names the doc"
assert_not_contains "$out" "command not found"       "curl absent → not a bare command-not-found"

section "checksum verification"

bin_ok="$tmp/bin-ok"
make_bin "$bin_ok" "${TOOLS[@]}"
marker="$tmp/should-not-exist"
ec=0
out="$(run_script "$bin_ok" HOME="$tmp/home" \
  FAKE_INSTALL_BIN="$marker" FAKE_ARGS_FILE="$tmp/args-bad" \
  INSTALLER_SHA256=0000000000000000000000000000000000000000000000000000000000000000)" || ec=$?
assert_equals "$ec" "65"          "checksum mismatch → exit 65"
assert_contains "$out" "checksum" "checksum mismatch → says checksum"
if [[ ! -e "$marker/opencode" ]]; then pass "checksum mismatch → installer not executed"
else fail "checksum mismatch → installer not executed" "marker was created"; fi

section "happy path"

gh_path="$tmp/github_path"; : > "$gh_path"
install_bin="$tmp/installed"
args_file="$tmp/args"
ec=0
out="$(run_script "$bin_ok" HOME="$tmp/home" \
  FAKE_INSTALL_BIN="$install_bin" FAKE_ARGS_FILE="$args_file" \
  INSTALLER_SHA256="$GOOD_SHA" \
  OPENCODE_BIN_CANDIDATES="$install_bin" \
  GITHUB_PATH="$gh_path")" || ec=$?
assert_equals "$ec" "0"                            "happy path → exit 0"
assert_contains "$(cat "$gh_path")" "$install_bin" "happy path → bin dir on GITHUB_PATH"
assert_contains "$(cat "$args_file")" "--version"  "happy path → installer pinned by --version"
assert_contains "$(cat "$args_file")" "1.15.13"    "happy path → pinned to OPENCODE_VERSION"

section "version override is honoured"

ec=0
run_script "$bin_ok" HOME="$tmp/home" \
  FAKE_INSTALL_BIN="$install_bin" FAKE_ARGS_FILE="$args_file" \
  INSTALLER_SHA256="$GOOD_SHA" OPENCODE_BIN_CANDIDATES="$install_bin" \
  OPENCODE_VERSION=9.9.9 >/dev/null || ec=$?
assert_contains "$(cat "$args_file")" "9.9.9" "OPENCODE_VERSION override reaches the installer"

section "installer ran but produced no binary"

ec=0
out="$(run_script "$bin_ok" HOME="$tmp/home" \
  FAKE_INSTALL_BIN="$tmp/elsewhere" FAKE_ARGS_FILE="$tmp/args2" \
  OPENCODE_BIN_CANDIDATES="$tmp/nowhere" \
  INSTALLER_SHA256="$GOOD_SHA")" || ec=$?
assert_equals "$ec" "66"                             "no binary → exit 66"
assert_contains "$out" "docs/RUNNER-REQUIREMENTS.md" "no binary → names the doc"

section "DRY_RUN"

ec=0
out="$(run_script "$bin_ok" HOME="$tmp/home" DRY_RUN=1)" || ec=$?
assert_equals "$ec" "0"               "DRY_RUN → exit 0"
assert_contains "$out" "DRY_RUN"      "DRY_RUN → says so"
assert_not_contains "$out" "fetching" "DRY_RUN → nothing fetched"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'failed:\n'; printf '  - %s\n' "${FAIL_NAMES[@]}"
  exit 1
fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run-install-opencode-tests.sh`
Expected: FAIL — `scripts/install-opencode.sh` does not exist.

- [ ] **Step 3: Write minimal implementation**

Create `scripts/install-opencode.sh`:

```bash
#!/usr/bin/env bash
#
# install-opencode.sh — Put the OpenCode CLI on PATH via its native installer.
#
# Replaces `npm install -g "opencode-ai@$OPENCODE_VERSION"` (#395). `npm
# install -g` resolves to the shared `npm config get prefix` (/usr/local on a
# typical runner), which on a PERSISTENT self-hosted runner is shared across
# every job and every run. Once that prefix has been written as root, a later
# install as the runner user cannot rename the package directory and dies with
# `EACCES / syscall rename`. #302 fixed exactly this for the Claude CLI; this
# is the same fix for the last path that still had it.
#
# The native installer lands the binary in $HOME/.opencode/bin — per-user and
# per-runner, never shared — which is the point.
#
# Optional environment variables:
#   OPENCODE_VERSION  Version to install. Default below; ensure-toolchain.sh
#                     owns the canonical pin and passes it down.
#   INSTALLER_URL     Where to fetch the installer. Default below.
#   INSTALLER_SHA256  Expected SHA-256 of the installer. Default below.
#   OPENCODE_BIN_CANDIDATES
#                     Colon-separated dirs to search for the installed binary,
#                     ahead of the defaults. Exists for tests.
#   DRY_RUN           "1" → run the prerequisite guards, then stop.
#   GITHUB_PATH       When set, the dir holding `opencode` is appended to it.
#   GITHUB_OUTPUT     When set, the exit code is published as `exit-code`.
#
# Exit codes:
#   0   opencode on PATH at OPENCODE_VERSION
#   64  a prerequisite is absent — names it and the doc
#   65  installer checksum mismatch — refuses to execute
#   66  installer ran but `opencode` is still not on PATH
set -euo pipefail
IFS=$'\n\t'

# shellcheck source=lib/fetch-verified-installer.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/fetch-verified-installer.sh"

# Canonical pin lives in scripts/ensure-toolchain.sh (OPENCODE_VERSION); this
# default exists only so the script can be run standalone.
OPENCODE_VERSION="${OPENCODE_VERSION:-1.15.13}"
INSTALLER_URL="${INSTALLER_URL:-https://opencode.ai/install}"

# SHA-256 of the installer as fetched on 2026-09-23. Refreshing this is a
# deliberate commit, reviewed like any other dependency bump.
INSTALLER_SHA256="${INSTALLER_SHA256:-fc3c1b2123f49b6df545a7622e5127d21cd794b15134fc3b66e1ca49f7fb297e}"

PURPOSE='install the OpenCode CLI for an AGENT=opencode run'

require_tool curl "$PURPOSE"
require_tool sha256sum "$PURPOSE"

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  printf 'prerequisites present; install skipped (DRY_RUN)\n'
  exit 0
fi

installer="$(fetch_verified_installer "$INSTALLER_URL" "$INSTALLER_SHA256")"

printf 'installing OpenCode CLI %s\n' "$OPENCODE_VERSION"
bash "$installer" --version "$OPENCODE_VERSION"

# The native installer targets $HOME/.opencode/bin; the candidates list keeps
# this from being a single hardcoded guess.
CANDIDATES="${OPENCODE_BIN_CANDIDATES:-}"
CANDIDATES="${CANDIDATES:+$CANDIDATES:}$HOME/.opencode/bin:$HOME/.local/bin"

opencode_dir=''
IFS=':' read -ra cand_dirs <<< "$CANDIDATES"
for d in "${cand_dirs[@]}"; do
  if [[ -n "$d" && -x "$d/opencode" ]]; then
    opencode_dir="$d"
    break
  fi
done

if [[ -z "$opencode_dir" ]] && command -v opencode >/dev/null 2>&1; then
  opencode_dir="$(dirname "$(command -v opencode)")"
fi

if [[ -z "$opencode_dir" ]]; then
  printf 'error: installer completed but no opencode binary was found.\n' >&2
  printf '       Searched: %s\n' "$CANDIDATES" >&2
  printf '       Unmet runner requirement — see docs/RUNNER-REQUIREMENTS.md\n' >&2
  publish_exit_code 66
  exit 66
fi

if [[ -n "${GITHUB_PATH:-}" ]]; then
  printf '%s\n' "$opencode_dir" >> "$GITHUB_PATH"
fi

PATH="$opencode_dir:$PATH"
export PATH
printf 'opencode installed at %s (version: %s)\n' \
  "$opencode_dir/opencode" "$("$opencode_dir/opencode" --version 2>/dev/null || printf 'unknown')"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run-install-opencode-tests.sh`
Expected: PASS — all cases green, sub-second.

- [ ] **Step 5: Lint**

Run: `shellcheck -x -e SC1091 scripts/install-opencode.sh tests/run-install-opencode-tests.sh`
Expected: no findings.

- [ ] **Step 6: Commit**

```bash
git add scripts/install-opencode.sh tests/run-install-opencode-tests.sh
git commit -m "feat(runners): install opencode via its native installer

Checksum-pinned, version-pinned with --version, landing the binary in the
per-user \$HOME/.opencode/bin instead of the shared npm global prefix.

Refs #395"
```

---

### Task 4: Delegate from ensure_opencode, and drop npm from the contract

**Files:**
- Modify: `scripts/ensure-toolchain.sh` (add `HERE`; replace the npm block in `ensure_opencode`; update the header comment)
- Modify: `docs/RUNNER-REQUIREMENTS.md`
- Modify: `tests/run-script-tests.sh` (add the no-npm guard)
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: `scripts/install-opencode.sh` (Task 3).
- Produces: no new interface. `ensure_opencode`'s contract — `opencode` on PATH at `OPENCODE_VERSION` — is unchanged.

- [ ] **Step 1: Write the failing test**

Append to `tests/run-script-tests.sh`, immediately before its final summary block:

```bash
section "no npm anywhere in the pipeline (#395)"

# #302 took the claude path off npm; #395 takes opencode off it. Nothing in
# scripts/ should shell out to npm any more, in any shape. The guard is
# inverted on purpose: it stops npm coming BACK, rather than asserting that
# some particular mitigation is still in place.
assert_equals "$(grep -rl 'npm install' "$ROOT/scripts" 2>/dev/null | wc -l | tr -d ' ')" "0" \
  "no script installs anything with npm"

# The canonical pin stays in exactly one place and is passed down.
assert_equals "$(grep -c '^OPENCODE_VERSION=' "$ROOT/scripts/ensure-toolchain.sh" || true)" "1" \
  "OPENCODE_VERSION is declared exactly once"

assert_contains "$(cat "$ROOT/scripts/ensure-toolchain.sh")" 'install-opencode.sh' \
  "ensure_opencode delegates to the native installer"

# The runner contract no longer demands Node.js.
assert_not_contains "$(cat "$ROOT/docs/RUNNER-REQUIREMENTS.md")" 'nodejs' \
  "RUNNER-REQUIREMENTS no longer requires nodejs"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run-script-tests.sh`
Expected: FAIL — `npm install` is still in `ensure-toolchain.sh` and `nodejs` still in the doc.

- [ ] **Step 3: Add `HERE` to ensure-toolchain.sh**

`ensure-toolchain.sh` has no `HERE` today. Add it directly below the
`IFS=$'\n\t'` line:

```bash
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
```

- [ ] **Step 4: Delegate the install**

In `ensure_opencode`, replace this block:

```bash
  # Install via npm — pinned by exact version. The maintainer can swap
  # to a curl-installer with vendored checksum if upstream changes its
  # distribution; the contract (binary `opencode` on PATH, returning
  # OPENCODE_VERSION from `--version`) is what downstream code relies on.
  if command -v npm >/dev/null 2>&1; then
    npm install -g "opencode-ai@${OPENCODE_VERSION}"
  else
    printf 'error: npm not available; cannot install opencode\n' >&2
    return 1
  fi
```

with:

```bash
  # Native installer, checksum-pinned — not `npm install -g`, which resolves to
  # the shared global prefix and dies with EACCES on a persistent runner whose
  # prefix was ever written as root (#395, the same hazard #302 fixed for the
  # claude path). The contract downstream relies on is unchanged: binary
  # `opencode` on PATH, returning OPENCODE_VERSION from `--version`.
  OPENCODE_VERSION="$OPENCODE_VERSION" bash "$HERE/install-opencode.sh"
```

Also update the script's header comment, which still says the OpenCode install
is npm-based — replace the `OPENCODE_DRY_RUN` description's mention of "the
actual network/npm step" with "the actual network/install step".

- [ ] **Step 5: Drop npm from the runner contract**

Three edits in `docs/RUNNER-REQUIREMENTS.md`:

Replace the `AGENT=opencode` source cell so it no longer names npm:

```markdown
| `opencode` | **1.15.13** | native installer (`scripts/install-opencode.sh`, checksum-pinned) |
```

Delete the npm-missing paragraph entirely. It currently reads (after #302
narrowed it) that `ensure-toolchain.sh` fails with a clear error when npm is
absent, and that the promise covers the opencode path only. That path no longer
uses npm, so the paragraph now describes nothing. Replace it with:

```markdown
Both agents install via a checksum-pinned native installer, so **no pipeline
path requires Node.js or npm**. Their shared prerequisites are `curl` and
`sha256sum`, listed under *Always required* above.
```

Remove the `nodejs` line from the Ansible package list:

```yaml
github_actions_runner_packages:
  - ripgrep
  - jq
  - gh
```

- [ ] **Step 6: Run the tests**

Run: `bash tests/run-script-tests.sh`
Expected: PASS, including the four new assertions.

Then the whole suite: `bash tests/run-all.sh`
Expected: every runner green. The `ensure-toolchain` dry-run cases at
`tests/run-script-tests.sh:2922-2954` must still pass — `OPENCODE_DRY_RUN=1`
still short-circuits before the installer is called, so they should be
unaffected. If one fails, the dry-run seam was moved by mistake.

- [ ] **Step 7: Add the changelog entry**

Under `## [Unreleased]` in `CHANGELOG.md`, in the **existing** `### Changed`
subsection (do not add a second one — `[Unreleased]` already has `Added`,
`Changed`, `Deprecated`, `Removed` and `Fixed`, and a duplicate heading trips
markdownlint MD024):

```markdown
- **runners:** opencode installs via its native installer (checksum-pinned)
  instead of `npm install -g`, which resolved to the shared global prefix and
  died with `EACCES` on a persistent runner whose prefix was ever written as
  root (#395 — the same hazard #302 fixed for the claude path). With this, no
  pipeline path uses npm: `nodejs` is no longer a runner requirement.
```

- [ ] **Step 8: Lint**

```bash
mapfile -t f < <(find scripts tests -type f -name '*.sh' | sort)
shellcheck -x -e SC1091 "${f[@]}"
pre-commit run --all-files
```

Expected: both clean. Run `pre-commit` locally rather than discovering
`markdownlint`/`typos` findings in CI.

- [ ] **Step 9: Commit**

```bash
git add scripts/ensure-toolchain.sh docs/RUNNER-REQUIREMENTS.md tests/run-script-tests.sh CHANGELOG.md
git commit -m "fix(runners): take opencode off the shared npm global prefix

ensure_opencode delegates to install-opencode.sh, keeping its AGENT gate,
version check and dry-run seam. With the last npm consumer gone, no pipeline
path needs Node.js, so RUNNER-REQUIREMENTS drops it and deletes the
npm-missing promise rather than narrowing it a second time.

Closes #395"
```

---

## Verification

Confirm each acceptance criterion with a command, not an impression:

```bash
# No npm anywhere under scripts/
grep -rn 'npm install' scripts/            # expect: no output

# One shared fetch-and-verify implementation, used by both installers
grep -l 'fetch_verified_installer' scripts/install-claude-cli.sh scripts/install-opencode.sh

# The claude guard passed unmodified — this is the refactor's proof
git diff --stat origin/main -- tests/run-install-claude-cli-tests.sh   # expect: no output
bash tests/run-install-claude-cli-tests.sh                             # expect: 19 passed

# Pins are real, not placeholders
grep -n 'INSTALLER_SHA256' scripts/install-opencode.sh
grep -n '^OPENCODE_VERSION=' scripts/ensure-toolchain.sh               # expect: exactly one

# Node.js is gone from the contract
grep -n 'nodejs\|npm' docs/RUNNER-REQUIREMENTS.md                      # expect: no output

# Full gate
bash tests/run-all.sh
pre-commit run --all-files
```
