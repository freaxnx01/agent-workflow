# Knowledge Bundle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generate `docs/generated/software-factory-knowledge.md` from 18 listed docs of three repos, and keep it current through an auto-merged App PR.

**Architecture:** A list file plus one bash script that preflights every source and writes atomically. A workflow checks the three repos out as siblings, runs the script, and, only when `git status` shows a change, force-pushes `chore/knowledge-bundle` with an App token, opens or reuses the PR and enables squash auto-merge.

**Tech Stack:** Bash 5 (`set -euo pipefail`, `IFS=$'\n\t'`), git, `gh`, GitHub Actions YAML, a dedicated Layer-1 runner `tests/run-knowledge-bundle-tests.sh` (discovered by `tests/run-all.sh`), `shellcheck`, `actionlint`.

**Spec:** `docs/superpowers/specs/2026-11-12-knowledge-bundle-design.md`

## Global Constraints

- Existing tests pass unmodified. No change to branch protection, no new secret (`PIPELINE_APP_ID` / `PIPELINE_APP_PRIVATE_KEY` exist).
- The bundle holds no timestamp or run id: header SHAs are the last commit touching each path.
- `[skip ci]` appears only in the squash-merge subject, never in the PR head commit message.
- Workflow `permissions: contents: read`; the App token is the only write credential and is created only when the bundle changed.
- Sibling checkouts use the default token and `fetch-depth: 0`.
- Do not run the workflow, and do not commit a generated bundle: the first run creates it.
- Conventional Commits, scope `docs` or `pipeline`; reference `#601`.

## Review Focus

1. `[skip ci]` placement and the loop/stall analysis. Task 3.
2. Preflight before output; atomic write; shallow refusal. Task 1.
3. Determinism. Task 1.
4. Every hook that would touch `docs/generated/` is excluded. Task 4.

---

### Task 1: `build-knowledge-bundle.sh` and its tests (TDD)

**Files:**
- Create: `tests/run-knowledge-bundle-tests.sh`
- Create: `scripts/build-knowledge-bundle.sh`

**Interfaces:**
- Consumes: `<root>/agent-workflow/docs/knowledge-bundle.txt`; sources at `<root>/<repo>/<path>`.
- Produces: `--out` file. Exit 0 ok; 1 source problem (missing file, not a git checkout, shallow, no history); 2 usage or malformed entry.

- [ ] **Step 1: Write the failing runner**

Create `tests/run-knowledge-bundle-tests.sh` (mode 755):

```bash
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
# fresh_root — a root with the three repos, two files committed in each of two.
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
B="$(cat "$OUT")"
assert_contains "$B" "# Software Factory knowledge bundle" "preamble title"
assert_contains "$B" "bridge MCP" "preamble points live state at the bridge MCP"
assert_contains "$B" "# FILE: agent-workflow/README.md (@$(sha7 "$R" agent-workflow README.md))" "header: repo/path and short sha"
assert_contains "$B" "# FILE: bridge/docs/dispatch.md (@$(sha7 "$R" bridge docs/dispatch.md))" "header for a second repo"
assert_contains "$B" "alpha" "file body is included"
assert_contains "$B" $'bridge doc without trailing newline\n' "a missing final newline is added"
assert_eq "$(grep -c '^# FILE: ' "$OUT")" "3" "one header per entry"
first="$(grep -n '^# FILE: ' "$OUT" | head -1 | cut -d: -f2-)"
assert_contains "$first" "agent-workflow/README.md" "entries keep list order"

section "bundle — sha is the last commit touching the path"

before="$(grep '^# FILE: bridge/docs/dispatch.md' "$OUT")"
printf 'other\n' > "$R/bridge/other.md"
commit_all "$R" bridge unrelated
run_build "$R"
after="$(grep '^# FILE: bridge/docs/dispatch.md' "$OUT")"
assert_eq "$after" "$before" "an unrelated commit in the repo does not change the header"
printf 'changed\n' >> "$R/bridge/docs/dispatch.md"
commit_all "$R" bridge touch
run_build "$R"
assert_contains "$(grep '^# FILE: bridge/docs/dispatch.md' "$OUT")" "@$(sha7 "$R" bridge docs/dispatch.md)" "touching the file moves its sha"

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
assert_eq "$(grep -c '^# FILE: ' "$OUT")" "2" "only the two real entries are bundled"
assert_not_contains "$(cat "$OUT")" "a comment" "comment text never reaches the bundle"

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
write_list "$R" <<'LIST'
agent-workflow/README.md
LIST
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
run_build "$R"; cp "$OUT" "$TMP/run1.md"
sleep 1
printf 'x\n' > "$R/ai-instructions/unlisted.md"; commit_all "$R" ai-instructions unlisted
run_build "$R"
if cmp -s "$OUT" "$TMP/run1.md"; then pass "two runs are byte-identical, also after an unrelated commit and a second"; else fail "bundle is not deterministic"; fi
assert_not_contains "$(cat "$OUT")" "$(date +%Y)-" "no date appears in the output"

# --- workflow structure -------------------------------------------------

section "workflow — structure"

W="$(cat "$WF")"
job() { awk -v j="$1" '$0 ~ "^  "j":$"{f=1;next} f && /^  [a-z_-]+:$/{exit} f' "$WF"; }
J="$(job bundle)"
assert_contains "$W" "workflow_dispatch:" "dispatch trigger"
assert_contains "$W" "schedule:" "nightly schedule trigger"
assert_contains "$W" "- '!docs/generated/**'" "push trigger excludes the generated directory"
assert_contains "$W" "- 'docs/knowledge-bundle.txt'" "push trigger names the list file"
assert_contains "$W" "group: knowledge-bundle" "concurrency group"
top="$(awk '/^jobs:/{exit} {print}' "$WF")"
assert_contains "$top" $'permissions:\n  contents: read' "workflow permissions are contents: read"
assert_not_contains "$W" "contents: write" "no job widens contents"
assert_eq "$(grep -c 'fetch-depth: 0' "$WF")" "3" "all three checkouts fetch full history"
assert_eq "$(grep -c 'persist-credentials: false' "$WF")" "3" "no checkout stores a credential"
pin="$(grep -o 'actions/create-github-app-token@[0-9a-f]\{40\}' "$ROOT_DIR/.github/workflows/agent-implement.yml" | head -1)"
assert_contains "$W" "$pin" "App token action pinned to the same SHA as agent-implement.yml"
assert_contains "$W" "PIPELINE_APP_PRIVATE_KEY" "uses the pipeline App secrets"
assert_contains "$J" "--auto --squash" "auto-merge is squash"
assert_contains "$J" "--subject \"\$SUBJECT [skip ci]\"" "[skip ci] is on the squash subject"
assert_eq "$(grep -v '^ *#' "$WF" | grep -c 'skip ci')" "1" "skip ci occurs once in code: the merge subject"
commit_line="$(grep -n 'commit -q' "$WF" | head -1)"
assert_not_contains "$commit_line" "skip ci" "the head commit message has no [skip ci]"
assert_not_contains "$W" "refs/heads/main" "never pushes to main"
assert_contains "$W" "git status --porcelain -- docs/generated/" "change detection sees untracked files"

# --- lint exclusions ----------------------------------------------------

section "lint — generated bundle is excluded"

assert_contains "$(cat "$ROOT_DIR/.markdownlint-cli2.yaml")" '"docs/generated/**"' "markdownlint ignores docs/generated"
pc="$(cat "$ROOT_DIR/.pre-commit-config.yaml")"
for hook in trailing-whitespace end-of-file-fixer check-added-large-files typos; do
  blk="$(awk -v h="$hook" '$0 ~ "- id: "h"$"{f=1;print;next} f && /- id:|- repo:/{exit} f' "$ROOT_DIR/.pre-commit-config.yaml")"
  assert_contains "$blk" "docs/generated/" "pre-commit hook $hook excludes docs/generated"
done
: "$pc"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
```

Note: the unused `pc` line can be dropped. `sleep 1` in the determinism block is deliberate (a clock-dependent generator would differ).

- [ ] **Step 2: Run to verify it fails**

Run: `chmod +x tests/run-knowledge-bundle-tests.sh && bash tests/run-knowledge-bundle-tests.sh 2>&1 | tail -30`
Expected: FAIL (script and workflow absent; the first `run_build` reports a non-zero exit).

- [ ] **Step 3: Implement the script**

Create `scripts/build-knowledge-bundle.sh` (mode 755):

```bash
#!/usr/bin/env bash
#
# build-knowledge-bundle.sh — Concatenate the docs listed in
# docs/knowledge-bundle.txt into one Markdown file for the Software Factory
# Claude Project's GitHub integration (#601).
#
# Usage: scripts/build-knowledge-bundle.sh [--root <dir>] [--out <file>]
#   --root  Directory holding the sibling checkouts agent-workflow/, bridge/ and
#           ai-instructions/. Default: two levels above this script, the parent
#           of the agent-workflow checkout. From a .worktrees/<name> checkout
#           that default is wrong; pass --root.
#   --out   Default: <root>/agent-workflow/docs/generated/software-factory-knowledge.md
#
# The list is <root>/agent-workflow/docs/knowledge-bundle.txt: one <repo>/<path>
# per line, `#` comments and blank lines ignored.
#
# Each file gets `# FILE: <repo>/<path> (@<sha7>)`, where sha7 is the last commit
# touching that path (not the repo HEAD, so an unrelated commit does not churn
# the bundle). No timestamp: an unchanged source set must give identical bytes.
#
# All sources are validated before anything is written, and the bundle is moved
# into place atomically, so a failure never leaves a partial bundle.
#
# Exit codes: 0 ok; 1 source problem (missing file, not a git checkout, shallow,
# no history); 2 bad arguments or malformed list entry.
set -euo pipefail
IFS=$'\n\t'

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT=""

die() {  # <code> <message>
  printf 'error: %s\n' "$2" >&2
  exit "$1"
}

parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      --root) (( $# >= 2 )) || die 2 "--root needs a value"; ROOT="$2"; shift 2 ;;
      --out)  (( $# >= 2 )) || die 2 "--out needs a value";  OUT="$2";  shift 2 ;;
      -h|--help) sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d;s/^# \{0,1\}//'; exit 0 ;;
      *) die 2 "unknown argument: $1" ;;
    esac
  done
  [[ -d "$ROOT" ]] || die 2 "--root is not a directory: $ROOT"
  ROOT="$(cd "$ROOT" && pwd)"
  OUT="${OUT:-$ROOT/agent-workflow/docs/generated/software-factory-knowledge.md}"
}

# read_entries <list> — prints one trimmed entry per line, skipping comments/blanks.
read_entries() {
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    printf '%s\n' "$line"
  done < "$1"
}

validate_entry() {  # <entry>
  [[ "$1" =~ ^[A-Za-z0-9._-]+/[^/].*$ ]] || die 2 "malformed list entry (want <repo>/<path>): $1"
  case "/$1/" in
    */../*) die 2 "list entry may not contain '..': $1" ;;
  esac
}

# source_sha <entry> — prints the 7-char last-touching sha, or dies naming the entry.
source_sha() {
  local entry="$1" repo path full
  repo="${entry%%/*}"
  path="${entry#*/}"
  [[ -f "$ROOT/$entry" ]] || die 1 "missing source file: $entry"
  git -C "$ROOT/$repo" rev-parse --git-dir >/dev/null 2>&1 \
    || die 1 "not a git checkout: $repo (needed for $entry)"
  [[ "$(git -C "$ROOT/$repo" rev-parse --is-shallow-repository)" == false ]] \
    || die 1 "shallow checkout of $repo: fetch full history (fetch-depth: 0) to get $entry's sha"
  full="$(git -C "$ROOT/$repo" log -1 --format=%H -- "$path")"
  [[ -n "$full" ]] || die 1 "no commit touches $entry (untracked?)"
  printf '%s' "${full:0:7}"
}

emit_preamble() {
  cat <<'EOF'
# Software Factory knowledge bundle

> Generated by `scripts/build-knowledge-bundle.sh` from `docs/knowledge-bundle.txt`
> in freaxnx01/agent-workflow. Do not edit; change the list or the source docs.
>
> This is a snapshot of documentation. Live state (issues, PRs, runs, the queue)
> comes from the bridge MCP, not from this file.
>
> Each section starts with `# FILE: <repo>/<path> (@<sha>)`: the source file and
> the last commit that touched it.
EOF
}

emit_file() {  # <entry> <sha>
  printf '\n# FILE: %s (@%s)\n\n' "$1" "$2"
  cat "$ROOT/$1"
  [[ -z "$(tail -c1 "$ROOT/$1")" ]] || printf '\n'
}

main() {
  parse_args "$@"
  local list="$ROOT/agent-workflow/docs/knowledge-bundle.txt"
  [[ -f "$list" ]] || die 1 "list file not found: agent-workflow/docs/knowledge-bundle.txt"

  local -a entries=() shas=()
  local entry sha
  while IFS= read -r entry; do
    validate_entry "$entry"
    entries+=("$entry")
    sha="$(source_sha "$entry")" || exit $?
    shas+=("$sha")
  done < <(read_entries "$list")
  (( ${#entries[@]} > 0 )) || die 1 "list file has no entries"

  mkdir -p "$(dirname "$OUT")"
  local tmp
  tmp="$(mktemp "$OUT.XXXXXX")"
  trap 'rm -f "$tmp"' EXIT
  {
    emit_preamble
    local i
    for i in "${!entries[@]}"; do
      emit_file "${entries[$i]}" "${shas[$i]}"
    done
  } > "$tmp"
  mv "$tmp" "$OUT"
  trap - EXIT
}

main "$@"
```

The explicit `|| exit $?` matters: a failing command substitution inside an array assignment is not fatal under `set -e`, and `die` inside `$(...)` exits only the subshell (its message still reaches stderr).

- [ ] **Step 4: Run to verify the script cases pass**

Run: `bash tests/run-knowledge-bundle-tests.sh 2>&1 | sed -n 1,60p; shellcheck -x scripts/build-knowledge-bundle.sh tests/run-knowledge-bundle-tests.sh`
Expected: every case before the "workflow — structure" section passes; shellcheck clean. The workflow and lint-exclusion cases still fail (Tasks 3 and 4).

- [ ] **Step 5: Commit**

```bash
git add scripts/build-knowledge-bundle.sh tests/run-knowledge-bundle-tests.sh
git commit -m "feat(docs): add knowledge bundle generator (#601)"
```

---

### Task 2: The list file, verified against the real repos

**Files:**
- Create: `docs/knowledge-bundle.txt`

- [ ] **Step 1: Create the list**

```text
# Software Factory knowledge bundle: sources, one <repo>/<path> per line.
# This is the only place to edit when the set changes (see README, "Knowledge bundle").
# Lines starting with # and blank lines are ignored.

# agent-workflow
agent-workflow/README.md
agent-workflow/docs/FACTORY-MAP.md
agent-workflow/docs/DECISIONS.md
agent-workflow/docs/AUTOPILOT.md
agent-workflow/docs/ALARMS.md
agent-workflow/docs/AZDO-PIPELINE-SETUP.md
agent-workflow/docs/DESIGN.md
agent-workflow/docs/glossary.md
agent-workflow/docs/TODO.md

# bridge
bridge/README.md
bridge/docs/cockpit.md
bridge/docs/dispatch.md
bridge/docs/mcp-cheatsheet.md
bridge/docs/positioning.md

# ai-instructions
ai-instructions/README.md
ai-instructions/.ai/base-instructions.md
ai-instructions/conventions/milestones.md
ai-instructions/WORKFLOW-ROLE.md
```

- [ ] **Step 2: Verify against the local checkouts, output to the scratchpad (not committed)**

The list lives in the worktree, so build under a throwaway root that symlinks the real siblings and this list:

```bash
R="$(mktemp -d)"
for r in bridge ai-instructions; do ln -s ~/repos/github/freaxnx01/public/$r "$R/$r"; done
mkdir -p "$R/agent-workflow/docs"
ln -s ~/repos/github/freaxnx01/public/agent-workflow/.git "$R/agent-workflow/.git"
cp -r ~/repos/github/freaxnx01/public/agent-workflow/README.md "$R/agent-workflow/"
for f in FACTORY-MAP DECISIONS AUTOPILOT ALARMS AZDO-PIPELINE-SETUP DESIGN glossary TODO; do
  cp ~/repos/github/freaxnx01/public/agent-workflow/docs/$f.md "$R/agent-workflow/docs/"
done
cp docs/knowledge-bundle.txt "$R/agent-workflow/docs/"
bash scripts/build-knowledge-bundle.sh --root "$R" --out "$R/out.md"
grep -c '^# FILE: ' "$R/out.md"; wc -c "$R/out.md"
rm -rf "$R"
```

Expected: exit 0, `18`, about 360000 bytes. If any file is reported missing, stop and report it; do not edit the list silently. (Measured 2026-11-12 on `origin/main`: all 18 exist.)

- [ ] **Step 3: Commit**

```bash
git add docs/knowledge-bundle.txt
git commit -m "feat(docs): list the 18 knowledge bundle sources (#601)"
```

---

### Task 3: The workflow

**Files:**
- Create: `.github/workflows/knowledge-bundle.yml`

- [ ] **Step 1: Confirm the structural tests fail**

Run: `bash tests/run-knowledge-bundle-tests.sh 2>&1 | sed -n '/workflow — structure/,$p'`
Expected: failures (file absent).

- [ ] **Step 2: Write the workflow**

```yaml
name: knowledge-bundle

# Regenerates docs/generated/software-factory-knowledge.md (#601) and lands a
# change on main through an App-authored PR with squash auto-merge.
#
# Why a PR: main is classically protected (required checks gate-selftest and
# test), so a direct push is rejected. The PR is authored by the pipeline App
# because GITHUB_TOKEN-authored PRs do not trigger CI, and auto-merge would wait
# forever on checks that never start.
#
# `[skip ci]` goes ONLY on the squash-merge subject: on the PR head commit the
# required checks would be skipped and the merge would stall. On the merge
# commit it stops the pipelines on main.
#
# The three repos are public, so the sibling checkouts use the default token.

on:
  workflow_dispatch:
  schedule:
    - cron: '17 3 * * *'
  push:
    branches: [main]
    paths:
      - 'README.md'
      - 'docs/**'
      - 'docs/knowledge-bundle.txt'
      - '!docs/generated/**'

permissions:
  contents: read

concurrency:
  group: knowledge-bundle
  cancel-in-progress: false

jobs:
  bundle:
    name: bundle
    if: github.repository == 'freaxnx01/agent-workflow' && github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    timeout-minutes: 10
    env:
      BRANCH: chore/knowledge-bundle
      SUBJECT: 'chore(docs): regenerate knowledge bundle'
    steps:
      - name: Checkout agent-workflow
        uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683  # v4.2.2
        with:
          path: factory/agent-workflow
          fetch-depth: 0
          persist-credentials: false

      - name: Checkout bridge
        uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683  # v4.2.2
        with:
          repository: freaxnx01/bridge
          path: factory/bridge
          fetch-depth: 0
          persist-credentials: false

      - name: Checkout ai-instructions
        uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683  # v4.2.2
        with:
          repository: freaxnx01/ai-instructions
          path: factory/ai-instructions
          fetch-depth: 0
          persist-credentials: false

      - name: Build the bundle
        # A missing source fails here with <repo>/<path> named; nothing is written.
        run: bash factory/agent-workflow/scripts/build-knowledge-bundle.sh --root factory

      - name: Detect change
        id: change
        working-directory: factory/agent-workflow
        # status, not `git diff --quiet`: diff does not see an untracked file,
        # so the first run (no bundle on main yet) would look unchanged.
        run: |
          if [[ -z "$(git status --porcelain -- docs/generated/)" ]]; then
            echo "changed=false" >> "$GITHUB_OUTPUT"
            echo "Bundle unchanged: no branch, no PR."
          else
            echo "changed=true" >> "$GITHUB_OUTPUT"
          fi

      - name: Mint pipeline App token
        id: app_token
        if: steps.change.outputs.changed == 'true'
        uses: actions/create-github-app-token@fee1f7d63c2ff003460e3d139729b119787bc349  # v2.2.2
        with:
          app-id: ${{ secrets.PIPELINE_APP_ID }}
          private-key: ${{ secrets.PIPELINE_APP_PRIVATE_KEY }}

      - name: Push branch, open or update PR, enable auto-merge
        if: steps.change.outputs.changed == 'true'
        working-directory: factory/agent-workflow
        env:
          GH_TOKEN: ${{ steps.app_token.outputs.token }}
          GH_REPO: ${{ github.repository }}
        run: |
          set -euo pipefail
          git switch -C "$BRANCH"
          git add docs/generated/software-factory-knowledge.md
          git -c user.name='github-actions[bot]' \
              -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
              commit -q -m "$SUBJECT" -m "Generated by scripts/build-knowledge-bundle.sh (#601)."
          git push --force "https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" "HEAD:refs/heads/${BRANCH}"

          number="$(gh pr list --head "$BRANCH" --state open --json number --jq '.[0].number // empty')"
          if [[ -z "$number" ]]; then
            url="$(gh pr create --base main --head "$BRANCH" --title "$SUBJECT" \
              --body "Regenerated by the knowledge-bundle workflow. Auto-merges once the required checks pass.")"
            number="${url##*/}"
          fi
          gh pr merge "$number" --auto --squash --subject "$SUBJECT [skip ci]" --body ""
          echo "PR #$number: auto-merge enabled."
```

- [ ] **Step 3: Run the tests and lint**

Run: `bash tests/run-knowledge-bundle-tests.sh 2>&1 | sed -n '/workflow — structure/,/lint/p'; actionlint .github/workflows/knowledge-bundle.yml; yamllint .github/workflows/knowledge-bundle.yml`
Expected: structure cases pass; actionlint and yamllint clean (skip actionlint if not installed and say so). Do not dispatch the workflow.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/knowledge-bundle.yml tests/run-knowledge-bundle-tests.sh
git commit -m "ci(docs): regenerate the knowledge bundle via auto-merged App PR (#601)"
```

---

### Task 4: Exclude `docs/generated/` from the hooks that would touch it

**Files:**
- Modify: `.markdownlint-cli2.yaml` (`ignores:`)
- Modify: `.pre-commit-config.yaml` (hooks `trailing-whitespace`, `end-of-file-fixer`, `check-added-large-files`, `typos`)

- [ ] **Step 1: markdownlint**

Append to `ignores:` in `.markdownlint-cli2.yaml`:

```yaml
  # Generated knowledge bundle (#601): concatenated third-party docs, so its
  # headings repeat and nest by design. The sources are linted in their own repos.
  - "docs/generated/**"
```

- [ ] **Step 2: pre-commit excludes**

`trailing-whitespace` and `end-of-file-fixer` already have `exclude: ^tests/fixtures/run-report-golden/`; widen both to `exclude: ^(tests/fixtures/run-report-golden/|docs/generated/)`. Add `exclude: ^docs/generated/` to `check-added-large-files` (the bundle is about 357 KB against the 500 KB default, and grows with the sources) and to `typos`:

```yaml
      - id: check-added-large-files
        exclude: ^docs/generated/
...
  - repo: https://github.com/crate-ci/typos
    rev: v1.47.2
    hooks:
      - id: typos
        exclude: ^docs/generated/
```

`gitleaks` is deliberately not excluded. Keep the explanatory comment above the pair of hooks that already carries one, and add one line for the new exclusion.

- [ ] **Step 3: Verify**

Run: `bash tests/run-knowledge-bundle-tests.sh 2>&1 | tail -15; pre-commit run --all-files 2>&1 | tail -20` (skip pre-commit if not installed and say so)
Expected: the lint-exclusion cases pass; the whole runner reports 0 failed.

- [ ] **Step 4: Commit**

```bash
git add .markdownlint-cli2.yaml .pre-commit-config.yaml
git commit -m "chore(docs): exclude the generated knowledge bundle from lint hooks (#601)"
```

---

### Task 5: README section and full verification

**Files:**
- Modify: `README.md` (new `## Knowledge bundle` section before `## Related repos`)

- [ ] **Step 1: Add the section**

```markdown
## Knowledge bundle

`docs/generated/software-factory-knowledge.md` is one generated file holding the
docs the "Software Factory" Claude Project needs from agent-workflow, bridge and
ai-instructions. Add this repo to the Project once through its GitHub
integration and the Project stays current; nothing is uploaded by hand.

- **Change the set:** edit `docs/knowledge-bundle.txt` (one `<repo>/<path>` per
  line, `#` comments allowed). That is the only place.
- **Regeneration:** the `knowledge-bundle` workflow runs nightly, on pushes to
  `main` touching `README.md` or `docs/`, and on demand. It opens (or updates) a
  `chore/knowledge-bundle` PR that auto-merges; an unchanged bundle makes no PR.
  Do not edit the generated file.
- **Headers:** each section starts `# FILE: <repo>/<path> (@<sha>)`, the last
  commit that touched that file. There is no timestamp.
- **Locally:** `scripts/build-knowledge-bundle.sh --root ~/repos/github/freaxnx01/public --out /tmp/bundle.md`
  (sibling checkouts with full history; a missing source fails, naming it).
- **Live state** (issues, PRs, runs) is not in the bundle; use the bridge MCP.
```

Use a scratchpad path rather than `/tmp` in the example if the repo's docs convention prefers it; markdownlint must stay green (no bare URLs, fenced blocks have a language).

- [ ] **Step 2: Full verification**

Run: `bash tests/run-all.sh 2>&1 | tail -15; shellcheck -x scripts/build-knowledge-bundle.sh tests/run-knowledge-bundle-tests.sh; pre-commit run --all-files 2>&1 | tail -20`
Expected: every runner passes (the new one is discovered automatically), shellcheck clean, pre-commit green. Existing tests untouched.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs(docs): document the knowledge bundle (#601)"
```

- [ ] **Step 4: After merge, one manual check (operator)**

Dispatch the `knowledge-bundle` workflow once. Expected: a `chore/knowledge-bundle` PR from the App, required checks run, auto-merge completes, the squash commit subject ends in `[skip ci]`. A second dispatch right after produces no PR. Then add the repo to the Claude Project and watch the first sync (open question 1 in the spec).
