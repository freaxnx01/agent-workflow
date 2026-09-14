#!/usr/bin/env bash
#
# migrate-consumers.sh — Take stock of what every consumer repo pins, and move
# them to a new major line when one opens.
#
# The moving tag keeps a consumer current within its major line, and
# check-major-drift.sh raises a warning when a newer line opens. Neither rolls
# the change out: a major bump may break things, so upgrading stays a decision.
# What was missing was a supported way to *carry out* that decision across a
# fleet — the v1→v2 migration of 70 repos was done with a throwaway script, and
# it mangled the one repo pinned to a full version.
#
# Two modes, because "keep it up to date" is really two questions:
#
#   inventory (default)  What does each consumer pin right now? Answers "where
#                        do I stand", needs no target, and is safe to run any
#                        time.
#   migrate (--to <ref>) Rewrite the pins. Dry-run unless --apply.
#
# Required environment variables: none.
#
# Arguments:
#   --owner <owner>      Discover consumers by code search under this owner.
#   --repo <owner/name>  Operate on this repo. Repeatable; skips discovery.
#   --to <ref>           Target ref, e.g. v2. Without it, inventory only.
#   --apply              Actually write. Default is a dry run.
#   --pr                 Open a pull request instead of committing to the
#                        default branch. Required wherever that branch is
#                        protected, which is the normal case at work.
#   --branch <name>      Branch for --pr. Default 'chore/migrate-agent-workflow'.
#   --force              Also rewrite refs that are not version pins (`main`,
#                        a SHA, a branch). Off by default: tracking something
#                        other than a release line is a deliberate choice and
#                        clobbering it silently would be the same class of
#                        mistake this script exists to undo.
#   --path <path>        Stub path. Default '.github/workflows/agent.yml'.
#
# Seams (tests):
#   REWRITE_STDIN   When '1', read a stub on stdin, write the rewritten stub on
#                   stdout, and exit. No network, no discovery — this exposes
#                   the one piece that has to be exactly right. TARGET_REF and
#                   optionally FORCE are read from the environment.
#   CONSUMERS       Newline-separated owner/name list, skipping discovery.
#
# Output:
#   One line per repo: `<repo>  <current-ref>  <verdict>`.
#
# Exit codes:
#   0  success, including "nothing to do"
#   2  bad arguments
set -euo pipefail
IFS=$'\n\t'

STUB_PATH='.github/workflows/agent.yml'
TARGET_REF="${TARGET_REF:-}"
APPLY=false
USE_PR=false
BRANCH='chore/migrate-agent-workflow'
FORCE="${FORCE:-false}"
OWNER=''
REPOS=''

usage_error() { printf 'error: %s\n' "$1" >&2; exit 2; }

# --- the part that has to be exactly right ----------------------------------
#
# Replace the WHOLE ref, never a substring of it. The throwaway script used a
# substring swap of `@v1` → `@v2`, which turned the one repo pinned `@v1.13.0`
# into `@v2.13.0` — a ref that does not exist. Matching `\S+` and replacing it
# wholesale makes a full-version pin migrate correctly to the moving tag, which
# is what it should have been in the first place.
#
# rewrite_pin <target> <force> — stub on stdin, rewritten stub on stdout.
rewrite_pin() {
  local target="$1" force="$2"
  awk -v target="$target" -v force="$force" '
    {
      line = $0
      if (line ~ /agent-implement\.yml@[^[:space:]]+/) {
        match(line, /agent-implement\.yml@[^[:space:]]+/)
        ref = substr(line, RSTART + length("agent-implement.yml@"), RLENGTH - length("agent-implement.yml@"))
        if (force == "true" || ref ~ /^v[0-9]+/)
          sub(/agent-implement\.yml@[^[:space:]]+/, "agent-implement.yml@" target, line)
      }
      if (line ~ /^[[:space:]]*pipeline-ref:[[:space:]]*[^[:space:]]+/) {
        match(line, /pipeline-ref:[[:space:]]*[^[:space:]]+/)
        seg = substr(line, RSTART, RLENGTH)
        sub(/^pipeline-ref:[[:space:]]*/, "", seg)
        if (force == "true" || seg ~ /^v[0-9]+/)
          sub(/pipeline-ref:[[:space:]]*[^[:space:]]+/, "pipeline-ref: " target, line)
      }
      print line
    }'
}

# Pull the ref a stub currently pins, for the inventory column.
current_ref() {
  grep -oE 'agent-implement\.yml@[^[:space:]]+' \
    | head -1 | sed 's|.*@||' || printf ''
}

if [[ "${REWRITE_STDIN:-}" == "1" ]]; then
  [[ -n "$TARGET_REF" ]] || usage_error "TARGET_REF must be set for REWRITE_STDIN"
  rewrite_pin "$TARGET_REF" "$FORCE"
  exit 0
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --owner)  OWNER="${2:?}"; shift 2 ;;
    --repo)   REPOS+="${2:?}"$'\n'; shift 2 ;;
    --to)     TARGET_REF="${2:?}"; shift 2 ;;
    --apply)  APPLY=true; shift ;;
    --pr)     USE_PR=true; shift ;;
    --branch) BRANCH="${2:?}"; USE_PR=true; shift 2 ;;
    --force)  FORCE=true; shift ;;
    --path)   STUB_PATH="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,50p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)        usage_error "unknown argument: $1" ;;
  esac
done

command -v gh >/dev/null || usage_error "gh is required"

# Discovery: explicit --repo wins, then $CONSUMERS, then code search.
if [[ -z "$REPOS" ]]; then
  if [[ -n "${CONSUMERS:-}" ]]; then
    REPOS="$CONSUMERS"
  elif [[ -n "$OWNER" ]]; then
    REPOS="$(gh search code --owner "$OWNER" 'agent-implement.yml@' --limit 100 \
               --json repository,path \
               --jq ".[] | select(.path == \"$STUB_PATH\") | .repository.nameWithOwner" \
             2>/dev/null | sort -u || printf '')"
  else
    usage_error "pass --owner or at least one --repo"
  fi
fi
[[ -n "${REPOS//[[:space:]]/}" ]] || { printf 'no consumers found\n'; exit 0; }

changed=0; skipped=0; failed=0
while IFS= read -r repo; do
  [[ -z "$repo" ]] && continue
  blob="$(gh api "repos/${repo}/contents/${STUB_PATH}" --jq '.content' 2>/dev/null || printf '')"
  if [[ -z "$blob" ]]; then
    printf '%s  -  UNREADABLE\n' "$repo"; failed=$((failed+1)); continue
  fi
  sha="$(gh api "repos/${repo}/contents/${STUB_PATH}" --jq '.sha')"
  content="$(printf '%s' "$blob" | base64 -d)"
  cur="$(printf '%s' "$content" | current_ref)"
  cur="${cur:--}"

  if [[ -z "$TARGET_REF" ]]; then
    printf '%s  %s  inventory\n' "$repo" "$cur"; continue
  fi
  if [[ "$cur" == "$TARGET_REF" ]]; then
    printf '%s  %s  already on target\n' "$repo" "$cur"; skipped=$((skipped+1)); continue
  fi
  if [[ "$FORCE" != "true" && ! "$cur" =~ ^v[0-9]+ ]]; then
    printf '%s  %s  skipped (not a version pin; --force to override)\n' "$repo" "$cur"
    skipped=$((skipped+1)); continue
  fi

  new="$(printf '%s' "$content" | rewrite_pin "$TARGET_REF" "$FORCE")"
  if [[ "$new" == "$content" ]]; then
    printf '%s  %s  no change needed\n' "$repo" "$cur"; skipped=$((skipped+1)); continue
  fi
  if [[ "$APPLY" != "true" ]]; then
    printf '%s  %s  would migrate → %s\n' "$repo" "$cur" "$TARGET_REF"
    changed=$((changed+1)); continue
  fi

  msg="ci(agent-workflow): pin ${TARGET_REF}"$'\n\n'"Was ${cur}. The moving tag only follows releases in its own major line, so a superseded line stops receiving fixes silently."
  args=(-X PUT "repos/${repo}/contents/${STUB_PATH}"
        -f "message=${msg}"
        -f "content=$(printf '%s' "$new" | base64 -w0)"
        -f "sha=${sha}")
  if [[ "$USE_PR" == "true" ]]; then
    base_sha="$(gh api "repos/${repo}" --jq '.default_branch' \
                | xargs -I{} gh api "repos/${repo}/git/ref/heads/{}" --jq '.object.sha')"
    gh api -X POST "repos/${repo}/git/refs" -f "ref=refs/heads/${BRANCH}" \
           -f "sha=${base_sha}" >/dev/null 2>&1 || true
    args+=(-f "branch=${BRANCH}")
  fi
  if gh api "${args[@]}" >/dev/null 2>&1; then
    if [[ "$USE_PR" == "true" ]]; then
      gh pr create --repo "$repo" --head "$BRANCH" \
        --title "ci(agent-workflow): pin ${TARGET_REF}" --body "$msg" >/dev/null 2>&1 || true
    fi
    printf '%s  %s  migrated → %s\n' "$repo" "$cur" "$TARGET_REF"; changed=$((changed+1))
  else
    printf '%s  %s  WRITE FAILED\n' "$repo" "$cur"; failed=$((failed+1))
  fi
done <<< "$REPOS"

printf '\n%d changed, %d skipped, %d failed\n' "$changed" "$skipped" "$failed"
