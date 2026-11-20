# Azure DevOps: size the turn budget from the plan file (#651)

## Intent

On Azure DevOps, `/enrich` writes the acceptance criteria and **pointers** to the
committed spec and plan into the work item. Per ADR-017 it does not inline the
plan, because `System.Description` is HTML. `implement-azdo.sh`'s
`classify_issue` runs `classify-turns.sh` against the work item body. That body
has no `## Implementation Plan` section, so every ADO run gets the unplanned
default of 120 turns: far too many for a one-task item, too few for a large plan.

## Goals

- On the ADO path, the turn budget is sized from the plan file the work item
  points to, with the same tiers as on GitHub.
- If there is no pointer, or the file is not in the checkout, today's unplanned
  default stays, and the job log says why.
- The agent's prompt and `classify-agent.sh` still see the work item's own body.

## Non-goals

- Changing ADR-017. The plan stays out of the HTML field.
- Plan coverage on ADO. `plan-coverage-step.sh` is wired only into the GitHub
  workflow (`agent-implement.yml`), not into `implement-azdo.sh`, so the gap does
  not reach it. Adding plan coverage to ADO would be a separate feature.

## Approaches

1. **Read the pointed-to plan from the checkout and inject it into
   `classify-turns.sh` only (chosen).** `classify-turns.sh` already takes an
   injected `ISSUE_BODY`. The plan is read with `git show HEAD:<path>`.
   `classify_issue` runs before `resolve_default_branch` in `main`, and on ADO
   the checkout is the default branch that `/enrich` committed the plan to.
2. **Inline the plan into the work item.** Rejected by ADR-017.
3. **Rely on a `turns:N` tag.** This stays as the override, but it puts the
   sizing on the operator for every item and does not fix the cause.

## Design

- **`azdo_plan_pointer <body>`** goes in a new `scripts/lib/azdo-plan-pointer.sh`.
  - It prints the first path matching `docs/[A-Za-z0-9._/-]*plans/[A-Za-z0-9._/-]*\.md`
    in the body. The body is raw HTML; `/enrich` writes the path inside
    `<code>…</code>`.
  - It returns 1 and prints nothing when there is no match, when the path
    contains `..`, or when it starts with `/`.
- **`classify_issue`** in `implement-azdo.sh`:
  - When a pointer is found and `git show "HEAD:<path>"` succeeds, it runs only
    the `classify-turns.sh` call with
    `ISSUE_BODY="<title>"$'\n''## Implementation Plan'$'\n'"<plan file content>"`.
    The global `ISSUE_BODY` is untouched.
  - Otherwise it runs as today, and the `turns :` log line gets a suffix:
    - ` (unplanned default: no plan pointer)`, or
    - ` (unplanned default: <path> not in checkout)`.
  - An explicit `turns:N` tag still wins. `classify-turns.sh` reads the tags
    first, unchanged.
- **ADR-017** gets an amendment (2026-11-20, #651) saying that the pipeline sizes
  the turn budget from the pointed-to plan file, and that the decision stands.

## Acceptance criteria

- [ ] A work item whose body points to a plan file with N `## Task` / `### Task`
      headings gets the same budget tier as a GitHub issue with that plan
      inlined.
- [ ] With no plan pointer, the budget is the unplanned default, and the log
      line says `unplanned default: no plan pointer`.
- [ ] With a pointer to a file that is not in the checkout, the budget is the
      unplanned default, and the log line names the path.
- [ ] A pointer containing `..` or starting with `/` is ignored, and no file
      outside the repository is read.
- [ ] The agent prompt (`ISSUE_JSON`) and `classify-agent.sh` still get the work
      item's own body.
- [ ] A `turns:N` tag still overrides.
- [ ] ADR-017 carries the amendment.
