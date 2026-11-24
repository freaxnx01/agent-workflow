#!/usr/bin/env bash
#
# run-azdo-markdown-doc-tests.sh — Layer-1 checks on the Azure DevOps sections
# of commands/enrich.md and commands/new.md, and on ADR-025 (#683). The
# sections are prompts, not scripts, so these assert the names and shapes the
# Markdown-work-item path depends on.
#
# Usage: tests/run-azdo-markdown-doc-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PASS=0
FAIL=0
FAIL_NAMES=()

pass() { PASS=$((PASS + 1)); printf '  ✓ %s\n' "$1"; }
fail() {
  FAIL=$((FAIL + 1)); FAIL_NAMES+=("$1")
  printf '  ✗ %s\n' "$1"
  [[ $# -gt 1 ]] && printf '      %s\n' "$2"
  return 0
}

# has NAME TEXT PATTERN [grep flags] — assert PATTERN matches TEXT.
has() {
  local name="$1" text="$2" pattern="$3" flags="${4:--E}"
  if printf '%s\n' "$text" | grep -q "$flags" -- "$pattern"; then pass "$name"
  else fail "$name" "no match for: $pattern"; fi
}

# lacks NAME TEXT PATTERN — assert a fixed string is absent.
lacks() {
  local name="$1" text="$2" pattern="$3"
  if printf '%s\n' "$text" | grep -qF -- "$pattern"; then fail "$name" "found: $pattern"
  else pass "$name"; fi
}

ado_section() {
  awk '/^## Azure DevOps$/{on=1; print; next} on && /^## /{exit} on{print}' "$1"
}

enrich="$(ado_section "$ROOT/commands/enrich.md")"
new="$(ado_section "$ROOT/commands/new.md")"

has "enrich_ado_ReadsFormat" "$enrich" 'azdo_description_format'
has "enrich_ado_MarkdownBranch: setter" "$enrich" 'azdo_set_markdown_description' -F
has "enrich_ado_MarkdownBranch: plan heading" "$enrich" '## Implementation Plan' -F
has "enrich_ado_MarkdownBranch: AC heading" "$enrich" '## Acceptance Criteria' -F
has "enrich_ado_MarkdownBranch: spec heading" "$enrich" '## Spec' -F
has "enrich_ado_HtmlBranchKept: azdo_set_description" "$enrich" 'azdo_set_description' -F
has "enrich_ado_HtmlBranchKept: azdo_html_escape" "$enrich" 'azdo_html_escape' -F
has "enrich_ado_SizeLimit" "$enrich" '1,000,000' -F

# A failed format read must stop and release the lock, never fall to HTML.
fmt_para="$(printf '%s\n' "$enrich" | grep -B4 -A8 'azdo_description_format' | head -40 || true)"
has "enrich_ado_FormatFailureStops: stops" "$fmt_para" 'stop' -i
# shellcheck disable=SC2016  # literal $ISSUE in the doc
has "enrich_ado_FormatFailureStops: releases the lock" "$fmt_para" 'azdo_remove_tag "\$ISSUE" enrichment-ongoing'
has "enrich_ado_FormatFailureStops: not HTML" "$fmt_para" 'never.*HTML' -Ei

has "new_ado_CreatesMarkdown" "$new" 'azdo_create_markdown_item' -F
lacks "new_ado_CreatesMarkdown: old call gone" "$new" 'System.Description=<body>'

has "decisions_Adr025" "$(cat "$ROOT/docs/DECISIONS.md")" \
  '^## ADR-025 — A Markdown work item carries the plan inline \(2026-11-23\)$'
adr017="$(awk '/^## ADR-017 /{on=1; print; next} on && /^## /{exit} on{print}' "$ROOT/docs/DECISIONS.md")"
has "decisions_Adr017Amended" "$adr017" 'ADR-025' -F

printf '\npassed: %d   failed: %d\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'failed:\n'
  for n in "${FAIL_NAMES[@]}"; do printf -- '  - %s\n' "$n"; done
  exit 1
fi
exit 0
