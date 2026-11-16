# Azure DevOps /rev guard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** `azdo_add_tag`, `azdo_remove_tag` and `azdo_set_description` lead their PATCH with a json-patch `test` on `/rev` taken from the read they already do, and report a lost race as exit 64 without retrying.

**Architecture:** `azdo_fields` emits `rev`. A shared `_azdo_patch_item` runs the PATCH and maps `TestPatchOperationFailedException` to exit 64. `_azdo_edit_tags` and `azdo_set_description` take the rev from the same read as their data; an explicit expected-rev argument wins. Everything lives in `scripts/lib/azdo.sh`; tests are Layer-1 fixture tests.

**Tech Stack:** Bash 5, python3 (stdlib), curl (mocked in `tests/mocks/curl`), `az` (mocked), shellcheck.

**Spec:** `docs/superpowers/specs/2026-11-16-azdo-rev-guard-design.md`

## Global Constraints

- Exit 64 = revision conflict, nothing on stdout, server message on stderr, **no retry** anywhere in the library.
- A read without an integer `rev` refuses the write (exit 1, no PATCH).
- `azdo_set_tags` keeps its opt-in 3rd argument and its current behaviour; `azdo_comment` is untouched.
- `azdo_description` is not modified (issue #498 edits it).
- Run `tests/run-azdo-lib-tests.sh` and `shellcheck scripts/lib/azdo.sh tests/run-azdo-lib-tests.sh` before every commit.

## File Structure

- Modify `scripts/lib/azdo.sh`: `azdo_fields`, new `_azdo_patch_item`, `azdo_set_tags`, `_azdo_edit_tags`, `azdo_add_tag`, new `_azdo_description_row`, `azdo_set_description`, header and comments.
- Modify `tests/run-azdo-lib-tests.sh`, fixtures `tests/fixtures/azdo-fields-*.json`, new `tests/fixtures/azdo-fields-no-rev.json`.
- Modify `commands/enrich.md`, `commands/enrich-phased.md` (Azure DevOps sections only).

## Task 1: azdo_fields emits rev

**Files:** `scripts/lib/azdo.sh` (`azdo_fields`, ~line 161), `tests/run-azdo-lib-tests.sh` (~line 118), fixtures.

**Interfaces:** each output row gains `"rev": <int or null>`.

- [ ] **Step 1: Write the failing test.** Add `"rev": 12` to the work item objects (top level, beside `"id"`) in `azdo-fields-tagged.json`, `azdo-fields-ai-implement.json`, `azdo-fields-ai-implement-mixedcase.json`, `azdo-fields-mixedcase-tagged.json`, and add `"rev": 7` to id 4 in `azdo-batch-fields.json`. Create `azdo-fields-no-rev.json` as a copy of `azdo-fields-tagged.json` without `rev`. In the `azdo_fields` section of the test file add:

```bash
assert_eq "azdo_fields emits the item's rev" "7" \
  "$(run_lib azdo-batch-fields.json azdo_fields 1,4 | tail -1 \
     | python3 -c 'import sys,json; print(json.loads(sys.stdin.read())["rev"])')"
```

- [ ] **Step 2: Run, expect FAIL** (`KeyError: 'rev'`): `tests/run-azdo-lib-tests.sh`.
- [ ] **Step 3: Implement.** In the second python block of `azdo_fields` add `"rev": w.get("rev"),` to the printed dict.
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Commit** `feat(azdo): emit rev from azdo_fields (#500)`.

## Task 2: shared PATCH helper, set_tags onto it

**Files:** `scripts/lib/azdo.sh` (`azdo_set_tags`).

**Interfaces:** `_azdo_patch_item <caller> <id> <body>`: stdout the response JSON on success; exit 64 on `TestPatchOperationFailedException` (message on stderr as `<caller>: revision conflict: <message>`); exit 1 on a curl failure or a response without `fields`.

- [ ] **Step 1: No new test.** Existing `set_tags_*` tests (lines ~208-245) are the safety net: conflict exit 64 with empty stdout, 400 exit 1, tags echoed.
- [ ] **Step 2: Implement** above `azdo_set_tags`:

```bash
# _azdo_patch_item <caller> <id> <json-patch-body>  PATCHes a work item.
# Exit 0 (response JSON on stdout); 64 revision conflict (the leading `test` op on
# /rev failed -- nothing was applied, nothing is echoed); 1 any other failure.
# The library never retries: the caller decides (#500).
_azdo_patch_item() {
  local caller="${1-}" id="${2-}" body="${3-}"
  : "${AZURE_DEVOPS_EXT_PAT:?AZURE_DEVOPS_EXT_PAT must be set}"
  local url out
  url="$(azdo_org_url)/_apis/wit/workitems/${id}?api-version=7.1"
  out=$(printf 'user = ":%s"\n' "$AZURE_DEVOPS_EXT_PAT" \
    | curl -sS -K - \
        -H 'Content-Type: application/json-patch+json' \
        -X PATCH "$url" -d "$body") || return 1
  printf '%s' "$out" | python3 -c '
import sys, json
caller = sys.argv[1]
d = json.load(sys.stdin)
if d.get("typeKey") == "TestPatchOperationFailedException":
    sys.stderr.write("%s: revision conflict: %s\n" % (caller, d.get("message", "")))
    sys.exit(64)
if "fields" not in d:
    sys.stderr.write("%s: unexpected response: %s\n" % (caller, str(d)[:200]))
    sys.exit(1)
print(json.dumps(d))' "$caller"
}
```

Then in `azdo_set_tags` replace the `url=`, the `out=$(... curl ...)` and the response-parsing python with:

```bash
  local resp
  resp=$(_azdo_patch_item azdo_set_tags "$id" "$body") || return $?
  printf '%s' "$resp" | python3 -c '
import sys, json
d = json.load(sys.stdin)
tags = d["fields"].get("System.Tags", "")
if not isinstance(tags, str):
    sys.stderr.write("azdo_set_tags: System.Tags in the response is not text\n")
    sys.exit(1)
print(tags)'
```

Keep the `body=$(python3 ...)` construction as is and keep the long WARNING comment.

- [ ] **Step 3: Run `tests/run-azdo-lib-tests.sh`, expect all existing PASS** (incl. the PAT-not-on-argv test).
- [ ] **Step 4: Commit** `refactor(azdo): share the PATCH and conflict mapping (#500)`.

## Task 3: tag writes take the rev from their own read

**Files:** `scripts/lib/azdo.sh` (`_azdo_edit_tags`, `azdo_add_tag`), `tests/run-azdo-lib-tests.sh` (section "azdo_add_tag / azdo_remove_tag").

**Interfaces:** `azdo_add_tag <id> <tag> [expected-rev]`; both tag functions send the `test` op first with the read rev unless an explicit rev is given.

- [ ] **Step 1: Write the failing tests.** `sent_value` currently reads `[0][0]["value"]`; the replace is now the last op, so change it to `[0][-1]["value"]` (python `[-1]`). Add:

```bash
sent_test_op() {
  python3 -c '
import json,sys
b = json.loads(open(sys.argv[1]).read().strip().splitlines()[0])
print(b[0]["op"], b[0]["path"], b[0]["value"])' "$tg_dir/body.txt"
}

rm -f "$tg_dir/body.txt"
run_tag azdo-fields-tagged.json azdo_add_tag 5 enrichment-ongoing >/dev/null
assert_eq "add_tag leads with a test on the rev it read" "test /rev 12" "$(sent_test_op)"

rm -f "$tg_dir/body.txt"
run_tag azdo-fields-tagged.json azdo_remove_tag 5 roadmap >/dev/null
assert_eq "remove_tag leads with a test on the rev it read" "test /rev 12" "$(sent_test_op)"

rm -f "$tg_dir/body.txt"
run_tag azdo-fields-tagged.json azdo_add_tag 5 enrichment-ongoing 99 >/dev/null
assert_eq "an explicit expected rev wins over the read" "test /rev 99" "$(sent_test_op)"

rm -f "$tg_dir/body.txt"
rc=0
run_tag azdo-fields-no-rev.json azdo_add_tag 5 enrichment-ongoing >/dev/null 2>&1 || rc=$?
assert_eq "a read without a rev refuses the write" "1" "$rc"
if [[ -s "$tg_dir/body.txt" ]]; then
  fail "a read without a rev sends no PATCH" "a request body was recorded"
else
  pass "a read without a rev sends no PATCH"
fi

# Lost race: the server answers with the conflict; the library reports 64, no retry.
rm -f "$tg_dir/body.txt" "$tg_dir/argv.txt"
rc=0; out=$(
  # shellcheck disable=SC2030,SC2031
  export PATH="$MOCKS:$PATH" AZ_MOCK_FIXTURE="$FIXTURES/azdo-fields-tagged.json" \
         CURL_MOCK_FIXTURE="$FIXTURES/azdo-set-tags-rev-conflict.json" \
         CURL_MOCK_BODY_LOG="$tg_dir/body.txt" CURL_MOCK_LOG="$tg_dir/argv.txt" \
         AZDO_ORG=contoso AZDO_PROJECT=MyProject AZDO_REPO=my-repo \
         AZURE_DEVOPS_EXT_PAT=not-a-real-token
  # shellcheck disable=SC1090
  source "$LIB"; azdo_add_tag 5 enrichment-ongoing 2>/dev/null
) || rc=$?
assert_eq "add_tag lost race exits 64" "64" "$rc"
assert_eq "add_tag lost race prints nothing" "" "$out"
assert_eq "add_tag lost race is not retried" "1" "$(wc -l < "$tg_dir/argv.txt" | tr -d ' ')"
```

- [ ] **Step 2: Run, expect FAIL** (no test op is sent yet).
- [ ] **Step 3: Implement.** In `_azdo_edit_tags` replace the transform with one that also yields the rev, and fall back to it:

```bash
  local parsed next read_rev
  parsed=$(printf '%s' "$row" | python3 -c '
import sys, json
row = json.loads(sys.stdin.readline())
mode, tag = sys.argv[1], sys.argv[2]
tags = [t.strip() for t in row.get("tags", "").split(";") if t.strip()]
if mode == "add":
    if tag not in tags:
        tags.append(tag)
else:
    tags = [t for t in tags if t.lower() != tag.lower()]
rev = row.get("rev")
print(rev if isinstance(rev, int) and not isinstance(rev, bool) else "")
print("; ".join(tags))' "$mode" "$tag") || return 1
  read_rev=$(printf '%s\n' "$parsed" | sed -n 1p)
  next=$(printf '%s\n' "$parsed" | sed -n 2p)

  if [[ -z "$rev" ]]; then
    if [[ ! "$read_rev" =~ ^[0-9]+$ ]]; then
      echo "_azdo_edit_tags: work item $id was read without a revision — refusing to write" >&2
      return 1
    fi
    rev="$read_rev"
  fi
  azdo_set_tags "$id" "$next" "$rev"
```

(The `|| return 1` on the transform overlaps issue #498's scope; it is needed here because a failed parse must not reach the write.) Update the comment above the function: the rev comes from the same read; explicit wins; 64 = lost race. Change `azdo_add_tag() { _azdo_edit_tags "${1-}" add "${2-}" "${3-}"; }` and its comment.

- [ ] **Step 4: Run, expect PASS** including the unchanged "removing leaves the others intact" and "adding keeps the existing tags".
- [ ] **Step 5: Commit** `feat(azdo): guard add_tag/remove_tag with the rev they read (#500)`.

## Task 4: azdo_set_description guard

**Files:** `scripts/lib/azdo.sh` (`azdo_set_description`, new `_azdo_description_row`), `tests/run-azdo-lib-tests.sh` (section "azdo_description / azdo_set_description").

**Interfaces:** `azdo_set_description <id> <html> [expected-rev]`; `_azdo_description_row <id>` echoes `{"rev": N, "description": "..."}`, exit 1 when `fields` or an integer `rev` is missing.

- [ ] **Step 1: Write the failing tests.** The two existing op assertions read `...[0][0]["op"]`; the add/replace op is now last, change both to `[0][-1]["op"]`. Add:

```bash
rm -f "$sd_dir/body.txt"
run_desc azdo-workitem-with-description.json azdo-set-description-stored.json \
  azdo_set_description 5 '<p>new</p>' >/dev/null
assert_eq "set_description leads with a test on the rev it read" "test /rev 3" \
  "$(python3 -c '
import json,sys
b = json.loads(open(sys.argv[1]).read().strip().splitlines()[0])
print(b[0]["op"], b[0]["path"], b[0]["value"])' "$sd_dir/body.txt")"

rm -f "$sd_dir/body.txt"
run_desc azdo-workitem-with-description.json azdo-set-description-stored.json \
  azdo_set_description 5 '<p>new</p>' 99 >/dev/null
assert_eq "set_description: an explicit rev wins" "99" \
  "$(python3 -c '
import json,sys
print(json.loads(open(sys.argv[1]).read().strip().splitlines()[0])[0]["value"])' "$sd_dir/body.txt")"

rc=0; out=$(run_desc azdo-workitem-with-description.json azdo-set-tags-rev-conflict.json \
  azdo_set_description 5 '<p>new</p>' 2>/dev/null) || rc=$?
assert_eq "set_description lost race exits 64" "64" "$rc"
assert_eq "set_description lost race prints nothing" "" "$out"

# A read without a rev refuses the write.
printf '{"id": 5, "fields": {"System.Id": 5}}' > "$sd_dir/no-rev.json"
rm -f "$sd_dir/body.txt"
rc=0
(
  export PATH="$MOCKS:$PATH" AZ_MOCK_FIXTURE="$sd_dir/no-rev.json" \
         CURL_MOCK_FIXTURE="$FIXTURES/azdo-set-description-stored.json" \
         CURL_MOCK_BODY_LOG="$sd_dir/body.txt" \
         AZDO_ORG=contoso AZDO_PROJECT=MyProject AZDO_REPO=my-repo \
         AZURE_DEVOPS_EXT_PAT=not-a-real-token
  # shellcheck disable=SC1090
  source "$LIB"; azdo_set_description 5 '<p>new</p>' >/dev/null 2>&1
) || rc=$?
assert_eq "set_description: a read without a rev refuses the write" "1" "$rc"
[[ ! -s "$sd_dir/body.txt" ]] && pass "set_description: no PATCH without a rev" \
  || fail "set_description: no PATCH without a rev" "a request body was recorded"
```

- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.** Add before `azdo_set_description`:

```bash
# _azdo_description_row <id>  ONE read returning the revision and the description,
# so the `test` op and the add/replace choice rest on the same snapshot (#500).
_azdo_description_row() {
  local id="${1:?_azdo_description_row requires a work-item id}"
  : "${AZDO_PROJECT:?AZDO_PROJECT must be set — call resolve_azdo_context first}"
  az boards work-item show --id "$id" --org "$(azdo_org_url)" \
      --output json --only-show-errors \
  | python3 -c '
import sys, json
d = json.load(sys.stdin)
rev = d.get("rev")
if "fields" not in d or not isinstance(rev, int) or isinstance(rev, bool):
    sys.stderr.write("_azdo_description_row: unexpected response shape\n")
    sys.exit(1)
print(json.dumps({"rev": rev,
                  "description": d["fields"].get("System.Description", "")}))'
}
```

Rewrite the body of `azdo_set_description`: signature `local id="${1-}" html="${2-}" rev="${3-}"`; reject a non-integer `rev` with exit 2 (before any request); read the row (`row=$(_azdo_description_row "$id") || rc=$?`, refuse with exit 1 as today); extract `current` and `read_rev` with python (`sys.stdout.write`); `rev="${rev:-$read_rev}"`; build the body as

```bash
body=$(python3 -c '
import json, sys
print(json.dumps([{"op": "test", "path": "/rev", "value": int(sys.argv[3])},
                  {"op": sys.argv[1], "path": "/fields/System.Description",
                   "value": sys.argv[2]}]))' "$op" "$html" "$rev")
```

and send with `resp=$(_azdo_patch_item azdo_set_description "$id" "$body") || return $?`, then print `System.Description` from `resp` as before. Update the header block (`azdo_set_description <id> <html> [expected-rev]`), the exit-code table (add `azdo_set_description, azdo_add_tag` to the 64 line) and the function comment: exit 64 = lost race, caller retries (library does not), and add:

```bash
# The write is guarded by a json-patch `test` on /rev (#500). Live evidence that the op
# works and is atomic -- a stale rev is rejected and the replace does NOT apply:
# docs/ai-notes/2026-10-08-azdo-writeback-live-run.md, Step 5.
```

- [ ] **Step 4: Run, expect PASS** (existing "failed read refuses the write" still exit 1: the TF51011 fixture is not JSON, python fails, status propagates; confirm `rc` is captured as today).
- [ ] **Step 5: `shellcheck scripts/lib/azdo.sh tests/run-azdo-lib-tests.sh`**, then commit `feat(azdo): guard azdo_set_description with /rev (#500)`.

## Task 5: callers and docs

**Files:** `commands/enrich.md` (Azure DevOps "Write the description", ~line 900-935), `commands/enrich-phased.md` (~546-580).

- [ ] **Step 1:** In `enrich.md` read the rev together with the description the body is composed from and pass it:

```bash
row="$(_azdo_description_row "$ISSUE")" || { echo "read failed — not writing"; exit 1; }
orig="$(printf '%s' "$row" | python3 -c 'import sys,json; sys.stdout.write(json.load(sys.stdin)["description"])')"
rev="$(printf '%s' "$row" | python3 -c 'import sys,json; print(json.load(sys.stdin)["rev"])')"
```

and `azdo_set_description "$ISSUE" "…" "$rev"`. Add: "Exit 64 means someone edited the item after you read it. Stop and report it — re-read and re-compose; never retry the same body." Same sentence for `azdo_add_tag` / `azdo_remove_tag` (lock acquire/release): a 64 there is reported, not looped.
- [ ] **Step 2:** Mirror the sentence in `enrich-phased.md`'s Azure DevOps lock section.
- [ ] **Step 3:** `grep -rn "azdo_set_description" commands` shows no caller left without a status check; run `tests/run-azdo-lib-tests.sh`, `tests/run-script-tests.sh` (smoke), shellcheck.
- [ ] **Step 4: Commit** `docs(azdo): callers handle the /rev conflict (exit 64) (#500)`.
