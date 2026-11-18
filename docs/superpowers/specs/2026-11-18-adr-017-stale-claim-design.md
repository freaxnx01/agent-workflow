# Reword the stale "pipeline is GitHub-only" claim (#616)

## Problem

Four commands tell the reader that agent-workflow's pipeline is GitHub-only, or
that nothing on Azure DevOps dispatches, and cite ADR-017 for it:

- `commands/new.md:291-293` ("there is no pipeline dispatch on this forge")
- `commands/route.md:218-222` ("pipeline is GitHub-only ... route is unavailable")
- `commands/work.md:91-95` ("pipeline is GitHub-only ... nothing here picks the item up")
- `commands/enrich.md:963-967` ("nothing on this forge dispatches", "There is no `ai-implement` here")

ADR-017's amendment (`docs/DECISIONS.md:1636-1646`, from #573) says a pipeline now
runs on Azure DevOps: tagging a work item `ai-implement` dispatches
`scripts/azdo-pipeline-run.sh` from an Azure Pipeline, and an enriched item is
dispatchable where that pipeline is installed. The citation is right, the claim
is stale.

## Design

Docs-only. Reword the claim in the four files so each says what ADR-017 says
now, keeping the ADR-017 citation, and keep each command's behaviour unchanged:

- `/new` still does not apply `needs-enrichment` on Azure DevOps. The reason
  changes from "no dispatch exists" to "the trigger is the `ai-implement` tag and
  nothing reads `needs-enrichment`" (`grep needs-enrichment scripts/azdo-tag-guard.sh
  scripts/implement-azdo.sh scripts/lib/azdo.sh` finds nothing; the scripts that
  read it are GitHub-side: `issue-intake.sh`, `autopilot.sh`, `ai-funnel.sh`).
- `/route` stops saying the pipeline route is unavailable. It says the route
  exists where the Azure Pipeline is installed (`docs/AZDO-PIPELINE-SETUP.md`),
  recommends local execution where it is not or cannot be told, and still
  dispatches nothing before the user confirms (`commands/route.md:17,134`).
- `/work` still never applies `ai-implement` and has no draft PR to wait on; it
  says dispatch exists separately and is a user step.
- `/enrich` still reports the paths and stops. It no longer says nothing
  dispatches; it says the item is dispatchable where the pipeline is installed
  and that the user applies `ai-implement`. It still does not apply the tag and
  does not claim the item was dispatched.

Add one regression test to `tests/run-script-tests.sh` (next to the ADR-017
assertions at `:5013-5021`) that fails if the four stale phrases return and
requires the ADR-017 citation to stay.

Out of scope, written down not acted on: `commands/queue.md:304` carries the same
stale claim ("the pipeline is GitHub-only") without an ADR citation, so it is not
one of the four. See A2.

## Acceptance criteria

- None of `commands/new.md`, `route.md`, `work.md`, `enrich.md` says the pipeline
  is GitHub-only or that nothing on Azure DevOps dispatches, on their Azure DevOps
  paths.
- Each still cites ADR-017, and the wording agrees with the amendment dated
  2026-11-02.
- No command behaviour changes: `/new` applies no `needs-enrichment`, `/work` and
  `/enrich` apply no `ai-implement`, `/route` dispatches nothing unconfirmed.
- `enrich.md:58` ("Headless mode is GitHub-only in v1") is unchanged; it is a
  different, true claim.
- `tests/run-script-tests.sh` passes with the new assertions.

## Ordering and overlap

- #495 (ADR-012 to ADR-017 citation in `new.md`/`route.md`) is already on `main`
  as `55502f3` (#622): `new.md:292` and `route.md:219` already cite ADR-017, so
  this spec plans against those lines as they are now. If #495's work lands in a
  different form, rebase; the hunks are the same lines in `new.md` and `route.md`.
- #499 (re-enrichment strips the prior block) and #500 (`/rev` optimistic
  concurrency) both edit the `commands/enrich.md` Azure DevOps write block,
  `:940-960` today (`orig=`, `azdo_set_description`, the read-back paragraph).
  This change touches only `:962-967` (the lock-release paragraph and the "Do not
  claim" paragraph), directly after that block. No line overlap, but the hunks are
  adjacent, so whichever lands second may need a trivial textual rebase.
  `docs/superpowers/plans/2026-11-16-reenrich-replace-sections.md` and
  `2026-11-16-azdo-rev-guard.md` are the plans for #499 and #500.

## Assumptions

- **A1** [high] Docs-only, no script or ADR change. Rejected: also fixing ADR-017's
  Decision/Why prose ("no pipeline agent"). The amendment at
  `docs/DECISIONS.md:1636-1646` already supersedes it and ADRs are append-only.
- **A2** [med] `commands/queue.md:304` is left alone. Rejected: folding it in as a
  fifth file. The issue names four files and says "all four files together";
  `queue.md` has the same stale phrase but no ADR citation (`commands/queue.md:304`).
  Parked for a follow-up issue.
- **A3** [med] `/route` states availability conditionally ("where the Azure
  Pipeline is installed"). Rejected: asserting the route is always available.
  A command cannot tell whether the project's pipeline is installed
  (`docs/AZDO-PIPELINE-SETUP.md` is per-project setup; ADR amendment says "where
  the pipeline is installed").
- **A4** [high] `/new` keeps not applying `needs-enrichment` on Azure DevOps, only
  the reason is reworded. Evidence: `scripts/azdo-tag-guard.sh`,
  `scripts/implement-azdo.sh` and `scripts/lib/azdo.sh` never reference it.
- **A5** [high] One regression test is added to `tests/run-script-tests.sh:5013`
  area. Rejected: no test. The same stale phrase survived in four files, a cheap
  grep guard stops it coming back.

## Consequences

- `/route` on Azure DevOps may now recommend the pipeline route, which it never
  did before; the user still has to confirm and apply the tag.
- `enrich.md` line numbers after `:962` shift by a few lines.
