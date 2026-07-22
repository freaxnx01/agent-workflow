---
description: Map UI logic with Mermaid flow diagrams (Phase 2 of 4)
---

The ASCII wireframe from Phase 1 has been approved. Now map the logic before any
code is written. This is Phase 2 of the 4-phase UI workflow (`/ui:brainstorm` →
`/ui:flow` → `/ui:build` → `/ui:review`).

This command is stack-neutral. If the project has a synced stack overlay
(`.ai/stacks/<stack>.md`), use its component-library naming in the component map;
otherwise infer names from the existing codebase.

**Target:** $ARGUMENTS

---

## Your job in this phase

### Diagram 1 — User Journey (flowchart)

Generate a Mermaid `flowchart TD` covering:

- All entry points to this screen
- User decisions and branching paths
- Error states (validation errors, API failures, 403/404)
- Empty states (no data yet, first-run)
- Success states and exit points
- Confirmation dialogs for destructive actions

### Diagram 2 — Component & State Map (graph or flowchart)

Generate a Mermaid diagram showing:

- Component hierarchy (parent → children)
- Which component owns which state
- Data flow direction (props/parameters down, events up)
- Which services are injected and where
- API calls: which component triggers them

Use the component-library names from the active stack overlay (e.g. `MudDataGrid`
for .NET/Blazor) in the component map when one is present.

### Step 3 — Screen inventory check

List any additional screens or dialogs implied by this flow that were not in the wireframe (e.g. detail views, wizard steps, modals). Flag them explicitly.

### Step 4 — Wait for approval

Do NOT write any component code.
End with: "Do these diagrams capture the intended logic? Approve to continue to Phase 3 (/ui:build)."

---

## Rules

- No component code in this phase
- If the flow reveals a missing screen, surface it — do not silently skip it
- Keep Mermaid diagrams readable: max ~15 nodes per diagram, split if needed
- On approval, save the diagrams to `docs/design/<feature-name>/flow.md`
