#!/usr/bin/env bash
#
# check-caller-permissions.sh — Does a caller workflow grant every permission a
# reusable workflow's jobs request?
#
# A reusable workflow can never be granted more than its caller has. When a job
# in it asks for a scope the caller lacks, GitHub refuses the whole run at
# `startup_failure` — zero jobs, no logs (#434). This compares the two files
# statically so the gap is caught before a dispatch is.
#
# Usage: check-caller-permissions.sh <caller.yml|-> <reusable.yml>
#   '-' reads the caller from stdin.
#
# Semantics (GitHub's):
#   - A job's effective permissions are its own `permissions:` block if it has
#     one, else the workflow-level block. A job-level block REPLACES, it does
#     not merge.
#   - `read-all` / `write-all` grant that level on every scope.
#   - A scope absent from a block is `none`; `write` satisfies `read`.
#   - A caller with no block at all grants nothing we can rely on: the repo
#     default token is read-only on most repos, so every scope is reported.
#
# Output: one line per gap, `<scope>: needs <level>, caller grants <level>`.
# Exit codes: 0 no gap; 1 at least one gap; 2 bad arguments / unreadable file.
set -euo pipefail
IFS=$'\n\t'

usage_error() { printf 'error: %s\n' "$1" >&2; exit 2; }

# permission_entries <file> — `<context>\t<scope>\t<level>` per entry.
# context is `top` or `job:<name>`; scope `@` marks a job, `-` marks a block,
# `*` is read-all/write-all, `^` carries the job's `uses:` value.
permission_entries() {
  awk '
    function indent(s) { match(s, /^ */); return RLENGTH }
    /^[[:space:]]*(#|$)/ { next }
    {
      ind = indent($0); line = $0
      sub(/[[:space:]]+#.*$/, "", line); sub(/^ +/, "", line)
      if (inblock && ind > blockind) {
        key = line; sub(/:.*/, "", key)
        val = line; sub(/^[^:]*:[[:space:]]*/, "", val)
        printf "%s\t%s\t%s\n", ctx, key, val; next
      }
      inblock = 0
      if (ind == 0) { injobs = (line == "jobs:"); ctx = "top" }
      if (injobs && ind == 2 && line ~ /^[A-Za-z0-9_-]+:$/) {
        ctx = "job:" substr(line, 1, length(line) - 1)
        printf "%s\t@\t\n", ctx
      }
      if (injobs && ind == 4 && line ~ /^uses:/) {
        val = line; sub(/^uses:[[:space:]]*/, "", val)
        printf "%s\t^\t%s\n", ctx, val
      }
      if (line ~ /^permissions:/ && (ind == 0 || (injobs && ind == 4))) {
        val = line; sub(/^permissions:[[:space:]]*/, "", val)
        printf "%s\t-\t\n", ctx
        if (val == "read-all" || val == "write-all") printf "%s\t*\t%s\n", ctx, substr(val, 1, index(val, "-") - 1)
        else if (val == "") { inblock = 1; blockind = ind }
      }
    }' "$1"
}

rank() { case "$1" in write) printf 2 ;; read) printf 1 ;; *) printf 0 ;; esac }

# effective_grants <file> [calls] — `<scope>\t<level>` the file's jobs run with,
# the highest level per scope across jobs. With <calls> (a workflow file name),
# only jobs whose `uses:` names that file count: on the caller side, a scope
# granted to some unrelated job is never passed on to the reusable workflow.
# If no job names it, every job counts.
effective_grants() {
  local entries ctx scope level calls="${2:-}"
  entries="$(permission_entries "$1")"
  local -A has_block=() max=()
  local -a jobs=() callers=()
  while IFS=$'\t' read -r ctx scope level; do
    case "$scope" in
      @) jobs+=("$ctx") ;;
      -) has_block["$ctx"]=1 ;;
      ^) [[ -n "$calls" && "${level%@*}" == *"/$calls" ]] && callers+=("$ctx") ;;
    esac
  done <<< "$entries"
  ((${#callers[@]})) && jobs=("${callers[@]}")
  ((${#jobs[@]})) || jobs=(top)
  local job src
  for job in "${jobs[@]}"; do
    src="$job"; [[ -n "${has_block[$job]:-}" ]] || src=top
    while IFS=$'\t' read -r ctx scope level; do
      [[ "$ctx" == "$src" && "$scope" != @ && "$scope" != - && "$scope" != ^ ]] || continue
      if (( $(rank "$level") > $(rank "${max[$scope]:-none}") )); then max["$scope"]="$level"; fi
    done <<< "$entries"
  done
  for scope in "${!max[@]}"; do printf '%s\t%s\n' "$scope" "${max[$scope]}"; done
}

main() {
  [[ $# -eq 2 ]] || usage_error "usage: check-caller-permissions.sh <caller.yml|-> <reusable.yml>"
  local caller="$1" reusable="$2"
  [[ -r "$reusable" ]] || usage_error "cannot read $reusable"
  if [[ "$caller" == - ]]; then
    STDIN_COPY="$(mktemp)"; trap 'rm -f "$STDIN_COPY"' EXIT
    cat > "$STDIN_COPY"; caller="$STDIN_COPY"
  fi
  [[ -r "$caller" ]] || usage_error "cannot read $caller"

  local -A grant=()
  local scope level gaps=0 have
  while IFS=$'\t' read -r scope level; do
    [[ -n "$scope" ]] && grant["$scope"]="$level"
  done < <(effective_grants "$caller" "$(basename "$reusable")")

  while IFS=$'\t' read -r scope level; do
    [[ -n "$scope" ]] || continue
    have="${grant[$scope]:-${grant['*']:-none}}"
    if (( $(rank "$have") < $(rank "$level") )); then
      printf '%s: needs %s, caller grants %s\n' "$scope" "$level" "$have"
      gaps=$((gaps + 1))
    fi
  done < <(effective_grants "$reusable" | sort)
  (( gaps == 0 ))
}

main "$@"
