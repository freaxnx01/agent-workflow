# Guard the two unchecked paths in azdo.sh — design (#498)

## Why

Found by the #488 final review and left out of #494 to keep that branch scoped.
Both are the only places in `scripts/lib/azdo.sh` where a failure is silent
rather than loud.

1. `azdo_description` (`scripts/lib/azdo.sh:339-348`) reads
   `d.get("fields", {}).get("System.Description", "")`. Every other parser
   (`azdo_set_tags` at `:313`, `azdo_set_description` at `:406`) rejects a
   response without `"fields"`. If `az` exits 0 with unexpected JSON the read
   echoes `""`, `azdo_set_description` (`:382-386`) then picks `add`
   (`:388-389`), and the new content is appended to the existing description.
2. `_azdo_edit_tags` (`:459-488`) assigns `next=$(... python3 ...)` with no
   `|| return 1`. Callers use `||` (the file header says to), which suppresses
   `errexit` inside the whole function, so a failed transform yields
   `next=""` and `azdo_set_tags "$id" ""` clears every tag.

Plus one cosmetic defect: the usage message at `:462` names the private
`_azdo_edit_tags`, a form no caller types.

## Goal

Both paths fail loudly (exit 1, message on stderr, no PATCH sent), each covered
by a Layer-1 fixture test that fails without the fix.

## Design

- **`azdo_description`**: in the python filter, `if "fields" not in d:` write
  `azdo_description: unexpected response: <first 200 chars>` to stderr and
  `sys.exit(1)`. Same wording shape as `azdo_set_tags`. An item with no
  description still has a `fields` object, so the documented "absent field
  echoes nothing, exit 0" contract is unchanged. The function's header comment
  gains "exit 1 also on a response without `fields`".
- **`_azdo_edit_tags`**: append `|| return 1` to the transform, with a stderr
  line `_azdo_edit_tags: could not compute the new tag set for work item $id —
  refusing to write`. No other change to the function: an empty `next` from a
  legitimate `remove` of the last tag stays valid, so the guard is on the
  transform's status, not on emptiness.
- **Usage message**: `usage: azdo_add_tag <id> <tag> | azdo_remove_tag <id> <tag> [expected-rev]`.
  Exit code 2 and the validation condition are unchanged.

## Tests (Layer 1, `tests/run-azdo-lib-tests.sh`)

- New fixture `tests/fixtures/azdo-workitem-no-fields.json`: valid JSON with no
  `fields` key.
- `azdo_description` on that fixture exits 1, stderr mentions
  `unexpected response`.
- `azdo_set_description` on that fixture exits 1 and records no PATCH body (the
  append-instead-of-replace path is closed).
- `azdo_add_tag` / `azdo_remove_tag` invoked with `|| rc=$?` while `azdo_fields`
  is overridden to emit non-JSON: exit 1, no PATCH body recorded. Without the
  fix the PATCH body is recorded with `value: ""`.
- Usage error on `azdo_add_tag 5` names `azdo_add_tag`/`azdo_remove_tag` and not
  `_azdo_edit_tags`.

## Out of scope

- `/rev` optimistic concurrency on the write functions: #500. Same functions,
  see Consequences.
- Revalidating other parsers.

## Assumptions

- **A1** [high] Guard `azdo_description` with the same `"fields" not in d` check
  the other parsers use. Rejected: a stricter `isinstance(d, dict)` check or a
  new shared helper. `scripts/lib/azdo.sh:313` and `:406` already use the inline
  form; the issue asks to match them.
- **A2** [high] Guard only the transform's exit status, not an empty result.
  Rejected: refusing empty `next`. `remove` of the last tag legitimately yields
  `""` and must still clear it (`tests/run-azdo-lib-tests.sh:389-445` covers
  removal).
- **A3** [med] Usage text is `usage: azdo_add_tag <id> <tag> | azdo_remove_tag <id> <tag> [expected-rev]`.
  Rejected: two separate lines, or keeping `[expected-rev]` off. The issue only
  says to name the public functions; `[expected-rev]` is accepted only by
  `azdo_remove_tag` (`:494`).
- **A4** [med] The tag-transform failure is simulated in tests by overriding
  `azdo_fields` after sourcing the library to emit non-JSON. Rejected: a new
  mock binary for `python3`. The real library path is exercised and the PATH
  mock approach would also break the library's other python calls.
- **A5** [high] The old plan `docs/superpowers/plans/2026-10-08-azdo-enrichment-writeback.md:481`
  keeps its historical usage string. It is a record, not a source of truth.

## Consequences

- #500 edits `azdo_set_description` and `_azdo_edit_tags`/`azdo_*_tag` bodies in
  the same file. Expect a textual conflict in `_azdo_edit_tags` if both land;
  the second to merge rebases by hand. No behavioural dependency.
