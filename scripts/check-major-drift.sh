#!/usr/bin/env bash
#
# check-major-drift.sh — Warn a consumer that its pinned major line has been
# left behind.
#
# Consumers pin the reusable workflow by moving major tag (`@v2`). Since #261
# that tag follows every `v2.x.y` release on its own, so patches and features
# arrive with no human step. That solves drift *within* a major line.
#
# It does nothing for drift *between* them. `update-moving-tag.sh` derives the
# tag to move from the pushed release (`major="${RELEASE_TAG%%.*}"`), so
# releasing `v3.0.0` moves `v3` — never `v2`. The moment a new major line
# opens, every `@v2` consumer stops receiving anything, and nothing says so:
# runs stay green, the consumer just executes old code.
#
# That is not hypothetical. `v1` froze at v1.11.1 on 2026-08-03 and sat 173
# commits behind `main` while 70 repos pinned it. The pipeline defects fixed in
# #335, #337, #338, #340, #342 and #345 never reached any of them, and
# `classify-turns.sh` did not exist there at all — so those consumers silently
# ran on `max_turns: 30` and died at `error_max_turns`, which looks exactly
# like a legitimate agent failure. Six weeks, no signal.
#
# So this is deliberately a *detector*, not a fixer. A major bump is allowed to
# break things; upgrading is the consumer's decision and must stay one. What
# cannot stay a human's job is *noticing* — the moving-tag design (see
# docs/superpowers/specs/2026-09-10-moving-major-tag-design.md) already
# established that anything relying on memory has been falsified in practice.
#
# Required environment variables:
#   PIPELINE_REF   The ref the consumer pinned, e.g. `v2`, `v2.0.5`, `main`,
#                  or a SHA. Only a `vN`-shaped ref is comparable; anything
#                  else is reported and skipped rather than guessed at.
#
# Optional environment variables:
#   PIPELINE_REPO  owner/name to read tags from. Default: freaxnx01/agent-workflow.
#   ALL_TAGS       Newline-separated candidate tags. When set, skips the API
#                  call — the same seam ALL_TAGS gives update-moving-tag.sh, so
#                  the Layer-1 suite covers every branch in milliseconds with no
#                  fixture repo and no network.
#
# Output:
#   Always prints `drift: <verdict> (<reason>)`.
#   On drift, additionally emits a `::warning::` annotation, so it surfaces on
#   the run itself rather than only in a log nobody opens.
#
# Exit codes:
#   0  always, including on drift. This is advisory: failing a consumer's run
#      because a newer major exists would punish them for a decision they have
#      not been asked to make yet.
#   2  required env missing
set -euo pipefail
IFS=$'\n\t'

require_env() {
  if [[ -z "${!1:-}" ]]; then
    printf 'error: %s must be set\n' "$1" >&2
    exit 2
  fi
}

require_env PIPELINE_REF
PIPELINE_REPO="${PIPELINE_REPO:-freaxnx01/agent-workflow}"

# Only a major-shaped pin is comparable. `main`, a SHA or a branch is a
# deliberate choice to track something other than a release line, and warning
# about it would be noise — say what was seen and stop.
# shellcheck disable=SC2153  # PIPELINE_REF and PIPELINE_REPO are distinct inputs, not a typo
if [[ ! "$PIPELINE_REF" =~ ^v([0-9]+)(\.|$) ]]; then
  printf 'drift: skip (%s is not a version pin, nothing to compare)\n' "$PIPELINE_REF"
  exit 0
fi
current="${BASH_REMATCH[1]}"

# Candidate tags: caller-supplied (tests) or the pipeline repo's real tags.
# matching-refs is one call and needs no checkout, so this works the same
# whether the scripts were checked out shallow, from a tag, or not at all.
if [[ -n "${ALL_TAGS:-}" ]]; then
  all_tags="$ALL_TAGS"
else
  all_tags="$(gh api "repos/${PIPELINE_REPO}/git/matching-refs/tags/v" \
                --jq '.[].ref | sub("^refs/tags/"; "")' 2>/dev/null || printf '')"
fi

# Highest major among well-formed, non-prerelease release tags. A bare moving
# tag (`v2`) is skipped on purpose: it is the thing being pointed at, not
# evidence that a major line exists — only a real vX.Y.Z release is.
latest=""
while IFS= read -r tag; do
  [[ -z "$tag" ]] && continue
  [[ "$tag" =~ ^v([0-9]+)\.[0-9]+\.[0-9]+$ ]] || continue
  n="${BASH_REMATCH[1]}"
  if [[ -z "$latest" ]] || (( n > latest )); then
    latest="$n"
  fi
done <<< "$all_tags"

if [[ -z "$latest" ]]; then
  printf 'drift: unknown (no release tags found in %s)\n' "$PIPELINE_REPO"
  exit 0
fi

if (( current < latest )); then
  printf 'drift: behind (pinned v%s, newest major line is v%s)\n' "$current" "$latest"
  printf '::warning title=agent-workflow major line v%s is no longer maintained::' "$current"
  printf 'This repo pins @v%s, but v%s has been released. The moving tag v%s ' \
    "$current" "$latest" "$current"
  printf 'only follows v%s.x.y releases, and there will be no more of them — ' "$current"
  printf 'so this pipeline is frozen and will silently miss every later fix. '
  printf 'Migrate the stub to @v%s; see docs/CONSUMER-SETUP.md.\n' "$latest"
elif (( current > latest )); then
  printf 'drift: ahead (pinned v%s, newest released major is v%s)\n' "$current" "$latest"
else
  printf 'drift: current (v%s is the newest major line)\n' "$current"
fi
