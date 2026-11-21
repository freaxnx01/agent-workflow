#!/usr/bin/env bash
#
# enrich-body.sh — sourced, not executed.
#   enrich_body_strip_markdown   filter: stdin to stdout, for GitHub/Forgejo bodies
#   enrich_body_strip_html       filter: stdin to stdout, for Azure DevOps HTML
#
# Both cut the body at the first enrich-owned heading and emit the prefix above
# it, so a re-run of /enrich REPLACES its own previous sections instead of
# appending a second Acceptance Criteria block (#499). Both exit 0 when there is
# nothing to strip, passing the input through unchanged, and non-zero only if
# python3 fails. Both are idempotent across a re-compose:
# strip(strip(x) + new sections) == strip(x).
#
# Not in azdo.sh deliberately: the HTML filter is text munging, not an Azure
# DevOps API call.
set -euo pipefail
IFS=$'\n\t'

# enrich_body_strip_markdown  filter: stdin to stdout.
#
# Cuts from the first line-anchored, exact level-2 enrich-owned heading to the
# end of the body. The owned headings are the six this command writes:
# Acceptance Criteria, Assumptions, Consequences, Implementation Plan, Spec, and
# Forgejo's combined "Spec & Implementation Plan".
#
# The cut runs to the end rather than removing each section individually,
# because the inlined plan carries its own `##` headings (e.g.
# `## Global Constraints`) and per-section removal would leave those fragments
# behind. Anything a human appended BELOW a previous run's sections goes with
# them -- indistinguishable from the plan's own headings.
#
# Matching is exact and case-sensitive, so `## Specification` and
# `## Acceptance criteria notes` are safe, and it skips lines inside ``` / ~~~
# fences so a body quoting a previous enrichment is not cut. Fences follow
# CommonMark: a fence closes only on the same character at least as long as
# the opener, so a ~~~ line inside a ``` fence, or a ``` block nested in a ````
# fence, does not end it early. `\r\n` is handled
# for matching only: the kept prefix is byte-identical to the input apart from
# trailing blank lines, which are dropped.
enrich_body_strip_markdown() {
  # shellcheck disable=SC2016  # backticks are fence characters in Python, not expansions
  python3 -c '
import re, sys

OWNED = re.compile(
    r"##[ \t]+("
    r"Acceptance Criteria"
    r"|Assumptions"
    r"|Consequences"
    r"|Implementation Plan"
    r"|Spec"
    r"|Spec & Implementation Plan"
    r")[ \t]*"
)

text = sys.stdin.buffer.read().decode("utf-8")
lines = text.splitlines(keepends=True)

FENCE = re.compile(r" {0,3}(`{3,}|~{3,})(.*)")

cut = None
fence = None  # the opening run, e.g. "````"; None outside a fence
for i, line in enumerate(lines):
    m = FENCE.fullmatch(line.rstrip("\r\n"))
    if fence is None:
        # A backtick fence may not carry a backtick in its info string.
        if m and not (m.group(1)[0] == "`" and "`" in m.group(2)):
            fence = m.group(1)
            continue
    else:
        # Close only on the same character, at least as long, with nothing after.
        run = m.group(1) if m else ""
        if run[:1] == fence[0] and len(run) >= len(fence) and not m.group(2).strip():
            fence = None
        continue
    if OWNED.fullmatch(line.rstrip("\r\n")):
        cut = i
        break

if cut is None:
    sys.stdout.buffer.write(text.encode("utf-8"))
    sys.exit(0)

kept = lines[:cut]
while kept and kept[-1].rstrip("\r\n") == "":
    kept.pop()
sys.stdout.buffer.write("".join(kept).encode("utf-8"))'
}

# enrich_body_strip_html  filter: stdin to stdout.
#
# The Azure DevOps counterpart: System.Description is an HTML field, so the
# sections /enrich writes there are `<h2>` elements, not markdown headings. Cuts
# at the first `<h2>` whose text is enrich-owned -- the six markdown headings
# plus "Spec & Plan", which is what the Azure DevOps block writes.
#
# Headings are matched on NORMALISED text (inner tags stripped, HTML-unescaped,
# whitespace collapsed, case-insensitive) rather than literally: the service
# rewrites stored markup, so the `<h2>Acceptance Criteria</h2>` written is not
# necessarily the `<h2>` read back. How exactly it rewrites has not been
# observed live, so the match tolerates attributes, wrapper tags and entities.
#
# Callers must keep the azdo_description read and this strip as two separate
# guarded statements -- piping the read into this filter would take the filter's
# exit status, and a failed read would become a write.
enrich_body_strip_html() {
  python3 -c '
import html, re, sys

OWNED = {
    "acceptance criteria",
    "assumptions",
    "consequences",
    "implementation plan",
    "spec",
    "spec & implementation plan",
    "spec & plan",
}

text = sys.stdin.buffer.read().decode("utf-8")

cut = None
for match in re.finditer(r"<h2\b[^>]*>(.*?)</h2\s*>", text, re.I | re.S):
    inner = re.sub(r"<[^>]+>", "", match.group(1))
    normalised = " ".join(html.unescape(inner).split()).casefold()
    if normalised in OWNED:
        cut = match.start()
        break

if cut is None:
    sys.stdout.buffer.write(text.encode("utf-8"))
    sys.exit(0)

sys.stdout.buffer.write(text[:cut].rstrip().encode("utf-8"))'
}
