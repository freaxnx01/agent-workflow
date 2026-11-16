# Correct the false ADR-012 citation in /new and /route (#495)

## Problem

`commands/new.md:292` and `commands/route.md:219` cite ADR-012 for "the pipeline
is GitHub-only / no pipeline dispatch on this forge". ADR-012 maps Azure DevOps
objects onto the forge-agnostic commands and says no such thing. ADR-017
(`docs/DECISIONS.md:1607`) states the fact on its own evidence, and
`commands/work.md:91` and `commands/enrich.md` already cite it.

## Design

Docs-only, two one-token edits, following the `commands/work.md:91` precedent:

- `commands/new.md:292`: `(ADR-012)` becomes `(ADR-017)`.
- `commands/route.md:219`: `(ADR-012)` becomes `(ADR-017)`.

Out of scope and left unchanged: `commands/milestone.md:412` and
`commands/issues.md:446`, where ADR-012 is genuinely about the Iteration
mapping.

## Acceptance criteria

- Neither `commands/new.md` nor `commands/route.md` cites ADR-012 for the
  pipeline claim; both cite ADR-017.
- `grep -rn "ADR-012" commands` lists only `milestone.md` and `issues.md`.
- No other text in either file changes (diff is two lines).

## Assumptions

- **A1** [high] Re-point the citation, keep the sentences. Rejected: restating
  the fact inline without a citation. `commands/work.md:91` already uses the
  same wording with ADR-017.
- **A2** [med] Do not reword the claim, although the ADR-017 amendment
  (`docs/DECISIONS.md:1635-1646`, #573) says a pipeline now runs on ADO and an
  enriched item is dispatchable where installed. Rejected: rewriting new.md and
  route.md to match. Reason: the issue scopes this to the citation, and
  `work.md:91` and `enrich.md:935` carry the same unrewritten claim, so the fix
  belongs in one sweep across all four files.
- **A3** [high] ADR-012 stays cited in `milestone.md:412` and `issues.md:446`;
  both are about the Iteration mapping.

## Consequences

- After this change the four commands cite ADR-017 for a claim its own
  amendment partly contradicts (see A2). Citation is correct, claim is stale.
