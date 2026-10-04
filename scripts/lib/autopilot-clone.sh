#!/usr/bin/env bash
#
# autopilot-clone.sh — sourced, not executed.
#   autopilot_clone_dir <owner/repo>      (query)   print the cache path
#   sync_autopilot_clone <owner/repo>      (command) clone or refresh it
#
# /enrich commits a spec and a plan and pushes them, so a headless enrich needs
# a checkout of the *target* repo. This keeps one clone per allowlisted repo
# under $AUTOPILOT_CACHE_DIR and resets it to a clean default branch before each
# use, so every enrich starts from a known state and nothing is carried between
# runs. A wedged clone is repaired by deleting the directory.
#
# This cache is deliberately NOT the operator's own working clones: an
# unattended timer running `reset --hard` in a directory a human also works in
# by hand is how a stray uncommitted change gets destroyed at 3am.
#
# Env:
#   AUTOPILOT_CACHE_DIR      cache root. Default ~/.cache/agent-workflow/autopilot
#   AUTOPILOT_CLONE_URL_BASE clone URL prefix. Default https://github.com
#                            Tests point this at a local file:// origin, which
#                            is what keeps the suite hermetic.
set -euo pipefail
IFS=$'\n\t'

autopilot_clone_dir() {
  local repo="$1"
  printf '%s/%s\n' \
    "${AUTOPILOT_CACHE_DIR:-$HOME/.cache/agent-workflow/autopilot}" \
    "${repo//\//__}"
}

sync_autopilot_clone() {
  local repo="$1" dir url branch
  dir="$(autopilot_clone_dir "$repo")"
  url="${AUTOPILOT_CLONE_URL_BASE:-https://github.com}/$repo.git"

  if [[ ! -d "$dir/.git" ]]; then
    mkdir -p "$(dirname "$dir")"
    if ! git clone --quiet "$url" "$dir"; then
      printf 'error: clone failed: %s\n' "$url" >&2
      return 1
    fi
  fi

  if ! git -C "$dir" fetch --quiet --prune origin; then
    printf 'error: fetch failed: %s\n' "$dir" >&2
    return 1
  fi

  # Ask the remote which branch is default rather than assuming main — a
  # consumer repo on master would otherwise silently fail every run.
  git -C "$dir" remote set-head origin --auto >/dev/null 2>&1 || true
  branch="$(git -C "$dir" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  branch="${branch#origin/}"
  [[ -n "$branch" ]] || branch=main

  if ! git -C "$dir" checkout --quiet -B "$branch" "origin/$branch"; then
    printf 'error: checkout %s failed: %s\n' "$branch" "$dir" >&2
    return 1
  fi
  if ! git -C "$dir" reset --quiet --hard "origin/$branch"; then
    printf 'error: reset failed: %s\n' "$dir" >&2
    return 1
  fi
  if ! git -C "$dir" clean -qfdx; then
    printf 'error: clean failed: %s\n' "$dir" >&2
    return 1
  fi

  return 0
}
