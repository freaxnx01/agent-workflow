# Guard the unchecked paths in azdo.sh Implementation Plan (#498)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `azdo_description` rejects a response without `fields`; `_azdo_edit_tags` aborts when its tag transform fails; the usage message names the public functions.

**Architecture:** Two small edits in `scripts/lib/azdo.sh`, each driven by a failing Layer-1 test in `tests/run-azdo-lib-tests.sh`.

**Tech Stack:** Bash 5 (`set -euo pipefail`, `IFS=$'\n\t'`), python3 inline filters, `az`/`curl` mocks in `tests/mocks`, `shellcheck`.

**Spec:** `docs/superpowers/specs/2026-11-16-azdo-guard-unchecked-paths-design.md`

## Global Constraints

- Existing tests in `tests/run-azdo-lib-tests.sh` pass unmodified.
- Exit codes are API: failures here are exit 1; usage stays exit 2.
- No behaviour change for a work item with no description (still exit 0, empty echo).
- Conventional Commits, scope `azdo`; reference `#498`.

## Task 1: `azdo_description` shape check

**Files:**
- Create: `tests/fixtures/azdo-workitem-no-fields.json`
- Modify: `tests/run-azdo-lib-tests.sh` (after the "an absent description reads as empty" case, ~line 309)
- Modify: `scripts/lib/azdo.sh:333-348`

- [ ] **Step 1: Write the fixture**

`tests/fixtures/azdo-workitem-no-fields.json`:

```json
{"id": 5, "rev": 1, "message": "unexpected shape, no fields key"}
```

- [ ] **Step 2: Write the failing tests**

Insert after the `"an absent description reads as empty, exit 0"` assertion:

```bash
rc=0
err="$(run_desc azdo-workitem-no-fields.json azdo-set-description-stored.json \
        azdo_description 5 2>&1 >/dev/null)" || rc=$?
assert_eq "a response without fields exits 1" "1" "$rc"
case "$err" in
  *"unexpected response"*) pass "a response without fields explains itself" ;;
  *) fail "a response without fields explains itself" "stderr: $err" ;;
esac

# The append-instead-of-replace path: an unreadable item must not be written.
rm -f "$sd_dir/body.txt"
rc=0
run_desc azdo-workitem-no-fields.json azdo-set-description-stored.json \
  azdo_set_description 5 '<p>new</p>' >/dev/null 2>&1 || rc=$?
assert_eq "set_description refuses an unreadable item" "1" "$rc"
if [[ -s "$sd_dir/body.txt" ]]; then
  fail "set_description sends no PATCH for an unreadable item" "a request body was recorded"
else
  pass "set_description sends no PATCH for an unreadable item"
fi
```

- [ ] **Step 3: Run and confirm failure**

Run: `bash tests/run-azdo-lib-tests.sh`
Expected: the new "exits 1" and "no PATCH" assertions FAIL (description reads `""`, op `add` is sent).

- [ ] **Step 4: Implement**

Replace the python filter in `azdo_description` with:

```bash
  | python3 -c '
import sys, json
d = json.load(sys.stdin)
if "fields" not in d:
    sys.stderr.write("azdo_description: unexpected response: %s\n" % str(d)[:200])
    sys.exit(1)
sys.stdout.write(d["fields"].get("System.Description", ""))'
```

Add to the function's header comment: "Exit 1 also when the response has no `fields` object, matching the other parsers."

- [ ] **Step 5: Run and confirm pass**

Run: `bash tests/run-azdo-lib-tests.sh`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/azdo.sh tests/run-azdo-lib-tests.sh tests/fixtures/azdo-workitem-no-fields.json
git commit -m "fix(azdo): azdo_description rejects a response without fields (#498)"
```

## Task 2: `_azdo_edit_tags` transform guard and usage message

**Files:**
- Modify: `tests/run-azdo-lib-tests.sh` (in the "azdo_add_tag / azdo_remove_tag" section, after the "usage error without a tag" case, ~line 437)
- Modify: `scripts/lib/azdo.sh:459-488`

- [ ] **Step 1: Write the failing tests**

```bash
# #498 -- a failed transform must not become a write. Callers use `|| rc=$?`,
# which suppresses errexit inside the function, so the guard must be explicit.
# azdo_fields is overridden to emit a row the transform cannot parse.
rm -f "$tg_dir/body.txt"
rc=0
(
  export PATH="$MOCKS:$PATH"
  export CURL_MOCK_FIXTURE="$FIXTURES/azdo-set-tags-replaced.json"
  export CURL_MOCK_BODY_LOG="$tg_dir/body.txt"
  export AZDO_ORG=contoso AZDO_PROJECT=MyProject AZDO_REPO=my-repo
  export AZURE_DEVOPS_EXT_PAT=not-a-real-token
  # shellcheck disable=SC1090
  source "$LIB"
  azdo_fields() { printf 'not json\n'; }
  azdo_remove_tag 5 roadmap
) >/dev/null 2>&1 || rc=$?
assert_eq "a failed tag transform exits 1" "1" "$rc"
if [[ -s "$tg_dir/body.txt" ]]; then
  fail "a failed tag transform sends no PATCH" "a request body was recorded"
else
  pass "a failed tag transform sends no PATCH"
fi

usage_err="$(run_tag azdo-fields-tagged.json azdo_add_tag 5 2>&1 >/dev/null || true)"
case "$usage_err" in
  *"azdo_add_tag"*"azdo_remove_tag"*) pass "usage names the public functions" ;;
  *) fail "usage names the public functions" "stderr: $usage_err" ;;
esac
case "$usage_err" in
  *"_azdo_edit_tags"*) fail "usage does not name the private function" "stderr: $usage_err" ;;
  *) pass "usage does not name the private function" ;;
esac
```

- [ ] **Step 2: Run and confirm failure**

Run: `bash tests/run-azdo-lib-tests.sh`
Expected: "a failed tag transform exits 1", "...sends no PATCH" and both usage assertions FAIL.

- [ ] **Step 3: Implement**

In `_azdo_edit_tags`, change the usage line to:

```bash
    echo "usage: azdo_add_tag <id> <tag> | azdo_remove_tag <id> <tag> [expected-rev]" >&2
```

and close the transform with a guard:

```bash
print("; ".join(tags))' "$mode" "$tag") || {
    echo "_azdo_edit_tags: could not compute the new tag set for work item $id — refusing to write" >&2
    return 1
  }
```

Add to the function's header comment: "The transform's status is checked explicitly: callers invoke with `||`, which suppresses errexit here, and an empty `next` would clear every tag."

- [ ] **Step 4: Run and confirm pass**

Run: `bash tests/run-azdo-lib-tests.sh && shellcheck scripts/lib/azdo.sh tests/run-azdo-lib-tests.sh`
Expected: all pass, shellcheck clean.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/azdo.sh tests/run-azdo-lib-tests.sh
git commit -m "fix(azdo): _azdo_edit_tags aborts on a failed transform, usage names public functions (#498)"
```

## Review Focus

1. Each new test fails without its fix (Task 1 step 3, Task 2 step 2).
2. A no-description work item still reads as empty with exit 0.
3. A legitimate `remove` of the last tag still sends `""`.
