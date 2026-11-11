#!/usr/bin/env bash
# pipeline-file-guard.sh — refuse to push agent changes to CI pipeline definitions (C6).
#
# Source this file, then call:  pipeline_file_guard <base-ref>
#
# An agent that can edit the pipeline file that validates its own PR could weaken
# the gate. Callers run this before any push and treat any non-zero as "do not push".
#
# Default globs (always active):
#   azure-pipelines*.yml   azure-pipelines*.yaml   .azure-pipelines/*   .azuredevops/*
# Extra globs: env PIPELINE_FILE_GLOBS, comma-separated, whitespace around entries
# is trimmed and empty entries are skipped. It can only add globs, never remove defaults.
#
# Matching: a glob containing "/" is matched against the full repo-relative path; a
# glob without "/" is matched against the basename. Bash "*" crosses "/", so "**"
# behaves like "*" and ".azure-pipelines/*" covers any depth.
#
# Scope: only committed changes in <base-ref>...HEAD count (that is all that gets
# pushed). Deletions and the old side of renames are included (--no-renames).
#
# Return codes:
#   0  no changed path matches
#   1  at least one path matches; each is printed to stderr as "  <path>"
#   2  the diff could not be computed (unknown base ref, no merge base); fail closed
# Prints nothing to stdout.

_PFG_DEFAULT_GLOBS=('azure-pipelines*.yml' 'azure-pipelines*.yaml' '.azure-pipelines/*' '.azuredevops/*')

# _pfg_globs — print the active globs, one per line.
_pfg_globs() {
  local entry
  printf '%s\n' "${_PFG_DEFAULT_GLOBS[@]}"
  local -a extra=()
  IFS=, read -r -a extra <<< "${PIPELINE_FILE_GLOBS:-}" || true
  for entry in "${extra[@]}"; do
    entry="${entry#"${entry%%[![:space:]]*}"}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    [[ -n "$entry" ]] && printf '%s\n' "$entry"
  done
  return 0
}

# _pfg_matches <path> — 0 if the path matches any active glob.
_pfg_matches() {
  local path="$1" glob target
  while IFS= read -r glob; do
    target="$path"
    [[ "$glob" == */* ]] || target="${path##*/}"
    # shellcheck disable=SC2053  # right-hand side is intentionally a glob pattern
    [[ "$target" == $glob ]] && return 0
  done < <(_pfg_globs)
  return 1
}

# _pfg_changed_paths <base-ref> <outfile> — NUL-separated changed paths into outfile.
_pfg_changed_paths() {
  git diff --name-only --no-renames -z "$1...HEAD" > "$2" 2>/dev/null
}

pipeline_file_guard() {
  local base="${1:?pipeline_file_guard: base ref required}"
  local tmp path found=0
  tmp="$(mktemp)"
  if ! _pfg_changed_paths "$base" "$tmp"; then
    rm -f "$tmp"
    printf 'pipeline_file_guard: cannot diff %s...HEAD\n' "$base" >&2
    return 2
  fi
  local -a paths=()
  mapfile -d '' paths < "$tmp"
  rm -f "$tmp"
  for path in "${paths[@]}"; do
    if _pfg_matches "$path"; then
      printf '  %s\n' "$path" >&2
      found=1
    fi
  done
  return "$found"
}
