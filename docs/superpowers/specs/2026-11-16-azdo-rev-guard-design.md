# Optimistic concurrency via /rev for the Azure DevOps write functions — Design

**Issue:** #500 · **Date:** 2026-11-16 · **Status:** written unattended (`/enrich --headless`).

## Intent

`azdo_add_tag`, `azdo_remove_tag` and `azdo_set_description` are read-modify-write over a
whole-field replace, so an edit landing between the read and the write is silently lost.
The #488 live run (`docs/ai-notes/2026-10-08-azdo-writeback-live-run.md`, Step 5) proved a
json-patch `test` on `/rev` is honoured and atomic: a stale rev is rejected with
`TestPatchOperationFailedException` (VS403351) and the accompanying `replace` does not apply.

## Current state (main @ 186c85e)

#573 already added an **opt-in** guard to part of the library:

- `azdo_set_tags <id> <tags> [expected-rev]` leads the patch with the `test` op and exits 64
  on a conflict (`scripts/lib/azdo.sh:283-326`).
- `azdo_remove_tag <id> <tag> [expected-rev]` passes it through (`azdo.sh:494`); the
  pipeline tag guard uses that.
- Missing: `azdo_add_tag` has no rev argument (`azdo.sh:490`); `azdo_set_description` has no
  guard at all (`azdo.sh:373-414`); nothing derives the rev from the read the function
  already performs, so every plain caller (`commands/enrich.md`, `commands/enrich-phased.md`)
  is still unguarded; `azdo_fields` does not emit `rev` (`azdo.sh:161-196`).

## Design

1. `azdo_fields` emits an additive `rev` key (the work item's `rev`).
2. A shared helper `_azdo_patch_item <caller> <id> <json-patch-body>` runs the PATCH and maps
   `TestPatchOperationFailedException` to exit 64 with the server message on stderr and nothing
   on stdout; any other non-`fields` response is exit 1. `azdo_set_tags` is refactored onto it
   (behaviour unchanged, existing tests are the guard).
3. `_azdo_edit_tags` (so `azdo_add_tag` / `azdo_remove_tag`) takes the rev **from the same
   read** that supplies the tags and passes it to `azdo_set_tags`, unless the caller gave an
   explicit `[expected-rev]`, which wins (keeps the pipeline guard's contract).
4. `azdo_set_description <id> <html> [expected-rev]` takes the rev from the same read that
   chooses `add` vs `replace` (new `_azdo_description_row`, one `az boards work-item show`
   call returning rev and description), leads the body with the `test` op, and exits 64 on
   conflict. An explicit expected-rev wins.
5. Exit 64 means "lost the race" for all four write functions. **No internal retry**: the
   caller retries (confirmed decision). Header exit-code table and the function comments
   say so; `azdo_set_description`'s comment points at the live-run notes.
6. `commands/enrich.md` and `commands/enrich-phased.md` Azure DevOps sections: capture the
   rev together with the description they compose from and pass it as `expected-rev`, so the
   guard covers the whole caller read-compose-write window, and state what to do on exit 64
   (stop and report, re-read and re-compose; never blind retry).

`azdo_set_tags` stays opt-in: it does no read, so it has no rev of its own. `azdo_comment` is
append-only (`System.History`) and is not a lost-update hazard.

## Assumptions

- **A1** [confirmed] On losing the `/rev` race the library only reports it. Confirmed answer to
  "When a write loses the /rev race, should the library retry on its own or only report it?":
  "Report only, caller retries: return a dedicated 64+ exit code, no internal retry."
- **A2** [high] Guard `azdo_add_tag`, `azdo_remove_tag`, `azdo_set_description`; leave
  `azdo_set_tags` opt-in and `azdo_comment` alone. Rejected: guarding `azdo_set_tags`
  by default, because it has no read to take a rev from (`azdo.sh:283-300`).
- **A3** [high] Exit code 64, the code `azdo_set_tags` already uses for a revision conflict
  (`azdo.sh:39-42`). Rejected: a new code such as 65. 64 is already per-function in this
  library (`azdo_tag_adder` uses it for "tag absent"), and the header table documents that.
- **A4** [med] The guard is **default-on** for the read-modify-write functions, using the rev
  from the function's own read. Rejected: opt-in only, which is what #573 shipped for
  `azdo_remove_tag` and leaves plain callers unguarded. Consequence: any caller that does not
  capture the status now sees exit 64 under `set -e` where it used to silently overwrite.
- **A5** [med] `azdo_fields` gains a `rev` key. Rejected: a second call to fetch the rev, which
  reopens the race window between two reads. Evidence gap: the batch response is a WorkItem
  array and WorkItem carries `rev`, but the repo's `azdo-batch-fields.json` fixture has no
  `rev` and the live run never read it from `workitemsbatch`; `azdo-workitem-with-description.json:1`
  shows `rev` on `work-item show`. A5 is made safe by A6.
- **A6** [med] A read with a missing or non-integer `rev` makes the write fail closed (exit 1,
  no PATCH), like a failed read does today (`azdo.sh:467-471`). Rejected: falling back to an
  unguarded write, which would turn a wrong A5 into a silent regression.
- **A7** [med] An explicit `[expected-rev]` overrides the rev read inside the function
  (for `azdo_set_description` too). Rejected: ignoring it. The caller of `/enrich` reads the
  description, composes, then writes; only a caller-supplied rev covers the compose window,
  and `azdo-tag-guard.sh` already relies on the override for removal.
- **A8** [med] `azdo_description` is left untouched; the new `_azdo_description_row` does its
  own `az boards work-item show` parse. Rejected: reworking `azdo_description`, because #498
  edits it (shape validation) and this keeps the two diffs from colliding. The duplication can
  be folded once #498 has landed.
- **A9** [med] The doc change is limited to the Azure DevOps sections of `commands/enrich.md`
  and `commands/enrich-phased.md`. Rejected: also touching `new.md`, `parked.md`, `roadmap.md`;
  they use `azdo_set_tags` (opt-in, unchanged).

## Consequences

- Each guarded write now loses to any concurrent edit, including a harmless one (a comment
  bumps `rev`). In `/enrich`, `azdo_comment` between the description read and the write (e.g.
  the lock comment) therefore forces a re-read; the snippet reads right before writing.
- `azdo_fields` consumers read named keys (`scripts/azdo-tag-guard.sh:87-99`), so the extra key
  is safe; fixtures that feed `_azdo_edit_tags` need a `rev`.
- Overlap with other issues: #498 edits `azdo_description` and `_azdo_edit_tags` in the same
  file (land #498 first, or expect a mechanical rebase); #499 changes the composition the
  description write receives, not the write itself, but `commands/enrich.md`'s snippet is
  shared.

## Acceptance Criteria

- [ ] `azdo_fields` output includes `rev`.
- [ ] `azdo_add_tag` and `azdo_remove_tag` send `{"op":"test","path":"/rev","value":<rev>}` as the
      first op, `<rev>` coming from the item read; an explicit expected-rev replaces it.
- [ ] `azdo_set_description` sends the same test op first and exits 64 on a revision conflict
      with nothing on stdout and no retry.
- [ ] A read without an integer `rev` refuses the write (exit 1, no PATCH).
- [ ] `azdo_set_tags` behaviour is unchanged (existing tests pass).
- [ ] The library header documents 64 for all four functions; `azdo_set_description`'s comment
      points at `docs/ai-notes/2026-10-08-azdo-writeback-live-run.md`.
- [ ] `commands/enrich.md` / `enrich-phased.md` pass the rev and say to stop and report on 64.
- [ ] `tests/run-azdo-lib-tests.sh` and shellcheck pass.
