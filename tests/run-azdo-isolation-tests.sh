#!/usr/bin/env bash
#
# run-azdo-isolation-tests.sh — structural guard for the Azure DevOps agent user
# boundary (#591, ADR-024), the counterpart of run-agent-isolation-tests.sh for
# this forge. The GitHub path keeps the agent out of the judge's job; here the
# agent is kept out of the judge's *user*, and that property lives in a handful
# of lines spread over five scripts. This test is what keeps them.
#
# It asserts, by reading the scripts (no runs, no Docker, no sudo):
#
#   1. implement-azdo.sh checks the boundary before it can reach an agent, and
#      its agent call names the agent's workspace.
#   2. azdo-self-fix.sh does the same for the fix agent.
#   3. no `git -c http.extraheader` is left in scripts/ — the token stays out of
#      argv, where any uid can read it.
#   4. every git call in agent-boundary.sh and in the three entry points
#      disables hooks and fsmonitor.
#   5. the sudoers drop-in grants exactly the three entry points, as awf-agent,
#      with exactly the environment allowlist.
#   6. the agent's result is read only through import-result-output.sh.
#
# Every check has a negative case: the same check run against a mutated copy of
# the tree must fail, or the check is not biting.
#
# Usage: tests/run-azdo-isolation-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
#
# shellcheck disable=SC2016  # the patterns and sed scripts below quote the
# scripts under test verbatim: their $vars must not expand here.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PASS=0
FAIL=0
FAIL_NAMES=()

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_GREEN=''; C_RED=''; C_DIM=''; C_OFF=''
fi

section() { printf '\n%s── %s ──%s\n' "$C_DIM" "$1" "$C_OFF"; }
pass() { PASS=$((PASS + 1)); printf '  %s✓%s %s\n' "$C_GREEN" "$C_OFF" "$1"; }
fail() {
  FAIL=$((FAIL + 1)); FAIL_NAMES+=("$1")
  printf '  %s✗%s %s\n' "$C_RED" "$C_OFF" "$1"
  [ $# -gt 1 ] && printf '      %s\n' "$2"
  return 0
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ENV_ALLOWLIST='CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY MODEL MAX_TURNS'
BOUNDARY_DIR_PATH=/usr/local/libexec/awf-agent

# logical <file> — one logical shell command per line: comment lines dropped,
# `\`-continued lines joined, whitespace runs collapsed. A command split over
# four lines is one line here, so "this call carries that variable" is a
# question about one line.
logical() {
  awk '
    /^[[:space:]]*#/ { next }
    {
      line = $0
      cont = (line ~ /\\[[:space:]]*$/)
      sub(/\\[[:space:]]*$/, "", line)
      buf = buf " " line
      if (cont) next
      gsub(/[[:space:]]+/, " ", buf)
      sub(/^ /, "", buf); sub(/ $/, "", buf)
      if (buf != "") print buf
      buf = ""
    }
    END { gsub(/[[:space:]]+/, " ", buf); sub(/^ /, "", buf); if (buf != "") print buf }
  ' "$1"
}

# func_body <text> <name> — the body of one shell function. Order inside a
# function is order of execution; order of DEFINITIONS is not, which is why
# every "X happens before Y" check below is scoped to one body.
func_body() {
  printf '%s\n' "$1" | awk -v name="$2" '
    $0 == name "() {" { inside = 1; next }
    inside && $0 == "}" { inside = 0 }
    inside { print }
  '
}

# before <text> <first> <second> — 0 when both appear and <first> comes first.
before() {
  local first second
  first="$(printf '%s\n' "$1" | grep -n -F -- "$2" | head -n1 | cut -d: -f1)"
  second="$(printf '%s\n' "$1" | grep -n -F -- "$3" | head -n1 | cut -d: -f1)"
  [[ -n "$first" && -n "$second" && "$first" -lt "$second" ]]
}

# Failures of the current run_checks call. EMIT=1 reports and counts each
# result; EMIT=0 only records, so a negative case stays silent.
CHECK_FAILS=0
CHECK_FAIL_NAMES=""
EMIT=1

check() { # check <name> <ok|bad> [detail]
  local name="$1" verdict="$2" detail="${3:-}"
  if [[ "$verdict" == ok ]]; then
    [[ "$EMIT" == 1 ]] && pass "$name"
    return 0
  fi
  CHECK_FAILS=$((CHECK_FAILS + 1))
  CHECK_FAIL_NAMES+=" $name "
  if [[ "$EMIT" == 1 ]]; then fail "$name" "$detail"; fi
  return 0
}

verdict() { if [[ "$1" -eq 0 ]]; then printf ok; else printf bad; fi; }

# --- the checks ---------------------------------------------------------------

check_implement_driver() { # check_implement_driver <root>
  local file="$1/scripts/implement-azdo.sh" text rc

  text="$(logical "$file")"
  rc=0
  # preflight runs before anything else and is where the boundary is demanded;
  # preflight_boundary records a refusal, and refuse_without_boundary reports
  # it and exits before the attempt loop can start an agent.
  local main_body
  main_body="$(func_body "$text" main)"
  before "$main_body" preflight refuse_without_boundary || rc=1
  before "$main_body" refuse_without_boundary attempt_loop || rc=1
  grep -q 'preflight_boundary' <<<"$(func_body "$text" preflight)" || rc=1
  grep -q 'checkout_has_credentials' <<<"$(func_body "$text" preflight_boundary)" || rc=1
  grep -q 'boundary_check' <<<"$(func_body "$text" preflight_boundary)" || rc=1
  grep -q 'exit 1' <<<"$(func_body "$text" refuse_without_boundary)" || rc=1
  check implement_boundary_check_precedes_the_agent "$(verdict "$rc")" \
    "preflight must call preflight_boundary, which must demand both the boundary and a credential-free checkout"

  # The private-feed pre-restore (#641) holds the driver's token, so it runs
  # before any agent: its config half in preflight, the restore itself once the
  # default branch is known, and a failure refuses the run like a missing
  # boundary does.
  rc=0
  grep -q 'preflight_restore' <<<"$(func_body "$text" preflight)" || rc=1
  before "$(func_body "$text" preflight)" preflight_boundary preflight_restore || rc=1
  before "$main_body" resolve_default_branch restore_private_feeds || rc=1
  before "$main_body" restore_private_feeds attempt_loop || rc=1
  grep -q 'refuse_without_boundary' <<<"$(func_body "$text" restore_private_feeds)" || rc=1
  grep -q 'pipeline_mode' <<<"$(func_body "$text" restore_private_feeds)" || rc=1
  check implement_restore_precedes_the_agent "$(verdict "$rc")" \
    "the private-feed restore must run in pipeline mode, after the default branch and before attempt_loop, and refuse on failure"

  local calls missing=0 line
  calls="$(printf '%s\n' "$text" | grep -F 'lib/agent-cmd-claude-implement.sh' || true)"
  while read -r line; do
    [[ -n "$line" ]] || continue
    [[ "$line" == *"AGENT_WORKSPACE="* ]] || missing=1
  done <<<"$calls"
  check implement_agent_call_carries_the_workspace "$(verdict "$missing")" \
    "every call of the implement wrapper must pass AGENT_WORKSPACE"
}

check_self_fix_driver() { # check_self_fix_driver <root>
  local file="$1/scripts/azdo-self-fix.sh" text rc=0

  text="$(logical "$file")"
  grep -q 'pipeline_mode' <<<"$(func_body "$text" main)" || rc=1
  grep -q 'run_fix_in_boundary' <<<"$(func_body "$text" main)" || rc=1
  before "$(func_body "$text" run_fix_in_boundary)" boundary_check run_fix_without_push || rc=1
  check selffix_boundary_check_precedes_the_agent "$(verdict "$rc")" \
    "main must dispatch to run_fix_in_boundary in pipeline mode, which must check the boundary before the agent"

  rc=0
  grep -qE 'AGENT_WORKSPACE=.*SF_AGENT_WS|SKIP_COMMIT=1 "AGENT_WORKSPACE' <<<"$text" || rc=1
  grep -q 'boundary_commit' <<<"$text" || rc=1
  grep -q 'boundary_reap' <<<"$text" || rc=1
  check selffix_fix_call_carries_the_workspace "$(verdict "$rc")" \
    "the pipeline path must set AGENT_WORKSPACE and commit/reap inside the boundary"
}

check_token_out_of_argv() { # check_token_out_of_argv <root>
  local hits
  hits="$(grep -rnE -- '-c[[:space:]]+http\.extraheader' "$1/scripts" 2>/dev/null \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
  check no_git_dash_c_extraheader_in_scripts \
    "$([[ -z "$hits" ]] && echo ok || echo bad)" "found: $(printf '%s' "$hits" | head -n2)"
}

check_git_calls_disable_hooks() { # check_git_calls_disable_hooks <root>
  local files=("$1/scripts/lib/agent-boundary.sh") name bad='' file line
  for name in awf-agent-run awf-agent-git awf-agent-reap; do
    files+=("$1/docker/azp-agent/boundary/$name")
  done
  for file in "${files[@]}"; do
    [[ -r "$file" ]] || { bad+=" ${file##*/}:unreadable"; continue; }
    while read -r line; do
      [[ -n "$line" ]] || continue
      # A git call, not a word inside a string: `git` starting a command.
      grep -qE '(^|[;&|(][[:space:]]*|^[[:space:]]*)git[[:space:]]' <<<"$line" || continue
      [[ "$line" == *"core.hooksPath=/dev/null"* && "$line" == *"core.fsmonitor=false"* ]] && continue
      bad+=" ${file##*/}:[$line]"
    done <<<"$(logical "$file")"
  done
  check boundary_git_calls_disable_hooks_and_fsmonitor \
    "$([[ -z "$bad" ]] && echo ok || echo bad)" "without both flags:$bad"
}

check_sudoers() { # check_sudoers <root>
  local file="$1/docker/azp-agent/sudoers-awf-agent" rule commands expected rc=0
  [[ -r "$file" ]] || { check sudoers_grants_only_the_three_entry_points bad "missing $file"; return 0; }
  rule="$(grep -E '^azp ' "$file" | head -n1 || true)"
  expected="$BOUNDARY_DIR_PATH/awf-agent-run, $BOUNDARY_DIR_PATH/awf-agent-git, $BOUNDARY_DIR_PATH/awf-agent-reap"
  [[ "$rule" =~ ^azp\ ALL=\(awf-agent\)\ NOPASSWD:\ (.*)$ ]] || rc=1
  commands="${BASH_REMATCH[1]:-}"
  [[ "$commands" == "$expected" ]] || rc=1
  grep -qF "Defaults:azp env_keep = \"$ENV_ALLOWLIST\"" "$file" || rc=1
  grep -qE '^Defaults:azp env_reset$' "$file" || rc=1
  check sudoers_grants_only_the_three_entry_points "$(verdict "$rc")" "rule: $rule"
}

check_result_import() { # check_result_import <root>
  local file="$1/scripts/implement-azdo.sh" text rc=0 reads
  text="$(logical "$file")"
  grep -q 'RESULT_JSON_FILE=' <<<"$text" || rc=1
  grep -q 'import-result-output.sh' <<<"$text" || rc=1
  grep -qF 'RESULT_FILE="$(_output_value result-file' <<<"$text" || rc=1
  # Nothing may parse the raw result itself: it is the agent's text until the
  # import has rebuilt it field by field.
  reads="$(printf '%s\n' "$text" | grep -F 'raw-result.json' \
    | grep -E '(jq|awk|sed|python3|grep|cat) ' || true)"
  [[ -z "$reads" ]] || rc=1
  check agent_result_read_only_through_the_import "$(verdict "$rc")" \
    "raw reads: $(printf '%s' "$reads" | head -n1)"
}

run_checks() { # run_checks <root>
  CHECK_FAILS=0
  CHECK_FAIL_NAMES=""
  check_implement_driver "$1"
  check_self_fix_driver "$1"
  check_token_out_of_argv "$1"
  check_git_calls_disable_hooks "$1"
  check_sudoers "$1"
  check_result_import "$1"
}

# --- mutations ----------------------------------------------------------------

# tree_copy <name> — a copy of the files the checks read, as its own root.
tree_copy() {
  local dir="$WORK/$1"
  mkdir -p "$dir/scripts/lib" "$dir/docker/azp-agent/boundary"
  cp "$ROOT/scripts/implement-azdo.sh" "$ROOT/scripts/azdo-self-fix.sh" "$dir/scripts/"
  cp "$ROOT/scripts/lib/agent-boundary.sh" "$dir/scripts/lib/"
  cp "$ROOT/docker/azp-agent/boundary/"* "$dir/docker/azp-agent/boundary/"
  cp "$ROOT/docker/azp-agent/sudoers-awf-agent" "$dir/docker/azp-agent/"
  printf '%s' "$dir"
}

mutate_drop_preflight_boundary() {
  sed -i '/|| preflight_boundary$/d' "$1/scripts/implement-azdo.sh"
}
mutate_drop_agent_workspace() {
  sed -i 's/ AGENT_WORKSPACE="\$AGENT_WORKSPACE" \\/ \\/' "$1/scripts/implement-azdo.sh"
}
mutate_drop_boundary_refusal() {
  sed -i '/^  refuse_without_boundary$/d' "$1/scripts/implement-azdo.sh"
}
mutate_drop_selffix_boundary_check() {
  sed -i '/boundary_check >\/dev\/null/d' "$1/scripts/azdo-self-fix.sh"
}
mutate_drop_selffix_workspace() {
  sed -i '/boundary=(SKIP_COMMIT=1 "AGENT_WORKSPACE=/d' "$1/scripts/azdo-self-fix.sh"
}
mutate_token_back_into_argv() {
  sed -i 's/  azdo_git push -q -u "\${lease\[@\]}" origin "\$1"/  git -c http.extraheader="x" push -q -u "${lease[@]}" origin "$1"/' \
    "$1/scripts/implement-azdo.sh"
}
mutate_strip_hook_flags() {
  sed -i 's/  git -c core.hooksPath=\/dev\/null -c core.fsmonitor=false "\$@"/  git "$@"/' \
    "$1/scripts/lib/agent-boundary.sh"
}
mutate_sudoers_all_commands() {
  sed -i -E 's#NOPASSWD: .*#NOPASSWD: ALL#' "$1/docker/azp-agent/sudoers-awf-agent"
}
mutate_restore_after_the_agent() {
  sed -i '/^  restore_private_feeds$/d' "$1/scripts/implement-azdo.sh"
}
mutate_read_the_raw_result() {
  sed -i 's/  RESULT_FILE="\$(_output_value result-file "\$out\/outputs")"/  RESULT_FILE="$raw"/' \
    "$1/scripts/implement-azdo.sh"
}

# negative <case-name> <mutator> <check-that-must-fail>
negative() {
  local name="$1" mutator="$2" expected="$3" dir
  dir="$(tree_copy "$name")"
  "$mutator" "$dir"
  if diff -r -q "$(tree_copy "${name}-pristine")" "$dir" >/dev/null 2>&1; then
    fail "$name" "mutation changed nothing — the case would pass vacuously"
    return 0
  fi
  EMIT=0; run_checks "$dir"; EMIT=1
  if (( CHECK_FAILS > 0 )) && [[ "$CHECK_FAIL_NAMES" == *" $expected "* ]]; then pass "$name"; else
    fail "$name" "expected $expected to fail | failed: ${CHECK_FAIL_NAMES:-none}"; fi
}

section "the boundary holds in the tree as it stands"
run_checks "$ROOT"

section "negative cases (a mutated tree must be caught)"
negative negative_no_boundary_preflight_is_caught mutate_drop_preflight_boundary \
  implement_boundary_check_precedes_the_agent
negative negative_agent_outside_the_workspace_is_caught mutate_drop_agent_workspace \
  implement_agent_call_carries_the_workspace
negative negative_no_boundary_refusal_is_caught mutate_drop_boundary_refusal \
  implement_boundary_check_precedes_the_agent
negative negative_selffix_without_boundary_check_is_caught mutate_drop_selffix_boundary_check \
  selffix_boundary_check_precedes_the_agent
negative negative_selffix_agent_outside_the_workspace_is_caught mutate_drop_selffix_workspace \
  selffix_fix_call_carries_the_workspace
negative negative_token_in_argv_is_caught mutate_token_back_into_argv \
  no_git_dash_c_extraheader_in_scripts
negative negative_hooks_enabled_is_caught mutate_strip_hook_flags \
  boundary_git_calls_disable_hooks_and_fsmonitor
negative negative_broad_sudo_grant_is_caught mutate_sudoers_all_commands \
  sudoers_grants_only_the_three_entry_points
negative negative_raw_result_read_is_caught mutate_read_the_raw_result \
  agent_result_read_only_through_the_import
negative negative_no_feed_restore_before_the_agent_is_caught mutate_restore_after_the_agent \
  implement_restore_precedes_the_agent

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then printf 'Failed: %s\n' "${FAIL_NAMES[*]}"; exit 1; fi
