#!/usr/bin/env bash
#
# run-pipeline-file-guard-tests.sh — Layer-1 tests for scripts/lib/pipeline-file-guard.sh
# (pipeline_file_guard <base-ref>). Each case builds a throwaway git repo, commits a
# change on a branch, and asserts the return code and stderr of the guard.
#
# Usage: tests/run-pipeline-file-guard-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

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
  if [[ "$actual" == "$expected" ]]; then pass "$name"; else fail "$name" "expected: $expected | actual: $actual"; fi
}
assert_contains() {
  local name="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then pass "$name"; else fail "$name" "missing: $needle | in: $haystack"; fi
}
assert_not_contains() {
  local name="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then pass "$name"; else fail "$name" "unexpected: $needle"; fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

REPO=""
RC=0
ERR=""
OUT=""

# make_repo [base-file...] — repo on main with README.md plus the given files,
# origin/main pinned to it, and the working branch agent/x checked out.
make_repo() {
  local f
  REPO="$(mktemp -d "$TMP/repo.XXXXXX")"
  git -C "$REPO" init -q -b main
  printf 'x\n' > "$REPO/README.md"
  for f in "$@"; do
    mkdir -p "$REPO/$(dirname "$f")"
    printf 'x\n' > "$REPO/$f"
  done
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m base
  git -C "$REPO" update-ref refs/remotes/origin/main HEAD
  git -C "$REPO" checkout -q -b agent/x
}

# add_files <file...> — create files and commit them on the branch.
add_files() {
  local f
  for f in "$@"; do
    mkdir -p "$REPO/$(dirname "$f")"
    printf 'y\n' > "$REPO/$f"
  done
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m change
}

# run_guard <base-ref> [globs] — sets RC, ERR, OUT. Globs unset unless given.
run_guard() {
  local base="$1"
  local errf="$TMP/err" outf="$TMP/out"
  local -a envcmd=(env -u PIPELINE_FILE_GLOBS)
  [[ $# -ge 2 ]] && envcmd=(env "PIPELINE_FILE_GLOBS=$2")
  RC=0
  # shellcheck disable=SC2016  # $1/$2 expand in the inner bash, on purpose
  # The inner shell uses the same strict mode as the real callers.
  ( cd "$REPO" && "${envcmd[@]}" bash -c \
      'set -euo pipefail; IFS=$'"'"'\n\t'"'"'; source "$1/scripts/lib/pipeline-file-guard.sh" && pipeline_file_guard "$2"' \
      _ "$ROOT" "$base" ) >"$outf" 2>"$errf" || RC=$?
  ERR="$(cat "$errf")"
  OUT="$(cat "$outf")"
}

# blocked_case <name> <expected-path> <globs-or-"-"> <file...> — add files, expect rc 1.
blocked_case() {
  local name="$1" want="$2" globs="$3"
  shift 3
  make_repo
  add_files "$@"
  if [[ "$globs" == "-" ]]; then run_guard origin/main; else run_guard origin/main "$globs"; fi
  assert_eq "$name: rc" 1 "$RC"
  assert_contains "$name: stderr" "  $want" "$ERR"
  assert_eq "$name: stdout empty" "" "$OUT"
}

section "defaults"
make_repo
add_files src/app.cs
run_guard origin/main
assert_eq "src_only_passes: rc" 0 "$RC"
assert_eq "src_only_passes: stderr empty" "" "$ERR"
assert_eq "src_only_passes: stdout empty" "" "$OUT"

blocked_case root_yml_blocked azure-pipelines-pr.yml - azure-pipelines-pr.yml
blocked_case root_yaml_blocked azure-pipelines.yaml - azure-pipelines.yaml
blocked_case nested_basename_blocked ci/azure-pipelines.yml - ci/azure-pipelines.yml
blocked_case dot_azure_pipelines_deep_blocked .azure-pipelines/a/b.yml - .azure-pipelines/a/b.yml
blocked_case dot_azuredevops_blocked .azuredevops/policies.yml - .azuredevops/policies.yml

section "deletion and rename"
make_repo azure-pipelines-pr.yml
git -C "$REPO" rm -q azure-pipelines-pr.yml
git -C "$REPO" commit -q -m del
run_guard origin/main
assert_eq "deletion_blocked: rc" 1 "$RC"
assert_contains "deletion_blocked: stderr" "azure-pipelines-pr.yml" "$ERR"

make_repo azure-pipelines-pr.yml
git -C "$REPO" mv azure-pipelines-pr.yml x.yml
git -C "$REPO" commit -q -m mv
run_guard origin/main
assert_eq "rename_out_blocked: rc" 1 "$RC"
assert_contains "rename_out_blocked: stderr" "azure-pipelines-pr.yml" "$ERR"

section "listing"
make_repo
add_files azure-pipelines-pr.yml .azuredevops/a.yml src/a.cs
run_guard origin/main
assert_eq "all_offenders_listed: rc" 1 "$RC"
assert_contains "all_offenders_listed: first" "  azure-pipelines-pr.yml" "$ERR"
assert_contains "all_offenders_listed: second" "  .azuredevops/a.yml" "$ERR"
assert_not_contains "all_offenders_listed: clean path omitted" "src/a.cs" "$ERR"

section "PIPELINE_FILE_GLOBS"
blocked_case extra_glob_adds_path deploy/build.yml 'deploy/**' deploy/build.yml
blocked_case extra_glob_trimmed_and_empty_skipped deploy/build.yml ' ci/*.yml , ,deploy/** ' deploy/build.yml
blocked_case extra_glob_cannot_remove_defaults azure-pipelines-pr.yml '' azure-pipelines-pr.yml

section "fail closed and uncommitted"
make_repo
add_files src/app.cs
run_guard origin/nope
assert_eq "unknown_base_fails_closed: rc" 2 "$RC"
assert_contains "unknown_base_fails_closed: stderr" "cannot diff" "$ERR"

make_repo
add_files src/app.cs
printf 'z\n' > "$REPO/azure-pipelines-pr.yml"
run_guard origin/main
assert_eq "uncommitted_pipeline_edit_ignored: rc" 0 "$RC"
assert_eq "uncommitted_pipeline_edit_ignored: stderr empty" "" "$ERR"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  printf 'Failed:\n'; printf '  - %s\n' "${FAIL_NAMES[@]}"
  exit 1
fi
