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
#   REQUIRED_CHECKS_STATUS One of: pass | fail | none. Skip the live
#                          two-step query entirely and use this value
#                          directly. `none` means there are no required
#                          checks configured on the target branch.
#   REQUIRED_CHECKS_COUNT  Lower-level test seam. Integer count of
#                          required checks configured on the base
#                          branch (skips the `gh api` call). Combined
#                          with REQUIRED_CHECKS_PASS to exercise the
#                          live decision path without real network.
#   REQUIRED_CHECKS_PASS   `true` | `false`. The would-be exit-code
#                          outcome of `gh pr checks --required` for
#                          testing. Only consulted when
#                          REQUIRED_CHECKS_COUNT > 0.
#   PR_BASE_BRANCH         The PR's base branch (default: query via
#                          `gh pr view --json baseRefName`). Used to
#                          target the correct branch-protection rule.
#   REPO_ALLOWS_SQUASH     true|false; skip the `allow_squash_merge`
#                          query against `gh api repos/.../`.
#   REPO_ALLOWS_AUTO_MERGE true|false; skip the `allow_auto_merge`
#                          query against `gh api repos/.../`.
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
  # Two-step decision (replaces an earlier heuristic that parsed stdout
  # of `gh pr checks --required` to distinguish "none configured" from
  # "failing/pending" — that heuristic mis-classified pending checks as
  # 'none' on some gh-cli versions, satisfying gate 5 before any check
  # had actually run). Per ADR-002 §2.5: refuse to promote on
  # flaky/pending. So:
  #
  #   1. Authoritatively query the base branch's required-status-checks
  #      protection rule. Empty contexts (or 404 → no protection) means
  #      no required checks configured → gate 5 vacuously passes.
  #   2. Otherwise, `gh pr checks --required` exit code tells us
  #      pass (0) vs not-green (non-zero — covers both failing and
  #      pending; both forbid promotion).
  required_count="${REQUIRED_CHECKS_COUNT:-}"
  if [[ -z "$required_count" ]]; then
    if [[ -z "${PR_BASE_BRANCH:-}" ]]; then
      PR_BASE_BRANCH="$(gh pr view "$PR_NUMBER" --repo "$REPO" \
        --json baseRefName --jq '.baseRefName' 2>/dev/null || echo '')"
    fi
    if [[ -n "$PR_BASE_BRANCH" ]]; then
      required_count="$(gh api \
        "repos/$REPO/branches/$PR_BASE_BRANCH/protection/required_status_checks" \
        --jq '.contexts | length' 2>/dev/null || echo 0)"
    else
      required_count=0
    fi
  fi

  if (( required_count == 0 )); then
    required_checks_status=none
  else
    pass_flag="${REQUIRED_CHECKS_PASS:-}"
    if [[ -z "$pass_flag" ]]; then
      if gh pr checks "$PR_NUMBER" --repo "$REPO" --required >/dev/null 2>&1; then
        pass_flag=true
      else
        pass_flag=false
      fi
    fi
    case "$pass_flag" in
      true)  required_checks_status=pass ;;
      false) required_checks_status=fail ;;
      *)
        printf 'error: REQUIRED_CHECKS_PASS must be true|false (got %q)\n' \
          "$pass_flag" >&2
        exit 2
        ;;
    esac
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

# --- Gate 7: branch-protection compat (squash + auto-merge enabled) ------
#
# Two repo-level settings both must be true:
#   - allow_squash_merge — required because the promote step calls
#     `gh pr merge --squash`.
#   - allow_auto_merge   — required because the promote step adds
#     `--auto`. This flag is OFF by default on new GitHub repos, so a
#     consumer who enables squash but forgets auto-merge would get
#     `gh pr merge --auto` failing AFTER `gh pr ready` already promoted
#     the draft — an inconsistent half-promoted state that the marking
#     step doesn't catch. Verify both up front.

gate7_failed=false

check_repo_setting() {
  # check_repo_setting <env-var-name> <api-field> <human-name>
  local var="$1" field="$2" name="$3" value
  value="${!var:-}"
  if [[ -z "$value" ]]; then
    value="$(gh api "repos/$REPO" --jq ".$field" 2>/dev/null || echo unknown)"
  fi
  case "$value" in
    true) return 0 ;;
    false|unknown)
      gate7_failed=true
      REASONS+=("repo does not allow $name ($field=$value)")
      ;;
    *)
      printf 'error: %s must be true|false (got %q)\n' "$var" "$value" >&2
      exit 2
      ;;
  esac
}

check_repo_setting REPO_ALLOWS_SQUASH     allow_squash_merge squash-merge
check_repo_setting REPO_ALLOWS_AUTO_MERGE allow_auto_merge   auto-merge

if [[ "$gate7_failed" == true ]]; then
  FAILED_GATES+=(7)
fi

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
