#!/usr/bin/env bash
#
# run-knowledge-bundle-tests.sh — Layer-1 tests for scripts/build-knowledge-bundle.sh,
# scripts/publish-knowledge-bundle.sh and the structure of
# .github/workflows/knowledge-bundle.yml (#601).
#
# Fixture repos are built with `git init` in a temp dir and the publish script
# pushes to a local bare repo with the shared `gh` mock on PATH; no network.
# Usage: tests/run-knowledge-bundle-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT_DIR/scripts/build-knowledge-bundle.sh"
PUBLISH="$ROOT_DIR/scripts/publish-knowledge-bundle.sh"
MOCKS="$ROOT_DIR/tests/mocks"
WF="$ROOT_DIR/.github/workflows/knowledge-bundle.yml"

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

PASS=0
FAIL=0

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_GREEN=''; C_RED=''; C_DIM=''; C_OFF=''
fi

section() { printf '\n%s── %s ──%s\n' "$C_DIM" "$1" "$C_OFF"; }
pass() { PASS=$((PASS + 1)); printf '  %s✓%s %s\n' "$C_GREEN" "$C_OFF" "$1"; }
fail() {
  FAIL=$((FAIL + 1))
  printf '  %s✗%s %s\n' "$C_RED" "$C_OFF" "$1"
  [ $# -gt 1 ] && printf '      %s\n' "$2"
  return 0
}
assert_eq() {  # <actual> <expected> <name>
  if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3" "expected [$2] got [$1]"; fi
}
assert_contains() {  # <haystack> <needle> <name>
  if [[ "$1" == *"$2"* ]]; then pass "$3"; else fail "$3" "missing [$2]"; fi
}
assert_not_contains() {  # <haystack> <needle> <name>
  if [[ "$1" != *"$2"* ]]; then pass "$3"; else fail "$3" "unexpected [$2]"; fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- fixtures ----------------------------------------------------------

mkrepo() {  # <root> <repo>
  mkdir -p "$1/$2"
  git -C "$1/$2" init -q
}
commit_all() {  # <root> <repo> <message>
  git -C "$1/$2" add -A
  git -C "$1/$2" -c user.name=t -c user.email=t@example.invalid \
    -c commit.gpgsign=false commit -q -m "$3"
}
sha7() {  # <root> <repo> <path>
  local full
  full="$(git -C "$1/$2" log -1 --format=%H -- "$3")"
  printf '%s' "${full:0:7}"
}
# fresh_root — a root with the three repos, files committed in each.
fresh_root() {
  local r
  r="$(mktemp -d "$TMP/root.XXXXXX")"
  mkrepo "$r" agent-workflow
  mkrepo "$r" bridge
  mkrepo "$r" ai-instructions
  mkdir -p "$r/agent-workflow/docs" "$r/bridge/docs"
  printf '# AW readme\nalpha\n' > "$r/agent-workflow/README.md"
  printf 'bridge doc without trailing newline' > "$r/bridge/docs/dispatch.md"
  printf 'untouched\n' > "$r/ai-instructions/README.md"
  commit_all "$r" agent-workflow first
  commit_all "$r" bridge first
  commit_all "$r" ai-instructions first
  printf '%s' "$r"
}
write_list() {  # <root> — list content on stdin
  mkdir -p "$1/agent-workflow/docs"
  cat > "$1/agent-workflow/docs/knowledge-bundle.txt"
}
run_build() {  # <root> [args...]; sets RC, ERR; bundle at $OUT
  local r="$1"; shift
  OUT="$r/out/bundle.md"
  RC=0
  ERR="$(bash "$BUILD" --root "$r" --out "$OUT" "$@" 2>&1 >/dev/null)" || RC=$?
}

# --- concatenation and header ------------------------------------------

section "bundle — concatenation and header"

R="$(fresh_root)"
write_list "$R" <<'LIST'
agent-workflow/README.md
bridge/docs/dispatch.md
ai-instructions/README.md
LIST
run_build "$R"
assert_eq "$RC" "0" "valid list exits 0"
B="$(cat "$OUT" 2>/dev/null || true)"
assert_contains "$B" "# Software Factory knowledge bundle" "preamble title"
assert_contains "$B" "bridge MCP" "preamble points live state at the bridge MCP"
assert_contains "$B" "# FILE: agent-workflow/README.md (@$(sha7 "$R" agent-workflow README.md))" "header: repo/path and short sha"
assert_contains "$B" "# FILE: bridge/docs/dispatch.md (@$(sha7 "$R" bridge docs/dispatch.md))" "header for a second repo"
assert_contains "$B" "alpha" "file body is included"
assert_contains "$B" $'bridge doc without trailing newline\n' "a missing final newline is added"
assert_eq "$(grep -c '^# FILE: ' "$OUT" 2>/dev/null || true)" "3" "one header per entry"
first="$(grep -n '^# FILE: ' "$OUT" 2>/dev/null | head -1 | cut -d: -f2- || true)"
assert_contains "$first" "agent-workflow/README.md" "entries keep list order"

section "bundle — sha is the last commit touching the path"

before="$(grep '^# FILE: bridge/docs/dispatch.md' "$OUT" 2>/dev/null || true)"
printf 'other\n' > "$R/bridge/other.md"
commit_all "$R" bridge unrelated
run_build "$R"
after="$(grep '^# FILE: bridge/docs/dispatch.md' "$OUT" 2>/dev/null || true)"
assert_eq "$after" "$before" "an unrelated commit in the repo does not change the header"
printf 'changed\n' >> "$R/bridge/docs/dispatch.md"
commit_all "$R" bridge touch
run_build "$R"
assert_contains "$(grep '^# FILE: bridge/docs/dispatch.md' "$OUT" 2>/dev/null || true)" "@$(sha7 "$R" bridge docs/dispatch.md)" "touching the file moves its sha"

# --- list parsing -------------------------------------------------------

section "list — comments, blank lines, CRLF, whitespace"

R="$(fresh_root)"
{
  printf '# a comment\n\n'
  printf '   # an indented comment\n'
  printf 'agent-workflow/README.md\r\n'
  printf '\t\n'
  printf '  bridge/docs/dispatch.md  \n'
} | write_list "$R"
run_build "$R"
assert_eq "$RC" "0" "comments and blanks do not fail the build"
assert_eq "$(grep -c '^# FILE: ' "$OUT" 2>/dev/null || true)" "2" "only the two real entries are bundled"
assert_not_contains "$(cat "$OUT" 2>/dev/null || true)" "a comment" "comment text never reaches the bundle"

# --- failure modes ------------------------------------------------------

section "failure — nothing partial"

R="$(fresh_root)"
write_list "$R" <<'LIST'
agent-workflow/README.md
bridge/docs/nope.md
LIST
run_build "$R"
assert_eq "$RC" "1" "missing source exits 1"
assert_contains "$ERR" "bridge/docs/nope.md" "the missing file is named as <repo>/<path>"
assert_eq "$([[ -e "$OUT" ]] && echo yes || echo no)" "no" "no output file is written"
assert_eq "$(find "$R/out" -type f 2>/dev/null | wc -l | tr -d ' ')" "0" "no temp file is left behind"

mkdir -p "$R/out"; printf 'previous bundle\n' > "$OUT"
run_build "$R"
assert_eq "$(cat "$OUT")" "previous bundle" "a failing run leaves the previous bundle untouched"

R="$(fresh_root)"
write_list "$R" <<'LIST'
bridge/../agent-workflow/README.md
LIST
run_build "$R"
assert_eq "$RC" "2" "a '..' segment is rejected"
write_list "$R" <<'LIST'
justapath.md
LIST
run_build "$R"
assert_eq "$RC" "2" "an entry without <repo>/ is rejected"

R="$(fresh_root)"
git clone -q --depth 1 "file://$R/agent-workflow" "$TMP/shallow-aw" 2>/dev/null
rm -rf "$R/agent-workflow/.git"; cp -a "$TMP/shallow-aw/.git" "$R/agent-workflow/.git"
write_list "$R" <<'LIST'
agent-workflow/README.md
LIST
run_build "$R"
assert_eq "$RC" "1" "a shallow checkout is refused"
assert_contains "$ERR" "shallow" "the refusal says why"

R="$(fresh_root)"
write_list "$R" <<'LIST'
agent-workflow/README.md
LIST
RC=0
bash "$BUILD" --root "$R/does-not-exist" >/dev/null 2>&1 || RC=$?
assert_eq "$RC" "2" "a missing --root exits 2"

# --- determinism --------------------------------------------------------

section "determinism"

R="$(fresh_root)"
write_list "$R" <<'LIST'
agent-workflow/README.md
bridge/docs/dispatch.md
LIST
run_build "$R"; cp "$OUT" "$TMP/run1.md" 2>/dev/null || true
sleep 1
printf 'x\n' > "$R/ai-instructions/unlisted.md"; commit_all "$R" ai-instructions unlisted
run_build "$R"
if cmp -s "$OUT" "$TMP/run1.md" 2>/dev/null; then
  pass "two runs are byte-identical, also after an unrelated commit and a second"
else
  fail "bundle is not deterministic"
fi
assert_not_contains "$(cat "$OUT" 2>/dev/null || true)" "$(date +%Y)-" "no date appears in the output"

# --- workflow structure -------------------------------------------------

section "workflow — structure"

W="$(cat "$WF" 2>/dev/null || true)"
job() { awk -v j="$1" '$0 ~ "^  "j":$"{f=1;next} f && /^  [a-z_-]+:$/{exit} f' "$WF" 2>/dev/null || true; }
J="$(job bundle)"
assert_contains "$W" "workflow_dispatch:" "dispatch trigger"
assert_contains "$W" "schedule:" "nightly schedule trigger"
assert_contains "$W" "- '!docs/generated/**'" "push trigger excludes the generated directory"
assert_contains "$W" "- 'docs/knowledge-bundle.txt'" "push trigger names the list file"
assert_contains "$W" "group: knowledge-bundle" "concurrency group"
top="$(awk '/^jobs:/{exit} {print}' "$WF" 2>/dev/null || true)"
assert_contains "$top" $'permissions:\n  contents: read' "workflow permissions are contents: read"
assert_not_contains "$W" "contents: write" "no job widens contents"
assert_eq "$(grep -c 'fetch-depth: 0' "$WF" 2>/dev/null || true)" "3" "all three checkouts fetch full history"
assert_eq "$(grep -c 'persist-credentials: false' "$WF" 2>/dev/null || true)" "3" "no checkout stores a credential"
# Asserted against this workflow alone. Reading the pin out of a sibling
# workflow instead coupled the suite to a file this feature never touches, so a
# Dependabot bump over there turned these tests red; `|| true` because `head`
# closing the pipe early is a SIGPIPE failure under `set -o pipefail`.
app_pin="$(grep -o 'actions/create-github-app-token@[0-9a-f]\{40\}' "$WF" 2>/dev/null | head -1 || true)"
assert_contains "$app_pin" "actions/create-github-app-token@" "App token action pinned to a full 40-char SHA"
assert_contains "$W" "PIPELINE_APP_PRIVATE_KEY" "uses the pipeline App secrets"
assert_contains "$J" "bash scripts/publish-knowledge-bundle.sh" "the job publishes through the extracted script"
assert_contains "$W" "git status --porcelain -- docs/generated/" "change detection sees untracked files"

# --- publish: shape -----------------------------------------------------

section "publish — shape"

P="$(cat "$PUBLISH" 2>/dev/null || true)"
assert_contains "$P" "--auto --squash" "auto-merge is squash"
assert_contains "$P" "--subject \"\$SUBJECT [skip ci]\"" "[skip ci] is on the squash subject"
assert_eq "$(grep -v '^ *#' "$PUBLISH" 2>/dev/null | grep -c 'skip ci' || true)" "1" "skip ci occurs once in code: the merge subject"
commit_line="$(grep -n 'commit -q' "$PUBLISH" 2>/dev/null | head -1 || true)"
assert_not_contains "$commit_line" "skip ci" "the head commit message has no [skip ci]"
# Scoped to the `git push` lines, not the whole file: the branch name appears in
# several places and a file-wide assertion would say nothing about the target.
push_lines="$(grep 'git push' "$PUBLISH" 2>/dev/null || true)"
# shellcheck disable=SC2016  # matching the literal `${BRANCH}` in the script, not expanding it
assert_contains "$push_lines" 'HEAD:refs/heads/${BRANCH}' "the push target is the bundle branch"
assert_not_contains "$push_lines" "refs/heads/main" "never pushes to main"
# Code only: the comment above the push names the x-access-token:<token>@ form
# it deliberately avoids, and a whole-file check would match that explanation.
assert_not_contains "$(grep -v '^ *#' "$PUBLISH" 2>/dev/null || true)" "x-access-token:" "the token stays out of the remote URL and the argv"

# --- publish: branch, PR, auto-merge ------------------------------------

section "publish — branch, PR, auto-merge"

# work_root — a checkout whose `origin` is a local bare repo, with a freshly
# regenerated bundle sitting uncommitted. Prints the root; the checkout is
# <root>/work and the remote <root>/origin.git.
work_root() {
  local r
  r="$(mktemp -d "$TMP/pub.XXXXXX")"
  git init -q --bare "$r/origin.git"
  git init -q "$r/work"
  git -C "$r/work" symbolic-ref HEAD refs/heads/main
  git -C "$r/work" remote add origin "$r/origin.git"
  printf 'seed\n' > "$r/work/README.md"
  commit_all "$r" work seed
  git -C "$r/work" push -q origin main
  mkdir -p "$r/work/docs/generated"
  printf '# bundle\n' > "$r/work/docs/generated/software-factory-knowledge.md"
  printf '%s' "$r"
}
# pr_map <root> <substring> <stdout> — a GH_MOCK_STDOUT_MAP answering any gh
# call whose argv contains <substring> with <stdout>.
pr_map() {
  printf '%s\n' "$3" > "$1/mock-stdout.txt"
  printf '%s\t%s\n' "$2" "$1/mock-stdout.txt" > "$1/map.tsv"
  printf '%s' "$1/map.tsv"
}
run_publish() {  # <root> [VAR=value ...]; sets RC, OUT_TEXT, GH_LOG
  local r="$1"; shift
  RC=0
  OUT_TEXT="$(cd "$r/work" && env PATH="$MOCKS:$PATH" GH_MOCK_LOG="$r/gh.log" \
    GH_TOKEN=app-token GH_REPO=owner/repo BRANCH=chore/knowledge-bundle \
    SUBJECT='chore(docs): regenerate knowledge bundle' \
    "$@" bash "$PUBLISH" 2>&1)" || RC=$?
  GH_LOG="$(cat "$r/gh.log" 2>/dev/null || true)"
}
origin_log() { git -C "$1/origin.git" log -1 --format="$3" "$2" 2>/dev/null || true; }

R="$(work_root)"
# `gh pr create` prints the PR URL; `gh pr list --jq` prints what the jq filter
# produced, a bare number or nothing. The mock does not run jq.
run_publish "$R" GH_MOCK_STDOUT_MAP="$(pr_map "$R" 'pr create' 'https://github.com/owner/repo/pull/42')"
assert_eq "$RC" "0" "a regenerated bundle publishes cleanly"
assert_contains "$GH_LOG" "auth setup-git" "the push authenticates through gh's credential helper"
assert_contains "$GH_LOG" "pr create --base main --head chore/knowledge-bundle" "no open PR: one is opened against main"
assert_contains "$GH_LOG" "pr merge 42 --auto --squash" "the PR number is parsed out of the create URL"
assert_contains "$GH_LOG" "--subject chore(docs): regenerate knowledge bundle [skip ci]" "[skip ci] rides the squash subject"
assert_contains "$OUT_TEXT" "PR #42: auto-merge enabled." "the step reports the PR it armed"
assert_eq "$(origin_log "$R" refs/heads/chore/knowledge-bundle '%s')" "chore(docs): regenerate knowledge bundle" "the branch is pushed with the plain subject, no [skip ci]"
assert_eq "$(origin_log "$R" main '%s')" "seed" "main is never pushed to"
files="$(git -C "$R/origin.git" show --pretty=format: --name-only refs/heads/chore/knowledge-bundle 2>/dev/null | grep -v '^$' || true)"
assert_eq "$files" "docs/generated/software-factory-knowledge.md" "only the bundle is committed"
assert_eq "$(origin_log "$R" refs/heads/chore/knowledge-bundle '%an')" "github-actions[bot]" "the bot authors the commit — the runner checkout has no identity"

R="$(work_root)"
run_publish "$R" GH_MOCK_STDOUT_MAP="$(pr_map "$R" 'pr list' '7')"
assert_eq "$RC" "0" "an already-open PR publishes cleanly"
assert_not_contains "$GH_LOG" "pr create" "the open PR is reused, never recreated"
assert_contains "$GH_LOG" "pr merge 7 --auto --squash" "auto-merge is re-armed on the existing PR"

# A re-run finds last night's branch on origin, diverged from main. The push
# must replace it rather than fail on a non-fast-forward.
R="$(work_root)"
git -C "$R/work" switch -q -c stale
printf 'stale bundle\n' > "$R/work/docs/generated/software-factory-knowledge.md"
commit_all "$R" work stale
git -C "$R/work" push -q origin stale:refs/heads/chore/knowledge-bundle
git -C "$R/work" switch -q main
mkdir -p "$R/work/docs/generated"
printf '# bundle\n' > "$R/work/docs/generated/software-factory-knowledge.md"
run_publish "$R" GH_MOCK_STDOUT_MAP="$(pr_map "$R" 'pr list' '7')"
assert_eq "$RC" "0" "a diverged bundle branch on origin is force-replaced"
assert_eq "$(origin_log "$R" refs/heads/chore/knowledge-bundle '%s')" "chore(docs): regenerate knowledge bundle" "the stale head is gone"

R="$(work_root)"
RC=0
OUT_TEXT="$(cd "$R/work" && env PATH="$MOCKS:$PATH" GH_MOCK_LOG="$R/gh.log" \
  GH_TOKEN=app-token SUBJECT=s bash "$PUBLISH" 2>&1)" || RC=$?
assert_eq "$RC" "2" "a missing BRANCH exits 2"
assert_contains "$OUT_TEXT" "BRANCH" "the refusal names the variable"
assert_eq "$([[ -e "$R/gh.log" ]] && echo yes || echo no)" "no" "nothing is pushed and gh is never called"

R="$(work_root)"
rm -f "$R/work/docs/generated/software-factory-knowledge.md"
run_publish "$R"
assert_eq "$RC" "2" "no bundle in the worktree exits 2 instead of committing nothing"

# --- lint exclusions ----------------------------------------------------

section "lint — generated bundle is excluded"

assert_contains "$(cat "$ROOT_DIR/.markdownlint-cli2.yaml")" '"docs/generated/**"' "markdownlint ignores docs/generated"
for hook in trailing-whitespace end-of-file-fixer check-added-large-files mixed-line-ending typos; do
  blk="$(awk -v h="$hook" '$0 ~ "- id: "h"$"{f=1;print;next} f && /- id:|- repo:/{exit} f' "$ROOT_DIR/.pre-commit-config.yaml")"
  assert_contains "$blk" "docs/generated/" "pre-commit hook $hook excludes docs/generated"
done

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
