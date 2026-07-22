---
description: Review the implemented component against wireframe, flow diagrams, and conventions (Phase 4 of 4)
---

Review the implemented component against the approved wireframe, flow diagrams, and
project conventions. This is Phase 4 of the 4-phase UI workflow (`/ui:brainstorm` →
`/ui:flow` → `/ui:build` → `/ui:review`).

This command is stack-neutral. If the project has a synced stack overlay
(`.ai/stacks/<stack>.md`), cross-reference component-library preferences and
file-layout rules against it; otherwise infer conventions from the existing codebase.

**Target:** $ARGUMENTS

---

## Review checklist — work through every item

### Layout & Wireframe fidelity

- [ ] Does the layout match the approved ASCII wireframe?
- [ ] Are all sections present (top bar, nav, main content, actions)?
- [ ] Are empty states implemented and visible when there is no data?
- [ ] Are loading states implemented (skeleton / progress / spinner)?
- [ ] Are error states handled visibly (toast / banner / alert)?

### Flow fidelity

- [ ] Does every user action from the Mermaid flow have an implementation?
- [ ] Are all error branches handled (API failure, 403, 404, validation)?
- [ ] Are destructive actions gated by a confirmation dialog?
- [ ] Are all exit points (navigation, success redirect) wired correctly?

### Component-library conventions (per stack overlay)

- [ ] No raw HTML / primitive widgets where a first-party library component exists
- [ ] Tabular data uses the stack's preferred data-grid component
- [ ] Toasts / snackbars use the stack's feedback component (no custom toast)
- [ ] Icons come from a single icon set, used consistently
- [ ] Spacing uses the stack's spacing utilities

### Code conventions

- [ ] No business logic in view/markup files (only binding and UI events)
- [ ] Code-behind / controller / ViewModel separation respected (per stack)
- [ ] No direct API calls from the component — always via a service
- [ ] No duplicate components — anything reusable moved to the shared folder

### Testing

- [ ] Component-level test file exists for this component
- [ ] Happy path test passes
- [ ] Empty state test passes
- [ ] Error state test passes
- [ ] E2E test added or updated if the feature is user-facing

---

## Output format

Report findings in three groups:

1. **Must fix** — blocks PR merge
2. **Should fix** — not blocking but flagged for follow-up
3. **Looks good** — confirmed compliant items

End with an overall verdict: ✅ Ready for PR / ⚠️ Needs fixes before PR.
