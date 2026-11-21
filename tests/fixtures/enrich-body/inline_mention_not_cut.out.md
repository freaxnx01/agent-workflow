Re-running `/enrich` on an already-enriched issue **appends a second Acceptance
Criteria block** rather than replacing the first.

## Scope

Decide what re-enrichment should do, then make both forges do it:

- replace the previous `## Acceptance Criteria` / `## Implementation Plan` /
  `## Spec` sections while preserving everything above them, or
- refuse when those sections already exist and tell the user to clear them first, or
- keep appending but mark the previous block superseded.

Found during the #488 final whole-branch review.
