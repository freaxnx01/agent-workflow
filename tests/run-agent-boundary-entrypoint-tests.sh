#!/usr/bin/env bash
#
# run-agent-boundary-entrypoint-tests.sh — Layer-1 tests for the three boundary
# entry points of docker/azp-agent/boundary/ (#591, Task 1).
#
# In the image these run as `awf-agent` through one sudoers rule. Here they run
# directly, as the test user, with AWF_WS_ROOT pointed at a temp dir and
# AWF_AGENT_CLAUDE at a stub that dumps its environment — so the credential
# stripping, the workspace confinement and the git round trip are all checked
# without sudo, without Docker and without a second Linux user.
#
# `awf-agent-reap` kills every process of its own uid. Running that as the
# developer would kill their session, so the kill test only runs inside a
# throwaway user+pid namespace (`unshare --user --pid --fork --mount-proc`) and
# is skipped, loudly, when that is unavailable.
#
# Usage: tests/run-agent-boundary-entrypoint-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BOUNDARY="$ROOT/docker/azp-agent/boundary"

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
skip() { printf '  %s–%s %s (skipped: %s)\n' "$C_DIM" "$C_OFF" "$1" "$2"; }
fail() {
  FAIL=$((FAIL + 1)); FAIL_NAMES+=("$1")
  printf '  %s✗%s %s\n' "$C_RED" "$C_OFF" "$1"
  [ $# -gt 1 ] && printf '      %s\n' "$2"
  return 0
}
assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then pass "$name"; else
    fail "$name" "expected: $expected | actual: $actual"; fi
}
assert_contains() {
  local name="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then pass "$name"; else
    fail "$name" "missing: $needle"; fi
}
assert_not_contains() {
  local name="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then pass "$name"; else
    fail "$name" "unexpected: $needle"; fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

WS_ROOT="$TMP/ws"
mkdir -p "$WS_ROOT"

# A stand-in for the Claude CLI that reports what environment survived. Its log
# path is derived from $0, not from the environment: the entry point rebuilds
# the environment from the allowlist, so a stub that needed a variable of its
# own could never run.
CLAUDE_STUB="$TMP/claude-stub"
cat > "$CLAUDE_STUB" <<'STUB'
#!/usr/bin/env bash
printf 'argv=%s\n' "$*"
printf 'cwd=%s\n' "$PWD"
env
printf 'called\n' >> "$0.log"
STUB
chmod +x "$CLAUDE_STUB"
CLAUDE_LOG="$CLAUDE_STUB.log"
: > "$CLAUDE_LOG"

# entry <name> [args...] — runs one entry point with a polluted environment;
# sets RC and OUT (stdout + stderr).
RC=0; OUT=''
entry() {
  local name="$1"; shift
  RC=0
  OUT="$(env AWF_WS_ROOT="$WS_ROOT" AWF_AGENT_CLAUDE="$CLAUDE_STUB" \
    CLAUDE_STUB_LOG="$CLAUDE_LOG" \
    AZURE_DEVOPS_EXT_PAT=leak-pat SYSTEM_ACCESSTOKEN=leak-token \
    MODEL=claude-sonnet-5 MAX_TURNS=11 CLAUDE_CODE_OAUTH_TOKEN=tok-abc \
    "$BOUNDARY/$name" "$@" 2>&1)" || RC=$?
}

# git_in <dir> <args...> — plain git with the test identity, for fixtures.
git_in() {
  local dir="$1"; shift
  git -C "$dir" -c user.name=t -c user.email=t@example.invalid "$@"
}

section "protocol"

entry awf-agent-run --protocol
assert_eq "run_Protocol_PrintsOne: rc" "0" "$RC"
assert_eq "run_Protocol_PrintsOne: output" "1" "$OUT"

entry awf-agent-git --protocol
assert_eq "git_Protocol_PrintsOne: rc" "0" "$RC"
assert_eq "git_Protocol_PrintsOne: output" "1" "$OUT"

entry awf-agent-reap --protocol
assert_eq "reap_Protocol_PrintsOne: rc" "0" "$RC"
assert_eq "reap_Protocol_PrintsOne: output" "1" "$OUT"

section "awf-agent-run"

mkdir -p "$WS_ROOT/w1"
entry awf-agent-run "$WS_ROOT/w1" -- --print --max-turns 11
assert_eq "run_StripsCredentials: rc" "0" "$RC"
assert_contains "run_StripsCredentials: passes the args through" "argv=--print --max-turns 11" "$OUT"
assert_contains "run_StripsCredentials: runs in the workspace" "cwd=$WS_ROOT/w1" "$OUT"
assert_contains "run_StripsCredentials: keeps MODEL" "MODEL=claude-sonnet-5" "$OUT"
assert_contains "run_StripsCredentials: keeps MAX_TURNS" "MAX_TURNS=11" "$OUT"
assert_contains "run_StripsCredentials: keeps the Claude token" "CLAUDE_CODE_OAUTH_TOKEN=tok-abc" "$OUT"
assert_not_contains "run_StripsCredentials: no Azure DevOps credential" "leak-pat" "$OUT"
assert_not_contains "run_StripsCredentials: no job token" "leak-token" "$OUT"
assert_not_contains "run_StripsCredentials: no PAT variable name" "AZURE_DEVOPS_EXT_PAT" "$OUT"
assert_contains "run_StripsCredentials: own home" "HOME=/home/awf-agent" "$OUT"

: > "$CLAUDE_LOG"
mkdir -p "$TMP/elsewhere"
entry awf-agent-run "$TMP/elsewhere" -- --print
assert_eq "run_WorkspaceOutsideRoot_Exit2: absolute path outside the root" "2" "$RC"
entry awf-agent-run "$WS_ROOT/../elsewhere" -- --print
assert_eq "run_WorkspaceOutsideRoot_Exit2: traversal out of the root" "2" "$RC"
mkdir -p "$WS_ROOT/deep/deeper"
entry awf-agent-run "$WS_ROOT/deep/deeper" -- --print
assert_eq "run_WorkspaceOutsideRoot_Exit2: not a direct child" "2" "$RC"
assert_eq "run_WorkspaceOutsideRoot_Exit2: the agent never ran" "" "$(cat "$CLAUDE_LOG")"

entry awf-agent-run "$WS_ROOT/w1" --print
assert_eq "run_MissingSeparator_Exit2" "2" "$RC"
entry awf-agent-run
assert_eq "run_NoArgs_Exit2" "2" "$RC"

section "awf-agent-git"

# A two-commit source repo; the bundle carries its FIRST commit, as the driver's
# seed bundle carries the attempt's base.
SRC="$TMP/src"
mkdir -p "$SRC"
git init -q -b main "$SRC"
printf 'one\n' > "$SRC/a.txt"
git_in "$SRC" add a.txt
git_in "$SRC" commit -q -m first
FIRST_SHA="$(git -C "$SRC" rev-parse HEAD)"
printf 'two\n' > "$SRC/b.txt"
git_in "$SRC" add b.txt
git_in "$SRC" commit -q -m second
git_in "$SRC" branch seedbase "$FIRST_SHA"
SEED_BUNDLE="$TMP/seed.bundle"
git -C "$SRC" bundle create -q "$SEED_BUNDLE" seedbase

entry awf-agent-git "$WS_ROOT/rt" seed "$SEED_BUNDLE" seedbase
assert_eq "git_SeedCommitBundle_RoundTrip: seed rc" "0" "$RC"
assert_eq "git_SeedCommitBundle_RoundTrip: seeded at the base commit" "$FIRST_SHA" \
  "$(git -C "$WS_ROOT/rt" rev-parse HEAD 2>/dev/null || true)"
assert_eq "git_SeedCommitBundle_RoundTrip: detached" "" \
  "$(git -C "$WS_ROOT/rt" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
assert_eq "git_SeedCommitBundle_RoundTrip: no later commit came along" "no" \
  "$([[ -e "$WS_ROOT/rt/b.txt" ]] && echo yes || echo no)"
assert_eq "git_SeedCommitBundle_RoundTrip: commit identity set" "ai-implement" \
  "$(git -C "$WS_ROOT/rt" config user.name 2>/dev/null || true)"

entry awf-agent-git "$WS_ROOT/rt" seed "$SEED_BUNDLE" seedbase
assert_eq "git_SeedExistingWorkspace_Exit2" "2" "$RC"

printf 'agent work\n' > "$WS_ROOT/rt/NEW.md"
entry awf-agent-git "$WS_ROOT/rt" commit "agent commit"
assert_eq "git_SeedCommitBundle_RoundTrip: commit rc" "0" "$RC"
assert_eq "git_SeedCommitBundle_RoundTrip: committed as ai-implement" "ai-implement" \
  "$(git -C "$WS_ROOT/rt" log -1 --format=%an)"

OUT_BUNDLE="$TMP/out.bundle"
RC=0
env AWF_WS_ROOT="$WS_ROOT" "$BOUNDARY/awf-agent-git" "$WS_ROOT/rt" bundle "$FIRST_SHA" \
  > "$OUT_BUNDLE" 2>/dev/null || RC=$?
assert_eq "git_SeedCommitBundle_RoundTrip: bundle rc" "0" "$RC"
# The bundle is thin: it carries base..HEAD, so it only verifies where the base
# commit already is — which is exactly the driver's own checkout.
VERIFY="$TMP/verify"
git clone -q "$SRC" "$VERIFY"
assert_eq "git_SeedCommitBundle_RoundTrip: bundle verifies" "0" \
  "$(rc=0; git -C "$VERIFY" bundle verify "$OUT_BUNDLE" >/dev/null 2>&1 || rc=$?; printf '%s' "$rc")"
assert_eq "git_SeedCommitBundle_RoundTrip: one head" "1" \
  "$(git -C "$VERIFY" bundle list-heads "$OUT_BUNDLE" | grep -c . || true)"

# The agent owns its workspace, hooks and all: nothing it leaves there may run
# when the boundary touches that repo.
entry awf-agent-git "$WS_ROOT/hooks" seed "$SEED_BUNDLE" seedbase
MARKER="$TMP/hook-ran"
mkdir -p "$WS_ROOT/hooks/.git/hooks"
printf '#!/usr/bin/env bash\ntouch %q\n' "$MARKER" > "$WS_ROOT/hooks/.git/hooks/pre-commit"
chmod +x "$WS_ROOT/hooks/.git/hooks/pre-commit"
printf 'x\n' > "$WS_ROOT/hooks/HOOKED.md"
entry awf-agent-git "$WS_ROOT/hooks" commit "with a hook in place"
assert_eq "git_HooksIgnored: commit rc" "0" "$RC"
assert_eq "git_HooksIgnored: hook did not run" "no" \
  "$([[ -e "$MARKER" ]] && echo yes || echo no)"

entry awf-agent-git "$WS_ROOT/clean" seed "$SEED_BUNDLE" seedbase
entry awf-agent-git "$WS_ROOT/clean" commit "nothing to do"
assert_eq "git_CommitClean_Exit3" "3" "$RC"

entry awf-agent-git "$WS_ROOT/clean" bundle "$FIRST_SHA"
assert_eq "git_BundleNoNewCommits_Exit3" "3" "$RC"

entry awf-agent-git "$TMP/elsewhere" commit "x"
assert_eq "git_WorkspaceOutsideRoot_Exit2" "2" "$RC"
entry awf-agent-git "$WS_ROOT/clean" frobnicate
assert_eq "git_UnknownSubcommand_Exit2" "2" "$RC"

section "awf-agent-reap"

# The reap ends every process of the caller's uid, so the only safe place to
# prove it is a throwaway user+pid namespace of our own. `exec` makes the reap
# pid 1 in that namespace: it outlives everything it kills, so its count is
# written before the namespace is torn down.
if unshare --user --pid --fork --mount-proc true 2>/dev/null; then
  : > "$TMP/reap.out"
  # shellcheck disable=SC2016  # $1/$2 are for the inner bash, not this one
  unshare --user --pid --fork --mount-proc bash -c '
    sleep 300 &
    exec env AWF_REAP_TEST=1 "$1" > "$2" 2>/dev/null' _ "$BOUNDARY/awf-agent-reap" "$TMP/reap.out" \
    >/dev/null 2>&1 || true
  assert_eq "reap_KillsBackgroundProcess: nothing of the agent's uid survives" "0" \
    "$(cat "$TMP/reap.out")"
else
  skip "reap_KillsBackgroundProcess" "unshare --user --pid is unavailable here"
fi

entry awf-agent-reap --unknown-flag
assert_eq "reap_UnknownArg_Exit2" "2" "$RC"
entry awf-agent-reap
assert_eq "reap_RefusesOutsideTheBoundaryUser" "2" "$RC"
assert_contains "reap_RefusesOutsideTheBoundaryUser: says why" "refusing to run as" "$OUT"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then printf 'Failed: %s\n' "${FAIL_NAMES[*]}"; exit 1; fi
