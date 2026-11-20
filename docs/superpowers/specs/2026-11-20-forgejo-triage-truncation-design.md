# Forgejo /milestone triage: warn when the fetch hits its cap (#663)

## Problem

`commands/milestone.md`, section Forgejo, `triage`, Phase 1 fetches
`issues?state=open&type=issues&limit=100` and filters that one page in Python. It
prints only `to triage: <filtered count>`, so a repo with more than 100 open
issues is cut off with no signal. The GitHub section fixed this for its own cap in
#656: the `--jq` prints `fetched: N of at most 200` before the rows, and the prose
tells the reader to read that line, not the row count.

## Design

Mirror the GitHub guard, adapted to Forgejo's cap of 100. No pagination.

1. **Code.** In the Forgejo Phase 1 Python fence, load the JSON into a variable and
   print `fetched: <len(issues)> of at most 100` as the first output line, counted
   before the milestone/label filter. The `100` is the literal `limit=100` of the
   URL on the line above; the two move together.
2. **Prose.** Replace the Forgejo Phase 1 paragraph's count sentence with the same
   truncation guard text the GitHub section carries: the fetch caps at 100 open
   issues and the filter runs over that page alone, so read the `fetched:` line,
   not the number of rows; if it says 100, say the list may be incomplete rather
   than implying it is everything, even when the filter left few rows or none.
3. **Test.** `tests/run-backlog-milestone-tests.sh`, section "/milestone triage —
   Forgejo Phase 1": a small-page assertion (`fetched: 6 of at most 100`) and a
   full-page one (100 fetched, 3 survive, line reads `fetched: 100 of at most
   100`), copying the two GitHub assertions above it. The fixture is a sibling of
   `issues-full-page.json` with 100 rows.

Out of scope: the other Forgejo fence that uses `limit=100` (the milestone list,
which has its own `open_issues` truncation text), the GitHub section, `/issues`
and `/triage`.

## Acceptance criteria

- A Forgejo page of 100 fetched issues makes the triage output carry
  `fetched: 100 of at most 100`, even when the filter leaves 3 rows.
- A Forgejo page of 6 prints `fetched: 6 of at most 100` (count taken before the
  filter, not after).
- The existing Forgejo row assertions (rows `1,2,6`, missing-backlog pointer) still
  pass.
- The command's prose instructs the reader to act on a `fetched:` of 100.
- The new assertions fail on the unchanged command (written first).

## Assumptions

- **A1** [confirmed] Warn, do not paginate, adapted from the GitHub guard. Answer
  given: "Warnen wie GitHub": count fetched (pre-filter) issues and warn on a full
  page, exactly like the GitHub section of commands/milestone.md does since #656
  (`fetched: N of at most 200`), adapted to Forgejo's cap of 100. No pagination.
- **A2** [high] The line is printed by the Python in the fence, first, and the test
  runs the real fence against a fixture. Rejected: a separate `jq` count. The
  fence is already Python and the GitHub test model
  (`tests/run-backlog-milestone-tests.sh:216-224`) asserts on printed text.
- **A3** [high] Output format is the GitHub one verbatim apart from the number
  (`fetched: N of at most 100`). Rejected: a new wording. Same format means one
  reading rule for both sections (`commands/milestone.md:154`).
- **A4** [high] The Forgejo fixture reuses the shape of `issues.json` (`number`,
  `title`, `labels[].name`, `milestone.title`); the tea stub returns the fixture
  raw (`tests/run-backlog-milestone-tests.sh:142-151`), so no stub change is
  needed.
- **A5** [med] The warning fires on exactly `100`, the requested `limit`. A Forgejo
  instance whose `MAX_RESPONSE_ITEMS` is below 100 clamps the page silently and
  would never print 100; handling that needs the response's `X-Total-Count`
  header, which `tea api` does not expose here. Rejected: reading the header.
  Recorded under Consequences instead.

## Consequences

- Forgejo instances with `MAX_RESPONSE_ITEMS` under 100 (Forgejo's default is 50)
  still truncate without the warning; the guard only protects the nominal cap.
  Not a decision taken here, a limit of the chosen approach.
- Output gains one line before `to triage:`; the test helper `numbers` only picks
  lines starting with digits, so row extraction is unaffected.
- Edits to `commands/milestone.md` reach the user-level install via
  `/update-commands`; nothing else reads the Forgejo fence.
