#!/usr/bin/env bash
# azdo-plan-pointer.sh — find the implementation plan an enriched Azure DevOps
# work item points to (#651).
#
# Source this file, then call:  azdo_plan_pointer <body>
#
# Per ADR-017 the plan is never inlined into `System.Description` -- that field
# is HTML -- so /enrich writes the committed plan's repo-relative path into it
# instead, typically inside a <code> element. Everything that wants to size work
# from the plan has to start by finding that path, and the body it starts from
# is raw HTML, not Markdown.
#
# Matching: the first path matching
#   docs/<anything>plans/<anything>.md
# wins. The spec pointer (docs/.../specs/...-design.md) is written first by
# /enrich and does not match, so "first" means "first plan", not "first link".
#
# Refused, because the result is used to read a file out of the checkout:
#   * a path containing ".." -- it can leave the repository;
#   * a path starting with "/" -- it is absolute, and it is also what the inside
#     of a URL looks like (https://host/docs/.../plans/x.md).
# The leading "/" is part of the match rather than a lookbehind, so a path
# preceded by one is seen as absolute rather than silently truncated to the
# relative-looking tail.
#
# Return codes:
#   0  a usable path was found; it is printed to stdout, with no trailing text
#   1  no match, or the only match was refused; nothing is printed

_AZDO_PLAN_POINTER_RE='/?docs/[A-Za-z0-9._/-]*plans/[A-Za-z0-9._/-]*\.md'

# azdo_plan_pointer <body>
azdo_plan_pointer() {
  local body="${1-}" path
  local -a matches=()
  # Collect every match and take the first, rather than `grep ... | head -1`:
  # head exits on its first line, grep then dies of SIGPIPE, and the caller's
  # `set -o pipefail` turns a SUCCESSFUL match into a failed pipeline. That is
  # the trap that silently downgraded a 57 KB enriched body to the default
  # budget once already -- see the here-string comment in classify-turns.sh.
  # `|| true`: grep exits 1 on no match, which is a documented answer here.
  mapfile -t matches < <(grep -oE "$_AZDO_PLAN_POINTER_RE" <<< "$body" || true)
  path="${matches[0]-}"

  [[ -n "$path" ]] || return 1
  [[ "$path" != /* ]] || return 1
  [[ "$path" != *..* ]] || return 1

  printf '%s\n' "$path"
}
