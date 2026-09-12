#!/usr/bin/env bash
#
# update-moving-tag.sh — Decide whether a moving major tag (vX) should move
# to the release tag that was just pushed, and to what.
#
# Consumer repos pin the reusable workflow by major tag (e.g.
# `agent-implement.yml@v1`), following the convention `actions/checkout` and
# friends use. That only works if something actually moves `vX` forward when
# a new `vX.y.z` is released -- nothing did, and `v1` sat 159 commits behind
# `main` before this script existed (see docs/superpowers/specs/
# 2026-09-10-moving-major-tag-design.md).
#
# The one piece of real logic here is forward-only movement: releases are not
# always cut in ascending order (a hotfix can land on an old line after a
# newer release already shipped), so `vX` must move to the pushed tag ONLY IF
# that tag is the highest non-prerelease `vX.*.*` tag that exists. Otherwise
# a late `v1.11.2` pushed after `v1.13.0` already exists would silently drag
# every `@v1` consumer backwards -- the exact failure mode this script exists
# to prevent, just pointed the other direction. A skip is therefore a
# correct, expected outcome, not an error.
#
# This script is pure decision logic with respect to git: given RELEASE_TAG
# and a candidate tag list, it decides and prints a verdict. It performs the
# actual tag move only when APPLY=true (see step 9 below); Layer-1 tests
# always run with APPLY unset/false and drive the decision logic via
# ALL_TAGS, no repository required.
#
# Required environment variables:
#   RELEASE_TAG   The tag that was just pushed, e.g. v1.13.0. Must match
#                 ^v[0-9]+\.[0-9]+\.[0-9]+$ -- no pre-release/build suffix.
#                 The release.yml trigger already filters pre-releases out,
#                 but this script is reachable by hand and does not trust
#                 that filtering happened.
#
# Optional environment variables:
#   ALL_TAGS   Newline-separated candidate tags. When set, skips
#              `git tag -l`. Mirrors the ISSUE_LABELS / ISSUE_BODY overrides
#              classify-turns.sh already uses, so the Layer-1 suite can cover
#              every ordering branch in milliseconds with no fixture repo.
#   APPLY      'true' or 'false' (default: false). Only when 'true' AND the
#              verdict is "move" does the script force-update the tag and
#              push it.
#
# Output:
#   Writes `moving-tag=<vX|>`, `should-move=<true|false>` and
#   `reason=<text>` to $GITHUB_OUTPUT when set, and always prints
#   `chosen: <verdict> (<reason>)` to stdout.
#
# Exit codes:
#   0  success -- moved OR deliberately skipped (a skip is NOT an error;
#      failing the workflow on a legitimate hotfix release would be wrong)
#   2  required env missing, or RELEASE_TAG is malformed
set -euo pipefail
IFS=$'\n\t'

require_env() {
  if [[ -z "${!1:-}" ]]; then
    printf 'error: %s must be set\n' "$1" >&2
    exit 2
  fi
}

# A well-formed release tag: vMAJOR.MINOR.PATCH, no pre-release/build suffix.
TAG_RE='^v[0-9]+\.[0-9]+\.[0-9]+$'

require_env RELEASE_TAG

if [[ ! "$RELEASE_TAG" =~ $TAG_RE ]]; then
  printf 'error: RELEASE_TAG must match %s, got: %s\n' "$TAG_RE" "$RELEASE_TAG" >&2
  exit 2
fi

# Derive the major line from the pushed tag -- never hardcode it, so this
# script keeps working unchanged for v2, v3, etc.
major="${RELEASE_TAG%%.*}"

# Candidate tags: caller-supplied (tests) or the real repo's tags in this
# major line only.
all_tags="${ALL_TAGS:-$(git tag -l "${major}.*.*")}"

# Filter to well-formed, non-prerelease tags in THIS major line. This is
# what stops a v1.99.99 tag from being considered during a v2 release, and
# what stops a -rc/-alpha/-beta tag from ever winning the "newest" pick.
line_re="^${major}\.[0-9]+\.[0-9]+\$"
candidates=""
while IFS= read -r tag; do
  [[ -z "$tag" ]] && continue
  if [[ "$tag" =~ $line_re ]]; then
    candidates+="${tag}"$'\n'
  fi
done <<< "$all_tags"

# Always consider the pushed tag itself, even if the caller's candidate list
# omitted it (e.g. a real `git tag -l` run before the tag object is visible).
candidates+="${RELEASE_TAG}"$'\n'

# Semver-aware ordering, not lexical: v1.10.0 must beat v1.9.0. sort -V
# handles this; do not hand-roll comparison and do not use plain `sort`.
newest="$(printf '%s' "$candidates" | sort -V | tail -1)"

if [[ "$newest" == "$RELEASE_TAG" ]]; then
  should_move=true
  reason="${RELEASE_TAG} is the newest non-prerelease tag in the ${major} line"
  printf 'chosen: move %s → %s (%s)\n' "$major" "$RELEASE_TAG" "$reason"
else
  should_move=false
  reason="${newest} is newer than ${RELEASE_TAG}"
  printf 'chosen: skip (%s)\n' "$reason"
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  if [[ "$should_move" == "true" ]]; then
    printf 'moving-tag=%s\n' "$major" >> "$GITHUB_OUTPUT"
  else
    printf 'moving-tag=\n' >> "$GITHUB_OUTPUT"
  fi
  printf 'should-move=%s\n' "$should_move" >> "$GITHUB_OUTPUT"
  printf 'reason=%s\n' "$reason" >> "$GITHUB_OUTPUT"
fi

if [[ "${APPLY:-false}" == "true" ]] && [[ "$should_move" == "true" ]]; then
  # Snapshot what the remote currently holds for refs/tags/$major BEFORE we
  # touch the local ref, so --force-with-lease below has a real expected
  # value to check the push against instead of comparing to the value we
  # are about to write ourselves. Empty when the tag doesn't exist upstream
  # yet (first-ever move for this major line); ls-remote, not rev-parse, so
  # this reflects the remote, not whatever fetch-tags happened to leave
  # locally.
  remote_before="$(git ls-remote origin "refs/tags/${major}" | cut -f1)"
  # Dereference with ^{} so an annotated release tag resolves to its commit
  # rather than to the tag object -- `git tag -f` on a tag object would move
  # vX to point at another tag instead of a commit.
  git tag -f "$major" "${RELEASE_TAG}^{}"
  # --force-with-lease, not a bare -f: the remote snapshot above is not
  # atomic with this push, so two near-simultaneous releases could otherwise
  # race and land vX on the older one. Lease against the exact value read
  # from the remote a moment ago so a concurrent mover is detected and
  # rejected instead of silently overwritten.
  git push "--force-with-lease=refs/tags/${major}:${remote_before}" origin "refs/tags/${major}"
fi
