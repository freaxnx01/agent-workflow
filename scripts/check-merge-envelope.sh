#!/usr/bin/env bash
#
# check-merge-envelope.sh — Enforce ADR-002's auto-merge safety envelope.
#
# This script evaluates gates 1, 5, 6, 7 from ADR-002. Gates 2 + 3 are
# evaluated by `check-auto-review-gate.sh` and gate 4 (verdict=approve)
# is evaluated by the calling workflow against `review-pr.sh`'s output.
# This is the single source of truth for path/branch/author checks; any
# divergence with the ADR is a bug here, not a policy disagreement.
#
# Gates enforced:
#   1. Pipeline-authored PR — pr.user.login ∈ allowlist
#   5. Required status checks green
#   6. Diff inside path envelope (no .github/, no secret-glob, no
#      .claude-auto-merge-blocklist matches)
#   7. Branch-protection compatibility — target branch allows squash
#
# Required environment variables:
#   PR_NUMBER  PR number
#   REPO       owner/repo (default: $GITHUB_REPOSITORY)
#   GH_TOKEN   (or ambient gh auth) — used when seam vars below are unset
#
# Optional environment variables (mostly test seams):
#   AUTHOR_ALLOWLIST       Newline-separated allowed pr.user.login values.
#                          Default: 'github-actions[bot]'.
#   BLOCKLIST_FILE         Path to a `.claude-auto-merge-blocklist` file
#                          in the consumer repo checkout. Default:
#                          ./.claude-auto-merge-blocklist (absent file =
#                          empty blocklist).
#   PR_AUTHOR              Skip `gh pr view --json author` and use this.
#   PR_FILES               Newline-separated changed file paths; skips
#                          `gh pr view --json files`.
#   REQUIRED_CHECKS_STATUS One of: pass | fail | none. Skip
#                          `gh pr checks --required`. `none` means
#                          there are no required checks configured.
#   REPO_ALLOWS_SQUASH     true|false; skip `gh api repos/.../`.
#
# Output ($GITHUB_OUTPUT and stdout):
#   envelope       pass | fail
#   failed-gates   comma-separated gate IDs that failed (empty on pass)
#   reason         one-line human summary
#
# Exit codes:
#   0   evaluated cleanly (envelope=pass or envelope=fail)
#   2   required env missing or invalid
set -euo pipefail
IFS=$'\n\t'

require_env() {
  if [[ -z "${!1:-}" ]]; then
    printf 'error: %s must be set\n' "$1" >&2
    exit 2
  fi
}

require_env PR_NUMBER
REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
if [[ -z "$REPO" ]]; then
  printf 'error: REPO or GITHUB_REPOSITORY must be set\n' >&2
  exit 2
fi

AUTHOR_ALLOWLIST="${AUTHOR_ALLOWLIST:-github-actions[bot]}"
BLOCKLIST_FILE="${BLOCKLIST_FILE:-.claude-auto-merge-blocklist}"

FAILED_GATES=()
REASONS=()

# --- Gate 1: pipeline-author allowlist -----------------------------------

if [[ -z "${PR_AUTHOR:-}" ]]; then
  PR_AUTHOR="$(gh pr view "$PR_NUMBER" --repo "$REPO" \
    --json author --jq '.author.login')"
fi

author_ok=false
while IFS= read -r allowed; do
  [[ -z "$allowed" ]] && continue
  if [[ "$PR_AUTHOR" == "$allowed" ]]; then
    author_ok=true
    break
  fi
done <<< "$AUTHOR_ALLOWLIST"

if [[ "$author_ok" != true ]]; then
  FAILED_GATES+=(1)
  REASONS+=("author '$PR_AUTHOR' not in allowlist")
fi

# --- Gate 5: required status checks green --------------------------------

required_checks_status="${REQUIRED_CHECKS_STATUS:-}"
if [[ -z "$required_checks_status" ]]; then
  # `gh pr checks --required` exits non-zero if any required check is
  # failing or pending. No required checks configured → exit 0 with empty
  # output (which we treat as "none required, gate vacuously passes").
  if gh pr checks "$PR_NUMBER" --repo "$REPO" --required >/dev/null 2>&1; then
    required_checks_status=pass
  else
    # Distinguish "failing" from "no required checks" by re-running and
    # inspecting output.
    if [[ -z "$(gh pr checks "$PR_NUMBER" --repo "$REPO" --required 2>/dev/null || true)" ]]; then
      required_checks_status=none
    else
      required_checks_status=fail
    fi
  fi
fi

case "$required_checks_status" in
  pass|none) ;;
  fail)
    FAILED_GATES+=(5)
    REASONS+=("required status checks not all green")
    ;;
  *)
    printf 'error: REQUIRED_CHECKS_STATUS must be pass|fail|none (got %q)\n' \
      "$required_checks_status" >&2
    exit 2
    ;;
esac

# --- Gate 6: path envelope -----------------------------------------------

if [[ -z "${PR_FILES:-}" ]]; then
  PR_FILES="$(gh pr view "$PR_NUMBER" --repo "$REPO" \
    --json files --jq '.files[].path')"
fi

# Hardcoded secret-glob fragments from ADR-002 §2.6. Match via case
# globs (extglob-free for portability). Non-exhaustive — consumer repos
# extend coverage via BLOCKLIST_FILE.
matches_secret_glob() {
  local p="$1"
  case "$p" in
    *.sops.yaml|*.sops.yml) return 0 ;;
    *.enc.*)                return 0 ;;
    *.age|*.gpg|*.pem)      return 0 ;;
    *.key|*.kbx)            return 0 ;;
    *.p12|*.pfx)            return 0 ;;
    secrets.*|*/secrets.*)  return 0 ;;
  esac
  return 1
}

# Read blocklist patterns (one glob per line, # for comments).
BLOCKLIST_PATTERNS=()
if [[ -f "$BLOCKLIST_FILE" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    BLOCKLIST_PATTERNS+=("$line")
  done < "$BLOCKLIST_FILE"
fi

matches_blocklist() {
  local p="$1" pat
  for pat in "${BLOCKLIST_PATTERNS[@]:-}"; do
    [[ -z "$pat" ]] && continue
    # shellcheck disable=SC2053
    # We want pattern interpretation, not literal match.
    if [[ "$p" == $pat ]]; then
      return 0
    fi
  done
  return 1
}

path_violations=()
while IFS= read -r path; do
  [[ -z "$path" ]] && continue
  if [[ "$path" == .github/* || "$path" == .github ]]; then
    path_violations+=(".github/: $path")
    continue
  fi
  if matches_secret_glob "$path"; then
    path_violations+=("secret-glob: $path")
    continue
  fi
  if matches_blocklist "$path"; then
    path_violations+=("blocklist: $path")
    continue
  fi
done <<< "$PR_FILES"

if (( ${#path_violations[@]} > 0 )); then
  FAILED_GATES+=(6)
  # Surface only the first violation in the reason; the full list is in
  # the script's stdout for log inspection.
  REASONS+=("path envelope: ${path_violations[0]}")
  for v in "${path_violations[@]}"; do
    printf 'path-violation: %s\n' "$v"
  done
fi

# --- Gate 7: branch-protection compat (squash-merge enabled) -------------

repo_allows_squash="${REPO_ALLOWS_SQUASH:-}"
if [[ -z "$repo_allows_squash" ]]; then
  repo_allows_squash="$(gh api "repos/$REPO" --jq '.allow_squash_merge' 2>/dev/null || echo unknown)"
fi

case "$repo_allows_squash" in
  true) ;;
  false|unknown)
    FAILED_GATES+=(7)
    REASONS+=("repo does not allow squash-merge (allow_squash_merge=$repo_allows_squash)")
    ;;
  *)
    printf 'error: REPO_ALLOWS_SQUASH must be true|false (got %q)\n' \
      "$repo_allows_squash" >&2
    exit 2
    ;;
esac

# --- summarize -----------------------------------------------------------

if (( ${#FAILED_GATES[@]} == 0 )); then
  envelope=pass
  failed=''
  reason='all envelope gates satisfied'
else
  envelope=fail
  failed="$(IFS=,; printf '%s' "${FAILED_GATES[*]}")"
  reason="$(IFS='; '; printf '%s' "${REASONS[*]}")"
fi

printf 'envelope=%s (%s)\n' "$envelope" "$reason"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    printf 'envelope=%s\n'     "$envelope"
    printf 'failed-gates=%s\n' "$failed"
    printf 'reason=%s\n'       "$reason"
  } >> "$GITHUB_OUTPUT"
fi
