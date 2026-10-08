# Azure DevOps enrichment write-back — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give `/enrich` and `/enrich-phased` a working write path on Azure DevOps — a work item that comes back carrying acceptance criteria, pointers to the committed spec and plan, and a lock that can be released.

**Architecture:** Five functions join `scripts/lib/azdo.sh`, all following `azdo_set_tags`: json-patch over `curl` against `api-version=7.1`, sourced not executed, exit codes as API. Every write is a read-modify-write that refuses to proceed from a failed read. The command markdown composes; the library only writes.

**Tech Stack:** Bash 5 (`set -euo pipefail`, `IFS=$'\n\t'`), `az` 2.87.0 + azure-devops 1.0.4, `curl`, `python3` (stdlib only — `json`, `html`), Layer-1 fixture tests with mocked `az`/`curl`, `shellcheck -x`, `markdownlint`.

**Spec:** `docs/superpowers/specs/2026-10-08-azdo-enrichment-writeback-design.md`

## Global Constraints

- **`System.Description` is an HTML field** (`type=html`, read live 2026-10-08). Never write Markdown into it.
- **No new dependencies.** `python3` standard library only — `html.escape`, `json`. No `markdown`, no `pandoc`.
- **Every write is a read-modify-write.** Capture the read's exit status and abort on non-zero. An empty read is NOT distinguishable from a failed one — `azdo_fields` defaults an absent `System.Tags` to `""` by design.
- **Exit codes are API:** `0` success, `1` generic error, `2` usage error, `64+` task-specific.
- **`scripts/lib/azdo.sh` is sourced, not executed** — functions only, no side effects at source time.
- **The PAT travels by `curl -K -` on stdin**, never argv, so it cannot leak into a process listing.
- **Layer-1 tests mock `az` and `curl`** via `tests/mocks/`; no network, under five seconds.
- **No Azure DevOps credential exists in CI.** Tasks 1–4 are dispatchable. Task 5 is **local-only**.
- **Never write to the `bossinfo` organization.** The PAT reaches it and it is production.
- **Sandbox fixtures 1–4 are load-bearing** — never write to them. Work item #5 is the write probe.
- Quote every expansion, `[[ ]]` over `[ ]`, `$(…)` over backticks, no `eval`, Conventional Commits.

## Review Focus

Five conditions the spec implies that no obvious happy-path test exercises. Each has a test pinned to the task that owns the code.

1. **A read that fails returns empty, and the write proceeds anyway** — wipes the description or the item's tags. Pinned to Tasks 1 and 3.
2. **A work item that has never had a description** — `replace` on an absent field path errors; the op must be chosen from what the read found. Pinned to Task 1.
3. **Acceptance-criteria text containing `<`, `&` or `"`** — unescaped, it breaks the stored HTML or silently drops content. Pinned to Task 1.
4. **A lock comment returned as HTML** — the lock pattern never matches, so every lock reads as unknown-age and invites a takeover. Pinned to Task 2.
5. **Releasing a lock on an item that also carries `parked` or `roadmap`** — a naive write clears them with it. Pinned to Task 3.

---

### Task 1: `azdo_description` and `azdo_set_description`

**Files:**
- Modify: `scripts/lib/azdo.sh` (append after `azdo_set_tags`)
- Modify: `tests/run-azdo-lib-tests.sh` (append before the summary block)
- Create: `tests/fixtures/azdo-workitem-with-description.json`
- Create: `tests/fixtures/azdo-workitem-no-description.json`
- Create: `tests/fixtures/azdo-set-description-stored.json`

**Interfaces:**
- Consumes: `azdo_org_url` from this library; `AZDO_ORG` / `AZDO_PROJECT` from `resolve_azdo_context`; `AZURE_DEVOPS_EXT_PAT`.
- Produces:
  - `azdo_description <id>` → echoes the item's current `System.Description`. Exit `0` on success **including an absent field** (echoes nothing); `1` on any read error.
  - `azdo_set_description <id> <html>` → writes the field and echoes the stored value back. Chooses the json-patch op from the read: `add` when the field is absent, `replace` when it is present. Exit `0` success, `1` read or write failure, `2` usage.
  - `azdo_html_escape` → filter, stdin to stdout, escaping `& < > "`.

**Why the op is chosen, not fixed.** The existing `azdo_set_tags` test records that a json-patch `add` on `System.Tags` *appends*, which is the behaviour `replace` exists to escape. If that also holds for an HTML field, a fixed `add` would append to the existing description — the exact mangling this work avoids. A fixed `replace` fails on an item that never had one. Reading first settles it, and the read has to happen anyway to compose the new body.

- [ ] **Step 1: Write the failing tests**

Append to `tests/run-azdo-lib-tests.sh`, before the `--- summary ---` block:

```bash
section "azdo_description / azdo_set_description — the HTML field"

sd_dir="$(mktemp -d)"
# shellcheck disable=SC2030,SC2031
run_desc() {
  local az_fixture="$1" curl_fixture="$2"; shift 2
  (
    export PATH="$MOCKS:$PATH"
    export AZ_MOCK_FIXTURE="$FIXTURES/$az_fixture"
    export CURL_MOCK_FIXTURE="$FIXTURES/$curl_fixture"
    export CURL_MOCK_BODY_LOG="$sd_dir/body.txt" CURL_MOCK_LOG="$sd_dir/argv.txt"
    export AZDO_ORG=contoso AZDO_PROJECT=MyProject AZDO_REPO=my-repo
    export AZURE_DEVOPS_EXT_PAT=not-a-real-token
    # shellcheck disable=SC1090
    source "$LIB"
    "$@"
  )
}

assert_eq "reads an existing description" "<p>original</p>" \
  "$(run_desc azdo-workitem-with-description.json azdo-set-description-stored.json \
      azdo_description 5)"

assert_eq "an absent description reads as empty, exit 0" "" \
  "$(run_desc azdo-workitem-no-description.json azdo-set-description-stored.json \
      azdo_description 5)"

# Review Focus 2 — the op is chosen from the read, never fixed.
rm -f "$sd_dir/body.txt"
run_desc azdo-workitem-with-description.json azdo-set-description-stored.json \
  azdo_set_description 5 '<p>new</p>' >/dev/null
assert_eq "an existing description is REPLACED" "replace" \
  "$(python3 -c '
import json,sys
print(json.loads(open(sys.argv[1]).read().strip().splitlines()[0])[0]["op"])' "$sd_dir/body.txt")"

rm -f "$sd_dir/body.txt"
run_desc azdo-workitem-no-description.json azdo-set-description-stored.json \
  azdo_set_description 5 '<p>new</p>' >/dev/null
assert_eq "an absent description is ADDead" "add" \
  "$(python3 -c '
import json,sys
print(json.loads(open(sys.argv[1]).read().strip().splitlines()[0])[0]["op"])' "$sd_dir/body.txt")"

# Review Focus 1 — a failed read must not become a write.
rm -f "$sd_dir/body.txt"
rc=0
run_desc azdo-wiql-tf51011.txt azdo-set-description-stored.json \
  azdo_set_description 5 '<p>new</p>' >/dev/null 2>&1 || rc=$?
assert_eq "a failed read refuses the write" "1" "$rc"
if [[ -s "$sd_dir/body.txt" ]]; then
  fail "a failed read sends no PATCH" "a request body was recorded"
else
  pass "a failed read sends no PATCH"
fi

# Review Focus 3 — interpolated text is escaped.
# Piped INTO run_desc, not run through `bash -c`: the subshell inherits stdin,
# whereas a nested `bash -c` would not have the sourced function at all.
assert_eq "escapes the HTML metacharacters" "a &lt;b&gt; &amp; &quot;c&quot;" \
  "$(printf '%s' 'a <b> & "c"' \
     | run_desc azdo-workitem-with-description.json azdo-set-description-stored.json \
         azdo_html_escape)"

assert_eq "usage error without an id" "2" \
  "$( rc=0; run_desc azdo-workitem-with-description.json azdo-set-description-stored.json \
       azdo_set_description >/dev/null 2>&1 || rc=$?; printf '%s' "$rc" )"

rm -rf "$sd_dir"
```

Create `tests/fixtures/azdo-workitem-with-description.json`:

```json
{"id": 5, "rev": 3, "fields": {"System.Id": 5, "System.Title": "write probe", "System.Description": "<p>original</p>"}}
```

Create `tests/fixtures/azdo-workitem-no-description.json`:

```json
{"id": 5, "rev": 1, "fields": {"System.Id": 5, "System.Title": "write probe"}}
```

Create `tests/fixtures/azdo-set-description-stored.json`:

```json
{"id": 5, "rev": 4, "fields": {"System.Id": 5, "System.Description": "<p>new</p>"}}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `tests/run-azdo-lib-tests.sh`

Expected: FAIL — `azdo_description: command not found` and the assertions below it.

- [ ] **Step 3: Write the minimal implementation**

Append to `scripts/lib/azdo.sh`:

```bash
# azdo_html_escape  filter: stdin to stdout, escaping & < > " for System.Description.
#
# System.Description is an HTML field (type=html, verified live 2026-10-08), so
# anything interpolated into it -- an AC line, a file path -- must be escaped or
# it breaks the stored markup. html.escape is standard library; no dependency.
azdo_html_escape() {
  python3 -c 'import html, sys; sys.stdout.write(html.escape(sys.stdin.read()))'
}

# azdo_description <id>  echoes the work item's current System.Description.
#
# Exit 0 on success INCLUDING an absent field, which echoes nothing: a work item
# that has never had a description simply omits the key. Exit 1 on a read error.
# Callers must capture the status -- an empty echo alone cannot tell the two
# apart, and composing a write from a failed read destroys the existing body.
azdo_description() {
  local id="${1:?azdo_description requires a work-item id}"
  : "${AZDO_PROJECT:?AZDO_PROJECT must be set — call resolve_azdo_context first}"
  az boards work-item show --id "$id" --org "$(azdo_org_url)" \
      --output json --only-show-errors \
  | python3 -c '
import sys, json
d = json.load(sys.stdin)
sys.stdout.write(d.get("fields", {}).get("System.Description", ""))'
}

# azdo_set_description <id> <html>  writes System.Description, echoes it back.
#
# The json-patch op is CHOSEN FROM THE READ, never fixed: `replace` errors on a
# field that does not exist yet, and `add` on an existing field is the appending
# behaviour azdo_set_tags exists to escape. Reading first settles it, and the
# caller has to read anyway to compose the new body.
#
# Exit 0 success, 1 read or write failure, 2 usage.
azdo_set_description() {
  local id="${1-}" html="${2-}"
  if [[ -z "$id" || $# -lt 2 ]]; then
    echo "usage: azdo_set_description <id> <html>" >&2
    return 2
  fi
  : "${AZURE_DEVOPS_EXT_PAT:?AZURE_DEVOPS_EXT_PAT must be set}"

  local current rc=0
  current="$(azdo_description "$id")" || rc=$?
  if [[ $rc -ne 0 ]]; then
    echo "azdo_set_description: could not read work item $id — refusing to write" >&2
    return 1
  fi

  local op=add
  [[ -n "$current" ]] && op=replace

  local url body out
  url="$(azdo_org_url)/_apis/wit/workitems/${id}?api-version=7.1"
  body=$(python3 -c '
import json, sys
print(json.dumps([{"op": sys.argv[1], "path": "/fields/System.Description",
                   "value": sys.argv[2]}]))' "$op" "$html")

  out=$(printf 'user = ":%s"\n' "$AZURE_DEVOPS_EXT_PAT" \
    | curl -sS -K - \
        -H 'Content-Type: application/json-patch+json' \
        -X PATCH "$url" -d "$body") || return 1

  printf '%s' "$out" | python3 -c '
import sys, json
d = json.load(sys.stdin)
if "fields" not in d:
    sys.stderr.write("azdo_set_description: unexpected response: %s\n" % str(d)[:200])
    sys.exit(1)
sys.stdout.write(d["fields"].get("System.Description", ""))'
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `tests/run-azdo-lib-tests.sh`

Expected: PASS, with the count risen from 17 to 24.

- [ ] **Step 5: Lint**

Run: `shellcheck -x scripts/lib/azdo.sh tests/run-azdo-lib-tests.sh`

Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/azdo.sh tests/run-azdo-lib-tests.sh tests/fixtures/azdo-workitem-with-description.json tests/fixtures/azdo-workitem-no-description.json tests/fixtures/azdo-set-description-stored.json
git commit -m "feat(azdo): write System.Description, choosing the op from the read

Refs #488"
```

---

### Task 2: `azdo_comment` and `azdo_comments`

**Files:**
- Modify: `scripts/lib/azdo.sh` (append after `azdo_set_description`)
- Modify: `tests/run-azdo-lib-tests.sh` (append before the summary block)
- Create: `tests/fixtures/azdo-comments-locked.json`

**Interfaces:**
- Consumes: `azdo_org_url`; `AZDO_PROJECT`.
- Produces:
  - `azdo_comment <id> <text>` → posts a discussion comment. Exit `0` success, `1` failure, `2` usage.
  - `azdo_comments <id>` → echoes one comment per line, **HTML stripped and newest last**, so a caller can pattern-match a lock line. Exit `0` success (including none), `1` failure.

- [ ] **Step 1: Write the failing tests**

Append to `tests/run-azdo-lib-tests.sh`, before the summary block:

```bash
section "azdo_comment / azdo_comments — the lock's timestamp"

cm_dir="$(mktemp -d)"
# shellcheck disable=SC2030,SC2031
run_cm() {
  local fixture="$1"; shift
  (
    export PATH="$MOCKS:$PATH"
    export AZ_MOCK_FIXTURE="$FIXTURES/$fixture"
    export AZ_MOCK_LOG="$cm_dir/argv.txt"
    export AZDO_ORG=contoso AZDO_PROJECT=MyProject AZDO_REPO=my-repo
    # shellcheck disable=SC1090
    source "$LIB"
    "$@"
  )
}

# Review Focus 4 — the API returns comment bodies as HTML, so the lock pattern
# only ever matches if the tags come off first.
assert_eq "strips the HTML the comments API returns" \
  "Enrichment lock acquired at 2026-10-08T09:05:27Z" \
  "$(run_cm azdo-comments-locked.json azdo_comments 5 | tail -1)"

assert_eq "posts through the discussion flag" "1" \
  "$( run_cm azdo-comments-locked.json azdo_comment 5 'hello' >/dev/null
     grep -c -- '--discussion hello' "$cm_dir/argv.txt" )"

assert_eq "usage error without text" "2" \
  "$( rc=0; run_cm azdo-comments-locked.json azdo_comment 5 >/dev/null 2>&1 || rc=$?
     printf '%s' "$rc" )"

rm -rf "$cm_dir"
```

Create `tests/fixtures/azdo-comments-locked.json`:

```json
{"totalCount": 2, "comments": [{"id": 11, "text": "<div>a note</div>"}, {"id": 12, "text": "<div>Enrichment lock acquired at 2026-10-08T09:05:27Z</div>"}]}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `tests/run-azdo-lib-tests.sh`

Expected: FAIL — `azdo_comments: command not found`.

- [ ] **Step 3: Write the minimal implementation**

Append to `scripts/lib/azdo.sh`:

```bash
# azdo_comment <id> <text>  posts a comment to the work item's discussion.
#
# `az boards work-item update --discussion` writes System.History, so no raw API
# call is needed for the write. Exit 0 success, 1 failure, 2 usage.
azdo_comment() {
  local id="${1-}" text="${2-}"
  if [[ -z "$id" || $# -lt 2 ]]; then
    echo "usage: azdo_comment <id> <text>" >&2
    return 2
  fi
  az boards work-item update --id "$id" --org "$(azdo_org_url)" \
    --discussion "$text" --output json --only-show-errors >/dev/null
}

# azdo_comments <id>  echoes one comment per line, oldest first, HTML STRIPPED.
#
# The comments API returns each body as HTML -- "<div>Enrichment lock acquired
# at ...</div>" -- so a caller matching a plain-text lock line finds nothing
# unless the tags come off first. Newlines inside a comment are collapsed so one
# comment stays one line and the caller's `tail -1` means what it looks like.
azdo_comments() {
  local id="${1:?azdo_comments requires a work-item id}"
  : "${AZDO_PROJECT:?AZDO_PROJECT must be set — call resolve_azdo_context first}"
  az devops invoke --org "$(azdo_org_url)" --area wit --resource comments \
      --route-parameters project="$AZDO_PROJECT" workItemId="$id" \
      --api-version 7.1-preview --output json --only-show-errors \
  | python3 -c '
import sys, json, re, html
d = json.load(sys.stdin)
for c in d.get("comments", []):
    text = re.sub(r"<[^>]+>", "", c.get("text", ""))
    print(" ".join(html.unescape(text).split()))'
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `tests/run-azdo-lib-tests.sh`

Expected: PASS, count risen to 27.

- [ ] **Step 5: Lint and commit**

```bash
shellcheck -x scripts/lib/azdo.sh tests/run-azdo-lib-tests.sh
git add scripts/lib/azdo.sh tests/run-azdo-lib-tests.sh tests/fixtures/azdo-comments-locked.json
git commit -m "feat(azdo): post and read discussion comments, HTML stripped

Refs #488"
```

---

### Task 3: `azdo_add_tag` and `azdo_remove_tag`

**Files:**
- Modify: `scripts/lib/azdo.sh` (append after `azdo_comments`)
- Modify: `tests/run-azdo-lib-tests.sh` (append before the summary block)
- Create: `tests/fixtures/azdo-fields-tagged.json`

**Interfaces:**
- Consumes: `azdo_fields`, `azdo_set_tags` from this library.
- Produces:
  - `azdo_add_tag <id> <tag>` → read-modify-write; adds one tag, preserving the rest. Exit `0` success, `1` read or write failure, `2` usage.
  - `azdo_remove_tag <id> <tag>` → same, removing one. Same exit codes.

**Why these exist.** `azdo_set_tags` replaces the whole string, so acquiring a lock means read-then-append and releasing means read-then-remove. Done by hand at each call site, a failed read silently becomes "the item had no tags", and the write then clears `parked` or `roadmap` along with the lock.

- [ ] **Step 1: Write the failing tests**

Append to `tests/run-azdo-lib-tests.sh`, before the summary block:

```bash
section "azdo_add_tag / azdo_remove_tag — read-modify-write, guarded"

tg_dir="$(mktemp -d)"
# shellcheck disable=SC2030,SC2031
run_tag() {
  local az_fixture="$1"; shift
  (
    export PATH="$MOCKS:$PATH"
    export AZ_MOCK_FIXTURE="$FIXTURES/$az_fixture"
    export CURL_MOCK_FIXTURE="$FIXTURES/azdo-set-tags-replaced.json"
    export CURL_MOCK_BODY_LOG="$tg_dir/body.txt"
    export AZDO_ORG=contoso AZDO_PROJECT=MyProject AZDO_REPO=my-repo
    export AZURE_DEVOPS_EXT_PAT=not-a-real-token
    # shellcheck disable=SC1090
    source "$LIB"
    "$@"
  )
}

sent_value() {
  python3 -c '
import json,sys
print(json.loads(open(sys.argv[1]).read().strip().splitlines()[0])[0]["value"])' "$tg_dir/body.txt"
}

rm -f "$tg_dir/body.txt"
run_tag azdo-fields-tagged.json azdo_add_tag 5 enrichment-ongoing >/dev/null
assert_eq "adding keeps the existing tags" "parked; roadmap; enrichment-ongoing" \
  "$(sent_value)"

# Review Focus 5 — releasing a lock must not take parked/roadmap with it.
rm -f "$tg_dir/body.txt"
run_tag azdo-fields-tagged.json azdo_remove_tag 5 roadmap >/dev/null
assert_eq "removing leaves the others intact" "parked" "$(sent_value)"

# Review Focus 1 — a failed read must not become a write.
rm -f "$tg_dir/body.txt"
rc=0
run_tag azdo-wiql-tf51011.txt azdo_remove_tag 5 roadmap >/dev/null 2>&1 || rc=$?
assert_eq "a failed read refuses the tag write" "1" "$rc"
if [[ -s "$tg_dir/body.txt" ]]; then
  fail "a failed tag read sends no PATCH" "a request body was recorded"
else
  pass "a failed tag read sends no PATCH"
fi

assert_eq "usage error without a tag" "2" \
  "$( rc=0; run_tag azdo-fields-tagged.json azdo_add_tag 5 >/dev/null 2>&1 || rc=$?
     printf '%s' "$rc" )"

rm -rf "$tg_dir"
```

Create `tests/fixtures/azdo-fields-tagged.json`:

```json
{"count": 1, "value": [{"id": 5, "fields": {"System.Id": 5, "System.Title": "write probe", "System.State": "New", "System.Tags": "parked; roadmap", "System.IterationPath": "MyProject"}}]}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `tests/run-azdo-lib-tests.sh`

Expected: FAIL — `azdo_add_tag: command not found`.

- [ ] **Step 3: Write the minimal implementation**

Append to `scripts/lib/azdo.sh`:

```bash
# _azdo_edit_tags <id> <add|remove> <tag>  shared read-modify-write.
#
# azdo_set_tags replaces the WHOLE string, so a single-tag edit has to read the
# current set first. The read's status is captured and a non-zero one aborts:
# azdo_fields defaults an absent System.Tags to "", so an empty read is
# indistinguishable from a failed one, and writing anyway would clear every tag
# the item has -- parked and roadmap included.
_azdo_edit_tags() {
  local id="${1-}" mode="${2-}" tag="${3-}"
  if [[ -z "$id" || -z "$mode" || -z "$tag" ]]; then
    echo "usage: _azdo_edit_tags <id> <add|remove> <tag>" >&2
    return 2
  fi

  local row rc=0
  row="$(azdo_fields "$id")" || rc=$?
  if [[ $rc -ne 0 || -z "$row" ]]; then
    echo "_azdo_edit_tags: could not read work item $id — refusing to write" >&2
    return 1
  fi

  local next
  next=$(printf '%s' "$row" | python3 -c '
import sys, json
row = json.loads(sys.stdin.readline())
mode, tag = sys.argv[1], sys.argv[2]
tags = [t.strip() for t in row.get("tags", "").split(";") if t.strip()]
if mode == "add":
    if tag not in tags:
        tags.append(tag)
else:
    tags = [t for t in tags if t != tag]
print("; ".join(tags))' "$mode" "$tag")

  azdo_set_tags "$id" "$next"
}

# azdo_add_tag <id> <tag>  adds one tag, preserving the rest.
azdo_add_tag() { _azdo_edit_tags "${1-}" add "${2-}"; }

# azdo_remove_tag <id> <tag>  removes one tag, preserving the rest.
azdo_remove_tag() { _azdo_edit_tags "${1-}" remove "${2-}"; }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `tests/run-azdo-lib-tests.sh`

Expected: PASS, count risen to 32.

- [ ] **Step 5: Run the full suite, lint, commit**

```bash
tests/run-script-tests.sh
shellcheck -x scripts/lib/azdo.sh tests/run-azdo-lib-tests.sh
git add scripts/lib/azdo.sh tests/run-azdo-lib-tests.sh tests/fixtures/azdo-fields-tagged.json
git commit -m "feat(azdo): add and remove a single tag without clobbering the rest

Refs #488"
```

---

### Task 4: The command sections and the ADR

**Files:**
- Modify: `commands/enrich.md` (the `## Azure DevOps` section)
- Modify: `commands/enrich-phased.md` (the `## Azure DevOps` section)
- Modify: `commands/work.md` (the `## Azure DevOps` section — one sentence)
- Modify: `docs/DECISIONS.md` (append ADR-017 after ADR-016)
- Modify: `tests/run-script-tests.sh` (append before the summary block)

**Interfaces:**
- Consumes: `azdo_description`, `azdo_set_description`, `azdo_html_escape`, `azdo_comment`, `azdo_comments`, `azdo_add_tag`, `azdo_remove_tag` from Tasks 1–3.
- Produces: no code interface — documentation plus cross-reference tests.

- [ ] **Step 1: Write the failing tests**

Append to `tests/run-script-tests.sh`, before its summary block:

```bash
section "azdo enrichment write-back — the command sections match the library"

AZDO_LIB="$ROOT/scripts/lib/azdo.sh"

for fn in azdo_description azdo_set_description azdo_html_escape \
          azdo_comment azdo_comments azdo_add_tag azdo_remove_tag; do
  assert_equals "$(grep -c "^$fn()" "$AZDO_LIB" || true)" "1" \
    "$fn is defined exactly once in the library"
done

assert_equals "$(grep -c 'azdo_set_description' "$ROOT/commands/enrich.md" || true)" "1" \
  "enrich.md calls the description writer"

assert_equals "$(grep -c 'azdo_add_tag' "$ROOT/commands/enrich-phased.md" || true)" "1" \
  "enrich-phased.md acquires its lock through the guarded tag writer"

# The stale framing must be gone from all three, not just the two that change.
for f in enrich.md enrich-phased.md work.md; do
  assert_equals "$(grep -c '#286 Task 6' "$ROOT/commands/$f" || true)" "0" \
    "$f no longer cites the closed issue"
done

assert_equals "$(grep -c 'ADR-017' "$ROOT/docs/DECISIONS.md" || true)" "1" \
  "the divergence is recorded as an ADR"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `tests/run-script-tests.sh`

Expected: FAIL — `enrich.md calls the description writer` reports `0`, not `1`.

- [ ] **Step 3: Rewrite `commands/enrich.md`'s Azure DevOps section**

Replace the whole `## Azure DevOps` section with:

````markdown
## Azure DevOps

The write path works. `System.Description` is an **HTML** field, so what goes
into it is not `/enrich`'s GitHub body — see ADR-017 for why that is deliberate.

```bash
source "$HOME/.claude/scripts/lib/detect-forge.sh"
source "$HOME/.claude/scripts/lib/azdo.sh"
resolve_azdo_context || { echo "not an Azure DevOps remote"; exit 1; }
```

**Acquire the lock** before brainstorming, mirroring the GitHub steps: the
timestamped comment first, so the tag always has an age, then the tag.

```bash
azdo_comment "$ID" "Enrichment lock acquired at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
azdo_add_tag "$ID" enrichment-ongoing
```

Read an existing lock with `azdo_comments "$ID"`, which strips the HTML the API
returns. The 24-hour staleness rule and the same-second tie-break (lowest
comment id wins) are the GitHub section's, unchanged.

**Write the description** once the spec and plan are committed and pushed. The
work item gets the original description, then the acceptance criteria, then
pointers — not the inlined plan:

```bash
orig="$(azdo_description "$ID")" || { echo "read failed — not writing"; exit 1; }
ac="$(printf '%s' "$AC_TEXT" | azdo_html_escape)"
azdo_set_description "$ID" "$orig<h2>Acceptance Criteria</h2><ul>$ac</ul>
<h2>Spec &amp; Plan</h2><ul><li><code>$SPEC_PATH</code></li>
<li><code>$PLAN_PATH</code></li></ul>
<p>Read the plan before writing any code.</p>"
```

Every interpolated value goes through `azdo_html_escape` — an unescaped `<` or
`&` in an acceptance criterion breaks the stored markup. Assert the read-back
contains the heading and both paths rather than comparing bytes: Azure DevOps
sanitizes stored HTML.

**Release the lock** with `azdo_remove_tag "$ID" enrichment-ongoing`. The lock
comment stays as an audit trail. There is no readiness tag to clear — per
ADR-012 nothing on this forge dispatches, so `/new` never applies one.

**Do not claim the item is dispatchable.** There is no `ai-implement` here;
report the paths and stop.
````

- [ ] **Step 4: Rewrite `commands/enrich-phased.md`'s Azure DevOps section**

Replace the whole `## Azure DevOps` section with:

````markdown
## Azure DevOps

The phased flow works here now. It depends on the **enrichment lock** surviving
a `/clear`, and the lock can be released since `azdo_set_tags` replaces rather
than appends.

```bash
source "$HOME/.claude/scripts/lib/detect-forge.sh"
source "$HOME/.claude/scripts/lib/azdo.sh"
resolve_azdo_context || { echo "not an Azure DevOps remote"; exit 1; }
```

Acquire once, before the spec phase, and release once, after the body write:

```bash
azdo_comment "$ID" "Enrichment lock acquired at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
azdo_add_tag "$ID" enrichment-ongoing
# ... spec phase, /clear, plan phase, /clear, body write ...
azdo_remove_tag "$ID" enrichment-ongoing
```

`azdo_add_tag` and `azdo_remove_tag` read the current tags and write the whole
set back, aborting if the read fails — so a transient error cannot strip
`parked` or `roadmap` off the item along with the lock.

The body write is `/enrich`'s Azure DevOps section verbatim: acceptance criteria
plus pointers, never the inlined plan. See ADR-017.
````

- [ ] **Step 5: Correct the one sentence in `commands/work.md`**

In the `## Azure DevOps` section, replace the `**No issue-body enrichment.**`
bullet with:

```markdown
- **No pipeline dispatch, so no handoff.** `/enrich` can now write acceptance
  criteria and plan pointers onto the work item (ADR-017), but per ADR-012
  nothing here picks the item up afterwards. This command's Azure DevOps path
  stays local execution only: plan, implement, open a PR with
  `az repos pr create --work-items <id>`.
```

- [ ] **Step 6: Append ADR-017 to `docs/DECISIONS.md`**

```markdown
## ADR-017 — An enriched ADO work item carries criteria and pointers, not the plan (2026-10-08)

**Status:** accepted

**Context.** `/enrich`'s GitHub path inlines the whole implementation plan into
the issue body, because the pipeline agent reads *only* that body. `System.
Description` on Azure DevOps is an HTML field (`type=html`, read live from
`AndreasImboden0022` on 2026-10-08); there is no Markdown-format field, and
neither `python-markdown` nor `pandoc` is available.

**Decision.** On Azure DevOps the work item gets the original description, the
acceptance criteria, and pointers to the committed spec and plan. The plan is
not inlined, in any form.

**Why this is not a regression.** The "body alone is enough" rule exists for the
pipeline agent, and per ADR-012 there is no pipeline on this forge. The reader
here is a human or a local `/work` session, both with the repository checked
out. Inlining a 40 KB plan into an HTML field would solve a problem Azure
DevOps does not have, and render as an unformatted wall.

**Rejected.** Wrapping the Markdown in `<pre>` — preserves the GitHub contract
but produces an unusable work item. Converting Markdown to HTML — needs a
dependency the guardrails forbid adding unasked, and makes the write lossy.

**Consequence.** `/enrich` reports the paths and stops; it never claims the item
is dispatchable, because nothing dispatches it.
```

- [ ] **Step 7: Run the tests and lint**

Run: `tests/run-script-tests.sh && tests/run-azdo-lib-tests.sh`

Expected: PASS, both suites.

Run: `pre-commit run --files commands/enrich.md commands/enrich-phased.md commands/work.md docs/DECISIONS.md tests/run-script-tests.sh`

Expected: all hooks pass, markdownlint included.

- [ ] **Step 8: Commit**

```bash
git add commands/enrich.md commands/enrich-phased.md commands/work.md docs/DECISIONS.md tests/run-script-tests.sh
git commit -m "feat(azdo): make /enrich and /enrich-phased write on Azure DevOps

Refs #488"
```

---

### Task 5: Live verification — LOCAL ONLY, do not dispatch

**This task cannot run in the pipeline.** This repository has no Azure DevOps
credential in CI — `gh secret list` shows none and no workflow references Azure
DevOps — so a dispatched agent would exercise the mocks from Tasks 1–3 and
report green without touching anything. A human runs this task locally.

**Files:**
- Create: `docs/ai-notes/2026-10-08-azdo-writeback-live-run.md`
- Modify: `docs/ai-notes/2026-09-25-ado-forge-support-complete.md` (the do-not-delete list)

**Interfaces:**
- Consumes: every function from Tasks 1–3, sourced from **the repository's**
  `scripts/lib/azdo.sh` — not `$HOME/.claude/scripts/lib/azdo.sh`, which is the
  stale installed copy.

- [ ] **Step 1: Create the dedicated write-probe work item**

Sandbox fixtures 1–4 each prove something specific; writing to any of them
corrupts the rig. Create #5 once and keep it:

```bash
direnv exec ~/repos/ado/personal bash -c '
az boards work-item create --org "https://dev.azure.com/AndreasImboden0022" \
  --project agent-workflow-sandbox --type Issue \
  --title "write probe — do not delete (#488)" \
  --fields "System.AreaPath=agent-workflow-sandbox\\agent-workflow-sandbox" \
  --output json --only-show-errors | python3 -c "import sys,json; print(json.load(sys.stdin)[\"id\"])"'
```

Note the id it prints. It should be `5`; use whatever comes back.

- [ ] **Step 2: Verify the op choice against a work item with no description**

The item just created has none, so this exercises the `add` branch:

```bash
direnv exec ~/repos/ado/personal bash -c '
export AZDO_ORG=AndreasImboden0022 AZDO_PROJECT=agent-workflow-sandbox AZDO_REPO=agent-workflow-sandbox
source scripts/lib/azdo.sh
azdo_set_description 5 "<p>first</p>"'
```

Expected: echoes `<p>first</p>`. Record the actual output in the notes file —
including any HTML the service rewrote.

- [ ] **Step 3: Verify the replace branch and that it does not append**

```bash
direnv exec ~/repos/ado/personal bash -c '
export AZDO_ORG=AndreasImboden0022 AZDO_PROJECT=agent-workflow-sandbox AZDO_REPO=agent-workflow-sandbox
source scripts/lib/azdo.sh
azdo_set_description 5 "<p>second</p>"
azdo_description 5'
```

Expected: `<p>second</p>` alone. **If it reads `<p>first</p><p>second</p>`, the
service appends on `replace` too** — stop, record it, and open a follow-up; the
whole write path rests on this.

- [ ] **Step 4: Verify the lock round trip, and whether emoji survive**

ADR-016 covers emoji in tag *names* only; a comment body is untested.

```bash
direnv exec ~/repos/ado/personal bash -c '
export AZDO_ORG=AndreasImboden0022 AZDO_PROJECT=agent-workflow-sandbox AZDO_REPO=agent-workflow-sandbox
source scripts/lib/azdo.sh
azdo_comment 5 "🔒 Enrichment lock acquired at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
azdo_comments 5 | tail -1
azdo_add_tag 5 enrichment-ongoing
azdo_fields 5
azdo_remove_tag 5 enrichment-ongoing
azdo_fields 5'
```

Expected: the comment reads back with the lock line intact; the tag appears and
then disappears, leaving any other tags untouched. If the emoji does not
survive, record it and switch the lock marker to ASCII in `commands/enrich.md`
and `commands/enrich-phased.md`.

- [ ] **Step 5: Check whether a json-patch `test` on `/rev` makes acquire atomic**

```bash
direnv exec ~/repos/ado/personal bash -c '
set -euo pipefail
ORG="https://dev.azure.com/AndreasImboden0022"
rev=$(az boards work-item show --id 5 --org "$ORG" --output json --only-show-errors \
      | python3 -c "import sys,json; print(json.load(sys.stdin)[\"rev\"])")
printf "user = \":%s\"\n" "$AZURE_DEVOPS_EXT_PAT" | curl -sS -K - \
  -H "Content-Type: application/json-patch+json" \
  -X PATCH "$ORG/_apis/wit/workitems/5?api-version=7.1" \
  -d "[{\"op\":\"test\",\"path\":\"/rev\",\"value\":$rev},
       {\"op\":\"replace\",\"path\":\"/fields/System.Description\",\"value\":\"<p>third</p>\"}]" \
  | head -c 300'
```

Record the result. If the `test` op is honoured, note in the notes file that a
follow-up can give the lock optimistic concurrency and a `64+` "lost the race"
exit code. **Do not implement it in this plan** — it is out of scope.

- [ ] **Step 6: Write the notes file**

Create `docs/ai-notes/2026-10-08-azdo-writeback-live-run.md` recording, for each
step above: the command, the actual output, and whether it matched the
expectation. A step that behaved differently is the valuable part — write what
happened, not what should have.

- [ ] **Step 7: Add the probe item to the do-not-delete list**

In `docs/ai-notes/2026-09-25-ado-forge-support-complete.md`, under the preserved
fixtures list, add:

```markdown
- Work item **5** — the write probe for `azdo_set_description` / the lock round
  trip (#488). Its description and tags are expected to churn; the other four
  must not.
```

- [ ] **Step 8: Reinstall the commands and commit**

The installed copies under `$HOME/.claude/` are what a real `/enrich` run
sources, and they are stale until this runs:

```bash
/update-commands
```

```bash
git add docs/ai-notes/2026-10-08-azdo-writeback-live-run.md docs/ai-notes/2026-09-25-ado-forge-support-complete.md
git commit -m "docs(azdo): record the live write-back verification

Closes #488"
```
