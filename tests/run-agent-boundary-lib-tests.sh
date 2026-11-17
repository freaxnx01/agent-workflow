#!/usr/bin/env bash
#
# run-agent-boundary-lib-tests.sh — Layer-1 tests for scripts/lib/agent-boundary.sh
# (#591, Task 3), the driver side of the agent user boundary.
#
# The real entry points of docker/azp-agent/boundary/ run through tests/mocks/sudo,
# which reduces the environment the way the sudoers drop-in does. Nothing here
# needs a second Linux user: the boundary's contract is the three fixed commands
# and the data that crosses back, and both are observable as this user.
#
# Usage: tests/run-agent-boundary-lib-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
#
# shellcheck disable=SC2016  # every case body is deliberately single-quoted:
# its $vars are bound in the inner bash by the VAR=value pairs that follow it.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MOCKS="$ROOT/tests/mocks"
LIB="$ROOT/scripts/lib/agent-boundary.sh"
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
    fail "$name" "missing: $needle | in: $haystack"; fi
}
assert_not_contains() {
  local name="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then pass "$name"; else
    fail "$name" "unexpected: $needle"; fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

CASE_N=0
RC=0; OUT=''; ERR=''

# lib <bash-body> [VAR=value ...] — runs <bash-body> with the library sourced,
# in its own process; sets RC, OUT and ERR. No `set -e`: the library's functions
# report failure by exit status and each case checks it.
lib() {
  local body="$1"; shift
  CASE_N=$((CASE_N + 1))
  local script="$TMP/case-$CASE_N.sh"
  {
    printf '#!/usr/bin/env bash\nset -uo pipefail\nIFS=$'"'"'\\n\\t'"'"'\n'
    printf 'source %q\n' "$LIB"
    printf '%s\n' "$body"
  } > "$script"
  RC=0
  OUT="$(env PATH="$MOCKS:$PATH" HOME="$TMP" \
    AWF_BOUNDARY_DIR="${BOUNDARY_DIR_OVERRIDE:-$BOUNDARY}" \
    AWF_WS_ROOT="$WS_ROOT" SUDO_LOG="$SUDO_LOG" "$@" \
    bash "$script" 2>"$TMP/err-$CASE_N")" || RC=$?
  ERR="$(cat "$TMP/err-$CASE_N")"
}

# new_driver_checkout <name> — a repo standing in for the consumer checkout the
# driver owns: one commit on main, plus origin/main pointing at it.
new_driver_checkout() {
  local dir="$TMP/$1"
  mkdir -p "$dir"
  git init -q -b main "$dir"
  printf 'base\n' > "$dir/BASE.md"
  git -C "$dir" add BASE.md
  git -C "$dir" -c user.name=t -c user.email=t@example.invalid commit -q -m base
  git -C "$dir" update-ref refs/remotes/origin/main main
  printf '%s' "$dir"
}

# stub_boundary <name> <entry> <body> — a boundary dir whose <entry> is replaced
# by <body>; the other two entry points answer --protocol with 1.
stub_boundary() {
  local dir="$TMP/boundary-$1" entry="$2" body="$3" name
  mkdir -p "$dir"
  for name in awf-agent-run awf-agent-git awf-agent-reap; do
    if [[ "$name" == "$entry" ]]; then
      printf '#!/usr/bin/env bash\n%s\n' "$body" > "$dir/$name"
    else
      printf '#!/usr/bin/env bash\n[[ "${1:-}" != --protocol ]] || { printf "1\\n"; exit 0; }\nexit 0\n' > "$dir/$name"
    fi
    chmod +x "$dir/$name"
  done
  printf '%s' "$dir"
}

WS_ROOT="$TMP/ws"
mkdir -p "$WS_ROOT"
SUDO_LOG="$TMP/sudo.log"
: > "$SUDO_LOG"

section "boundary_check"

lib 'boundary_check'
assert_eq "check_AllProtocolsOne_Succeeds: rc" "0" "$RC"
assert_eq "check_AllProtocolsOne_Succeeds: one call per entry point" "3" \
  "$(grep -c 'awf-agent' "$SUDO_LOG" || true)"
assert_contains "check_AllProtocolsOne_Succeeds: as awf-agent, non-interactive" \
  "-n -u awf-agent" "$(cat "$SUDO_LOG")"

lib 'boundary_check' SUDO_MOCK_DENY=1
assert_eq "check_SudoDenied_FailsNamingSudo: rc" "1" "$RC"
assert_contains "check_SudoDenied_FailsNamingSudo: names sudo" "sudo" "$ERR"

BOUNDARY_DIR_OVERRIDE="$(stub_boundary wrongproto awf-agent-git \
  '[[ "${1:-}" != --protocol ]] || { printf "2\n"; exit 0; }')"
lib 'boundary_check'
assert_eq "check_WrongProtocol_Fails: rc" "1" "$RC"
assert_contains "check_WrongProtocol_Fails: names the version" "protocol" "$ERR"
BOUNDARY_DIR_OVERRIDE=''

BOUNDARY_DIR_OVERRIDE="$(stub_boundary missing awf-agent-reap 'exit 127')"
lib 'boundary_check'
assert_eq "check_EntryPointMissing_Fails: rc" "1" "$RC"
BOUNDARY_DIR_OVERRIDE=''

section "workspaces"

lib 'boundary_new_workspace; boundary_new_workspace' AWF_RUN_ID=run9
assert_eq "new_workspace_IsAFreshChildOfTheRoot" "$WS_ROOT/run9-1
$WS_ROOT/run9-2" "$OUT"
assert_eq "new_workspace_CreatesNothing" "" "$(ls -A "$WS_ROOT")"

section "seed, commit, collect"

DRIVER="$(new_driver_checkout driver)"
BASE_SHA="$(git -C "$DRIVER" rev-parse HEAD)"
lib '
cd "$DRIVER"
ws="$(boundary_new_workspace)" || exit 10
boundary_seed "$ws" "$HANDOFF" origin/main || exit 11
printf "agent work\n" > "$ws/AGENT.md"
git -C "$ws" checkout -q -b ai/591-boundary || exit 12
boundary_commit "$ws" "agent commit" || exit 13
branch="$(boundary_collect "$ws" "$BASE_SHA" "$HANDOFF")" || exit 14
printf "branch=%s\n" "$branch"
printf "collected=%s\n" "$(git -C "$DRIVER" rev-parse --verify refs/awf/collected)"
printf "tree=%s\n" "$(git -C "$DRIVER" ls-tree -r --name-only refs/awf/collected | tr "\n" " ")"
' AWF_RUN_ID=rt DRIVER="$DRIVER" HANDOFF="$TMP/handoff" BASE_SHA="$BASE_SHA"
assert_eq "seed_collect_RoundTrip: rc" "0" "$RC"
assert_contains "seed_collect_RoundTrip: prints the agent's branch" "branch=ai/591-boundary" "$OUT"
assert_contains "seed_collect_RoundTrip: the commit landed in refs/awf/collected" "tree=AGENT.md BASE.md" "$OUT"
assert_eq "seed_collect_RoundTrip: the seed bundle is world-readable" "644" \
  "$(stat -c '%a' "$TMP/handoff/seed.bundle")"
assert_eq "seed_collect_RoundTrip: the handoff dir is traversable, not listable" "711" \
  "$(stat -c '%a' "$TMP/handoff")"
assert_eq "seed_collect_RoundTrip: the driver's checkout stays on main" "main" \
  "$(git -C "$DRIVER" symbolic-ref --short HEAD)"

# A detached agent workspace carries HEAD, not a branch: the driver names it.
lib '
cd "$DRIVER"
ws="$(boundary_new_workspace)" || exit 10
boundary_seed "$ws" "$HANDOFF" origin/main || exit 11
printf "detached work\n" > "$ws/D.md"
boundary_commit "$ws" "agent commit" || exit 13
branch="$(boundary_collect "$ws" "$BASE_SHA" "$HANDOFF")" || exit 14
printf "branch=[%s]\n" "$branch"
' AWF_RUN_ID=det DRIVER="$DRIVER" HANDOFF="$TMP/handoff-det" BASE_SHA="$BASE_SHA"
assert_eq "collect_DetachedHead_PrintsNoBranch: rc" "0" "$RC"
assert_contains "collect_DetachedHead_PrintsNoBranch: empty branch" "branch=[]" "$OUT"

# Nothing committed is not invalid evidence: it is the "committed nothing" path.
lib '
cd "$DRIVER"
ws="$(boundary_new_workspace)" || exit 10
boundary_seed "$ws" "$HANDOFF" origin/main || exit 11
boundary_commit "$ws" "nothing"; printf "commit_rc=%s\n" "$?"
boundary_collect "$ws" "$BASE_SHA" "$HANDOFF" >/dev/null; printf "collect_rc=%s\n" "$?"
' AWF_RUN_ID=empty DRIVER="$DRIVER" HANDOFF="$TMP/handoff-empty" BASE_SHA="$BASE_SHA"
assert_contains "commit_NothingToCommit_Returns3" "commit_rc=3" "$OUT"
assert_contains "collect_NoNewCommits_Returns3" "collect_rc=3" "$OUT"

# Commits that do not descend from the attempt's base are refused.
lib '
cd "$DRIVER"
ws="$(boundary_new_workspace)" || exit 10
boundary_seed "$ws" "$HANDOFF" origin/main || exit 11
git -C "$ws" checkout -q --orphan ai/orphan
git -C "$ws" rm -rq --cached . 2>/dev/null || true
rm -f "$ws/BASE.md"
printf "elsewhere\n" > "$ws/OTHER.md"
boundary_commit "$ws" "unrelated root" || exit 13
boundary_collect "$ws" "$BASE_SHA" "$HANDOFF" >/dev/null; printf "collect_rc=%s\n" "$?"
' AWF_RUN_ID=wrongbase DRIVER="$DRIVER" HANDOFF="$TMP/handoff-wrongbase" BASE_SHA="$BASE_SHA"
assert_contains "collect_WrongBase_Fails: rc" "collect_rc=1" "$OUT"
assert_contains "collect_WrongBase_Fails: says why" "descend" "$ERR"

# The workspace is the agent's: its hooks and its fsmonitor must never run.
MARKER_DIR="$TMP/markers"
mkdir -p "$MARKER_DIR"
lib '
cd "$DRIVER"
ws="$(boundary_new_workspace)" || exit 10
boundary_seed "$ws" "$HANDOFF" origin/main || exit 11
printf "hooked\n" > "$ws/H.md"
git -C "$ws" checkout -q -b ai/hooked
# Armed last, so only the boundary itself could have tripped them.
git -C "$ws" config core.fsmonitor "touch $MARKERS/fsmonitor"
mkdir -p "$ws/.git/hooks"
printf "#!/usr/bin/env bash\ntouch %s/hook\n" "$MARKERS" > "$ws/.git/hooks/pre-commit"
chmod +x "$ws/.git/hooks/pre-commit"
rm -f "$MARKERS"/*
boundary_commit "$ws" "hooked commit" || exit 13
boundary_collect "$ws" "$BASE_SHA" "$HANDOFF" >/dev/null || exit 14
' AWF_RUN_ID=hooks DRIVER="$DRIVER" HANDOFF="$TMP/handoff-hooks" BASE_SHA="$BASE_SHA" \
  MARKERS="$MARKER_DIR"
assert_eq "collect_HookInAgentRepo_NotRun: rc" "0" "$RC"
assert_eq "collect_HookInAgentRepo_NotRun: no hook or fsmonitor marker" "" "$(ls -A "$MARKER_DIR")"

section "hostile input"

HOSTILE_NAMES=('--upload-pack=x' '../x' 'a b' '-dashed' '' 'a/../../b' '~x' 'a..b' 'he@{ad}')
for name in "${HOSTILE_NAMES[@]}"; do
  lib 'valid_branch_name "$NAME"; printf "rc=%s\n" "$?"' NAME="$name"
  assert_contains "valid_branch_name_RejectsHostileNames: ${name:-(empty)}" "rc=1" "$OUT"
done
lib 'valid_branch_name "$NAME"; printf "rc=%s\n" "$?"' NAME="$(printf 'a%.0s' {1..101})"
assert_contains "valid_branch_name_RejectsHostileNames: 101 chars" "rc=1" "$OUT"
for name in 'ai/591-boundary' 'feature/x_1.2' 'main'; do
  lib 'valid_branch_name "$NAME"; printf "rc=%s\n" "$?"' NAME="$name"
  assert_contains "valid_branch_name_Accepts: $name" "rc=0" "$OUT"
done

head -c 65537 /dev/zero | tr '\0' 'a' > "$TMP/over.json"
head -c 65536 /dev/zero | tr '\0' 'a' > "$TMP/exact.json"
lib 'cap_file_bytes "$OVER" 65536; printf "over=%s\n" "$?"
cap_file_bytes "$EXACT" 65536; printf "exact=%s\n" "$?"
cap_file_bytes "$TMP/absent.json" 65536; printf "absent=%s\n" "$?"' \
  OVER="$TMP/over.json" EXACT="$TMP/exact.json" TMP="$TMP"
assert_contains "cap_file_bytes_Over_Fails" "over=1" "$OUT"
assert_contains "cap_file_bytes_AtTheCap_Passes" "exact=0" "$OUT"
assert_contains "cap_file_bytes_Missing_Fails" "absent=1" "$OUT"

section "checkout credentials"

CLEAN="$(new_driver_checkout clean-checkout)"
git -C "$CLEAN" remote add origin https://example.invalid/org/project/_git/repo
lib 'cd "$REPO_DIR"; checkout_has_credentials; printf "rc=%s\n" "$?"' REPO_DIR="$CLEAN"
assert_contains "checkout_has_credentials_CleanRepoIsFalse" "rc=1" "$OUT"

git -C "$CLEAN" config http.https://example.invalid/.extraheader 'Authorization: Basic c2VjcmV0'
lib 'cd "$REPO_DIR"; checkout_has_credentials; printf "rc=%s\n" "$?"' REPO_DIR="$CLEAN"
assert_contains "checkout_has_credentials_DetectsExtraheader" "rc=0" "$OUT"
git -C "$CLEAN" config --unset http.https://example.invalid/.extraheader

git -C "$CLEAN" remote set-url origin https://user:pw@example.invalid/org/project/_git/repo
lib 'cd "$REPO_DIR"; checkout_has_credentials; printf "rc=%s\n" "$?"' REPO_DIR="$CLEAN"
assert_contains "checkout_has_credentials_DetectsCredentialUrl" "rc=0" "$OUT"

section "azdo_git keeps the token out of argv"

GITSTUB="$TMP/gitstub"
mkdir -p "$GITSTUB"
cat > "$GITSTUB/git" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GIT_STUB_ARGV"
env | grep -E '^GIT_CONFIG_' >> "$GIT_STUB_ENV" || true
exit 0
STUB
chmod +x "$GITSTUB/git"
: > "$TMP/git-argv.log"; : > "$TMP/git-env.log"
lib 'PATH="$GITSTUB:$PATH" azdo_git ls-remote --heads origin refs/heads/x; printf "rc=%s\n" "$?"' \
  GITSTUB="$GITSTUB" GIT_STUB_ARGV="$TMP/git-argv.log" GIT_STUB_ENV="$TMP/git-env.log" \
  AZURE_DEVOPS_EXT_PAT='tok-SECRET-9f3a'
assert_contains "azdo_git_TokenNotInArgv: the call ran" "rc=0" "$OUT"
assert_contains "azdo_git_TokenNotInArgv: argv is the plain git call" "ls-remote --heads origin refs/heads/x" \
  "$(cat "$TMP/git-argv.log")"
assert_not_contains "azdo_git_TokenNotInArgv: no token in argv" "tok-SECRET-9f3a" "$(cat "$TMP/git-argv.log")"
assert_not_contains "azdo_git_TokenNotInArgv: no -c in argv" "-c http.extraheader" "$(cat "$TMP/git-argv.log")"
assert_contains "azdo_git_TokenNotInArgv: the header travels in the environment" "GIT_CONFIG_KEY_0=http.extraheader" \
  "$(cat "$TMP/git-env.log")"
assert_contains "azdo_git_TokenNotInArgv: the header carries the token" \
  "$(printf ':%s' 'tok-SECRET-9f3a' | base64 -w0)" "$(cat "$TMP/git-env.log")"

section "exec and reap"

STUB_CLAUDE="$TMP/claude-env-dump"
cat > "$STUB_CLAUDE" <<'STUB'
#!/usr/bin/env bash
printf 'argv=%s\n' "$*"
printf 'cwd=%s\n' "$PWD"
env
STUB
chmod +x "$STUB_CLAUDE"
mkdir -p "$WS_ROOT/execws"
lib 'boundary_exec_claude "$AWF_WS_ROOT/execws" --print --max-turns 7 < /dev/null' \
  AWF_AGENT_CLAUDE="$STUB_CLAUDE" AZURE_DEVOPS_EXT_PAT=leak-pat SYSTEM_ACCESSTOKEN=leak-token \
  MODEL=claude-sonnet-5
assert_eq "exec_claude_RunsInTheWorkspace: rc" "0" "$RC"
assert_contains "exec_claude_RunsInTheWorkspace: args" "argv=--print --max-turns 7" "$OUT"
assert_contains "exec_claude_RunsInTheWorkspace: cwd" "cwd=$WS_ROOT/execws" "$OUT"
assert_contains "exec_claude_RunsInTheWorkspace: model survives" "MODEL=claude-sonnet-5" "$OUT"
assert_not_contains "exec_claude_RunsInTheWorkspace: no Azure DevOps credential" "leak-pat" "$OUT"
assert_not_contains "exec_claude_RunsInTheWorkspace: no job token" "leak-token" "$OUT"

BOUNDARY_DIR_OVERRIDE="$(stub_boundary survivor awf-agent-reap \
  '[[ "${1:-}" != --protocol ]] || { printf "1\n"; exit 0; }
printf "2\n"; exit 1')"
lib 'boundary_reap; printf "rc=%s\n" "$?"'
assert_contains "reap_SurvivorRemains_ReturnsFailure: rc" "rc=1" "$OUT"
assert_contains "reap_SurvivorRemains_ReturnsFailure: says what survived" "survived" "$ERR"
BOUNDARY_DIR_OVERRIDE=''

lib 'boundary_reap; printf "rc=%s\n" "$?"' \
  BOUNDARY_DIR_OVERRIDE_UNUSED=1 SUDO_MOCK_DENY=1
assert_contains "reap_SudoDenied_ReturnsFailure" "rc=1" "$OUT"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then printf 'Failed: %s\n' "${FAIL_NAMES[*]}"; exit 1; fi
