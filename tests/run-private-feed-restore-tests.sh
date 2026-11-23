#!/usr/bin/env bash
#
# run-private-feed-restore-tests.sh — Layer-1 tests for
# scripts/lib/private-feed-restore.sh (#641), the driver's credentialed
# pre-restore of a private Azure Artifacts feed.
#
# `dotnet` is tests/mocks/dotnet, so there is no SDK, no feed and no network.
# What the cases assert is the part that has to be right: the token reaches the
# temporary config and nothing else, the config is private and outside both the
# agent's reach and the package cache, the restore runs on the seed commit's own
# worktree, and nothing is left behind on either exit path.
#
# Usage: tests/run-private-feed-restore-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
#
# shellcheck disable=SC2016  # every case body is deliberately single-quoted:
# its $vars are bound in the inner bash by the VAR=value pairs that follow it.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MOCKS="$ROOT/tests/mocks"
LIB="$ROOT/scripts/lib/private-feed-restore.sh"
BOUNDARY_LIB="$ROOT/scripts/lib/agent-boundary.sh"

ADO_FEED='https://pkgs.dev.azure.com/org/_packaging/f/nuget/v3/index.json'
VS_FEED='https://org.pkgs.visualstudio.com/_packaging/f/nuget/v3/index.json'

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

# A PATH with a shell but no `dotnet`, for the "not on the image" case: this
# runner has a real dotnet, so dropping tests/mocks is not enough.
mkdir -p "$TMP/no-dotnet"
ln -s "$(command -v bash)" "$TMP/no-dotnet/bash"

# make_repo <name> [file...] — a repo with an origin/main carrying <file>s. A
# <file> may name a subdirectory, which is created.
make_repo() {
  local dir="$TMP/$1" file; shift
  mkdir -p "$dir"
  git init -q -b main "$dir"
  printf 'base\n' > "$dir/README.md"
  for file in "$@"; do
    mkdir -p "$(dirname "$dir/$file")"
    printf '<Solution/>\n' > "$dir/$file"
  done
  git -C "$dir" add -A
  git -C "$dir" -c user.name=t -c user.email=t@example.invalid commit -q -m base
  git -C "$dir" update-ref refs/remotes/origin/main main
  printf '%s' "$dir"
}

REPO_SLN="$(make_repo repo-sln a.sln b.slnx)"
REPO_PLAIN="$(make_repo repo-plain)"
# A root with a project but no solution: `dotnet restore` with no argument
# restored it before #682, so the default must still find it.
REPO_PROJ="$(make_repo repo-proj App.csproj)"
# A root with no solution of its own: the solution is in a subdirectory, next to
# a committed symlink, which stands in for an entry pointing out of the tree.
# `linkdir` is the same trick one component earlier: a path through it is not in
# the commit either, though `-f` follows it and `-L` never looks at it.
REPO_SUB="$(make_repo repo-sub samples/dotnet/Sample.sln)"
ln -s Sample.sln "$REPO_SUB/samples/dotnet/Link.sln"
ln -s samples/dotnet "$REPO_SUB/linkdir"
git -C "$REPO_SUB" add -A
git -C "$REPO_SUB" -c user.name=t -c user.email=t@example.invalid commit -q -m link
git -C "$REPO_SUB" update-ref refs/remotes/origin/main main

CASE_N=0
RC=0; OUT=''; ERR=''

# pfr <bash-body> [VAR=value ...] — runs <bash-body> with both libraries sourced,
# in its own process, with CWD $CWD and tests/mocks first on PATH; sets RC, OUT
# and ERR. No `set -e`: each function reports failure by exit status.
CWD=''
pfr() {
  local body="$1"; shift
  CASE_N=$((CASE_N + 1))
  local script="$TMP/case-$CASE_N.sh"
  {
    printf '#!/usr/bin/env bash\nset -uo pipefail\nIFS=$'"'"'\\n\\t'"'"'\n'
    printf 'source %q\n' "$BOUNDARY_LIB"
    printf 'source %q\n' "$LIB"
    printf '%s\n' "$body"
  } > "$script"
  RC=0
  OUT="$(cd "$CWD" && env PATH="${PATH_OVERRIDE:-$MOCKS:$PATH}" HOME="$TMP" \
    AWF_NUGET_CACHE="$CACHE" "$@" bash "$script" 2>"$TMP/err-$CASE_N")" || RC=$?
  ERR="$(cat "$TMP/err-$CASE_N")"
}

CACHE="$TMP/cache"
mkdir -p "$CACHE"
PATH_OVERRIDE=''
CWD="$REPO_SLN"

section "feed_restore_enabled"

pfr 'feed_restore_enabled; printf "rc=%s\n" "$?"' AWF_NUGET_FEEDS=''
assert_contains "feed_restore_enabled_EmptyIsOff" "rc=1" "$OUT"

pfr 'feed_restore_enabled; printf "rc=%s\n" "$?"' AWF_NUGET_FEEDS='   '
assert_contains "feed_restore_enabled_BlankIsOff" "rc=1" "$OUT"

pfr 'feed_restore_enabled; printf "rc=%s\n" "$?"' AWF_NUGET_FEEDS="$ADO_FEED"
assert_contains "feed_restore_enabled_SetIsOn" "rc=0" "$OUT"

section "feed_restore_config_check"

pfr 'feed_restore_config_check' \
  AWF_NUGET_FEEDS='https://evil.example/_packaging/f/nuget/v3/index.json'
assert_eq "feed_restore_config_check_RejectsForeignHost: rc" "1" "$RC"
assert_contains "feed_restore_config_check_RejectsForeignHost: names the URL" \
  "https://evil.example/_packaging/f/nuget/v3/index.json" "$ERR"

pfr 'feed_restore_config_check' AWF_NUGET_FEEDS="$ADO_FEED $VS_FEED"
assert_eq "feed_restore_config_check_AcceptsBothAdoForms: rc" "0" "$RC"

PATH_OVERRIDE="$TMP/no-dotnet"
pfr 'feed_restore_config_check' AWF_NUGET_FEEDS="$ADO_FEED"
PATH_OVERRIDE=''
assert_eq "feed_restore_config_check_NoDotnet: rc" "1" "$RC"
assert_contains "feed_restore_config_check_NoDotnet: names the image target" \
  "--target dotnet" "$ERR"

section "feed_write_config"

pfr 'feed_write_config "$CFG" && stat -c %a "$CFG"' \
  CFG="$TMP/token.config" AWF_NUGET_FEEDS="$ADO_FEED $VS_FEED" \
  AZURE_DEVOPS_EXT_PAT='a&b<c'
CONFIG_TEXT="$(cat "$TMP/token.config" 2>/dev/null || true)"
assert_eq "feed_write_config_EscapesToken: rc" "0" "$RC"
assert_eq "feed_write_config_EscapesToken: mode" "600" "$OUT"
assert_contains "feed_write_config_EscapesToken: the token is XML-escaped" \
  'a&amp;b&lt;c' "$CONFIG_TEXT"
assert_not_contains "feed_write_config_EscapesToken: the raw token is not in the file" \
  'a&b<c' "$CONFIG_TEXT"
assert_contains "feed_write_config_EscapesToken: clears the inherited sources" \
  '<clear' "$CONFIG_TEXT"
assert_contains "feed_write_config_EscapesToken: nuget.org stays a source" \
  'key="nuget.org"' "$CONFIG_TEXT"
assert_contains "feed_write_config_EscapesToken: first feed" 'key="feed1"' "$CONFIG_TEXT"
assert_contains "feed_write_config_EscapesToken: second feed" 'key="feed2"' "$CONFIG_TEXT"
assert_contains "feed_write_config_EscapesToken: credentials for the first feed" \
  '<feed1>' "$CONFIG_TEXT"
assert_contains "feed_write_config_EscapesToken: credentials for the second feed" \
  '<feed2>' "$CONFIG_TEXT"
assert_contains "feed_write_config_EscapesToken: the username NuGet wants" \
  'value="ai-implement"' "$CONFIG_TEXT"
XML_RC=0
python3 -c 'import sys,xml.etree.ElementTree as e; e.parse(sys.argv[1])' \
  "$TMP/token.config" >/dev/null 2>&1 || XML_RC=$?
assert_eq "feed_write_config_EscapesToken: the file is well-formed XML" "0" "$XML_RC"

section "feed_restore_targets_syntax_check (#682)"

pfr 'feed_restore_targets_syntax_check' AWF_NUGET_RESTORE='/abs.sln'
assert_eq "syntax_RejectsAbsolute: rc" "1" "$RC"
assert_contains "syntax_RejectsAbsolute: names the entry" \
  "AWF_NUGET_RESTORE entry '/abs.sln' is not a relative solution or project path" "$ERR"

pfr 'feed_restore_targets_syntax_check' AWF_NUGET_RESTORE='a/../b.sln'
assert_eq "syntax_RejectsDotDot: rc" "1" "$RC"

pfr 'feed_restore_targets_syntax_check' AWF_NUGET_RESTORE='a.txt'
assert_eq "syntax_RejectsBadExt: rc" "1" "$RC"

pfr 'feed_restore_targets_syntax_check' AWF_NUGET_RESTORE='a b.sln'
assert_eq "syntax_RejectsBadChar: rc" "1" "$RC"

# A leading dash in any component would reach `dotnet restore` in argv as an
# option rather than a path.
pfr 'feed_restore_targets_syntax_check' AWF_NUGET_RESTORE='-foo.csproj'
assert_eq "syntax_RejectsLeadingDash: rc" "1" "$RC"

pfr 'feed_restore_targets_syntax_check' AWF_NUGET_RESTORE='sub/-p.sln'
assert_eq "syntax_RejectsDashComponent: rc" "1" "$RC"

pfr 'feed_restore_targets_syntax_check' AWF_NUGET_RESTORE='a-b/c-d.sln'
assert_eq "syntax_AcceptsInnerDash: rc" "0" "$RC"

pfr 'feed_restore_targets_syntax_check' AWF_NUGET_RESTORE='a.sln sub/b.csproj c/d.fsproj'
assert_eq "syntax_AcceptsList: rc" "0" "$RC"

# A multi-line value is easy to produce in the Azure DevOps variables UI; every
# line must be seen, not silently dropped after the first.
pfr 'feed_restore_targets_syntax_check' AWF_NUGET_RESTORE='a.sln
bad.txt'
assert_eq "syntax_ChecksEveryLine: rc" "1" "$RC"
assert_contains "syntax_ChecksEveryLine: names the second line's entry" \
  "entry 'bad.txt'" "$ERR"

pfr 'feed_restore_targets_syntax_check' AWF_NUGET_RESTORE='   '
assert_eq "syntax_BlankIsUnset: rc" "0" "$RC"

section "feed_restore_targets (#682)"

NO_TARGET_MSG='no solution or project at the repository root; set AWF_NUGET_RESTORE to the solution or project to restore'
# One line per case: the return code, then the resolved targets comma-joined.
TARGETS_BODY='rc=0
feed_restore_targets "$WT" || rc=$?
printf "rc=%s targets=%s\n" "$rc" "$(IFS=,; printf "%s" "${FEED_TARGETS[*]}")"'

pfr "$TARGETS_BODY" WT="$REPO_SLN"
assert_contains "targets_DefaultRootSolutions" "rc=0 targets=a.sln,b.slnx" "$OUT"

pfr "$TARGETS_BODY" WT="$REPO_SLN" AWF_NUGET_RESTORE='  '
assert_contains "targets_BlankIsUnset" "rc=0 targets=a.sln,b.slnx" "$OUT"

# The root holds a project and no solution: the no-argument `dotnet restore` of
# before #682 handled that root, so the default must keep handling it.
pfr "$TARGETS_BODY" WT="$REPO_PROJ"
assert_contains "targets_DefaultRootProject" "rc=0 targets=App.csproj" "$OUT"

pfr "$TARGETS_BODY" WT="$REPO_SUB" AWF_NUGET_RESTORE='samples/dotnet/Sample.sln'
assert_contains "targets_Explicit" "rc=0 targets=samples/dotnet/Sample.sln" "$OUT"

pfr "$TARGETS_BODY" WT="$REPO_SUB"
assert_contains "targets_NoRootSolution: rc" "rc=2 targets=" "$OUT"
assert_eq "targets_NoRootSolution: says what to set" "$NO_TARGET_MSG" "$ERR"

pfr "$TARGETS_BODY" WT="$REPO_SUB" \
  AWF_NUGET_RESTORE='samples/dotnet/Sample.sln x/Missing.sln'
assert_contains "targets_MissingEntry: rc" "rc=2" "$OUT"
assert_eq "targets_MissingEntry: names the entry" \
  "AWF_NUGET_RESTORE entry 'x/Missing.sln' is not in the seed commit" "$ERR"

pfr "$TARGETS_BODY" WT="$REPO_SUB" AWF_NUGET_RESTORE='samples/dotnet/Link.sln'
assert_contains "targets_SymlinkEntry: rc" "rc=2" "$OUT"
assert_contains "targets_SymlinkEntry: names the entry" "samples/dotnet/Link.sln" "$ERR"

# The symlink one component earlier: the file at the end of the path is real and
# not a symlink, so only the commit's own file list rules it out.
pfr "$TARGETS_BODY" WT="$REPO_SUB" AWF_NUGET_RESTORE='linkdir/Sample.sln'
assert_contains "targets_SymlinkDirEntry: rc" "rc=2" "$OUT"
assert_contains "targets_SymlinkDirEntry: names the entry" "linkdir/Sample.sln" "$ERR"

# A multi-line value: the entry after the newline is resolved, not dropped.
pfr "$TARGETS_BODY" WT="$REPO_SUB" AWF_NUGET_RESTORE='samples/dotnet/Sample.sln
x/Missing.sln'
assert_contains "targets_EveryLine: rc" "rc=2" "$OUT"
assert_eq "targets_EveryLine: names the second line's entry" \
  "AWF_NUGET_RESTORE entry 'x/Missing.sln' is not in the seed commit" "$ERR"

section "feed_pre_restore — the successful run"

# One restore of a root holding both a .sln and a .slnx, with a stale package
# (dotfile included) left in the cache by an earlier job.
SECRET='s3cr3t-feed-token'
WD1="$TMP/wd1"; mkdir -p "$WD1"
mkdir -p "$CACHE/old"; : > "$CACHE/old/.hidden"
DLOG="$TMP/dotnet.log"; : > "$DLOG"
MLOG="$TMP/mode.log"; : > "$MLOG"
CFG_COPY="$TMP/config-copy.xml"

pfr 'feed_pre_restore origin/main "$WD"' \
  WD="$WD1" AWF_NUGET_FEEDS="$ADO_FEED" AZURE_DEVOPS_EXT_PAT="$SECRET" \
  DOTNET_LOG="$DLOG" DOTNET_MODE_LOG="$MLOG" DOTNET_CONFIG_COPY="$CFG_COPY"
assert_eq "feed_pre_restore_Succeeds: rc" "0" "$RC"

DLOG_TEXT="$(cat "$DLOG")"
assert_not_contains "feed_pre_restore_TokenNotInArgv" "$SECRET" "$DLOG_TEXT"
assert_contains "feed_pre_restore_TokenReachesTheConfig" "$SECRET" \
  "$(cat "$CFG_COPY" 2>/dev/null || true)"
# Every restore call logged one line; all of them must be private, so the
# distinct lines are exactly one.
assert_eq "feed_pre_restore_ConfigPrivate" "file=600 dir=700" "$(sort -u "$MLOG")"

CFG_PATH="$(grep -o -- '--configfile [^ ]*' <<<"$DLOG_TEXT" | head -n1 | cut -d' ' -f2)"
CFG_OK=0
[[ "$CFG_PATH" == "$WD1"/* ]] || CFG_OK=1
[[ "$CFG_PATH" != "$CACHE"/* ]] || CFG_OK=1
assert_eq "feed_pre_restore_ConfigOutsideCacheAndWorkspace" "0" "$CFG_OK"

RESTORE_PWD="$(grep '^pwd=' <<<"$DLOG_TEXT" | head -n1 | cut -d= -f2-)"
assert_eq "feed_pre_restore_RunsOnSeedWorktree: under the work dir" "0" \
  "$([[ "$RESTORE_PWD" == "$WD1"/* ]] && echo 0 || echo 1)"
assert_eq "feed_pre_restore_RunsOnSeedWorktree: HEAD is the seed commit" \
  "$(git -C "$REPO_SLN" rev-parse origin/main)" \
  "$(grep '^head=' <<<"$DLOG_TEXT" | head -n1 | cut -d= -f2-)"

assert_eq "feed_pre_restore_RestoresEachSolution: two calls" "2" \
  "$(grep -c '^argv=' <<<"$DLOG_TEXT" || true)"
assert_contains "feed_pre_restore_RestoresEachSolution: a.sln" "argv=restore a.sln " "$DLOG_TEXT"
assert_contains "feed_pre_restore_RestoresEachSolution: b.slnx" "argv=restore b.slnx " "$DLOG_TEXT"

# No build server or MSBuild worker node may outlive the credentialed call.
assert_eq "feed_pre_restore_NoBuildServers: every call disables build servers" "2" \
  "$(grep -c '^argv=.* --disable-build-servers' <<<"$DLOG_TEXT" || true)"
assert_eq "feed_pre_restore_NoBuildServers: every call disables node reuse" "2" \
  "$(grep -c '^nodereuse=1$' <<<"$DLOG_TEXT" || true)"

assert_eq "feed_pre_restore_EmptiesStaleCache" "" \
  "$(find "$CACHE" -name '.hidden' -o -name 'old' | head -n1)"

assert_eq "feed_pre_restore_CacheWorldReadable: files are 0644" "" \
  "$(find "$CACHE" -type f ! -perm 0644 | head -n1)"
assert_eq "feed_pre_restore_CacheWorldReadable: directories are 0755" "" \
  "$(find "$CACHE" -mindepth 1 -type d ! -perm 0755 | head -n1)"
assert_contains "feed_pre_restore_CacheWorldReadable: the package is there" \
  "testpkg.1.0.0.nupkg" "$(find "$CACHE" -type f -printf '%f\n')"

assert_eq "feed_pre_restore_CleansUpOnSuccess: nothing left under the work dir" "" \
  "$(find "$WD1" -mindepth 1 | head -n1)"
assert_eq "feed_pre_restore_CleansUpOnSuccess: no worktree left" "1" \
  "$(git -C "$REPO_SLN" worktree list | grep -c . || true)"

section "feed_pre_restore — a root with no solution file (#682)"

# A root holding a project but no solution: restored by name, as the
# no-argument `dotnet restore` of before #682 did, not refused.
CWD="$REPO_PROJ"
WD2A="$TMP/wd2a"; mkdir -p "$WD2A"
DLOG2A="$TMP/dotnet2a.log"; : > "$DLOG2A"
pfr 'feed_pre_restore origin/main "$WD"' \
  WD="$WD2A" AWF_NUGET_FEEDS="$ADO_FEED" AZURE_DEVOPS_EXT_PAT="$SECRET" \
  DOTNET_LOG="$DLOG2A"
assert_eq "pre_restore_RootProject_Restores: rc" "0" "$RC"
assert_contains "pre_restore_RootProject_Restores: the root project" \
  "argv=restore App.csproj " "$(cat "$DLOG2A")"

# `dotnet restore` with no argument stops with MSB1003 in a root that holds
# neither, so the run is refused with rc 2 before any dotnet call, not with a
# restore failure.
CWD="$REPO_PLAIN"
WD2="$TMP/wd2"; mkdir -p "$WD2"
DLOG2="$TMP/dotnet2.log"; : > "$DLOG2"
pfr 'feed_pre_restore origin/main "$WD"' \
  WD="$WD2" AWF_NUGET_FEEDS="$ADO_FEED" AZURE_DEVOPS_EXT_PAT="$SECRET" \
  DOTNET_LOG="$DLOG2"
assert_eq "pre_restore_NoTarget_Rc2_NoDotnet_CleansUp: rc" "2" "$RC"
assert_contains "pre_restore_NoTarget_Rc2_NoDotnet_CleansUp: says what to set" \
  "$NO_TARGET_MSG" "$ERR"
assert_eq "pre_restore_NoTarget_Rc2_NoDotnet_CleansUp: no restore ran" "" "$(cat "$DLOG2")"
assert_eq "pre_restore_NoTarget_Rc2_NoDotnet_CleansUp: nothing left under the work dir" "" \
  "$(find "$WD2" -mindepth 1 | head -n1)"
assert_eq "pre_restore_NoTarget_Rc2_NoDotnet_CleansUp: no worktree left" "1" \
  "$(git -C "$REPO_PLAIN" worktree list | grep -c . || true)"

# The named target is what reaches `dotnet restore`, as a relative path.
CWD="$REPO_SUB"
WD2B="$TMP/wd2b"; mkdir -p "$WD2B"
DLOG2B="$TMP/dotnet2b.log"; : > "$DLOG2B"
pfr 'feed_pre_restore origin/main "$WD"' \
  WD="$WD2B" AWF_NUGET_FEEDS="$ADO_FEED" AZURE_DEVOPS_EXT_PAT="$SECRET" \
  DOTNET_LOG="$DLOG2B" AWF_NUGET_RESTORE='samples/dotnet/Sample.sln'
assert_eq "pre_restore_Explicit_RestoresThatPath: rc" "0" "$RC"
assert_eq "pre_restore_Explicit_RestoresThatPath: one call" "1" \
  "$(grep -c '^argv=' "$DLOG2B" || true)"
assert_contains "pre_restore_Explicit_RestoresThatPath: the named solution" \
  "argv=restore samples/dotnet/Sample.sln " "$(cat "$DLOG2B")"

section "feed_pre_restore — a failed restore"

CWD="$REPO_SLN"
WD3="$TMP/wd3"; mkdir -p "$WD3"
DLOG3="$TMP/dotnet3.log"; : > "$DLOG3"
pfr 'feed_pre_restore origin/main "$WD"' \
  WD="$WD3" AWF_NUGET_FEEDS="$ADO_FEED" AZURE_DEVOPS_EXT_PAT="$SECRET" \
  DOTNET_LOG="$DLOG3" DOTNET_MOCK_FAIL=1
assert_eq "feed_pre_restore_CleansUpOnFailure: rc" "1" "$RC"
assert_contains "feed_pre_restore_CleansUpOnFailure: says what failed" "restore" "$ERR"
assert_eq "feed_pre_restore_CleansUpOnFailure: nothing left under the work dir" "" \
  "$(find "$WD3" -mindepth 1 | head -n1)"
assert_eq "feed_pre_restore_CleansUpOnFailure: no worktree left" "1" \
  "$(git -C "$REPO_SLN" worktree list | grep -c . || true)"
assert_eq "feed_pre_restore_CleansUpOnFailure: the cache is not left writable" "" \
  "$(find "$CACHE" -mindepth 1 -perm -o+w | head -n1)"

section "feed_cache_clear"

CLR="$TMP/clear-cache"; mkdir -p "$CLR/pkg"; : > "$CLR/pkg/a.nupkg"; : > "$CLR/.dot"
pfr 'feed_cache_clear' AWF_NUGET_CACHE="$CLR"
assert_eq "feed_cache_clear_Populated: rc" "0" "$RC"
assert_eq "feed_cache_clear_Populated: emptied" "" "$(find "$CLR" -mindepth 1 | head -n1)"
assert_eq "feed_cache_clear_Populated: the folder itself stays" "1" \
  "$([[ -d "$CLR" ]] && echo 1 || echo 0)"

pfr 'feed_cache_clear' AWF_NUGET_CACHE="$CLR"
assert_eq "feed_cache_clear_Empty: rc" "0" "$RC"

pfr 'feed_cache_clear' AWF_NUGET_CACHE="$TMP/no-such-cache"
assert_eq "feed_cache_clear_Absent: rc" "0" "$RC"

LINK_TARGET="$TMP/link-target"; mkdir -p "$LINK_TARGET"; : > "$LINK_TARGET/keep"
ln -s "$LINK_TARGET" "$TMP/link-cache"
pfr 'feed_cache_clear' AWF_NUGET_CACHE="$TMP/link-cache"
assert_eq "feed_cache_clear_Symlink: rc" "1" "$RC"
assert_contains "feed_cache_clear_Symlink: says why" "symlink" "$ERR"
assert_eq "feed_cache_clear_Symlink: the target is untouched" "1" \
  "$([[ -f "$LINK_TARGET/keep" ]] && echo 1 || echo 0)"

section "feed_pre_restore — the failure branches"

WD4="$TMP/wd4"; mkdir -p "$WD4"
pfr 'feed_pre_restore origin/main "$WD"' \
  WD="$WD4" AWF_NUGET_FEEDS="$ADO_FEED" AZURE_DEVOPS_EXT_PAT="$SECRET" \
  AWF_NUGET_CACHE="$TMP/no-such-cache"
assert_eq "feed_pre_restore_MissingCache: rc" "1" "$RC"
assert_contains "feed_pre_restore_MissingCache: says why" "does not exist" "$ERR"
assert_eq "feed_pre_restore_MissingCache: nothing left under the work dir" "" \
  "$(find "$WD4" -mindepth 1 | head -n1)"

WD5="$TMP/wd5"; mkdir -p "$WD5"
pfr 'feed_pre_restore origin/main "$WD"' \
  WD="$WD5" AWF_NUGET_FEEDS="$ADO_FEED" AZURE_DEVOPS_EXT_PAT="$SECRET" \
  AWF_NUGET_CACHE="$TMP/link-cache"
assert_eq "feed_pre_restore_SymlinkCache: rc" "1" "$RC"
assert_eq "feed_pre_restore_SymlinkCache: the target is untouched" "1" \
  "$([[ -f "$LINK_TARGET/keep" ]] && echo 1 || echo 0)"
assert_eq "feed_pre_restore_SymlinkCache: nothing left under the work dir" "" \
  "$(find "$WD5" -mindepth 1 | head -n1)"

WD6="$TMP/wd6"; mkdir -p "$WD6"
DLOG6="$TMP/dotnet6.log"; : > "$DLOG6"
pfr 'feed_pre_restore origin/no-such-branch "$WD"' \
  WD="$WD6" AWF_NUGET_FEEDS="$ADO_FEED" AZURE_DEVOPS_EXT_PAT="$SECRET" DOTNET_LOG="$DLOG6"
assert_eq "feed_pre_restore_WorktreeAddFails: rc" "1" "$RC"
assert_contains "feed_pre_restore_WorktreeAddFails: says why" "could not check out" "$ERR"
assert_eq "feed_pre_restore_WorktreeAddFails: no restore ran" "" "$(cat "$DLOG6")"
assert_eq "feed_pre_restore_WorktreeAddFails: nothing left under the work dir" "" \
  "$(find "$WD6" -mindepth 1 | head -n1)"
assert_eq "feed_pre_restore_WorktreeAddFails: no worktree left" "1" \
  "$(git -C "$REPO_SLN" worktree list | grep -c . || true)"

# A subfolder this user cannot write into makes `find -delete` fail. root
# ignores the mode, so the case cannot fail there and is skipped.
if [[ "$(id -u)" != 0 ]]; then
  STUCK="$TMP/stuck-cache"; mkdir -p "$STUCK/locked"; : > "$STUCK/locked/pkg"
  chmod 0500 "$STUCK/locked"
  WD7="$TMP/wd7"; mkdir -p "$WD7"
  DLOG7="$TMP/dotnet7.log"; : > "$DLOG7"
  pfr 'feed_pre_restore origin/main "$WD"' \
    WD="$WD7" AWF_NUGET_FEEDS="$ADO_FEED" AZURE_DEVOPS_EXT_PAT="$SECRET" \
    AWF_NUGET_CACHE="$STUCK" DOTNET_LOG="$DLOG7"
  chmod 0700 "$STUCK/locked"
  assert_eq "feed_pre_restore_CacheEmptyFails: rc" "1" "$RC"
  assert_contains "feed_pre_restore_CacheEmptyFails: says why" "could not empty" "$ERR"
  assert_eq "feed_pre_restore_CacheEmptyFails: no restore ran" "" "$(cat "$DLOG7")"
  assert_eq "feed_pre_restore_CacheEmptyFails: nothing left under the work dir" "" \
    "$(find "$WD7" -mindepth 1 | head -n1)"
else
  printf '  - feed_pre_restore_CacheEmptyFails skipped: running as root\n'
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then printf 'Failed: %s\n' "${FAIL_NAMES[*]}"; exit 1; fi
