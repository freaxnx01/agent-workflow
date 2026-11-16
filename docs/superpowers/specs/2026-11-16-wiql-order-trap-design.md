# Document the WIQL ordering trap in the ADO WIP filter (#501)

## Problem

`commands/issues.md` (Azure DevOps, step 2) orders candidates with
`ORDER BY [System.CreatedDate] DESC` and the render step promises newest first.
Step 4 drops WIP work items but does not say how. The obvious implementation,
`comm -23 <(sort ids) <(sort wip)`, returns ids in numeric order: WIQL `7 6 4 1`
becomes `1 4 6 7`, silently reversed.

## Design

Docs-only. Add a trap note to `commands/issues.md` step 4:

- name `comm` / `sort` as the wrong tool and say why (needs sorted input, so it
  discards the WIQL order),
- give the order-preserving form `grep -vxF` over the ordered list, using the
  WIP ids as a pattern file (`-f`) so multi-id lists work,
- guard the empty-WIP case (`grep -f` with an empty file matches nothing, so with
  `-v` everything survives; the guard is for `-vxF "$wip"` with an empty string,
  which matches every line and would drop all ids),
- note that `azdo_active_pr_work_items` itself is `sort -u` on purpose: its
  output is a set, and only the candidate list carries order.

`commands/queue.md` (ADO) also holds `wip` next to the ordered `ids`, but it
marks items in flight rather than dropping them. Add a one-line pointer there
that the in-flight lookup must be a membership test, not a `comm` over sorted
lists. `commands/triage.md` (ADO) does not consult WIP at all (by design, see
its GitHub section) and is left unchanged.

GitHub and Forgejo sections are unchanged: they sort at render time.

## Acceptance criteria

- `commands/issues.md` step 4 names `comm`/`sort` as wrong, gives the
  order-preserving form, and states why, including the observed `7 6 4 1` to
  `1 4 6 7` example.
- The empty-WIP guard is documented.
- `commands/queue.md` ADO section carries the short pointer.
- No other file changes; `triage.md` untouched.

## Assumptions

- **A1** [high] Docs-only change, no script change. Rejected: adding a helper to
  `scripts/lib/azdo.sh`. The issue's Scope says "add the trap to
  `commands/issues.md` step 4".
- **A2** [med] `/triage` needs no edit. Rejected: adding a note there anyway. The
  issue says `/queue` and `/triage` both filter an ordered id list, but
  `commands/triage.md:97-99` states WIP is deliberately not excluded and its ADO
  section (`:199-262`) never uses the WIP list.
- **A3** [med] `/queue` gets a one-line pointer, not a full trap section.
  Rejected: a full copy of the explanation. `commands/queue.md:288-295` computes
  `wip` for an in-flight marker, not a filter, so the risk is only a future
  `comm` implementation of the marker lookup.
- **A4** [high] Leave `azdo_active_pr_work_items` `sort -u` as is. Evidence:
  `scripts/lib/azdo.sh:234`; its output is a set and order-insensitive.

## Consequences

- `commands/issues.md` grows by roughly a dozen lines in step 4.
