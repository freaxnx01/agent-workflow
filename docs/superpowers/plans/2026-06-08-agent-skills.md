# agent-skills (Phase 0 + Phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the `agent-skills` Claude Code plugin foundation (tested bash `lib/` + scaffolding) and the four daily-loop skills (capture-idea, evaluate-to-issue, plan-sprint, review-pr), feeding the existing agent-pipeline CI.

**Architecture:** A standalone repo at `/home/admin/repos/github/freaxnx01/public/agent-skills` packaged as a Claude Code plugin. Judgment lives in `skills/<name>/SKILL.md` (prose orchestrating local Claude's Grep/Read/LSP/`gh`); deterministic operations live in fixture-tested bash helpers under `skills/lib/`. Substrate: per-repo `docs/ideas.md` → GitHub Issues → the "Backlog" Project board. Phase 2 skills (author-chain, pipeline-retro, groom-backlog, triage-failure) are a separate later plan.

**Tech Stack:** Bash 5 (`set -euo pipefail`), `gh` CLI, `jq`, `awk`; shellcheck + actionlint; `just`; git-cliff. Tests are fixture-driven with `gh` mocked via a shell-function override — no network.

**Conventions for the executor:**
- The new repo root is `/home/admin/repos/github/freaxnx01/public/agent-skills` — called **`$AS`** throughout. It does **not** exist yet; Task 1 creates it. All `Create:` paths are absolute under `$AS`.
- Run every `git` command with `git -C "$AS"` so the working directory never matters.
- No GitHub remote is created in this plan — the user creates it later. Nothing is pushed.
- Spec: `docs/superpowers/specs/2026-06-08-agent-skills-design.md` (in the agent-pipeline repo).

---

## File Structure

| File | Responsibility |
|---|---|
| `.claude-plugin/plugin.json` | Plugin manifest (name, version, description) |
| `skills/lib/ideas.sh` | Parse / append / update `docs/ideas.md` entries |
| `skills/lib/gh-helpers.sh` | Thin `gh` wrappers: create issue, add labels, read issue/PR |
| `skills/lib/board.sh` | "Backlog" Project operations: add item, set status |
| `skills/lib/ideas-schema.md` | The `ideas.md` entry format (human source of truth) |
| `skills/lib/spec-template.md` | Issue spec template (migrated from agent-pipeline DESIGN.md) |
| `skills/capture-idea/SKILL.md` | Frictionless idea → `ideas.md` |
| `skills/evaluate-to-issue/SKILL.md` | Idea/intent → Issue (or Mode #0 / refusal) |
| `skills/plan-sprint/SKILL.md` | Backlog → committed sprint set |
| `skills/review-pr/SKILL.md` | PR vs originating spec → merge/request-changes/close |
| `tests/mocks/gh-mock.sh` | Canned `gh` responses keyed by `GH_MOCK_CASE` |
| `tests/fixtures/*` | Canonical `ideas.md`, issue/PR JSON |
| `tests/run-skill-tests.sh` | Layer-1 test runner (<5s, sources `lib/`, overrides `gh`) |
| `justfile`,`VERSION`,`CHANGELOG.md`,`cliff.toml`,`.editorconfig`,`.gitignore` | Scaffold |
| `.github/workflows/lint.yml` | actionlint + shellcheck |
| `docs/DESIGN.md`,`docs/DECISIONS.md`,`README.md`,`CLAUDE.md` | Docs |

---

## PHASE 0 — Foundation

### Task 1: Initialize repo + plugin manifest

**Files:**
- Create: `/home/admin/repos/github/freaxnx01/public/agent-skills/.gitignore`
- Create: `/home/admin/repos/github/freaxnx01/public/agent-skills/.editorconfig`
- Create: `/home/admin/repos/github/freaxnx01/public/agent-skills/.claude-plugin/plugin.json`
- Create: `/home/admin/repos/github/freaxnx01/public/agent-skills/VERSION`

- [ ] **Step 1: Create the repo and directories**

```bash
AS=/home/admin/repos/github/freaxnx01/public/agent-skills
mkdir -p "$AS"/{.claude-plugin,skills/lib,tests/fixtures,tests/mocks,docs,.github/workflows}
git -C "$AS" init -q
```
Expected: `$AS/.git` exists.

- [ ] **Step 2: Write `.gitignore`**

File `/home/admin/repos/github/freaxnx01/public/agent-skills/.gitignore`:
```gitignore
.act/
coverage/
*.tmp
*.log
.DS_Store
```

- [ ] **Step 3: Write `.editorconfig`**

File `/home/admin/repos/github/freaxnx01/public/agent-skills/.editorconfig`:
```ini
root = true

[*]
charset = utf-8
end_of_line = lf
insert_final_newline = true
trim_trailing_whitespace = true
indent_style = space
indent_size = 2

[*.sh]
indent_style = space
indent_size = 2

[*.md]
trim_trailing_whitespace = false
```

- [ ] **Step 4: Write the plugin manifest**

File `/home/admin/repos/github/freaxnx01/public/agent-skills/.claude-plugin/plugin.json`:
```json
{
  "name": "agent-skills",
  "version": "0.1.0",
  "description": "Personal workflow skills: capture an idea, evaluate it into a GitHub issue, plan a sprint, and review the agent's PR. Feeds the agent-pipeline CI.",
  "author": { "name": "freaxnx01" }
}
```

- [ ] **Step 5: Write `VERSION`**

File `/home/admin/repos/github/freaxnx01/public/agent-skills/VERSION`:
```
0.1.0
```

- [ ] **Step 6: Commit**

```bash
AS=/home/admin/repos/github/freaxnx01/public/agent-skills
git -C "$AS" add -A
git -C "$AS" commit -q -m "chore: scaffold agent-skills plugin repo"
```
Expected: one commit created.

---

### Task 2: Test harness + `gh` mock

This task builds the Layer-1 harness *first* so every helper can be TDD'd against it.

**Files:**
- Create: `/home/admin/repos/github/freaxnx01/public/agent-skills/tests/mocks/gh-mock.sh`
- Create: `/home/admin/repos/github/freaxnx01/public/agent-skills/tests/run-skill-tests.sh`

- [ ] **Step 1: Write the `gh` mock**

File `/home/admin/repos/github/freaxnx01/public/agent-skills/tests/mocks/gh-mock.sh`:
```bash
#!/usr/bin/env bash
# Canned `gh` responses for Layer-1 tests. Behaviour selected via $GH_MOCK_CASE.
set -euo pipefail
IFS=$'\n\t'

sub="${1:-}"
case "$sub" in
  issue)
    case "${2:-}" in
      create) echo "https://github.com/freaxnx01/demo/issues/42" ;;
      view)   echo '{"number":42,"title":"Demo","body":"## Goal\nx","labels":[]}' ;;
      *) echo "gh-mock: unknown issue subcommand: ${2:-}" >&2; exit 64 ;;
    esac
    ;;
  pr)
    echo '{"number":7,"title":"feat: demo","body":"Closes #42","isDraft":true,"files":[{"path":"src/a.cs"}]}'
    ;;
  project)
    case "${2:-}" in
      item-add)  echo '{"id":"PVTI_item123"}' ;;
      item-edit) echo '{"id":"PVTI_item123"}' ;;
      item-list) echo '{"items":[{"content":{"number":42,"title":"Demo"},"status":"Todo"}]}' ;;
      *) echo "gh-mock: unknown project subcommand: ${2:-}" >&2; exit 64 ;;
    esac
    ;;
  *) echo "gh-mock: unknown command: $sub" >&2; exit 64 ;;
esac
```

- [ ] **Step 2: Write the test runner**

File `/home/admin/repos/github/freaxnx01/public/agent-skills/tests/run-skill-tests.sh`:
```bash
#!/usr/bin/env bash
# Layer-1 tests: source lib helpers, override `gh` with the mock, assert outputs.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/skills/lib"
MOCK="$ROOT/tests/mocks/gh-mock.sh"

PASS=0 FAIL=0

# Intercept `gh` for every helper that shells out to it.
gh() { "$MOCK" "$@"; }
export -f gh

assert_eq() { # <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); printf 'FAIL %s\n  expected: %q\n  actual:   %q\n' "$1" "$2" "$3" >&2
  fi
}
assert_contains() { # <label> <needle> <haystack>
  if [[ "$3" == *"$2"* ]]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); printf 'FAIL %s\n  missing: %q\n  in:      %q\n' "$1" "$2" "$3" >&2
  fi
}

# Test files are sourced here as they are added in later tasks.
for t in "$ROOT"/tests/cases/*.sh; do
  [[ -e "$t" ]] || continue
  # shellcheck disable=SC1090
  source "$t"
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
```

- [ ] **Step 3: Create the empty cases dir with a `.gitkeep`**

```bash
AS=/home/admin/repos/github/freaxnx01/public/agent-skills
mkdir -p "$AS/tests/cases"
: > "$AS/tests/cases/.gitkeep"
chmod +x "$AS/tests/mocks/gh-mock.sh" "$AS/tests/run-skill-tests.sh"
```

- [ ] **Step 4: Run the (empty) harness to verify it is green**

Run: `bash /home/admin/repos/github/freaxnx01/public/agent-skills/tests/run-skill-tests.sh`
Expected: `0 passed, 0 failed` and exit 0.

- [ ] **Step 5: Commit**

```bash
AS=/home/admin/repos/github/freaxnx01/public/agent-skills
git -C "$AS" add -A
git -C "$AS" commit -q -m "test: add Layer-1 harness and gh mock"
```

---

### Task 3: `ideas.sh` — append entry (TDD)

**Files:**
- Test: `/home/admin/repos/github/freaxnx01/public/agent-skills/tests/cases/ideas-append.sh`
- Create: `/home/admin/repos/github/freaxnx01/public/agent-skills/skills/lib/ideas.sh`

- [ ] **Step 1: Write the failing test**

File `/home/admin/repos/github/freaxnx01/public/agent-skills/tests/cases/ideas-append.sh`:
```bash
# shellcheck disable=SC1090
source "$LIB/ideas.sh"

tmpf="$(mktemp)"; trap 'rm -f "$tmpf"' RETURN
IDEAS_TODAY=2026-06-08 id="$(ideas_append "$tmpf" "Add 24h SRF cache" "cuts API calls" "free-form body")"

assert_eq "append:id"        "2026-06-08-add-24h-srf-cache" "$id"
body="$(cat "$tmpf")"
assert_contains "append:title"  "## Add 24h SRF cache"        "$body"
assert_contains "append:status" "status: raw"                 "$body"
assert_contains "append:value"  "- value: cuts API calls"     "$body"
assert_contains "append:body"   "free-form body"              "$body"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash /home/admin/repos/github/freaxnx01/public/agent-skills/tests/run-skill-tests.sh`
Expected: FAIL — `ideas.sh` does not exist / `ideas_append: command not found`.

- [ ] **Step 3: Write the minimal implementation**

File `/home/admin/repos/github/freaxnx01/public/agent-skills/skills/lib/ideas.sh`:
```bash
#!/usr/bin/env bash
# Read/append/update entries in a repo's docs/ideas.md.
# Sourced by skills and tests; never executed directly.
set -euo pipefail
IFS=$'\n\t'

# ideas_append <file> <title> <value> <body> -> prints the generated id
ideas_append() {
  local file="$1" title="$2" value="$3" body="${4:-}"
  local today slug id
  today="${IDEAS_TODAY:-$(date +%F)}"
  slug="$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-*//;s/-*$//')"
  id="${today}-${slug}"
  mkdir -p "$(dirname "$file")"
  [[ -f "$file" ]] || printf '# Ideas\n' > "$file"
  {
    printf '\n## %s\n' "$title"
    printf -- '- id: %s · captured: %s · status: raw\n' "$id" "$today"
    printf -- '- value: %s\n' "$value"
    [[ -n "$body" ]] && printf '%s\n' "$body"
  } >> "$file"
  printf '%s\n' "$id"
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash /home/admin/repos/github/freaxnx01/public/agent-skills/tests/run-skill-tests.sh`
Expected: `5 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
AS=/home/admin/repos/github/freaxnx01/public/agent-skills
git -C "$AS" add -A
git -C "$AS" commit -q -m "feat(lib): ideas_append writes a raw idea entry"
```

---

### Task 4: `ideas.sh` — list + set status (TDD)

**Files:**
- Test: `/home/admin/repos/github/freaxnx01/public/agent-skills/tests/cases/ideas-list-status.sh`
- Modify: `/home/admin/repos/github/freaxnx01/public/agent-skills/skills/lib/ideas.sh`

- [ ] **Step 1: Write the failing test**

File `/home/admin/repos/github/freaxnx01/public/agent-skills/tests/cases/ideas-list-status.sh`:
```bash
# shellcheck disable=SC1090
source "$LIB/ideas.sh"

tmpf="$(mktemp)"; trap 'rm -f "$tmpf"' RETURN
IDEAS_TODAY=2026-06-08 ideas_append "$tmpf" "First idea" "v1" "" >/dev/null
IDEAS_TODAY=2026-06-08 ideas_append "$tmpf" "Second idea" "v2" "" >/dev/null

list_all="$(ideas_list "$tmpf")"
assert_contains "list:has-first"  "2026-06-08-first-idea"  "$list_all"
assert_contains "list:has-second" "2026-06-08-second-idea" "$list_all"

ideas_set_status "$tmpf" "2026-06-08-first-idea" "issued(#42)"
raw_only="$(ideas_list "$tmpf" raw)"
assert_contains "list:raw-has-second"  "2026-06-08-second-idea" "$raw_only"
if [[ "$raw_only" == *"2026-06-08-first-idea"* ]]; then
  FAIL=$((FAIL+1)); echo "FAIL list:raw-excludes-first (first should no longer be raw)" >&2
else PASS=$((PASS+1)); fi

issued="$(ideas_list "$tmpf" "issued(#42)")"
assert_contains "list:issued-has-first" "2026-06-08-first-idea" "$issued"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash /home/admin/repos/github/freaxnx01/public/agent-skills/tests/run-skill-tests.sh`
Expected: FAIL — `ideas_list` / `ideas_set_status: command not found`.

- [ ] **Step 3: Append the implementation**

Append to `/home/admin/repos/github/freaxnx01/public/agent-skills/skills/lib/ideas.sh`:
```bash

# ideas_list <file> [status] -> tab-separated "id<TAB>status<TAB>title" per entry
ideas_list() {
  local file="$1" want="${2:-}"
  [[ -f "$file" ]] || return 0
  awk -v want="$want" '
    /^## / { title = substr($0, 4) }
    /^- id: / {
      match($0, /id: [^ ]+/);    id = substr($0, RSTART + 4, RLENGTH - 4)
      match($0, /status: .*$/);  st = substr($0, RSTART + 8)
      if (want == "" || st == want) printf "%s\t%s\t%s\n", id, st, title
    }
  ' "$file"
}

# ideas_set_status <file> <id> <status> -> rewrites the matching entry's status
ideas_set_status() {
  local file="$1" id="$2" status="$3" tmp
  tmp="$(mktemp)"
  awk -v id="$id" -v st="$status" '
    /^- id: / && index($0, "id: " id " ·") {
      sub(/status: .*$/, "status: " st)
    }
    { print }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash /home/admin/repos/github/freaxnx01/public/agent-skills/tests/run-skill-tests.sh`
Expected: all assertions pass (`0 failed`).

- [ ] **Step 5: Commit**

```bash
AS=/home/admin/repos/github/freaxnx01/public/agent-skills
git -C "$AS" add -A
git -C "$AS" commit -q -m "feat(lib): ideas_list and ideas_set_status"
```

---

### Task 5: `gh-helpers.sh` (TDD)

**Files:**
- Test: `/home/admin/repos/github/freaxnx01/public/agent-skills/tests/cases/gh-helpers.sh`
- Create: `/home/admin/repos/github/freaxnx01/public/agent-skills/skills/lib/gh-helpers.sh`

- [ ] **Step 1: Write the failing test**

File `/home/admin/repos/github/freaxnx01/public/agent-skills/tests/cases/gh-helpers.sh`:
```bash
# shellcheck disable=SC1090
source "$LIB/gh-helpers.sh"

bodyf="$(mktemp)"; printf '## Goal\nx\n' > "$bodyf"; trap 'rm -f "$bodyf"' RETURN
url="$(gh_create_issue "Add cache" "$bodyf" "ai-implement")"
assert_eq "gh:create-url" "https://github.com/freaxnx01/demo/issues/42" "$url"

num="$(gh_issue_number_from_url "$url")"
assert_eq "gh:num" "42" "$num"

body="$(gh_issue_body 42)"
assert_contains "gh:body" "## Goal" "$body"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash /home/admin/repos/github/freaxnx01/public/agent-skills/tests/run-skill-tests.sh`
Expected: FAIL — `gh_create_issue: command not found`.

- [ ] **Step 3: Write the implementation**

File `/home/admin/repos/github/freaxnx01/public/agent-skills/skills/lib/gh-helpers.sh`:
```bash
#!/usr/bin/env bash
# Thin wrappers around the gh CLI. Sourced; never executed directly.
# `gh` is the real CLI in production and a shell-function mock in tests.
set -euo pipefail
IFS=$'\n\t'

# gh_create_issue <title> <body-file> <labels-csv> -> prints the new issue URL
gh_create_issue() {
  local title="$1" body_file="$2" labels="$3"
  : "${title:?title required}"; : "${body_file:?body file required}"
  gh issue create --title "$title" --body-file "$body_file" --label "$labels"
}

# gh_issue_number_from_url <url> -> trailing number
gh_issue_number_from_url() {
  printf '%s\n' "${1##*/}"
}

# gh_issue_body <number> -> issue body text
gh_issue_body() {
  gh issue view "$1" --json body --jq '.body'
}
```

Note: the mock returns a full JSON object for `issue view`; `--jq` is ignored by the mock, so `gh_issue_body` returns the JSON. The test asserts `## Goal` is *contained*, which holds for both the mock JSON and real `--jq` output. Real `gh` honours `--jq` and returns just the body.

- [ ] **Step 4: Run to verify it passes**

Run: `bash /home/admin/repos/github/freaxnx01/public/agent-skills/tests/run-skill-tests.sh`
Expected: `0 failed`.

- [ ] **Step 5: Commit**

```bash
AS=/home/admin/repos/github/freaxnx01/public/agent-skills
git -C "$AS" add -A
git -C "$AS" commit -q -m "feat(lib): gh-helpers for issue create/read"
```

---

### Task 6: `board.sh` (TDD)

**Files:**
- Test: `/home/admin/repos/github/freaxnx01/public/agent-skills/tests/cases/board.sh`
- Create: `/home/admin/repos/github/freaxnx01/public/agent-skills/skills/lib/board.sh`

- [ ] **Step 1: Write the failing test**

File `/home/admin/repos/github/freaxnx01/public/agent-skills/tests/cases/board.sh`:
```bash
# shellcheck disable=SC1090
source "$LIB/board.sh"

# Missing required config must fail fast (exit non-zero).
if ( BACKLOG_PROJECT_NUMBER="" board_add_issue "https://x/issues/1" ) 2>/dev/null; then
  FAIL=$((FAIL+1)); echo "FAIL board:requires-project-number" >&2
else PASS=$((PASS+1)); fi

out="$(BACKLOG_PROJECT_NUMBER=5 BACKLOG_PROJECT_OWNER=freaxnx01 \
       board_add_issue "https://github.com/freaxnx01/demo/issues/42")"
assert_contains "board:add" "PVTI_item123" "$out"

statuses="$(BACKLOG_PROJECT_NUMBER=5 BACKLOG_PROJECT_OWNER=freaxnx01 board_list_open)"
assert_contains "board:list" "Demo" "$statuses"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash /home/admin/repos/github/freaxnx01/public/agent-skills/tests/run-skill-tests.sh`
Expected: FAIL — `board_add_issue: command not found`.

- [ ] **Step 3: Write the implementation**

File `/home/admin/repos/github/freaxnx01/public/agent-skills/skills/lib/board.sh`:
```bash
#!/usr/bin/env bash
# Operations on the freaxnx01 "Backlog" GitHub Project. Sourced; never run directly.
# Requires BACKLOG_PROJECT_NUMBER and BACKLOG_PROJECT_OWNER in the environment.
set -euo pipefail
IFS=$'\n\t'

_board_require() {
  : "${BACKLOG_PROJECT_NUMBER:?BACKLOG_PROJECT_NUMBER must be set}"
  : "${BACKLOG_PROJECT_OWNER:?BACKLOG_PROJECT_OWNER must be set}"
}

# board_add_issue <issue-url> -> adds the issue to the board, prints gh JSON
board_add_issue() {
  _board_require
  gh project item-add "$BACKLOG_PROJECT_NUMBER" \
    --owner "$BACKLOG_PROJECT_OWNER" --url "$1" --format json
}

# board_list_open -> prints the board items as JSON
board_list_open() {
  _board_require
  gh project item-list "$BACKLOG_PROJECT_NUMBER" \
    --owner "$BACKLOG_PROJECT_OWNER" --format json
}
```

Note: `board_set_status` (writing a status field) needs the project's field-id and option-id, which are repo-specific and discovered at runtime via `gh project field-list`. It is deferred to the plan-sprint skill task, where the SKILL.md walks the user through resolving those ids the first time. The mock's `item-add`/`item-list` cover the tested paths here.

- [ ] **Step 4: Run to verify it passes**

Run: `bash /home/admin/repos/github/freaxnx01/public/agent-skills/tests/run-skill-tests.sh`
Expected: `0 failed`.

- [ ] **Step 5: Commit**

```bash
AS=/home/admin/repos/github/freaxnx01/public/agent-skills
git -C "$AS" add -A
git -C "$AS" commit -q -m "feat(lib): board add/list helpers for the Backlog project"
```

---

### Task 7: Shared docs — `ideas-schema.md` + `spec-template.md`

**Files:**
- Create: `/home/admin/repos/github/freaxnx01/public/agent-skills/skills/lib/ideas-schema.md`
- Create: `/home/admin/repos/github/freaxnx01/public/agent-skills/skills/lib/spec-template.md`

- [ ] **Step 1: Write the ideas schema**

File `/home/admin/repos/github/freaxnx01/public/agent-skills/skills/lib/ideas-schema.md`:
```markdown
# ideas.md entry schema

One H2 per idea. The first two list items are the metadata line and the value
line; everything after is free-form body. `capture-idea` writes entries;
`evaluate-to-issue` and `groom-backlog` update `status`.

\`\`\`markdown
## <title>
- id: <YYYY-MM-DD-slug> · captured: <YYYY-MM-DD> · status: raw
- value: <one-line why it matters>
<free-form body, optional>
\`\`\`

`status` transitions: `raw` → `evaluated` → `issued(#N)` → `dropped`.

- `id` is `<capture-date>-<slugified-title>`; slug is lowercase, non-alphanumerics
  collapsed to single `-`, leading/trailing `-` trimmed.
- The metadata line uses ` · ` separators verbatim — `ideas_set_status` matches
  `id: <id> ·` to find the entry, so do not reformat it by hand.
```

- [ ] **Step 2: Write the spec template (migrated from agent-pipeline DESIGN.md)**

File `/home/admin/repos/github/freaxnx01/public/agent-skills/skills/lib/spec-template.md`:
```markdown
## Goal
<1-2 sentences. What does done look like?>

## Affected files (explicit paths)
- path/to/file1 — <one-line role: "primary change" / "interface update" / "tests">
- path/to/file2 — <...>

## Out of scope
- DO NOT touch X
- DO NOT refactor Y unless directly required

## Existing patterns to follow
- <link or path to similar code already in the repo, if any>
- <or: "this is greenfield — no existing pattern to mirror">

## Acceptance criteria
- [ ] criterion 1
- [ ] criterion 2
- [ ] tests pass
- [ ] formatter clean

## Test expectations
<which test project, what new tests, what existing tests must still pass>

## Constraints / context
<anything not in CLAUDE.md that the headless agent needs to know>
```

- [ ] **Step 3: Commit**

```bash
AS=/home/admin/repos/github/freaxnx01/public/agent-skills
git -C "$AS" add -A
git -C "$AS" commit -q -m "docs(lib): ideas schema and issue spec template"
```

---

### Task 8: Scaffold — justfile, lint workflow, changelog, docs

**Files:**
- Create: `justfile`, `cliff.toml`, `CHANGELOG.md`, `README.md`, `.github/workflows/lint.yml`, `docs/DESIGN.md`, `docs/DECISIONS.md` (all under `$AS`)

- [ ] **Step 1: Write the justfile**

File `/home/admin/repos/github/freaxnx01/public/agent-skills/justfile`:
```just
# Show the documented recipe set
default:
    @just --list --unsorted

# actionlint + shellcheck on workflows and shell libs
lint:
    actionlint
    mapfile -t files < <(find skills/lib tests -type f -name '*.sh' | sort); \
    shellcheck -x -e SC1091 "${files[@]}"

# Layer-1 fixture tests (<5s)
test:
    bash tests/run-skill-tests.sh

# Current version
version:
    @cat VERSION

# Regenerate the changelog from Conventional Commits
changelog:
    git-cliff --output CHANGELOG.md
```

- [ ] **Step 2: Write `cliff.toml`**

File `/home/admin/repos/github/freaxnx01/public/agent-skills/cliff.toml`:
```toml
[changelog]
header = "# Changelog\n\nAll notable changes to this project are documented here.\n"
body = """
{% for group, commits in commits | group_by(attribute="group") %}
### {{ group | upper_first }}
{% for commit in commits %}
- {{ commit.message | upper_first }}
{% endfor %}
{% endfor %}
"""
trim = true

[git]
conventional_commits = true
filter_unconventional = true
commit_parsers = [
  { message = "^feat", group = "Added" },
  { message = "^fix", group = "Fixed" },
  { message = "^docs", group = "Documentation" },
  { message = "^test", group = "Testing" },
  { message = "^chore", group = "Chore" },
]
tag_pattern = "v[0-9]*"
```

- [ ] **Step 3: Write `CHANGELOG.md`**

File `/home/admin/repos/github/freaxnx01/public/agent-skills/CHANGELOG.md`:
```markdown
# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com); versioning is [SemVer](https://semver.org).

## [Unreleased]

### Added
- Plugin scaffold and Layer-1 test harness.
- Shared `lib/` helpers: `ideas.sh`, `gh-helpers.sh`, `board.sh`.
- Daily-loop skills: capture-idea, evaluate-to-issue, plan-sprint, review-pr.
```

- [ ] **Step 4: Write the lint workflow**

File `/home/admin/repos/github/freaxnx01/public/agent-skills/.github/workflows/lint.yml`:
```yaml
name: lint
on:
  pull_request:
  push:
    branches: [main]
permissions:
  contents: read
jobs:
  actionlint:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@b4ffde65f46336ab88eb53be808477a3936bae11  # v4.1.1
      - uses: rhysd/actionlint@b4ffde65f46336ab88eb53be808477a3936bae11  # placeholder SHA — Renovate promotes
  shellcheck:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@b4ffde65f46336ab88eb53be808477a3936bae11  # v4.1.1
      - run: |
          mapfile -t files < <(find skills/lib tests -type f -name '*.sh' | sort)
          [[ ${#files[@]} -gt 0 ]] || { echo "No shell scripts — skipping."; exit 0; }
          shellcheck -x -e SC1091 "${files[@]}"
```

Note for the executor: the `rhysd/actionlint` SHA above is a placeholder. Before committing, resolve the real latest-release SHA with `gh api repos/rhysd/actionlint/commits/main --jq .sha` (or the pinned release tag's SHA) and replace it, keeping the `# vX.Y.Z` comment. Do not ship a placeholder SHA.

- [ ] **Step 5: Write `README.md`**

File `/home/admin/repos/github/freaxnx01/public/agent-skills/README.md`:
```markdown
# agent-skills

Personal Claude Code skills for the dev funnel: **capture an idea → evaluate it
into a GitHub issue → plan a sprint → review the agent's PR**. They run locally in
your Claude Code session and feed the [agent-pipeline](https://github.com/freaxnx01/agent-pipeline) CI.

## Skills

| Skill | What it does |
|---|---|
| `capture-idea` | Append a fuzzy idea to the current repo's `docs/ideas.md`. |
| `evaluate-to-issue` | Path-discover, fill the spec template, and create a GitHub issue — or decide to do it locally / refuse a vague spec. |
| `plan-sprint` | Pick the next sprint set from the Backlog board. |
| `review-pr` | Review the agent's PR against its originating issue spec and merge / request changes / close. |

## Install

This repo is a Claude Code plugin. Add it as a local plugin (see Claude Code plugin docs); the skills become available in every repo.

## Develop

- `just test` — Layer-1 fixture tests (<5s)
- `just lint` — actionlint + shellcheck

Config the board skills expect: `BACKLOG_PROJECT_NUMBER`, `BACKLOG_PROJECT_OWNER`.
```

- [ ] **Step 6: Promote the design + decisions docs**

Copy the spec into the new repo's `docs/DESIGN.md` and start an ADR log.

```bash
AS=/home/admin/repos/github/freaxnx01/public/agent-skills
SPEC=/home/admin/repos/github/freaxnx01/public/agent-pipeline/.worktrees/skills/docs/superpowers/specs/2026-06-08-agent-skills-design.md
cp "$SPEC" "$AS/docs/DESIGN.md"
```

File `/home/admin/repos/github/freaxnx01/public/agent-skills/docs/DECISIONS.md`:
```markdown
# Decisions (ADR log)

## ADR-001: Dedicated plugin repo, hybrid skill design
- **Context:** Personal workflow skills (capture/evaluate/plan/review) needed a home.
- **Decision:** A standalone `agent-skills` repo packaged as a Claude Code plugin.
  Judgment lives in `SKILL.md`; deterministic ops live in fixture-tested `lib/` bash.
- **Why:** Local/interactive and cross-stack — wrong fit for agent-pipeline (CI-only)
  or ai-instructions (stack conventions). A plugin installs once and is available
  everywhere. The bash split makes the family Layer-1 testable.

## ADR-002: Substrate is local md → Issues → Backlog board
- **Decision:** Raw capture in per-repo `docs/ideas.md`; evaluation promotes to a
  GitHub Issue; sprint planning operates on the "Backlog" Project.
- **Why:** Low-friction capture, clean handoff to agent-pipeline, board reflects the
  committed work.
```

- [ ] **Step 7: Lint and test, then commit**

Run:
```bash
AS=/home/admin/repos/github/freaxnx01/public/agent-skills
( cd "$AS" && shellcheck -x -e SC1091 skills/lib/*.sh tests/run-skill-tests.sh tests/mocks/gh-mock.sh )
bash "$AS/tests/run-skill-tests.sh"
```
Expected: shellcheck clean; tests `0 failed`.

```bash
AS=/home/admin/repos/github/freaxnx01/public/agent-skills
git -C "$AS" add -A
git -C "$AS" commit -q -m "chore: justfile, lint workflow, changelog, docs scaffold"
```

---

## PHASE 1 — Daily-loop skills

> SKILL.md files are prose deliverables, not unit-tested. Each task validates that
> (a) the frontmatter parses, and (b) every `lib/` function the skill references
> actually exists. Every SKILL.md ends with the **self-improvement closing** from
> the spec.

### Task 9: `capture-idea` skill

**Files:**
- Create: `/home/admin/repos/github/freaxnx01/public/agent-skills/skills/capture-idea/SKILL.md`

- [ ] **Step 1: Write the skill**

File `/home/admin/repos/github/freaxnx01/public/agent-skills/skills/capture-idea/SKILL.md`:
```markdown
---
name: capture-idea
description: Use when the user wants to jot down a feature idea, improvement, or "we should…" thought without acting on it now — appends a structured entry to the current repo's docs/ideas.md with zero friction.
---

# Capture Idea

Capture a fuzzy idea into `docs/ideas.md` for the current repo. Do **not** evaluate,
estimate, or expand it — just record it so it is not lost. Evaluation is a separate
skill (`evaluate-to-issue`).

## Steps

1. Determine the idea text from the user's message. If the request is a single
   clear sentence, use it directly — do not ask questions.
2. Derive a short **title** (≤6 words) and a one-line **value** (why it matters). If
   value is not obvious from the message, leave it as the title restated — do not
   interrogate the user.
3. Append the entry using the shared helper:

   \`\`\`bash
   source "${CLAUDE_PLUGIN_ROOT:-.}/skills/lib/ideas.sh"
   ideas_append "docs/ideas.md" "<title>" "<value>" "<optional body>"
   \`\`\`

4. Confirm to the user with the returned id and the file path. Stop.

## Rules

- Only ask a clarifying question if the title would otherwise be genuinely
  ambiguous (e.g. the message is one word). Default to capturing.
- Never create a GitHub issue here. Never modify code.
- One idea per invocation unless the user clearly lists several — then append each.

## Self-improvement

If you hit a blocker while running this skill, solve it, then update **this**
`SKILL.md` (or `skills/lib/ideas.sh` if the helper is at fault) so the blocker can't
recur — smallest durable fix, scoped to this skill's own files, landed as a normal
commit on a branch. Never push or merge automatically. Tell the user what you changed.
```

- [ ] **Step 2: Validate frontmatter + referenced helper**

Run:
```bash
AS=/home/admin/repos/github/freaxnx01/public/agent-skills
head -3 "$AS/skills/capture-idea/SKILL.md" | grep -q '^name: capture-idea' && echo OK-name
grep -q 'ideas_append' "$AS/skills/lib/ideas.sh" && echo OK-helper-exists
```
Expected: `OK-name` and `OK-helper-exists`.

- [ ] **Step 3: Commit**

```bash
AS=/home/admin/repos/github/freaxnx01/public/agent-skills
git -C "$AS" add -A
git -C "$AS" commit -q -m "feat(skill): capture-idea"
```

---

### Task 10: `evaluate-to-issue` skill (keystone)

**Files:**
- Create: `/home/admin/repos/github/freaxnx01/public/agent-skills/skills/evaluate-to-issue/SKILL.md`

- [ ] **Step 1: Write the skill**

File `/home/admin/repos/github/freaxnx01/public/agent-skills/skills/evaluate-to-issue/SKILL.md`:
```markdown
---
name: evaluate-to-issue
description: Use when the user wants to turn an idea (from docs/ideas.md) or a fuzzy intent into a precise, delegatable GitHub issue — runs path discovery, fills the issue spec template, and creates the issue, or decides to do it locally (Mode #0) or refuses a vague spec.
---

# Evaluate to Issue

Turn fuzzy intent into a precise, delegatable spec — or decide it is not worth
delegating. This is an **exploration → spec crystallization** workflow. Filling in
`Affected files` correctly is the most important job; do the discovery now, in this
session, with the tools you have.

## Inputs

- An idea id from `docs/ideas.md`, OR fresh fuzzy intent in the user's message.

## Steps

1. **Resolve the idea.** If given an id, read the entry:
   \`\`\`bash
   source "${CLAUDE_PLUGIN_ROOT:-.}/skills/lib/ideas.sh"
   ideas_list "docs/ideas.md"   # find the entry; read its body from the file
   \`\`\`
   Otherwise work from the user's message.

2. **Path discovery (do not skip, do not delegate this).** Use Grep/ripgrep for
   terms, Glob for filename patterns, Read to confirm relevance, and LSP
   `findReferences`/`goToDefinition` when a language plugin is loaded. Be
   opinionated: if a search returns many candidates, narrow with focused
   follow-ups rather than dumping the list.

3. **Surface negative findings explicitly.** State what you searched for and did
   not find ("no existing time-based cache pattern in repo"). Distinguish "no
   match" from "greenfield" — if nothing is found, ask whether this is new code or
   whether the codebase uses different terminology.

4. **Fill the spec template** at `${CLAUDE_PLUGIN_ROOT:-.}/skills/lib/spec-template.md`.
   Read it, then produce a fully-filled copy: Goal, Affected files (explicit paths
   with one-line roles), Out of scope, Existing patterns to follow, Acceptance
   criteria, Test expectations, Constraints.

5. **Decide the outcome:**
   - **Mode #1 (delegate):** every section can be filled with confidence → continue.
   - **Mode #0 (do it now):** the change is small and you have everything to do it
     locally → tell the user, and do not create an issue.
   - **Refuse:** the user cannot approve a concrete file list + acceptance criteria
     → say so and recommend more exploration or Mode #0. A refusal is a success.

6. **(Mode #1) Get approval, then create.** Show the full rendered issue body.
   Only after explicit approval:
   \`\`\`bash
   source "${CLAUDE_PLUGIN_ROOT:-.}/skills/lib/gh-helpers.sh"
   source "${CLAUDE_PLUGIN_ROOT:-.}/skills/lib/board.sh"
   url="$(gh_create_issue "<title>" "<rendered-body-file>" "ai-implement")"
   board_add_issue "$url"        # requires BACKLOG_PROJECT_NUMBER / _OWNER
   \`\`\`
   Then mark the source idea, if any:
   \`\`\`bash
   source "${CLAUDE_PLUGIN_ROOT:-.}/skills/lib/ideas.sh"
   ideas_set_status "docs/ideas.md" "<idea-id>" "issued(#$(gh_issue_number_from_url "$url"))"
   \`\`\`

7. Report the issue URL and the board state. Stop.

## Rules

- Never auto-submit an issue — approval gate is mandatory.
- Never invent labels; use the pipeline's (`ai-implement`, `model:*`).
- If `BACKLOG_PROJECT_NUMBER`/`_OWNER` are unset, create the issue but tell the
  user the board step was skipped and how to set them — do not guess the project.

## Self-improvement

If you hit a blocker while running this skill, solve it, then update **this**
`SKILL.md` (or the relevant `skills/lib/*.sh` it owns) so the blocker can't recur —
smallest durable fix, scoped to this skill's files, landed as a normal commit on a
branch. Never push or merge automatically. Tell the user what you changed.
```

- [ ] **Step 2: Validate frontmatter + referenced helpers exist**

Run:
```bash
AS=/home/admin/repos/github/freaxnx01/public/agent-skills
grep -q '^name: evaluate-to-issue' "$AS/skills/evaluate-to-issue/SKILL.md" && echo OK-name
for fn in ideas_list gh_create_issue board_add_issue ideas_set_status gh_issue_number_from_url; do
  grep -rq "$fn()" "$AS/skills/lib" && echo "OK-$fn" || echo "MISSING-$fn"
done
```
Expected: `OK-name` and `OK-` for every function (no `MISSING-`).

- [ ] **Step 3: Commit**

```bash
AS=/home/admin/repos/github/freaxnx01/public/agent-skills
git -C "$AS" add -A
git -C "$AS" commit -q -m "feat(skill): evaluate-to-issue (keystone)"
```

---

### Task 11: `plan-sprint` skill

**Files:**
- Create: `/home/admin/repos/github/freaxnx01/public/agent-skills/skills/plan-sprint/SKILL.md`

- [ ] **Step 1: Write the skill**

File `/home/admin/repos/github/freaxnx01/public/agent-skills/skills/plan-sprint/SKILL.md`:
```markdown
---
name: plan-sprint
description: Use when the user asks "what should I work on next?" or wants to pick the next sprint — reads open issues on the Backlog project, helps choose a worthwhile set, sets their board status, and optionally stamps ai-implement to kick the pipeline.
---

# Plan Sprint

Help the user choose the next sprint from the Backlog board, then record the choice.

## Steps

1. **Read the board.**
   \`\`\`bash
   source "${CLAUDE_PLUGIN_ROOT:-.}/skills/lib/board.sh"
   board_list_open    # requires BACKLOG_PROJECT_NUMBER / _OWNER
   \`\`\`
   Parse the JSON; for each item show number, title, current status, and any
   `Blocked by:` markers from the issue body (read with `gh issue view <n>`).

2. **Present a ranked shortlist.** Exclude items still blocked. Surface age and any
   priority field. Recommend a set sized to what the user asks for (default: ask
   "how many?"). Be opinionated about sequencing.

3. **Confirm the selection** with the user. Do not proceed without it.

4. **Record the choice.** For each selected issue, set its board status to the
   sprint column and, if the user wants the pipeline to start, add `ai-implement`:
   \`\`\`bash
   gh issue edit <n> --add-label ai-implement     # only if the user opts in
   \`\`\`
   To set the board status field, resolve the field/option ids once with
   `gh project field-list "$BACKLOG_PROJECT_NUMBER" --owner "$BACKLOG_PROJECT_OWNER" --format json`,
   then `gh project item-edit`. Record the resolved ids in `docs/DECISIONS.md` so
   future runs skip discovery.

5. Report the committed sprint list and which issues were handed to the pipeline.

## Rules

- Only add `ai-implement` when the user explicitly opts in — it triggers a real run.
- Never include blocked issues in a sprint.

## Self-improvement

If you hit a blocker while running this skill, solve it, then update **this**
`SKILL.md` (or the `skills/lib/*.sh` it owns) so it can't recur — smallest durable
fix, scoped to this skill's files, landed as a normal commit on a branch. Never push
or merge automatically. Tell the user what you changed.
```

- [ ] **Step 2: Validate**

Run:
```bash
AS=/home/admin/repos/github/freaxnx01/public/agent-skills
grep -q '^name: plan-sprint' "$AS/skills/plan-sprint/SKILL.md" && echo OK-name
grep -q 'board_list_open()' "$AS/skills/lib/board.sh" && echo OK-helper
```
Expected: `OK-name` and `OK-helper`.

- [ ] **Step 3: Commit**

```bash
AS=/home/admin/repos/github/freaxnx01/public/agent-skills
git -C "$AS" add -A
git -C "$AS" commit -q -m "feat(skill): plan-sprint"
```

---

### Task 12: `review-pr` skill

**Files:**
- Create: `/home/admin/repos/github/freaxnx01/public/agent-skills/skills/review-pr/SKILL.md`

- [ ] **Step 1: Write the skill**

File `/home/admin/repos/github/freaxnx01/public/agent-skills/skills/review-pr/SKILL.md`:
```markdown
---
name: review-pr
description: Use when the agent (or anyone) has opened a PR and the user wants to review it against its originating issue spec before merging — checks acceptance criteria, scope creep, and gate status, then merges / requests changes / closes on the user's decision.
---

# Review PR

Review a PR **against the issue it closes**. This is spec-conformance plus the
merge decision — distinct from `/code-review` (line-level) and the pipeline's
`pre-preview` self-review. You may *call* `/code-review` as one input.

## Steps

1. **Load the PR and its issue.**
   \`\`\`bash
   source "${CLAUDE_PLUGIN_ROOT:-.}/skills/lib/gh-helpers.sh"
   gh pr view <pr> --json number,title,body,isDraft,files,statusCheckRollup
   \`\`\`
   Extract the `Closes #N` reference from the PR body; read the issue spec with
   `gh_issue_body N`.

2. **Check conformance:**
   - **Acceptance criteria:** each box in the issue spec — met by the diff?
   - **Scope creep:** are changed files within the spec's "Affected files"? Flag
     extras.
   - **Gates:** CI status green? Draft state correct? If auto-merge is in play, are
     the ADR-002 envelope conditions satisfied?

3. **Optional deep review:** if the diff is risky, invoke `/code-review` and fold
   its findings in.

4. **Present a verdict** — a short table: criterion → met/partial/missing, plus
   scope and gate notes — and recommend one of: **merge**, **request changes**,
   **close**.

5. **Execute the user's decision** (only after they choose):
   - merge: `gh pr merge <pr> --squash` (respect the repo's merge policy)
   - request changes: `gh pr comment <pr> --body "<actionable feedback>"` written
     for the implementing agent (concrete, file-anchored)
   - close: `gh pr close <pr> --comment "<why>"`

6. Report what was done.

## Rules

- The user makes the merge/close call — never decide it yourself.
- Request-changes feedback is for an agent: concrete, file-and-line anchored,
  no vague "improve error handling".
- Paraphrase any quoted source material per the pipeline's constraint.

## Self-improvement

If you hit a blocker while running this skill, solve it, then update **this**
`SKILL.md` (or the `skills/lib/*.sh` it owns) so it can't recur — smallest durable
fix, scoped to this skill's files, landed as a normal commit on a branch. Never push
or merge automatically. Tell the user what you changed.
```

- [ ] **Step 2: Validate**

Run:
```bash
AS=/home/admin/repos/github/freaxnx01/public/agent-skills
grep -q '^name: review-pr' "$AS/skills/review-pr/SKILL.md" && echo OK-name
grep -q 'gh_issue_body()' "$AS/skills/lib/gh-helpers.sh" && echo OK-helper
```
Expected: `OK-name` and `OK-helper`.

- [ ] **Step 3: Commit**

```bash
AS=/home/admin/repos/github/freaxnx01/public/agent-skills
git -C "$AS" add -A
git -C "$AS" commit -q -m "feat(skill): review-pr"
```

---

### Task 13: Generate `CLAUDE.md` + final verification

**Files:**
- Create: `/home/admin/repos/github/freaxnx01/public/agent-skills/CLAUDE.md`

- [ ] **Step 1: Generate CLAUDE.md via the sync skill**

From the new repo, run the `/sync-ai-instructions ci` skill to assemble `CLAUDE.md`
(+ the `.ai/` files) from base + the CI stack overlay. If the skill cannot run
non-interactively in this context, write a minimal placeholder `CLAUDE.md` whose
first line is the source-of-truth banner and which points at `docs/DESIGN.md`, and
note in `docs/DECISIONS.md` that a full sync is pending.

Validate:
```bash
AS=/home/admin/repos/github/freaxnx01/public/agent-skills
test -f "$AS/CLAUDE.md" && echo OK-claude-md
```
Expected: `OK-claude-md`.

- [ ] **Step 2: Full green check — lint + test**

Run:
```bash
AS=/home/admin/repos/github/freaxnx01/public/agent-skills
( cd "$AS" && shellcheck -x -e SC1091 skills/lib/*.sh tests/run-skill-tests.sh tests/mocks/gh-mock.sh )
bash "$AS/tests/run-skill-tests.sh"
ls "$AS"/skills/*/SKILL.md
```
Expected: shellcheck clean; tests `0 failed`; four SKILL.md files listed.

- [ ] **Step 3: Commit**

```bash
AS=/home/admin/repos/github/freaxnx01/public/agent-skills
git -C "$AS" add -A
git -C "$AS" commit -q -m "chore: CLAUDE.md and Phase 0+1 completion"
git -C "$AS" log --oneline
```
Expected: full commit history for Phase 0 + Phase 1.

---

## Done criteria (Phase 0 + Phase 1)

- `just test` → `0 failed` in <5s; `just lint` clean.
- Four skills present with valid frontmatter, each referencing only `lib/`
  functions that exist, each ending with the self-improvement closing.
- `ideas.sh`, `gh-helpers.sh`, `board.sh` covered by fixture tests with `gh` mocked.
- Repo is local only; no remote, nothing pushed.
- Phase 2 (author-chain, pipeline-retro, groom-backlog, triage-failure) remains for
  a follow-up plan.
```
