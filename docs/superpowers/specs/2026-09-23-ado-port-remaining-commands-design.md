# Porting the remaining `## Azure DevOps` sections (#286)

**Date:** 2026-09-23
**Issue:** [#286](https://github.com/freaxnx01/agent-workflow/issues/286)
**Status:** approved
**Blocked by:** [#386](https://github.com/freaxnx01/agent-workflow/issues/386) · [#397](https://github.com/freaxnx01/agent-workflow/issues/397)

## Problem

`/issues` has a real `## Azure DevOps` section. **Twelve** other commands carry an
identical guard — *"this command has no Azure DevOps section yet. Say exactly that
and stop"* — which is safe but leaves ADO unusable for everything except listing.

> **Count correction.** The issue says "the remaining 11". It is **12**: `done`,
> `enrich`, `enrich-phased`, `milestone`, `new`, `parked`, `prs`, `queue`,
> `roadmap`, `route`, `triage`, `work`. Thirteen commands carry a
> `## Azure DevOps` section in total, one of them real.

## The decision this issue turns on

`/issues`' ADO section is ~150 lines of prompt describing a multi-call recipe:
resolve context, read work-item metadata, derive closed states, build WIQL, issue
it through the REST escape hatch, guard the Area Path, resolve fields via a second
batch call, drop WIP by active PR.

Porting that shape into twelve more markdown files **duplicates the recipe twelve
times**. The live run proved what that costs: five defects sat in the single
existing copy for months, four of them silent. Twelve copies means twelve places to
fix each one, and the fix for #386 would have to be applied thirteen times.

### Decision — extract the recipe into `scripts/lib/azdo.sh`

The repo already has this pattern and every command already uses it:

```bash
source "$HOME/.claude/scripts/lib/detect-forge.sh"
detect_forge
```

`detect-forge.sh` is a sourced shell library that all thirteen commands call. ADO's
primitives belong beside it, not copy-pasted into each prompt. A ported section
then reads as a handful of calls plus command-specific rendering, and a defect like
#386's is fixed **once**.

### Rejected — duplicate the prompt text per command

The status quo extended. It needs no new abstraction and each command stays
self-contained and readable in isolation. Rejected because the failure mode is
already demonstrated: the one existing copy carried five defects, and the whole
reason #286 is blocked on #386 is that porting a broken template replicates it.
Prompt text that is identical in twelve files is code, and should live where code
lives.

### Rejected — wait for #253's forge adapter

#253 extracts `agent-implement.yml`'s pipeline logic into a skill with a thin forge
adapter. There is real overlap ("read work item"). Rejected as a *blocker* because
#253 targets the CI/dispatch path and is a larger, differently-shaped refactor;
blocking twelve interactive commands on it stalls this indefinitely.
`scripts/lib/azdo.sh` is a reasonable thing for #253's adapter to consume later.

## Design

### `scripts/lib/azdo.sh`

Sourced, not executed. Functions only, no side effects at source time. Follows
`detect-forge.sh`'s conventions: `set -euo pipefail`, `IFS=$'\n\t'`, quoted
expansions, documented exit codes.

| Function | Responsibility |
|---|---|
| `azdo_closed_states` | Derive closed state names from project metadata via `workitemtypes`, keyed on `category ∈ {Completed, Removed}`. Echoes a `'A','B'` list ready to interpolate. |
| `azdo_wiql <query>` | Issue WIQL through `az devops invoke --area wit --resource wiql`. Echoes ids, one per line. Distinguishes `TF51011` (exit 2) from a genuine empty result (exit 0, no output). |
| `azdo_fields <ids> <fields>` | Resolve fields for ids via `workitemsbatch`. Defaults absent `System.Tags`. |
| `azdo_areas` / `azdo_iterations` | List classification nodes with the `children[]` paths, handling `children: null`. |
| `azdo_active_pr_work_items` | Ids linked to an **active** PR, for WIP derivation. |
| `azdo_work_item_types` | Valid types for the project — what `/new` needs. Shares the `workitemtypes` call with `azdo_closed_states`. |

Every one of these is a shape the live run verified; none is speculative.

### Sequencing the twelve

Ported in dependency order, not alphabetically:

1. **`/milestone`** — iterations. The most ADO-specific and the one with the
   documented traps: creation is two steps (`iteration project create`, then
   `iteration team add`, or the result is unassignable), iterations **nest** unlike
   flat GitHub milestones, and `--depth` defaults to 1 and hides the nested ones.
2. **`/new`** — needs valid work-item types (`azdo_work_item_types`) and tag
   writing. **Blocked on #397**: it writes the parked/roadmap tag, and
   `--fields "System.Tags=…"` **appends and cannot clear**, so an unpark needs a
   json-patch `replace`.
3. **`/prs`** — the best-understood surface. `[].pullRequestId` and `[].id` are both
   verified correct, and `--status` takes `active`/`completed`/`abandoned`/`all`
   with no `open`.
4. **`/triage`** — "bugs first" must key off work-item **type**, not a `bug` tag.
5. **`/parked`, `/roadmap`** — tag read/write. **Blocked on #397.**
6. **`/queue`, `/done`, `/route`, `/work`, `/enrich`, `/enrich-phased`** — compose
   the primitives above; little new ADO surface.

## Acceptance criteria

- [ ] `scripts/lib/azdo.sh` exists, is sourced not executed, and passes `shellcheck -x`
- [ ] It has Layer-1 fixture tests with `az` mocked in `tests/mocks/` — no network, under 5s
- [ ] Every ported section **calls** the library rather than inlining `az` commands
- [ ] No ported section contains a hardcoded work-item state name
- [ ] Each ported command's section is verified against `agent-workflow-sandbox`
- [ ] A command not yet ported still carries its guard, unchanged and still a hard stop
- [ ] `/milestone` documents the two-step iteration create, the nesting, and `--depth`
- [ ] `/triage` orders by work-item type, not by a `bug` tag
- [ ] The count is corrected to 12 wherever the docs say 11

## Testing

Two layers. `scripts/lib/azdo.sh` gets **Layer-1 fixture tests** with a mocked `az`
in `tests/mocks/`, following `tests/run-detect-forge-tests.sh` — this is the first
ADO logic that *can* be unit-tested, because it is shell rather than prompt text.
Each ported section is then verified live against `agent-workflow-sandbox`.

## Out of scope

- **#386** — fixing `/issues`' section. This issue consumes its corrected recipe.
- **#397** — what the parked tag is called. Blocks `/new`, `/parked`, `/roadmap` only.
- **#253** — the CI/dispatch forge adapter. May later consume `scripts/lib/azdo.sh`.
- Hybrid "ADO boards + GitHub code" repos — out of scope in ADR-012 by choice;
  `detect_forge` keys off the remote, so such a repo detects as `github`.
