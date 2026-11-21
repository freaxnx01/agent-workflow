The original human description.

## Scope

Keep this part.

## Acceptance Criteria

- [ ] `scripts/lib/enrich-body.sh` exists.
- [ ] The filter is idempotent.

## Assumptions

- **A1** [confirmed] Re-enrichment replaces the previous sections.

## Consequences

- A re-run silently discards hand edits.

## Implementation Plan

# Re-enrichment Replaces Its Own Sections Implementation Plan

## Global Constraints

- `scripts/lib/azdo.sh` is **not** modified.

### Task 1: Markdown filter

- [ ] **Step 1: Write the failing tests**

## Spec

[docs/superpowers/specs/design.md](docs/superpowers/specs/design.md)
