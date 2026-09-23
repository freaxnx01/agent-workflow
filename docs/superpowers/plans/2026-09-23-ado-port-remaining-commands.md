# Porting the remaining Azure DevOps sections — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the twelve guarded commands working Azure DevOps support by extracting the verified query recipe into a shared shell library and porting each section to call it.

**Architecture:** `scripts/lib/azdo.sh` holds the ADO primitives as sourced shell functions, beside the existing `scripts/lib/detect-forge.sh` that all thirteen commands already source. Each ported `## Azure DevOps` section becomes a few calls plus command-specific rendering, so a defect is fixed once rather than thirteen times.

**Tech Stack:** Bash 5 (`set -euo pipefail`, `IFS=$'\n\t'`), `az` 2.87.0 + azure-devops 1.0.4, `jq`/`python3`, Layer-1 fixture tests with a mocked `az`, `shellcheck -x`, `markdownlint`.

**Spec:** `docs/superpowers/specs/2026-09-23-ado-port-remaining-commands-design.md`

## Global Constraints

- **Blocked by #386.** Do not start Task 3 or later until #386 has landed — its corrected section is the template every port copies. Tasks 1–2 build the library from primitives the live run already verified and may proceed as soon as #386's *shape* is settled.
- **#397 gates the tag writers.** `/new`, `/parked` and `/roadmap` write the parked/roadmap tag. Do not port them until #397 decides whether the tag is renamed to ASCII everywhere or mapped per forge.
- `scripts/lib/azdo.sh` is **sourced, not executed** — functions only, no side effects at source time, mirroring `detect-forge.sh`.
- Quote every expansion, `[[ ]]` over `[ ]`, `$(…)` over backticks, no `eval`, `mktemp` + `trap` for temp files.
- **Exit codes are API.** `0` success, `1` generic error, `2` usage error, `64+` task-specific. `azdo_wiql` uses **2 for `TF51011`** so callers can tell a missing area from an empty result.
- **Never hardcode a work-item state name.** Derive from metadata, always.
- **Test rig:** project `agent-workflow-sandbox` in `https://dev.azure.com/AndreasImboden0022`, holding work items 1–4, area `agent-workflow-sandbox\agent-workflow-sandbox`, an abandoned PR, and iteration `Sprint 1\Week A`. Credentials via `direnv exec ~/repos/ado/personal …`; never echo the PAT.
- **Never write to the `bossinfo` org.** The PAT can reach it and it is production.
- Layer-1 tests mock `az` in `tests/mocks/` — no network, under 5 seconds. `tests/run-all.sh` discovers `run-*-tests.sh` by `find`; no registration needed.
- A command not yet ported keeps its guard **unchanged** and still a hard stop.

---

### Task 1: `scripts/lib/azdo.sh` — context, closed states, and WIQL

**Files:**
- Create: `scripts/lib/azdo.sh`
- Create: `tests/run-azdo-lib-tests.sh`
- Create: `tests/mocks/az` (executable stub)
- Create: `tests/fixtures/azdo-workitemtypes-basic.json`, `tests/fixtures/azdo-workitemtypes-agile.json`, `tests/fixtures/azdo-wiql-rows.json`, `tests/fixtures/azdo-wiql-tf51011.txt`

**Interfaces:**
- Consumes: `resolve_azdo_context` from `scripts/lib/detect-forge.sh`, which sets `AZDO_ORG` / `AZDO_PROJECT` / `AZDO_REPO`.
- Produces:
  - `azdo_org_url` → echoes `https://dev.azure.com/$AZDO_ORG`
  - `azdo_closed_states` → echoes `'Closed','Completed','Removed'` — a comma-joined, single-quoted list ready to interpolate into a WIQL `NOT IN (…)`
  - `azdo_wiql <query>` → echoes matching work-item ids, one per line. Exit `0` on success (including zero rows), **`2` when the Area Path does not exist (`TF51011`)**, `1` on any other error.

- [ ] **Step 1: Write the failing tests**

Create `tests/run-azdo-lib-tests.sh`, following `tests/run-detect-forge-tests.sh`'s
harness (`assert_eq`, `section`, `pass`/`fail`, the `PASS`/`FAIL` summary):

```bash
#!/usr/bin/env bash
#
# run-azdo-lib-tests.sh — Layer-1 fixture tests for scripts/lib/azdo.sh.
# `az` is mocked; no network, no live organization.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/scripts/lib/azdo.sh"
MOCKS="$ROOT/tests/mocks"
FIXTURES="$ROOT/tests/fixtures"

PASS=0; FAIL=0; FAIL_NAMES=()
section() { printf '\n── %s ──\n' "$1"; }
pass() { PASS=$((PASS + 1)); printf '  ✓ %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); FAIL_NAMES+=("$1"); printf '  ✗ %s\n      %s\n' "$1" "${2:-}"; return 0; }
assert_eq() {
  if [[ "$3" == "$2" ]]; then pass "$1"; else fail "$1" "expected: $2 | actual: $3"; fi
}

run_lib() {
  local fixture="$1"; shift
  (
    export PATH="$MOCKS:$PATH"
    export AZ_MOCK_FIXTURE="$FIXTURES/$fixture"
    export AZDO_ORG=contoso AZDO_PROJECT=MyProject AZDO_REPO=my-repo
    # shellcheck disable=SC1090
    source "$LIB"
    "$@"
  )
}

section "azdo_closed_states — derived, never hardcoded"

assert_eq "basic template includes Done" "'Closed','Completed','Done','Inactive','Removed'" \
  "$(run_lib azdo-workitemtypes-basic.json azdo_closed_states)"

assert_eq "agile-derived template omits Done" "'Closed','Completed','Inactive','Removed'" \
  "$(run_lib azdo-workitemtypes-agile.json azdo_closed_states)"

section "azdo_wiql — rows, empty, and TF51011 are three outcomes"

assert_eq "returns ids one per line" "1
2
4" "$(run_lib azdo-wiql-rows.json azdo_wiql 'SELECT [System.Id] FROM WorkItems')"

run_lib azdo-wiql-tf51011.txt azdo_wiql 'SELECT [System.Id] FROM WorkItems' >/dev/null 2>&1
assert_eq "TF51011 exits 2, distinct from empty" "2" "$?"

printf '\n  %d passed' "$PASS"
if [ "$FAIL" -gt 0 ]; then
  printf ', %d failed\n' "$FAIL"
  for n in "${FAIL_NAMES[@]}"; do printf '  - %s\n' "$n"; done
  exit 1
fi
printf '\n'; exit 0
```

The two-template assertion is the important one: it is what stops a future edit
reintroducing a hardcoded state list, which is exactly the #386 defect.

- [ ] **Step 2: Write the `az` mock**

`tests/mocks/az` — executable, echoes the fixture named by `AZ_MOCK_FIXTURE`.
A `.txt` fixture is treated as an error payload written to stderr with exit 1, so
the `TF51011` path can be exercised:

```bash
#!/usr/bin/env bash
# az mock — echoes $AZ_MOCK_FIXTURE. A .txt fixture is an error payload: it goes
# to stderr with exit 1, which is how the real `az` reports TF51011.
set -euo pipefail
: "${AZ_MOCK_FIXTURE:?AZ_MOCK_FIXTURE must be set}"
if [[ "$AZ_MOCK_FIXTURE" == *.txt ]]; then
  cat "$AZ_MOCK_FIXTURE" >&2
  exit 1
fi
cat "$AZ_MOCK_FIXTURE"
```

Fixtures: `azdo-workitemtypes-basic.json` and `azdo-workitemtypes-agile.json` are
trimmed real responses — `{"value":[{"name":"Issue","states":[{"name":"To Do","category":"Proposed"},{"name":"Done","category":"Completed"},…]}]}`
— with the Basic one carrying `Done` and the Agile-derived one not.
`azdo-wiql-rows.json` is `{"workItems":[{"id":1},{"id":2},{"id":4}]}`.
`azdo-wiql-tf51011.txt` is the literal
`ERROR: TF51011: The specified area path does not exist. The error is caused by «'MyProject\my-repo'».`

- [ ] **Step 3: Run the tests to verify they fail**

Run: `tests/run-azdo-lib-tests.sh`

Expected: FAIL — `scripts/lib/azdo.sh` does not exist yet, so sourcing it errors.

- [ ] **Step 4: Implement the three functions**

```bash
#!/usr/bin/env bash
#
# azdo.sh — sourced, not executed. Azure DevOps query primitives shared by every
# command's `## Azure DevOps` section, so a fix lands once instead of thirteen
# times. Requires AZDO_ORG / AZDO_PROJECT / AZDO_REPO, set by
# resolve_azdo_context in detect-forge.sh.
#
# Exit codes: 0 success (including zero rows); 1 error; 2 Area Path not found.
set -euo pipefail
IFS=$'\n\t'

azdo_org_url() { printf 'https://dev.azure.com/%s' "$AZDO_ORG"; }

# azdo_closed_states  echoes "'A','B'" — the project's closed state names, derived
# from metadata. State NAMES are template-specific (Basic has Done, an
# Agile-derived template does not) while the CATEGORIES are not, so never
# hardcode: read them and key on the category.
azdo_closed_states() {
  az devops invoke --org "$(azdo_org_url)" --area wit --resource workitemtypes \
    --route-parameters project="$AZDO_PROJECT" \
    --api-version 7.1 --output json --only-show-errors \
  | python3 -c '
import sys, json
d = json.load(sys.stdin)
closed = sorted({s["name"] for t in d.get("value", [])
                 for s in t.get("states", [])
                 if s.get("category") in ("Completed", "Removed")})
print(",".join("'"'"'%s'"'"'" % c for c in closed))'
}

# azdo_wiql <query>  echoes matching ids, one per line.
# `az boards query` is unusable — it exits 0 and prints zero bytes — so this goes
# through the REST escape hatch. A missing Area Path ERRORS with TF51011 rather
# than returning no rows, so it gets its own exit code: callers must be able to
# tell "this repo has no area" from "nothing is open".
azdo_wiql() {
  local query="$1" out rc
  out=$(az devops invoke --org "$(azdo_org_url)" --area wit --resource wiql \
          --route-parameters project="$AZDO_PROJECT" \
          --http-method POST --in-file /dev/stdin --api-version 7.1 \
          --output json --only-show-errors \
          <<<"$(python3 -c 'import json,sys; print(json.dumps({"query": sys.argv[1]}))' "$query")" 2>&1) || rc=$?
  if [[ -n "${rc:-}" ]]; then
    [[ "$out" == *TF51011* ]] && return 2
    printf '%s\n' "$out" >&2
    return 1
  fi
  printf '%s' "$out" | python3 -c '
import sys, json
for w in json.load(sys.stdin).get("workItems", []):
    print(w["id"])'
}
```

The query is JSON-encoded with `python3` rather than string-interpolated, because
WIQL contains both single quotes and backslashes — hand-quoting it into a JSON
body is how the escaping breaks.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `tests/run-azdo-lib-tests.sh`

Expected: PASS — all four assertions, in particular the two-template pair and the
`TF51011` exit code 2.

- [ ] **Step 6: Verify against the live sandbox**

```bash
direnv exec ~/repos/ado/personal bash -c '
cd ~/repos/ado/personal/agent-workflow-sandbox
source "$PWD/../../../repos/github/freaxnx01/public/agent-workflow/scripts/lib/detect-forge.sh"
source "$PWD/../../../repos/github/freaxnx01/public/agent-workflow/scripts/lib/azdo.sh"
resolve_azdo_context
echo "closed: $(azdo_closed_states)"
azdo_wiql "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = @project"'
```

Expected: `closed: 'Closed','Completed','Done','Inactive','Removed'` (Basic
template) and ids `1 2 3 4`. The mock proves the parsing; this proves the calls.

- [ ] **Step 7: Correct the command count in the docs**

The count is wrong wherever it is written down — there are **12** guarded
commands, not 11. Fix `TODO.md` lines 63, 67, 221 and 232:

```bash
grep -n 'other 11\|Port the 11\|11 sections' TODO.md
```

Change each to 12, and name them once so the number is checkable rather than
folklore: `done`, `enrich`, `enrich-phased`, `milestone`, `new`, `parked`, `prs`,
`queue`, `roadmap`, `route`, `triage`, `work`.

Leave `docs/DECISIONS.md:849` alone — its "remaining 11" is about moving commands
out of the `freaxnx01/config` repo and is a different eleven.

- [ ] **Step 8: Lint and commit**

```bash
shellcheck -x -e SC1091 scripts/lib/azdo.sh tests/run-azdo-lib-tests.sh tests/mocks/az
tests/run-all.sh
git add scripts/lib/azdo.sh tests/run-azdo-lib-tests.sh tests/mocks/az tests/fixtures/azdo-* TODO.md
git commit -m "feat(azdo): add shared ADO query primitives as a sourced library

The ADO recipe is ~150 lines of prompt in commands/issues.md. Porting it into
twelve more markdown files would duplicate it twelve times, and the live run
showed what that costs: five defects sat in the single existing copy, four of them
silent.

Put the primitives beside detect-forge.sh, which all thirteen commands already
source. azdo_closed_states derives state names from metadata rather than
hardcoding them, and azdo_wiql goes through az devops invoke because az boards
query exits 0 printing nothing. A missing Area Path exits 2 so callers can tell it
from an empty result.

Refs #286"
```

---

### Task 2: `scripts/lib/azdo.sh` — fields, classification nodes, and WIP

**Files:**
- Modify: `scripts/lib/azdo.sh`
- Modify: `tests/run-azdo-lib-tests.sh`
- Create: `tests/fixtures/azdo-batch-fields.json`, `tests/fixtures/azdo-areas-childless.json`, `tests/fixtures/azdo-areas-nested.json`

**Interfaces:**
- Consumes: `azdo_org_url` from Task 1.
- Produces:
  - `azdo_fields <ids-csv> <fields-csv>` → JSON lines, one object per work item, with `tags` defaulted to `""`
  - `azdo_areas` / `azdo_iterations` → node names, one per line, empty when none
  - `azdo_active_pr_work_items` → ids linked to an active PR, one per line

- [ ] **Step 1: Write the failing tests**

Append to `tests/run-azdo-lib-tests.sh`:

```bash
section "azdo_fields — System.Tags is ABSENT, not empty, when unset"

assert_eq "absent tags default to empty string" "1||A linked to an active PR" \
  "$(run_lib azdo-batch-fields.json azdo_fields 1 'System.Id,System.Title,System.Tags' \
     | python3 -c 'import sys,json; d=json.loads(sys.stdin.readline()); print("%s|%s|%s" % (d["id"], d["tags"], d["title"]))')"

section "azdo_work_item_types — /new and /triage both need these"

assert_eq "lists the project's types" "Issue
Epic
Task" "$(run_lib azdo-workitemtypes-basic.json azdo_work_item_types)"

section "azdo_areas — children[] not [], and children can be null"

assert_eq "childless project yields nothing, does not error" "" \
  "$(run_lib azdo-areas-childless.json azdo_areas)"

assert_eq "nested project lists its children" "AuditService
SagaEngine" "$(run_lib azdo-areas-nested.json azdo_areas)"
```

The childless assertion is the one that matters: `length(children)` **errors** on
`children: null`, so a naive implementation fails loudly on a perfectly normal
project.

- [ ] **Step 2: Run to verify they fail**

Run: `tests/run-azdo-lib-tests.sh`

Expected: FAIL on the three new assertions — the functions do not exist yet.
The Task 1 assertions must still pass.

- [ ] **Step 3: Implement**

```bash
# azdo_fields <ids-csv> <fields-csv>  echoes one JSON object per work item.
# WIQL returns ids ONLY -- the SELECTed columns come back as a description, not
# values -- so fields need this second call. System.Tags is ABSENT from `fields`
# when a work item has no tags (the key is missing, not null), hence the default.
azdo_fields() {
  local ids="$1" fields="$2"
  az devops invoke --org "$(azdo_org_url)" --area wit --resource workitemsbatch \
    --route-parameters project="$AZDO_PROJECT" \
    --http-method POST --in-file /dev/stdin --api-version 7.1 \
    --output json --only-show-errors \
    <<<"$(python3 -c '
import json, sys
print(json.dumps({"ids": [int(i) for i in sys.argv[1].split(",") if i],
                  "fields": sys.argv[2].split(",")}))' "$ids" "$fields")" \
  | python3 -c '
import sys, json
for w in json.load(sys.stdin).get("value", []):
    f = w.get("fields", {})
    print(json.dumps({
        "id":    f.get("System.Id"),
        "title": f.get("System.Title", ""),
        "state": f.get("System.State", ""),
        "tags":  f.get("System.Tags", ""),
        "iteration": f.get("System.IterationPath", ""),
    }))'
}

# _azdo_nodes <area|iteration>  shared by azdo_areas / azdo_iterations.
# The response is a SINGLE OBJECT, not an array, so a top-level `[]` query
# silently yields nothing. And `children` is null on a childless project, which
# makes `length(children)` error -- so select children[] and let it be empty.
_azdo_nodes() {
  az boards "$1" project list --org "$(azdo_org_url)" --project "$AZDO_PROJECT" \
    --depth 3 --output json --only-show-errors \
  | python3 -c '
import sys, json
for c in (json.load(sys.stdin).get("children") or []):
    print(c["name"])'
}
azdo_areas()      { _azdo_nodes area; }
azdo_iterations() { _azdo_nodes iteration; }

# azdo_work_item_types  echoes the project's valid work-item type names, one per
# line -- what /new needs to offer and what /triage orders by, since ADO has no
# `bug` label, it has a Bug TYPE. Same workitemtypes call azdo_closed_states
# makes; callers that need both should capture this once rather than paying for
# two round trips.
azdo_work_item_types() {
  az devops invoke --org "$(azdo_org_url)" --area wit --resource workitemtypes \
    --route-parameters project="$AZDO_PROJECT" \
    --api-version 7.1 --output json --only-show-errors \
  | python3 -c '
import sys, json
for t in json.load(sys.stdin).get("value", []):
    print(t["name"])'
}

# azdo_active_pr_work_items  ids linked to an ACTIVE pull request.
# "Not WIP" means no *active* PR: a completed or abandoned one does not count.
azdo_active_pr_work_items() {
  local pr
  for pr in $(az repos pr list --org "$(azdo_org_url)" --project "$AZDO_PROJECT" \
                --repository "$AZDO_REPO" --status active \
                --output tsv --only-show-errors --query '[].pullRequestId'); do
    az repos pr work-item list --org "$(azdo_org_url)" --id "$pr" \
      --output tsv --only-show-errors --query '[].id'
  done | sort -u
}
```

`--depth 3` is passed deliberately: it defaults to **1**, which hides nested
iterations — verified against real nested data.

- [ ] **Step 4: Run to verify they pass**

Run: `tests/run-azdo-lib-tests.sh` — all assertions green, Task 1's included.

- [ ] **Step 5: Verify live, including the missing-tags case**

Against the sandbox, `azdo_fields 1,4 'System.Id,System.Title,System.Tags'` must
return item 1 with `"tags": ""` (it genuinely has none) and item 4 with tags
containing `alpha`. Confirm item 1 does **not** error — that is the absent-key case.

- [ ] **Step 6: Lint and commit**

```bash
shellcheck -x -e SC1091 scripts/lib/azdo.sh tests/run-azdo-lib-tests.sh
tests/run-all.sh
git add scripts/lib/azdo.sh tests/run-azdo-lib-tests.sh tests/fixtures/azdo-*
git commit -m "feat(azdo): add field resolution, node listing, and WIP derivation

azdo_fields makes the second call WIQL requires, since WIQL returns ids only and
describes the selected columns rather than returning them. System.Tags is absent
from the response when a work item has no tags, so it is defaulted rather than
indexed.

The classification-node listings select children[] because the response is a
single object -- a top-level [] query silently returns nothing -- and tolerate
children being null, which makes length(children) error on any childless project.

Refs #286"
```

---

### Task 3: Port `/milestone` — iterations, the hardest of the twelve

**Files:**
- Modify: `commands/milestone.md` — replace the `## Azure DevOps` guard

**Interfaces:**
- Consumes: `azdo_iterations`, `azdo_org_url` from Tasks 1–2.
- Produces: the ported-section shape the remaining tasks follow.

> **Do not start until #386 has landed.** Its corrected `/issues` section is the
> template this copies. The requirements below are stable; the prose is not.

- [ ] **Step 1: Confirm the two-step create against the sandbox**

```bash
direnv exec ~/repos/ado/personal bash -c '
o="$AZURE_DEVOPS_ORG_URL"; P=agent-workflow-sandbox
az boards iteration project create --name "Sprint 2" --org "$o" --project "$P" --output tsv --query path
az boards iteration team add --team "$P Team" --org "$o" --project "$P" \
  --id "$(az boards iteration project list --org "$o" --project "$P" --depth 3 \
          --output tsv --query "children[?name=='"'"'Sprint 2'"'"'].identifier")"'
```

Expected: the create succeeds, and **the iteration is not assignable until the
`team add`**. Confirm that second command is genuinely required — this is the trap
the section must document. Delete `Sprint 2` afterwards.

- [ ] **Step 2: Write the section**

Replace the guard in `commands/milestone.md` with an `## Azure DevOps` section
that:

- sources `detect-forge.sh` and `azdo.sh`, calls `resolve_azdo_context`
- states that a **milestone is an iteration**, per ADR-012
- documents the **two-step create** (`iteration project create`, then
  `iteration team add`, or the result is unassignable)
- documents that iterations **nest**, unlike flat GitHub milestones, and that
  `--depth` defaults to 1 and hides the nested ones
- matches the argument on the leaf **name** but filters on the full **path**
- lists via `azdo_iterations` rather than an inline `az` call

- [ ] **Step 3: Verify against the sandbox**

`/milestone` on the sandbox clone lists `Sprint 1` **and** the nested `Week A`.
A depth-1 listing would show only `Sprint 1` — confirm the nested one appears, as
that is what proves `--depth` is being passed.

- [ ] **Step 4: Lint and commit**

```bash
markdownlint commands/milestone.md
git add commands/milestone.md
git commit -m "feat(milestone): add the Azure DevOps section

A milestone maps to an iteration. Creation is two steps -- iteration project
create, then iteration team add -- or the result is unassignable. Iterations nest,
unlike flat GitHub milestones, and --depth defaults to 1, which hides exactly the
sprints that hold work items.

Calls scripts/lib/azdo.sh rather than inlining az commands, so the query recipe
has one home.

Refs #286"
```

---

### Task 4: Port `/prs` and `/triage`

**Files:**
- Modify: `commands/prs.md`, `commands/triage.md`

**Interfaces:**
- Consumes: `azdo_active_pr_work_items`, `azdo_wiql`, `azdo_fields`, `azdo_work_item_types`.

> Blocked by #386, as Task 3.

- [ ] **Step 1: Port `/prs`**

The best-understood surface — both `--query` paths are verified. The section must
state that `--status` takes `active` / `completed` / `abandoned` / `all` and that
there is **no `open`**, and use `[].pullRequestId` / `[].id`, which are correct.

- [ ] **Step 2: Verify `/prs` against the sandbox**

Expected: the abandoned PR appears under `--status abandoned` / `all` and **not**
under `active`. Re-open one to confirm the active path, then abandon it again.

- [ ] **Step 3: Port `/triage`**

The one behavioural difference: **"bugs first" must key off work-item type**, not a
`bug` tag — ADO has no `bug` label, it has an `Issue`/`Bug`/`Task` type. Use
`azdo_work_item_types` (the same `workitemtypes` call `azdo_closed_states` makes —
do not add a second round trip).

- [ ] **Step 4: Verify `/triage` against the sandbox**

The four sandbox items are all type `Issue`, so ordering is unexercised by them.
**Create one `Task` and one `Bug`**, confirm the Bug sorts first, then delete both.
Do not leave them behind — later tasks assert on the four-item baseline.

- [ ] **Step 5: Lint and commit**

```bash
markdownlint commands/prs.md commands/triage.md
git add commands/prs.md commands/triage.md
git commit -m "feat(prs,triage): add the Azure DevOps sections

/prs is the best-understood ADO surface: both --query paths are verified, and
--status takes active/completed/abandoned/all with no open.

/triage needed the one real behavioural change: bugs-first has to key off the
work-item type, because ADO has no bug label -- it has a type. That reuses the
workitemtypes call azdo_closed_states already makes.

Refs #286"
```

---

### Task 5: Port the composition commands — `/queue`, `/done`, `/route`, `/work`, `/enrich`, `/enrich-phased`

**Files:**
- Modify: `commands/queue.md`, `commands/done.md`, `commands/route.md`, `commands/work.md`, `commands/enrich.md`, `commands/enrich-phased.md`

**Interfaces:**
- Consumes: every function from Tasks 1–2. Adds no new ADO surface.

> Blocked by #386.

- [ ] **Step 1: Port the four read-only ones first**

`/queue`, `/done`, `/route` and `/work`'s read half compose the existing
primitives: list candidates, resolve fields, drop WIP. No new `az` call. Each
section is a handful of library calls plus that command's own rendering.

- [ ] **Step 2: Verify each against the sandbox**

Each must return the four-item baseline filtered by its own rule, and **must not**
fall back to the GitHub or Forgejo path — confirm no `gh` or `tea` invocation
appears in any run.

- [ ] **Step 3: Port `/enrich` and `/enrich-phased`**

These write (issue body, labels), so their ADO sections must state plainly which
operations are **not yet supported** and stop on those, rather than half-porting a
write path. The tag-writing half waits on #397.

- [ ] **Step 4: Lint and commit**

```bash
markdownlint commands/queue.md commands/done.md commands/route.md commands/work.md commands/enrich.md commands/enrich-phased.md
git add commands/queue.md commands/done.md commands/route.md commands/work.md commands/enrich.md commands/enrich-phased.md
git commit -m "feat(commands): add Azure DevOps sections for the composition commands

/queue, /done, /route and /work's read half compose the shared primitives and add
no new ADO surface. /enrich and /enrich-phased state which write operations are
unsupported and stop on them rather than half-porting a write path, since the tag
half waits on #397.

Refs #286"
```

---

### Task 6: Port the tag writers — `/new`, `/parked`, `/roadmap`

**Files:**
- Modify: `commands/new.md`, `commands/parked.md`, `commands/roadmap.md`
- Modify: `scripts/lib/azdo.sh` — add `azdo_set_tags`
- Modify: `tests/run-azdo-lib-tests.sh`

**Interfaces:**
- Produces: `azdo_set_tags <id> <tags-csv>` — **replaces** a work item's tags.

> **Blocked by #397 as well as #386.** These three write the parked/roadmap tag,
> and #397 decides what it is called on this forge. Do not start until it is settled.

- [ ] **Step 1: Confirm why `--fields` is not enough**

```bash
direnv exec ~/repos/ado/personal bash -c '
o="$AZURE_DEVOPS_ORG_URL"
az boards work-item update --id 4 --org "$o" --fields "System.Tags=zzz" --output tsv --query "fields.\"System.Tags\""
az boards work-item update --id 4 --org "$o" --fields "System.Tags=" --output tsv --query "fields.\"System.Tags\""'
```

Expected: the first **appends** `zzz` rather than replacing, and the second is a
**no-op** — an empty value does not clear. This is why an unpark verb cannot be
built on `--fields`, and why `azdo_set_tags` must use a json-patch `replace`.

Note: `az devops invoke --media-type application/json-patch+json` failed with an
internal `'type'` traceback in extension 1.0.4. If it still does, use `curl` with
the PAT via `--user ":$AZURE_DEVOPS_EXT_PAT"` and vendor the call into `azdo.sh`
with a comment explaining why. Do not leave the append-only behaviour in place.

- [ ] **Step 2: Implement `azdo_set_tags` with a fixture test**

Test it the same way as the other primitives, with the `az` mock. Assert that
setting tags to a **shorter** list than the current one actually shrinks it — that
is the behaviour `--fields` cannot produce and the whole reason this exists.

- [ ] **Step 3: Port the three sections, honouring #397's decision**

Use whatever tag name #397 settled on. If it chose a per-forge mapping, the
sections consult that mapping rather than hardcoding either spelling.

Both sections must note that tags come back **`; `-separated** — semicolon *and
space* — so splitting on a bare `;` leaves leading whitespace on every tag but the
first.

- [ ] **Step 4: Verify round-trip against the sandbox**

Tag an item parked, confirm it drops out of `/issues`; **unpark it**, confirm it
returns. The unpark is the half that `--fields` could never do, so it is the one
that actually proves this task.

- [ ] **Step 5: Lint and commit**

```bash
markdownlint commands/new.md commands/parked.md commands/roadmap.md
shellcheck -x -e SC1091 scripts/lib/azdo.sh
tests/run-all.sh
git add commands/new.md commands/parked.md commands/roadmap.md scripts/lib/azdo.sh tests/run-azdo-lib-tests.sh
git commit -m "feat(new,parked,roadmap): add the Azure DevOps sections

These three write the parked/roadmap tag, so they needed #397's decision on what
it is called -- Azure DevOps rejects emoji in tag names, so the GitHub spelling
cannot exist here.

They also needed azdo_set_tags: az boards work-item update --fields appends to
System.Tags rather than replacing it, and an empty value is a no-op, so an unpark
verb could not be built on it at all.

Closes #286"
```

---

## Verification

After all six tasks:

```bash
tests/run-all.sh
shellcheck -x -e SC1091 scripts/lib/azdo.sh tests/run-azdo-lib-tests.sh
markdownlint commands/*.md
grep -rn 'has no Azure DevOps section yet' commands/    # expect: no matches
grep -rnE "NOT IN \('[A-Z]" commands/                   # expect: no hardcoded states
```

Then run each of the thirteen commands against `agent-workflow-sandbox` and confirm
none falls through to `gh` or `tea`.

**The greps are necessary, not sufficient.** They prove the guards are gone and no
state literal crept back; they cannot show a ported section actually works. The
live run is the acceptance test.
