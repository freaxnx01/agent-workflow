#!/usr/bin/env bash
#
# handoff-index.sh — render the handoff overview index for a repository.
#
# The per-branch `.claude/handoff-<branch-slug>.md` files written by /handoff are
# the source of truth; they are committed and travel with a clone. This script
# derives a read-only *index* from them so a board of parallel sessions can be
# seen at a glance:
#
#   <repo>/.claude/handoffs.md   repo-local overview (gitignored, one per copy)
#   ~/.claude/handoffs.md        machine-wide overview, one section per repo
#
# Derived, never authored: every run regenerates from what is on disk, so N
# sessions handing off at once cannot lose each other's rows (an append-a-row
# index could). Only the calling repo's section of the machine-wide file is
# rewritten; other repos' sections are preserved byte-for-byte.
#
# Usage:
#   handoff-index.sh [--repo <path>] [--repo-index <path>]
#                    [--global-index <path>] [--no-global] [--stdout]
#
#   --repo          any working copy of the repo to index (default: $PWD)
#   --repo-index    where to write the repo-local index
#                   (default: <calling working copy>/.claude/handoffs.md)
#   --global-index  where to write the machine-wide index
#                   (default: $HOME/.claude/handoffs.md)
#   --no-global     skip the machine-wide index
#   --stdout        print the rendered table and write nothing
#
# Exit codes: 0 ok; 2 usage error; 3 --repo is not inside a git repository;
#             4 could not take the lock on the machine-wide index.
set -euo pipefail
IFS=$'\n\t'

REPO_ARG="$PWD"
REPO_INDEX=""
GLOBAL_INDEX="${HOME}/.claude/handoffs.md"
WRITE_GLOBAL=1
TO_STDOUT=0
NEXT_STEP_MAX=110

die_usage() { printf 'usage error: %s\n' "$1" >&2; exit 2; }

while (($# > 0)); do
  case "$1" in
    --repo) REPO_ARG="${2:?--repo needs a path}"; shift 2 ;;
    --repo-index) REPO_INDEX="${2:?--repo-index needs a path}"; shift 2 ;;
    --global-index) GLOBAL_INDEX="${2:?--global-index needs a path}"; shift 2 ;;
    --no-global) WRITE_GLOBAL=0; shift ;;
    --stdout) TO_STDOUT=1; shift ;;
    -h|--help) sed -n '3,32p' "$0"; exit 0 ;;
    *) die_usage "unknown argument: $1" ;;
  esac
done

[[ -d "$REPO_ARG" ]] || die_usage "--repo is not a directory: $REPO_ARG"

# --- locate the repo and its working copies ---------------------------------

CALLING_COPY="$(git -C "$REPO_ARG" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$CALLING_COPY" ]]; then
  printf 'not a git repository: %s\n' "$REPO_ARG" >&2
  exit 3
fi

# Working copies as "<path>\t<branch>" lines; the first is the main worktree.
copies=()
while IFS= read -r line; do
  case "$line" in
    worktree\ *) wt_path="${line#worktree }" ;;
    branch\ refs/heads/*) copies+=("$wt_path"$'\t'"${line#branch refs/heads/}") ;;
    detached) copies+=("$wt_path"$'\t'"") ;;
  esac
done < <(git -C "$CALLING_COPY" worktree list --porcelain)

MAIN_COPY="${copies[0]%%$'\t'*}"
REPO_NAME="$(basename "$MAIN_COPY")"
[[ -n "$REPO_INDEX" ]] || REPO_INDEX="$CALLING_COPY/.claude/handoffs.md"

slugify() { printf '%s' "${1//\//-}"; }

# branch_of_slug <slug> — the working copy whose checked-out branch owns <slug>.
branch_of_slug() {
  local slug="$1" entry path branch
  for entry in "${copies[@]}"; do
    path="${entry%%$'\t'*}"; branch="${entry#*$'\t'}"
    [[ -n "$branch" ]] || continue
    if [[ "$(slugify "$branch")" == "$slug" ]]; then printf '%s' "$path"; return 0; fi
  done
  return 1
}

# display_path <abs-path> — relative to the main worktree when it lives inside it.
display_path() {
  local p="$1"
  if [[ "$p" == "$MAIN_COPY" ]]; then printf '.'
  elif [[ "$p" == "$MAIN_COPY"/* ]]; then printf '%s' "${p#"$MAIN_COPY"/}"
  else printf '%s' "$p"; fi
}

# --- read the handoff files -------------------------------------------------

# cell <text> — one table cell: collapsed to a line, pipes escaped, truncated.
cell() {
  local text max="${2:-0}"
  text="$(printf '%s' "$1" | tr '\n\t' '  ' | tr -s ' ')"
  text="${text# }"; text="${text% }"
  text="${text//|/\\|}"
  if ((max > 0)) && ((${#text} > max)); then text="${text:0:max-1}…"; fi
  printf '%s' "$text"
}

extract_title() {
  local title
  title="$(sed -n 's/^#\{1,6\}[[:space:]]*//p' "$1" | head -1 | sed 's/^Resume:[[:space:]]*//')"
  # A handoff written before the "## Resume: …" convention has no heading at all.
  [[ -n "$title" ]] || title="$(grep -m1 '[^[:space:]]' "$1" || true)"
  printf '%s' "$title"
}

extract_next_step() {
  awk '
    /\*\*Next step:\*\*/ { found = 1; sub(/^.*\*\*Next step:\*\*[[:space:]]*/, ""); }
    found && /^[[:space:]]*$/ { exit }
    found { print }
  ' "$1"
}

# One record per slug: "<date>\t<slug>\t<worktree cell>\t<title>\t<next step>\t<file>"
declare -A seen_slug=()
records=()

for entry in "${copies[@]}"; do
  copy="${entry%%$'\t'*}"
  for file in "$copy"/.claude/handoff-*.md "$copy"/.claude/handoff.md; do
    [[ -f "$file" ]] || continue
    base="$(basename "$file")"
    if [[ "$base" == "handoff.md" ]]; then
      slug="(legacy handoff.md)"
    else
      slug="${base#handoff-}"; slug="${slug%.md}"
    fi
    [[ -z "${seen_slug[$slug]:-}" ]] || continue

    # Prefer the copy whose branch owns the slug — other copies may carry the
    # same committed file after a merge or rebase, but it is not their task.
    owner=""
    if [[ "$base" == "handoff.md" ]]; then
      # The legacy name is gitignored and never travels, so it belongs to the
      # working copy it was found in, whatever branch that is.
      src="$file"
      wt_cell="\`$(display_path "$copy")\`"
      resume="\`cd $(display_path "$copy")\` → \`/pickup\`"
    elif owner="$(branch_of_slug "$slug")"; then
      src="$owner/.claude/$base"
      [[ -f "$src" ]] || src="$file"
      wt_cell="\`$(display_path "$owner")\`"
      resume="\`cd $(display_path "$owner")\` → \`/pickup\`"
    else
      src="$file"
      wt_cell="— _not checked out_"
      resume="check out \`$slug\`, then \`/pickup\`"
    fi
    seen_slug[$slug]=1

    src_copy="${src%/.claude/*}"
    date="$(git -C "$src_copy" log -1 --format=%ad --date=short -- ".claude/$base" 2>/dev/null || true)"
    [[ -n "$date" ]] || date="uncommitted"

    title="$(cell "$(extract_title "$src")" 60)"
    next="$(cell "$(extract_next_step "$src")" "$NEXT_STEP_MAX")"
    [[ -n "$next" ]] || next="_no **Next step:** line — read the file_"
    [[ "$slug" == "(legacy handoff.md)" ]] && title="${title} — legacy, rename on next /handoff"

    records+=("$date"$'\t'"$slug"$'\t'"$wt_cell"$'\t'"$title"$'\t'"$next"$'\t'".claude/$base"$'\t'"$resume")
  done
done

if ((${#records[@]} > 0)); then
  mapfile -t records < <(printf '%s\n' "${records[@]}" | sort -r)
fi

# --- render -----------------------------------------------------------------

NOW="$(date '+%Y-%m-%d %H:%M')"

render_rows() {
  local rec date slug wt title next file resume
  printf '| Branch | Worktree | Phase | Next step | Saved | Handoff file | Resume |\n'
  printf '|---|---|---|---|---|---|---|\n'
  for rec in "${records[@]}"; do
    IFS=$'\t' read -r date slug wt title next file resume <<<"$rec"
    # shellcheck disable=SC2016  # the backticks are markdown code spans, not substitution
    printf '| `%s` | %s | %s | %s | %s | `%s` | %s |\n' \
      "$slug" "$wt" "$title" "$next" "$date" "$file" "$resume"
  done
}

render_table() {
  printf '## %s\n\n' "$REPO_NAME"
  printf '_%s_\n\n' "$MAIN_COPY"
  if ((${#records[@]} == 0)); then
    printf 'No handoffs saved.\n'
    return
  fi
  render_rows
}

DERIVED_NOTE=$'_Derived index — regenerated by `/handoff` and `/pickup`. Do not edit: the\ncommitted per-branch `.claude/handoff-<branch>.md` files are the source of\ntruth, this is only a view of them._'

if ((TO_STDOUT == 1)); then
  render_table
  exit 0
fi

# Repo-local index. A repo that has never handed anything off gets no file at all
# — an empty index is untracked noise in someone else's checkout. An index that
# already exists is always rewritten, so a picked-up handoff's row disappears.
if ((${#records[@]} > 0)) || [[ -f "$REPO_INDEX" ]]; then
  mkdir -p "$(dirname "$REPO_INDEX")"
  {
    printf '# Handoffs — %s\n\n' "$REPO_NAME"
    printf '%s\n\n' "$DERIVED_NOTE"
    printf 'Generated %s.\n\n' "$NOW"
    render_table
  } >"$REPO_INDEX.tmp.$$"
  mv "$REPO_INDEX.tmp.$$" "$REPO_INDEX"
else
  REPO_INDEX="(none — no handoffs in this repo)"
fi

if ((WRITE_GLOBAL == 0)); then
  printf 'wrote %s (%d handoff(s))\n' "$REPO_INDEX" "${#records[@]}"
  exit 0
fi

# --- machine-wide index: replace only this repo's section -------------------

BEGIN_MARKER="<!-- handoff-index:begin path=$MAIN_COPY -->"
END_MARKER="<!-- handoff-index:end path=$MAIN_COPY -->"

mkdir -p "$(dirname "$GLOBAL_INDEX")"
LOCK="$GLOBAL_INDEX.lock"
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  if mkdir "$LOCK" 2>/dev/null; then break; fi
  # A lock older than two minutes is a crashed run, not a live one.
  if [[ -n "$(find "$LOCK" -maxdepth 0 -mmin +2 2>/dev/null)" ]]; then
    rm -rf "$LOCK"
    continue
  fi
  if ((attempt == 10)); then
    printf 'could not lock %s (held by another run?)\n' "$GLOBAL_INDEX" >&2
    exit 4
  fi
  sleep 1
done
trap 'rm -rf "$LOCK"' EXIT

# The file is nothing but a generated header plus marker-delimited sections, one
# per repo. Keep every *other* repo's section verbatim and re-render ours — so
# nothing outside the markers has to be parsed back out.
SECTIONS="$GLOBAL_INDEX.sections.$$"
: >"$SECTIONS"
trap 'rm -rf "$LOCK" "$SECTIONS"' EXIT

if [[ -f "$GLOBAL_INDEX" ]]; then
  awk -v b="$BEGIN_MARKER" -v e="$END_MARKER" '
    index($0, "<!-- handoff-index:begin ") == 1 { inside = 1; mine = ($0 == b) }
    inside && !mine { print }
    index($0, "<!-- handoff-index:end ") == 1 { inside = 0; mine = 0 }
  ' "$GLOBAL_INDEX" >>"$SECTIONS"
fi

if ((${#records[@]} > 0)); then
  {
    printf '%s\n' "$BEGIN_MARKER"
    render_table
    printf '%s\n' "$END_MARKER"
  } >>"$SECTIONS"
fi

# Order sections by repo path so the file is byte-stable no matter which repo
# regenerated last: fold each section onto one key-prefixed line, sort, unfold.
{
  printf '# Handoffs — all repos\n\n'
  printf '%s\n\n' "$DERIVED_NOTE"
  printf 'Generated %s.\n\n' "$NOW"
  awk '
    index($0, "<!-- handoff-index:begin ") == 1 {
      key = $0; sub(/^.*path=/, "", key); sub(/ -->$/, "", key)
      buf = $0; inside = 1; next
    }
    inside && index($0, "<!-- handoff-index:end ") == 1 {
      printf "%s\t%s\001%s\001\n", key, buf, $0; inside = 0; buf = ""; next
    }
    inside { buf = buf "\001" $0 }
  ' "$SECTIONS" | LC_ALL=C sort -t$'\t' -k1,1 | cut -f2- | tr '\001' '\n'
} >"$GLOBAL_INDEX.tmp.$$"
mv "$GLOBAL_INDEX.tmp.$$" "$GLOBAL_INDEX"

printf 'wrote %s and %s (%d handoff(s) in %s)\n' \
  "$REPO_INDEX" "$GLOBAL_INDEX" "${#records[@]}" "$REPO_NAME"
