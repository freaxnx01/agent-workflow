#!/usr/bin/env bash
#
# azdo-pr-feed-cleanup.sh — the always() step of an Azure DevOps PR build
# validation that restored a private Azure Artifacts feed (#699).
#
# The agent container outlives the job, so the private packages
# azdo-pr-feed-restore.sh put into the fallback folder must not be there for
# the next job: another PR's build would read packages no step of its own ever
# fetched. It runs on every outcome, including a failed or cancelled build, and
# needs no token.
#
# Exit codes: 0 the cache is empty or absent; 1 the cache path is refused or
# could not be emptied.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/private-feed-restore.sh
source "$ROOT/scripts/lib/private-feed-restore.sh"

main() {
  feed_cache_path_check 2>/dev/null || {
    printf 'pr feed cleanup: %s\n' "$FEED_CACHE_CAUSE" >&2
    exit 1
  }
  feed_cache_clear
}

main "$@"
