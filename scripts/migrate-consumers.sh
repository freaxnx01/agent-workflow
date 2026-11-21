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
# Four modes, because "keep it up to date" is really several questions:
#
#   inventory (default)  What does each consumer pin right now? Answers "where
#                        do I stand", needs no target, and is safe to run any
#                        time.
#   migrate (--to <ref>) Rewrite the pins. Dry-run unless --apply.
#   fix-perms            Add the scopes a perms:MISSING stub lacks to its
#     (--fix-perms)      caller `permissions:` block, one PR per repo (#441).
#                        Dry-run unless --apply; always via a PR.
#   add-milestone-guard  Add the backlog milestone guard's caller stub to a
#     (--add-milestone-  consumer onboarded before it existed, one PR per repo
#      guard)            (#653). Reports `backlog` and the un-milestoned issue
#                        count per repo. Dry-run unless --apply; always via a
#                        PR, on 'ci/backlog-milestone-guard'.
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
#   --fix-perms          fix-perms mode (see above). Not combinable with --to:
#                        a pin bump and a permissions fix are separate PRs.
#                        Branch defaults to 'fix/agent-workflow-caller-permissions'.
#   --add-milestone-guard
#                        add-milestone-guard mode (see above). Not combinable
#                        with --to, --rename-flow or --fix-perms — each is its
#                        own PR. Branch defaults to
#                        'ci/backlog-milestone-guard'. Only a ref that has the
#                        workflow gets a stub (a moving major from v2 on, or an
#                        exact pin >= v2.3.0); --force does not override that.
#
# Seams (tests):
#   REWRITE_STDIN   When '1', read a stub on stdin, write the rewritten stub on
#                   stdout, and exit. No network, no discovery — this exposes
#                   the one piece that has to be exactly right. TARGET_REF and
#                   optionally FORCE are read from the environment.
#   REWRITE_FLOW_STDIN  When '1', read a stub on stdin, write it back with the
#                   deprecated flow inputs renamed, and exit. Same no-network
#                   seam as REWRITE_STDIN.
#   FIX_PERMS_STDIN When '1', read a stub on stdin and write it back with the
#                   GRANTS added (comma-separated `scope=level`, e.g.
#                   `actions=write`). Exits 3, reason on stderr, on a shape it
#                   cannot edit safely. No network.
#   CONSUMERS       Newline-separated owner/name list, skipping discovery.
#
# Output:
#   One line per repo: `<repo>  <current-ref>  <verdict>  perms:<ok|MISSING …>`.
#   perms:MISSING names scopes agent-implement.yml's jobs request that the stub
#   does not grant — that consumer fails every dispatch at startup_failure.
#   --add-milestone-guard replaces the perms column with
#   `backlog:<present|would create|created|CLOSED>  unmilestoned:<N>`.
#
# Exit codes:
#   0  success, including "nothing to do"
#   1  --fix-perms only: at least one repo could not be fixed (perms:ERROR,
#      uneditable shape, write or PR failure) — the operator must look
#      --add-milestone-guard only: at least one repo could not be handled (a
#      closed `backlog`, an unreadable lookup, a write or PR failure)
#   2  bad arguments
#   3  FIX_PERMS_STDIN only: the stub's shape cannot be edited safely
#
# Rolling out a permissions fix (#441) — an operator step, never run by CI:
#   bash scripts/migrate-consumers.sh --owner freaxnx01 --fix-perms           # dry run
#   bash scripts/migrate-consumers.sh --owner freaxnx01 --fix-perms --apply
#   bash scripts/migrate-consumers.sh --owner freaxnx01                       # expect perms:ok
#
# Rolling out the backlog guard (#653) — an operator step, never run by CI:
#   bash scripts/migrate-consumers.sh --owner freaxnx01 --add-milestone-guard          # dry run
#   bash scripts/migrate-consumers.sh --owner freaxnx01 --add-milestone-guard --apply
# Then merge the PRs it opened, and per repo the run reported
# `unmilestoned:<N>` with N > 0, sweep the issues that predate the stub:
#   bash scripts/backfill-backlog-milestone.sh -R <owner/repo>                # dry run
#   bash scripts/backfill-backlog-milestone.sh -R <owner/repo> --apply
# The documented rollout covers consumers under the personal owner. A repo
# whose milestones scope releases wants a decision, not this tool.
set -euo pipefail
IFS=$'\n\t'

STUB_PATH='.github/workflows/agent.yml'
GUARD_PATH='.github/workflows/issue-milestone.yml'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/gh-retry.sh disable=SC1091
source "$SCRIPT_DIR/lib/gh-retry.sh"
# shellcheck source=scripts/lib/milestone-stub.sh disable=SC1091
source "$SCRIPT_DIR/lib/milestone-stub.sh"
# shellcheck source=scripts/lib/backlog-milestone.sh disable=SC1091
source "$SCRIPT_DIR/lib/backlog-milestone.sh"
# The workflow a stub's permissions are checked against. This checkout's copy:
# run the script from an up-to-date main, which is what @v<latest> points at.
REUSABLE="${REUSABLE:-$SCRIPT_DIR/../.github/workflows/agent-implement.yml}"
TARGET_REF="${TARGET_REF:-}"
RENAME_FLOW=false
APPLY=false
USE_PR=false
BRANCH=''
FIX_PERMS=false
ADD_GUARD=false
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

# rewrite_perms <grants> <calls> — stub on stdin; prints it with each
# `scope=level` in <grants> (comma-separated) granted. <calls> is the reusable
# workflow's file name. The block edited is the one GitHub uses for the calling
# job (#434): the job's own `permissions:` if it has one, else the top-level
# block. A missing scope is appended after the block's last entry at the
# entries' indent; a lower grant is raised in place, trailing comment kept.
# Anything else in the file is printed byte-for-byte.
# On a shape it cannot edit safely (flow style, read-all/write-all, no block,
# no calling job) prints the reason and exits 3 — never a guess.
rewrite_perms() {
  awk -v grants="$1" -v calls="/$2@" '
    function indent(s) { match(s, /^ */); return RLENGTH }
    function strip(s) { sub(/[[:space:]]+#.*$/, "", s); sub(/^ +/, "", s); return s }
    function rank(l) { return l == "write" ? 2 : (l == "read" ? 1 : 0) }
    function refuse(why) { print why; bad = 1; exit 3 }
    { L[++n] = $0 }
    END {
      if (bad) exit 3
      for (i = 1; i <= n; i++) {
        if (L[i] ~ /^[[:space:]]*(#|$)/) continue
        ind = indent(L[i]); t = strip(L[i])
        if (ind == 0) { injobs = (t == "jobs:"); job = "" }
        if (ind == 0 && t ~ /^permissions:/) top = i
        if (injobs && ind == 2 && t ~ /^[A-Za-z0-9_-]+:$/) job = substr(t, 1, length(t) - 1)
        if (injobs && ind == 4 && job != "" && t ~ /^permissions:/) own[job] = i
        if (injobs && ind == 4 && job != "" && t ~ /^uses:/ && index(t, calls)) caller = job
      }
      if (caller == "") refuse("no job calls " substr(calls, 2, length(calls) - 2))
      hdr = (caller in own) ? own[caller] : top
      if (!hdr) refuse("no permissions: block for job " caller " to extend")
      val = strip(L[hdr]); sub(/^permissions:[[:space:]]*/, "", val)
      if (val ~ /^\{/) refuse("flow-style permissions: " val)
      if (val != "") refuse("permissions: " val " (expanding it would change every other scope)")

      hind = indent(L[hdr]); last = hdr; eind = -1
      for (i = hdr + 1; i <= n; i++) {
        if (L[i] ~ /^[[:space:]]*(#|$)/) continue
        ind = indent(L[i])
        if (ind <= hind) break
        if (eind < 0) eind = ind
        if (ind != eind) continue
        key = strip(L[i]); sub(/:.*/, "", key); at[key] = i; last = i
      }
      if (eind < 0) eind = hind + 2
      pad = ""; for (k = 0; k < eind; k++) pad = pad " "

      m = split(grants, g, ",")
      for (k = 1; k <= m; k++) {
        split(g[k], kv, "="); key = kv[1]; lvl = kv[2]
        if (key == "") continue
        if (key in at) {
          i = at[key]; cur = strip(L[i]); sub(/^[^:]*:[[:space:]]*/, "", cur)
          if (rank(cur) >= rank(lvl)) continue
          match(L[i], /:[[:space:]]*[^[:space:]#]+/)
          head = substr(L[i], 1, RSTART - 1); seg = substr(L[i], RSTART, RLENGTH); tail = substr(L[i], RSTART + RLENGTH)
          match(seg, /^:[[:space:]]*/)
          L[i] = head substr(seg, 1, RLENGTH) lvl tail
        } else {
          add = add pad key ": " lvl "\n"
        }
      }
      for (i = 1; i <= n; i++) { print L[i]; if (i == last && add != "") printf "%s", add }
    }'
}

if [[ "${FIX_PERMS_STDIN:-}" == "1" ]]; then
  [[ -n "${GRANTS:-}" ]] || usage_error "GRANTS must be set for FIX_PERMS_STDIN"
  rc=0
  out="$(rewrite_perms "$GRANTS" "$(basename "$REUSABLE")")" || rc=$?
  if (( rc != 0 )); then printf 'error: cannot edit: %s\n' "$out" >&2; exit 3; fi
  printf '%s\n' "$out"
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
    --fix-perms) FIX_PERMS=true; shift ;;
    --add-milestone-guard) ADD_GUARD=true; shift ;;
    -h|--help) sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *)        usage_error "unknown argument: $1" ;;
  esac
done

if [[ "$ADD_GUARD" == "true" ]]; then
  [[ -z "$TARGET_REF" ]] || usage_error "--add-milestone-guard and --to are separate rollouts; run one at a time"
  [[ "$RENAME_FLOW" != "true" ]] || usage_error "--add-milestone-guard and --rename-flow are separate rollouts; run one at a time"
  [[ "$FIX_PERMS" != "true" ]] || usage_error "--add-milestone-guard and --fix-perms are separate rollouts; run one at a time"
  USE_PR=true
  BRANCH="${BRANCH:-ci/backlog-milestone-guard}"
fi
if [[ "$FIX_PERMS" == "true" ]]; then
  [[ -z "$TARGET_REF" ]] || usage_error "--fix-perms and --to are separate rollouts; run one at a time"
  [[ "$RENAME_FLOW" != "true" ]] || usage_error "--fix-perms and --rename-flow are separate rollouts; run one at a time"
  USE_PR=true
  BRANCH="${BRANCH:-fix/agent-workflow-caller-permissions}"
fi
BRANCH="${BRANCH:-chore/migrate-agent-workflow}"

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

# missing_grants — stub on stdin; prints the checker's gaps as the
# `scope=level,...` list rewrite_perms takes.
missing_grants() {
  bash "$SCRIPT_DIR/check-caller-permissions.sh" - "$REUSABLE" \
    | sed -E 's/^([^:]+): needs ([a-z]+),.*/\1=\2/' | paste -sd, - || true
}

# put_stub <repo> <sha> <content> <message> — write the stub; with --pr, on
# $BRANCH (created from the default branch's head if it does not exist yet).
put_stub() {
  local repo="$1" sha="$2" content="$3" msg="$4" base_sha
  local -a args=(-X PUT "repos/${repo}/contents/${STUB_PATH}"
        -f "message=${msg}"
        -f "content=$(printf '%s' "$content" | base64 -w0)"
        -f "sha=${sha}")
  if [[ "$USE_PR" == "true" ]]; then
    base_sha="$(gh api "repos/${repo}" --jq '.default_branch' \
                | xargs -I{} gh api "repos/${repo}/git/ref/heads/{}" --jq '.object.sha')"
    gh api -X POST "repos/${repo}/git/refs" -f "ref=refs/heads/${BRANCH}" \
           -f "sha=${base_sha}" >/dev/null 2>&1 || true
    args+=(-f "branch=${BRANCH}")
  fi
  gh api "${args[@]}" >/dev/null 2>&1
}

# fix_perms_repo <repo> <cur> <perms> <sha> <content> — the --fix-perms verdict
# and, with --apply, the PR for one repo. Updates the changed/skipped/failed
# counters.
fix_perms_repo() {
  local repo="$1" cur="$2" perms="$3" sha="$4" content="$5"
  local grants scopes new rc=0 lrc=0 open msg title url
  case "$perms" in
    perms:ok)    printf '%s  %s  perms ok\n' "$repo" "$cur"; skipped=$((skipped+1)); return ;;
    perms:ERROR) printf '%s  %s  perms:ERROR  not edited\n' "$repo" "$cur"; failed=$((failed+1)); return ;;
  esac
  scopes="${perms#perms:MISSING }"
  grants="$(printf '%s' "$content" | missing_grants)"
  new="$(printf '%s' "$content" | rewrite_perms "$grants" "$(basename "$REUSABLE")")" || rc=$?
  if (( rc != 0 )); then
    printf '%s  %s  cannot edit: %s\n' "$repo" "$cur" "$new"; failed=$((failed+1)); return
  fi
  # Belt and braces: the rewrite must satisfy the very checker that flagged it.
  if [[ "$(printf '%s\n' "$new" | perms_verdict)" != "perms:ok" ]]; then
    printf '%s  %s  cannot edit: rewrite did not close the gap\n' "$repo" "$cur"; failed=$((failed+1)); return
  fi
  # A failed lookup is not "none open": it would bypass the only duplicate
  # guard on a re-run, so it fails the repo instead.
  open="$(with_backoff gh pr list --repo "$repo" --head "$BRANCH" --state open --json url \
            --jq '.[0].url // empty' 2>/dev/null)" || lrc=$?
  if (( lrc != 0 )); then
    printf '%s  %s  CHECK FAILED (could not list open PRs)\n' "$repo" "$cur"; failed=$((failed+1)); return
  fi
  if [[ -n "$open" ]]; then
    printf '%s  %s  PR already open %s\n' "$repo" "$cur" "$open"; skipped=$((skipped+1)); return
  fi
  if [[ "$APPLY" != "true" ]]; then
    printf '%s  %s  would fix → %s  %s\n' "$repo" "$cur" "$scopes" "$perms"; changed=$((changed+1)); return
  fi
  title="fix(ci): grant ${grants//=/: } to the agent-workflow caller"
  title="${title//,/, }"
  msg="${title}"$'\n\n'"agent-implement.yml requests it, and a reusable workflow can't be granted more than its caller: every ai-implement dispatch ended in startup_failure with no logs. See https://github.com/freaxnx01/agent-workflow/issues/434."
  if ! put_stub "$repo" "$sha" "$new"$'\n' "$msg"; then
    printf '%s  %s  WRITE FAILED\n' "$repo" "$cur"; failed=$((failed+1)); return
  fi
  # Up to 37 PRs in a tight loop: back off on GitHub's secondary rate limit.
  if ! url="$(with_backoff gh pr create --repo "$repo" --head "$BRANCH" --title "$title" --body "$msg" 2>/dev/null)"; then
    printf '%s  %s  PR FAILED (branch %s written)\n' "$repo" "$cur" "$BRANCH"; failed=$((failed+1)); return
  fi
  printf '%s  %s  fixed → PR %s\n' "$repo" "$cur" "$url"; changed=$((changed+1))
}

# --- the backlog milestone guard rollout (#653) ------------------------------

# guard_ref_ok <ref> — true when backlog-milestone.yml exists at <ref>: a
# moving major from v2 on, or an exact pin of v2.3.0 or later (the release that
# shipped the guard, #646). A stub pinned at any other ref — v1, an older exact
# pin, `main`, a SHA — 404s on every issue event, so such a repo is skipped and
# `--force` does not override it.
guard_ref_ok() {
  local ref="$1" version
  if [[ "$ref" =~ ^v([0-9]+)$ ]]; then
    if (( BASH_REMATCH[1] >= 2 )); then return 0; fi
    return 1
  fi
  [[ "$ref" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || return 1
  # One sortable number; minor and patch stay below 1000, as they have for 2
  # major lines and 40-odd releases.
  version=$(( BASH_REMATCH[1] * 1000000 + BASH_REMATCH[2] * 1000 + BASH_REMATCH[3] ))
  if (( version >= 2003000 )); then return 0; fi
  return 1
}

# guard_file_state <repo> — 0 the stub is already there, 1 it is absent, 2 the
# lookup itself failed. An outage must not read as "absent": that would give
# the repo a second stub and a PR nobody asked for.
guard_file_state() {
  local repo="$1" err rc=0
  err="$(gh api "repos/${repo}/contents/${GUARD_PATH}" 2>&1 >/dev/null)" || rc=$?
  if (( rc == 0 )); then return 0; fi
  if [[ "$err" == *404* || "$err" == *'Not Found'* ]]; then return 1; fi
  return 2
}

# pipeline_repo_from_stub — agent.yml on stdin; the owner/name the consumer
# already calls. Read from the stub rather than hardcoded, so a fork's consumer
# keeps calling the fork.
pipeline_repo_from_stub() {
  grep -oE '[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/\.github/workflows/agent-implement\.yml@' \
    | head -1 | sed 's|/\.github/.*||' || printf ''
}

# put_new_file <repo> <path> <content> <message> — create a file that is not
# there yet, on $BRANCH (cut from the default branch's head if it does not
# exist). Separate from put_stub, which updates a file and therefore has to
# send its blob sha: sending one for a file that does not exist is rejected.
# Returns 1 when the write failed. Command.
put_new_file() {
  local repo="$1" path="$2" content="$3" msg="$4" base_sha
  base_sha="$(gh api "repos/${repo}" --jq '.default_branch' \
              | xargs -I{} gh api "repos/${repo}/git/ref/heads/{}" --jq '.object.sha')"
  gh api -X POST "repos/${repo}/git/refs" -f "ref=refs/heads/${BRANCH}" \
         -f "sha=${base_sha}" >/dev/null 2>&1 || true
  gh api -X PUT "repos/${repo}/contents/${path}" \
         -f "message=${msg}" \
         -f "content=$(printf '%s' "$content" | base64 -w0)" \
         -f "branch=${BRANCH}" >/dev/null 2>&1
}

# apply_guard_repo <repo> <cur> <content> <state> <count> — create `backlog`
# where it is missing, write the stub and open the PR. In that order: the
# milestone has to exist before the guard runs, or the consumer collects a
# warning per issue instead. Each step reports what already happened, so a
# re-run after a failure holds no surprises. Updates the counters. Command.
apply_guard_repo() {
  local repo="$1" cur="$2" pipeline="$3" state="$4" count="$5"
  local backlog='present' stub title msg url
  if [[ "$state" == missing ]]; then
    if ! create_backlog_milestone "$repo" >/dev/null; then
      printf '%s  %s  MILESTONE CREATE FAILED\n' "$repo" "$cur"; failed=$((failed+1)); return
    fi
    backlog='created'
  fi
  stub="$(build_milestone_yml "$pipeline" "$cur")"
  title='ci(milestone): assign backlog to issues opened without a milestone'
  msg="${title}"$'\n\n'"Adds the caller stub for ${pipeline}'s backlog-milestone.yml: an issue opened or reopened without a milestone gets the standing \`backlog\` one. This is the stub scripts/onboard-consumer.sh writes for a new consumer; see https://github.com/freaxnx01/agent-workflow/issues/646 and freaxnx01/ai-instructions#61. Only the issue number reaches the workflow."
  if ! put_new_file "$repo" "$GUARD_PATH" "$stub"$'\n' "$msg"; then
    printf '%s  %s  WRITE FAILED  backlog:%s\n' "$repo" "$cur" "$backlog"; failed=$((failed+1)); return
  fi
  # One PR per repo in a tight loop: back off on the secondary rate limit.
  if ! url="$(with_backoff gh pr create --repo "$repo" --head "$BRANCH" \
                --title "$title" --body "$msg" 2>/dev/null)"; then
    printf '%s  %s  PR FAILED (branch %s written)  backlog:%s\n' "$repo" "$cur" "$BRANCH" "$backlog"
    failed=$((failed+1)); return
  fi
  printf '%s  %s  added guard → PR %s  backlog:%s  unmilestoned:%s\n' \
    "$repo" "$cur" "$url" "$backlog" "$count"
  changed=$((changed+1))
}

# add_guard_repo <repo> <cur> <content> — the --add-milestone-guard verdict
# and, with --apply, the milestone and the PR for one repo. Updates the
# changed/skipped/failed counters.
add_guard_repo() {
  local repo="$1" cur="$2" content="$3"
  local pipeline state issues count=0 backlog open rc=0
  if ! guard_ref_ok "$cur"; then
    printf '%s  %s  skipped (pins %s; guard needs v2.3.0+)\n' "$repo" "$cur" "$cur"
    skipped=$((skipped+1)); return
  fi
  # The stub to be written names the pipeline repo, which only the consumer's
  # own stub can say. Without it the new `uses:` would have no owner at all.
  pipeline="$(printf '%s' "$content" | pipeline_repo_from_stub)"
  if [[ -z "$pipeline" ]]; then
    printf '%s  %s  CHECK FAILED (no pipeline repo in %s)\n' "$repo" "$cur" "$STUB_PATH"
    failed=$((failed+1)); return
  fi
  rc=0; guard_file_state "$repo" || rc=$?
  case "$rc" in
    0) printf '%s  %s  guard present\n' "$repo" "$cur"; skipped=$((skipped+1)); return ;;
    2) printf '%s  %s  CHECK FAILED (could not read %s)\n' "$repo" "$cur" "$GUARD_PATH"
       failed=$((failed+1)); return ;;
  esac
  # A failed lookup is not "none open" (#441): on a re-run it would bypass the
  # only duplicate guard and write over an existing rollout branch.
  rc=0
  open="$(with_backoff gh pr list --repo "$repo" --head "$BRANCH" --state open --json url \
            --jq '.[0].url // empty' 2>/dev/null)" || rc=$?
  if (( rc != 0 )); then
    printf '%s  %s  CHECK FAILED (could not list open PRs)\n' "$repo" "$cur"; failed=$((failed+1)); return
  fi
  if [[ -n "$open" ]]; then
    printf '%s  %s  PR already open %s\n' "$repo" "$cur" "$open"; skipped=$((skipped+1)); return
  fi
  rc=0; state="$(backlog_milestone_state "$repo")" || rc=$?
  if (( rc != 0 )); then
    printf '%s  %s  CHECK FAILED (could not read the milestones)\n' "$repo" "$cur"; failed=$((failed+1)); return
  fi
  # A closed `backlog` is left alone: reopening someone's closed milestone is a
  # decision, and a stub assigning a closed milestone would hide issues.
  if [[ "$state" == closed* ]]; then
    printf '%s  %s  backlog:CLOSED  not edited\n' "$repo" "$cur"; failed=$((failed+1)); return
  fi
  rc=0; issues="$(list_unmilestoned_issues "$repo")" || rc=$?
  if (( rc != 0 )); then
    printf '%s  %s  CHECK FAILED (could not list the open issues)\n' "$repo" "$cur"; failed=$((failed+1)); return
  fi
  [[ -z "$issues" ]] || count="$(printf '%s\n' "$issues" | wc -l | tr -d ' ')"

  if [[ "$APPLY" != "true" ]]; then
    backlog='present'
    if [[ "$state" == missing ]]; then backlog='would create'; fi
    printf '%s  %s  would add guard  backlog:%s  unmilestoned:%s\n' "$repo" "$cur" "$backlog" "$count"
    changed=$((changed+1)); return
  fi
  apply_guard_repo "$repo" "$cur" "$pipeline" "$state" "$count"
}

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

  # The guard rollout reads nothing out of the stub but its ref and the
  # pipeline repo it calls, so it runs before the permissions check.
  if [[ "$ADD_GUARD" == "true" ]]; then
    add_guard_repo "$repo" "$cur" "$content"; continue
  fi

  perms="$(printf '%s' "$content" | perms_verdict)"

  if [[ "$FIX_PERMS" == "true" ]]; then
    fix_perms_repo "$repo" "$cur" "$perms" "$sha" "$content"; continue
  fi

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
  if put_stub "$repo" "$sha" "$new" "$msg"; then
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
if [[ "$FIX_PERMS" == "true" ]] && (( failed > 0 )); then exit 1; fi
if [[ "$ADD_GUARD" == "true" ]] && (( failed > 0 )); then exit 1; fi
