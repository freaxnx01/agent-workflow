#!/usr/bin/env bash
#
# review-pr.sh — Agent-driven review of a freshly-opened PR.
#
# Fetches the PR diff, runs the selected agent against a review prompt
# template (scripts/lib/review-prompt.md), validates the structured reply,
# and posts a single PR comment with the summary. Idempotent per PR head
# SHA — repeated invocations against the same SHA do not duplicate the
# comment.
#
# The verdict is emitted to $GITHUB_OUTPUT for the downstream auto-merge
# job (#15) to act on. This script intentionally does NOT translate the
# verdict into a formal GitHub Pull Request Review (approve /
# request_changes) — that lives in #15 so the policy can also encode the
# rest of the auto-merge safety envelope (ADR-002).
#
# Required environment variables:
#   PR_NUMBER   PR number to review
#   REPO        owner/repo (default: $GITHUB_REPOSITORY)
#   AGENT       claude | opencode
#   HEAD_SHA    PR head commit SHA (used as the idempotency marker)
#
# Optional environment variables:
#   MODEL              Model id passed to the agent (default: agent's choice)
#   AGENT_CMD          Override the agent invocation. Contract:
#                        $AGENT_CMD <prompt-file> <result-file>
#                      Default resolves per-AGENT to a real CLI in PATH.
#                      Tests set this to a mock that emits a fixture.
#   MAX_DIFF_BYTES     Refuse to review diffs larger than this. Default
#                      320000 (~80k tokens at ~4 chars/token).
#   PROMPT_TEMPLATE    Override path to the review prompt template.
#                      Default: <script-dir>/lib/review-prompt.md
#   DIFF_FILE          Pre-fetched diff path. If set, skips `gh pr diff`.
#                      Used by Layer-1 tests.
#   EXISTING_COMMENTS  Newline-separated comment bodies. If set, skips the
#                      `gh pr view --json comments` call. Used by tests.
#   DRY_RUN            "1" to render the comment body but skip posting.
#
# Output ($GITHUB_OUTPUT):
#   verdict       approve | request_changes | block
#   reason        free-text explanation (always set)
#   summary-file  path to the validated agent JSON (for #15)
#   posted        true|false — whether a new comment was posted this run
#
# Exit codes:
#   0   success (any verdict, including block — agent crashes and
#       non-JSON output are normalized to verdict=block, not a non-zero
#       exit, so #15's gating wiring sees a verdict either way)
#   2   required env missing or invalid
#   64  template / fixture missing or unreadable
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- env validation -------------------------------------------------------

require_env() {
  if [[ -z "${!1:-}" ]]; then
    printf 'error: %s must be set\n' "$1" >&2
    exit 2
  fi
}

require_env PR_NUMBER
require_env HEAD_SHA
REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
if [[ -z "$REPO" ]]; then
  printf 'error: REPO or GITHUB_REPOSITORY must be set\n' >&2
  exit 2
fi

AGENT="${AGENT:-claude}"
case "$AGENT" in
  claude|opencode) ;;
  *)
    printf 'error: AGENT must be one of: claude | opencode (got %q)\n' "$AGENT" >&2
    exit 2
    ;;
esac

MAX_DIFF_BYTES="${MAX_DIFF_BYTES:-320000}"
PROMPT_TEMPLATE="${PROMPT_TEMPLATE:-$SCRIPT_DIR/lib/review-prompt.md}"

if [[ ! -r "$PROMPT_TEMPLATE" ]]; then
  printf 'error: prompt template not readable: %s\n' "$PROMPT_TEMPLATE" >&2
  exit 64
fi

WORK_DIR="${RUNNER_TEMP:-$(mktemp -d)}"
PROMPT_FILE="$WORK_DIR/review-prompt.md"
RESULT_FILE="$WORK_DIR/review-result.json"
COMMENT_FILE="$WORK_DIR/review-comment.md"

# --- helpers --------------------------------------------------------------

emit_output() {
  local key="$1" value="$2"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$key" "$value" >> "$GITHUB_OUTPUT"
  fi
}

marker() { printf '<!-- review-pr:%s -->' "$HEAD_SHA"; }

render_comment() {
  local verdict="$1" reason="$2" json_file="$3"
  # Backticks below are Markdown code spans, not command substitutions.
  # shellcheck disable=SC2016
  {
    marker; printf '\n\n'
    printf '## Automated review — verdict: `%s`\n\n' "$verdict"
    if [[ -n "$reason" ]]; then
      printf '_%s_\n\n' "$reason"
    fi
    if [[ -s "$json_file" ]]; then
      local summary
      summary="$(jq -r '.summary // ""' "$json_file" 2>/dev/null || true)"
      if [[ -n "$summary" ]]; then
        printf '%s\n\n' "$summary"
      fi
      local concerns_count
      concerns_count="$(jq -r '.concerns | length' "$json_file" 2>/dev/null || echo 0)"
      if [[ "$concerns_count" != 0 ]]; then
        printf '### Concerns\n\n'
        jq -r '.concerns[] | "- **\(.severity)**: \(.message)"' "$json_file"
        printf '\n'
      fi
    fi
    printf '_Agent: %s · head: `%s`_\n' "$AGENT" "$HEAD_SHA"
  } > "$COMMENT_FILE"
}

post_or_skip() {
  local existing
  if [[ -n "${EXISTING_COMMENTS:-}" ]]; then
    existing="$EXISTING_COMMENTS"
  else
    existing="$(gh pr view "$PR_NUMBER" --repo "$REPO" --json comments \
      --jq '.comments[].body' 2>/dev/null || true)"
  fi

  if printf '%s' "$existing" | grep -qF "$(marker)"; then
    printf 'skip-post: existing comment already marks head %s\n' "$HEAD_SHA"
    emit_output posted false
    return 0
  fi

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    printf 'dry-run: would post comment (see %s)\n' "$COMMENT_FILE"
    emit_output posted false
    return 0
  fi

  gh pr comment "$PR_NUMBER" --repo "$REPO" --body-file "$COMMENT_FILE" >/dev/null
  emit_output posted true
}

finish() {
  local verdict="$1" reason="$2" json_file="$3"
  render_comment "$verdict" "$reason" "$json_file"
  post_or_skip
  emit_output verdict "$verdict"
  emit_output reason "$reason"
  emit_output summary-file "$json_file"
  printf 'verdict=%s (%s)\n' "$verdict" "$reason"
  exit 0
}

# --- 1) diff fetch + size guard ------------------------------------------

if [[ -n "${DIFF_FILE:-}" ]]; then
  if [[ ! -r "$DIFF_FILE" ]]; then
    printf 'error: DIFF_FILE not readable: %s\n' "$DIFF_FILE" >&2
    exit 64
  fi
else
  DIFF_FILE="$WORK_DIR/pr.diff"
  gh pr diff "$PR_NUMBER" --repo "$REPO" --patch > "$DIFF_FILE"
fi

diff_bytes="$(wc -c < "$DIFF_FILE" | tr -d ' ')"
if (( diff_bytes > MAX_DIFF_BYTES )); then
  reason="diff size ${diff_bytes}B exceeds cap ${MAX_DIFF_BYTES}B — unreviewable"
  printf '{"verdict":"block","summary":"%s","concerns":[]}' "$reason" > "$RESULT_FILE"
  finish block "$reason" "$RESULT_FILE"
fi

# --- 2) build prompt ------------------------------------------------------

# Read template once, splice placeholders. Done with awk so the diff body
# (which may contain `&`, backslashes, etc.) isn't mangled by sed.
awk -v repo="$REPO" -v pr="$PR_NUMBER" -v sha="$HEAD_SHA" -v diff_path="$DIFF_FILE" '
  {
    gsub(/\{\{REPO\}\}/, repo)
    gsub(/\{\{PR_NUMBER\}\}/, pr)
    gsub(/\{\{HEAD_SHA\}\}/, sha)
    if (index($0, "{{DIFF}}")) {
      while ((getline line < diff_path) > 0) print line
      close(diff_path)
    } else {
      print
    }
  }
' "$PROMPT_TEMPLATE" > "$PROMPT_FILE"

# --- 3) invoke agent ------------------------------------------------------

if [[ -z "${AGENT_CMD:-}" ]]; then
  # Default: call the agent CLI with a `--model` flag if MODEL is set,
  # passing the prompt via stdin and writing JSON to stdout. The wrapper
  # captures stdout into $RESULT_FILE. Real wiring per agent lands in #15
  # — this default is here so the script is self-contained for shellcheck
  # and ad-hoc runs.
  #
  # Heredoc is single-quoted so AGENT_BIN / MODEL / argv expand at wrapper
  # *runtime* in the child shell — never at write time in this parent
  # shell. Embedding raw env values into the generated script would be a
  # shell-injection vector (a MODEL value containing `"`, `` ` ``, or `$`
  # would execute arbitrary code under the runner).
  case "$AGENT" in
    claude)   export AGENT_BIN=claude ;;
    opencode) export AGENT_BIN=opencode ;;
  esac
  export MODEL="${MODEL:-}"
  AGENT_CMD="$WORK_DIR/agent-cmd-default.sh"
  cat > "$AGENT_CMD" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
prompt="$1"; out="$2"
args=()
[[ -n "${MODEL:-}" ]] && args+=(--model "$MODEL")
"$AGENT_BIN" "${args[@]}" < "$prompt" > "$out"
EOF
  chmod +x "$AGENT_CMD"
fi

if ! "$AGENT_CMD" "$PROMPT_FILE" "$RESULT_FILE"; then
  reason='agent invocation failed'
  printf '{"verdict":"block","summary":"%s","concerns":[]}' "$reason" > "$RESULT_FILE"
  finish block "$reason" "$RESULT_FILE"
fi

# --- 4) validate result ---------------------------------------------------

# Agents often wrap the JSON verdict in a ```json fence or a sentence of prose
# (#72). Try the output as-is; if it isn't valid JSON, salvage the object — the
# span from the first line containing `{` to the last line containing `}`, which
# also drops surrounding fences/prose — and re-validate. Only output with no
# recoverable JSON object fail-safe blocks.
if ! jq -e . "$RESULT_FILE" >/dev/null 2>&1; then
  salvaged="$WORK_DIR/review-result.salvaged.json"
  awk '
    { lines[NR] = $0 }
    END {
      first = 0; last = 0
      for (i = 1; i <= NR; i++) if (!first && index(lines[i], "{")) first = i
      for (i = NR; i >= 1; i--) if (!last  && index(lines[i], "}")) last  = i
      if (first && last && last >= first)
        for (i = first; i <= last; i++) print lines[i]
    }
  ' "$RESULT_FILE" > "$salvaged"
  if [[ -s "$salvaged" ]] && jq -e . "$salvaged" >/dev/null 2>&1; then
    mv "$salvaged" "$RESULT_FILE"
  else
    reason='agent produced non-JSON output'
    printf '{"verdict":"block","summary":"%s","concerns":[]}' "$reason" > "$RESULT_FILE"
    finish block "$reason" "$RESULT_FILE"
  fi
fi

verdict="$(jq -r '.verdict // ""' "$RESULT_FILE")"
case "$verdict" in
  approve|request_changes|block) ;;
  *)
    reason="agent returned invalid verdict: ${verdict:-<empty>}"
    # Preserve the original JSON for #15 debugging, but force-block.
    jq --arg r "$reason" '. + {verdict:"block", summary:$r}' "$RESULT_FILE" \
      > "$RESULT_FILE.tmp" && mv "$RESULT_FILE.tmp" "$RESULT_FILE"
    finish block "$reason" "$RESULT_FILE"
    ;;
esac

reason="agent verdict: $verdict"
finish "$verdict" "$reason" "$RESULT_FILE"
