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
#   --rename-flow        Rename the deprecated flow inputs: pre-preview ->
#                        ai-review-human-merge, auto-review -> ai-review-ai-merge.
#                        Both still work and both are removed in v3. Combines
#                        with --to; on its own it needs no target.
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
#   REWRITE_FLOW_STDIN  When '1', read a stub on stdin, write it back with the
#                   deprecated flow inputs renamed, and exit. Same no-network
#                   seam as REWRITE_STDIN.
#   CONSUMERS       Newline-separated owner/name list, skipping discovery.
#
# Output:
#   One line per repo: `<repo>  <current-ref>  <verdict>  perms:<ok|MISSING …>`.
#   perms:MISSING names scopes agent-implement.yml's jobs request that the stub
#   does not grant — that consumer fails every dispatch at startup_failure.
#
# Exit codes:
#   0  success, including "nothing to do"
#   2  bad arguments
set -euo pipefail
IFS=$'\n\t'

STUB_PATH='.github/workflows/agent.yml'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The workflow a stub's permissions are checked against. This checkout's copy:
# run the script from an up-to-date main, which is what @v<latest> points at.
REUSABLE="${REUSABLE:-$SCRIPT_DIR/../.github/workflows/agent-implement.yml}"
TARGET_REF="${TARGET_REF:-}"
RENAME_FLOW=false
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

# rewrite_flow — stub on stdin, rewritten stub on stdout.
#
# Renames the deprecated flow inputs to their replacements. Both still work
# and both are removed in v3, so this is preparation, not a fix:
#
#   pre-preview: -> ai-review-human-merge:
#   auto-review: -> ai-review-ai-merge:
#
# Anchored to the start of the line so a key is rewritten and a *mention* is
# not: every one of these stubs explains the flow in comments above the key,
# and rewriting prose across 40 repos would be unreviewable noise for no
# behavioural gain. Only the key token is substituted, so indentation (which
# is structural in YAML -- losing it moves the key out of `with:`) and any
# trailing comment survive untouched.
rewrite_flow() {
  awk '
    {
      line = $0
      if (line ~ /^[[:space:]]*pre-preview:[[:space:]]*/)
        sub(/pre-preview:/, "ai-review-human-merge:", line)
      else if (line ~ /^[[:space:]]*auto-review:[[:space:]]*/)
        sub(/auto-review:/, "ai-review-ai-merge:", line)
      print line
    }'
}

# perms_verdict — stub on stdin; prints `perms:ok`, `perms:MISSING <scopes>`,
# or `perms:ERROR` when the checker could not run (its reason goes to stderr).
# A stub that grants less than agent-implement.yml's jobs request fails every
# dispatch at startup_failure with no logs (#434), so the inventory says so.
# Keyed on the exit code, not on empty output: a checker that never ran must
# not read as "no gaps" for the whole fleet.
perms_verdict() {
  local out rc=0
  out="$(bash "$SCRIPT_DIR/check-caller-permissions.sh" - "$REUSABLE")" || rc=$?
  case "$rc" in
    0) printf 'perms:ok' ;;
    1) printf 'perms:MISSING %s' "$(printf '%s\n' "$out" | sed 's/:.*//' | paste -sd, -)" ;;
    *) printf 'perms:ERROR' ;;
  esac
}

if [[ "${REWRITE_FLOW_STDIN:-}" == "1" ]]; then
  rewrite_flow
  exit 0
fi

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
    --rename-flow) RENAME_FLOW=true; shift ;;
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
  perms="$(printf '%s' "$content" | perms_verdict)"

  if [[ -z "$TARGET_REF" && "$RENAME_FLOW" != "true" ]]; then
    printf '%s  %s  inventory  %s\n' "$repo" "$cur" "$perms"; continue
  fi
  if [[ -n "$TARGET_REF" && "$cur" == "$TARGET_REF" && "$RENAME_FLOW" != "true" ]]; then
    printf '%s  %s  already on target  %s\n' "$repo" "$cur" "$perms"; skipped=$((skipped+1)); continue
  fi

  new="$content"
  if [[ -n "$TARGET_REF" && "$cur" != "$TARGET_REF" ]]; then
    if [[ "$FORCE" != "true" && ! "$cur" =~ ^v[0-9]+ ]]; then
      printf '%s  %s  skipped (not a version pin; --force to override)\n' "$repo" "$cur"
      skipped=$((skipped+1)); continue
    fi
    new="$(printf '%s' "$new" | rewrite_pin "$TARGET_REF" "$FORCE")"
  fi
  if [[ "$RENAME_FLOW" == "true" ]]; then
    new="$(printf '%s' "$new" | rewrite_flow)"
  fi

  if [[ "$new" == "$content" ]]; then
    printf '%s  %s  no change needed  %s\n' "$repo" "$cur" "$perms"; skipped=$((skipped+1)); continue
  fi

  # The pin-only wording is load-bearing: it is what the existing dry-run
  # assertion reads, and a report format is an interface like any other.
  if [[ -n "$TARGET_REF" && "$RENAME_FLOW" == "true" ]]; then
    summary="→ ${TARGET_REF} (deprecated flow inputs renamed)"
    title="ci(agent-workflow): pin ${TARGET_REF}, rename deprecated flow inputs"
  elif [[ -n "$TARGET_REF" ]]; then
    summary="→ ${TARGET_REF}"
    title="ci(agent-workflow): pin ${TARGET_REF}"
  else
    summary="(deprecated flow inputs renamed)"
    title="ci(agent-workflow): rename deprecated flow inputs"
  fi

  if [[ "$APPLY" != "true" ]]; then
    printf '%s  %s  would migrate %s  %s\n' "$repo" "$cur" "$summary" "$perms"
    changed=$((changed+1)); continue
  fi

  if [[ -n "$TARGET_REF" ]]; then
    msg="${title}"$'\n\n'"Was ${cur}. The moving tag only follows releases in its own major line, so a superseded line stops receiving fixes silently."
  else
    msg="${title}"$'\n\n'"pre-preview and auto-review still work but are removed in v3; this renames the keys to ai-review-human-merge and ai-review-ai-merge. Behaviour is unchanged."
  fi
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
        --title "$title" --body "$msg" >/dev/null 2>&1 || true
    fi
    printf '%s  %s  migrated %s\n' "$repo" "$cur" "$summary"; changed=$((changed+1))
  else
    printf '%s  %s  WRITE FAILED\n' "$repo" "$cur"; failed=$((failed+1))
  fi
done <<< "$REPOS"

printf '\n%d changed, %d skipped, %d failed\n' "$changed" "$skipped" "$failed"
