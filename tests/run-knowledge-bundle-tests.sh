#!/usr/bin/env bash
#
# run-knowledge-bundle-tests.sh — Layer-1 tests for scripts/build-knowledge-bundle.sh
# and the structure of .github/workflows/knowledge-bundle.yml (#601).
#
# Fixture repos are built with `git init` in a temp dir; no network.
# Usage: tests/run-knowledge-bundle-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT_DIR/scripts/build-knowledge-bundle.sh"
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
pin="$(grep -o 'actions/create-github-app-token@[0-9a-f]\{40\}' "$ROOT_DIR/.github/workflows/agent-implement.yml" | head -1)"
assert_contains "$W" "$pin" "App token action pinned to the same SHA as agent-implement.yml"
assert_contains "$W" "PIPELINE_APP_PRIVATE_KEY" "uses the pipeline App secrets"
assert_contains "$J" "--auto --squash" "auto-merge is squash"
assert_contains "$J" "--subject \"\$SUBJECT [skip ci]\"" "[skip ci] is on the squash subject"
assert_eq "$(grep -v '^ *#' "$WF" 2>/dev/null | grep -c 'skip ci' || true)" "1" "skip ci occurs once in code: the merge subject"
commit_line="$(grep -n 'commit -q' "$WF" 2>/dev/null | head -1 || true)"
assert_not_contains "$commit_line" "skip ci" "the head commit message has no [skip ci]"
assert_not_contains "$W" "refs/heads/main" "never pushes to main"
assert_contains "$W" "git status --porcelain -- docs/generated/" "change detection sees untracked files"

# --- lint exclusions ----------------------------------------------------

section "lint — generated bundle is excluded"

assert_contains "$(cat "$ROOT_DIR/.markdownlint-cli2.yaml")" '"docs/generated/**"' "markdownlint ignores docs/generated"
for hook in trailing-whitespace end-of-file-fixer check-added-large-files typos; do
  blk="$(awk -v h="$hook" '$0 ~ "- id: "h"$"{f=1;print;next} f && /- id:|- repo:/{exit} f' "$ROOT_DIR/.pre-commit-config.yaml")"
  assert_contains "$blk" "docs/generated/" "pre-commit hook $hook excludes docs/generated"
done

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
