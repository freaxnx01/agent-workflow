# `/issues` Azure DevOps section — live-org fixes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `commands/issues.md`'s `## Azure DevOps` section actually work against a live organization, replacing the query mechanism that returns nothing and the guard that never fires.

**Architecture:** All changes are to one file, `commands/issues.md`, within its `## Azure DevOps` section. Each task owns a different numbered Step of that section, so they do not overlap. The artifact is a prompt, not code: verification is running the commands the section prescribes against a preserved sandbox project and confirming the documented output.

**Tech Stack:** Markdown (`markdownlint`), `az` 2.87.0 + azure-devops extension 1.0.4, `jq`/`python3` for shaping JSON in examples.

**Spec:** `docs/superpowers/specs/2026-09-23-issues-ado-live-fixes-design.md`

## Global Constraints

- **Only `commands/issues.md` changes.** No script, workflow or test file is touched by this plan.
- **The sandbox is the test rig:** project `agent-workflow-sandbox` in org `https://dev.azure.com/AndreasImboden0022`, holding work items 1–4, an area path `agent-workflow-sandbox\agent-workflow-sandbox`, one abandoned PR, and iteration `Sprint 1\Week A`.
- **Reach credentials with direnv** — the agent shell fires no direnv hook: `direnv exec ~/repos/ado/personal <command>`. The PAT is `AZURE_DEVOPS_EXT_PAT`, the org `AZURE_DEVOPS_ORG_URL`. Never echo either.
- **Do not change** these, all verified correct: the `workitemtypes` resource name and `--api-version 7.1`; the `.value[].states[]` shape; deriving closed states from `category ∈ {Completed, Removed}`; `az repos pr list --query '[].pullRequestId'`; `az repos pr work-item list --query '[].id'`; the `--status active/completed/abandoned/all` values; the single backslash in `'Project\Repo'`; the `--depth` default-of-1 warning.
- **No state name may appear as a literal** anywhere in Step 2 after Task 1.
- `markdownlint` stays clean. Run it after every task.
- Writes to the sandbox are fine; **never** write to any project in the `bossinfo` org, which is a production organization the PAT can also reach.

---

### Task 1: Issue the WIQL through a mechanism that returns data, and interpolate the derived states

**Files:**
- Modify: `commands/issues.md` — the `### Step 2 — WIQL for the candidate work items` block, and the `### Step 1` → Step 2 handoff

**Interfaces:**
- Consumes: Step 1's derived closed-state list, already produced by the existing `workitemtypes` call — unchanged by this task.
- Produces: the documented two-call pattern (WIQL → ids, `workitemsbatch` → fields) that Task 2's guard and the rendering step both rely on. The field path `.value[].fields."System.<Name>"` is established here and referenced by later tasks.

- [ ] **Step 1: Reproduce the failure, so the fix is anchored**

```bash
direnv exec ~/repos/ado/personal bash -c '
out=$(az boards query --org "$AZURE_DEVOPS_ORG_URL" --project agent-workflow-sandbox \
  --output json --wiql "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = @project" 2>&1)
printf "exit=%s bytes=%s\n" "$?" "${#out}"'
```

Expected: **exit 0 and no output whatsoever**, against a project that contains four
work items. This is the defect. If it prints rows, stop — the toolchain differs
from the one this plan was written against and the whole premise needs re-checking.

- [ ] **Step 2: Confirm the replacement returns data**

```bash
direnv exec ~/repos/ado/personal bash -c '
az devops invoke --org "$AZURE_DEVOPS_ORG_URL" --area wit --resource wiql \
  --route-parameters project=agent-workflow-sandbox \
  --http-method POST --in-file /dev/stdin --api-version 7.1 \
  --output json --only-show-errors \
  <<<"{\"query\":\"SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = @project\"}"'
```

Expected: JSON containing `"workItems": [{"id": 1, …}, {"id": 2, …}, …]` — four ids.
Note it returns **ids and a `columns[]` description only**, not the selected values.

- [ ] **Step 3: Rewrite Step 2 of the section**

Replace the `az boards query` code block and the paragraph introducing it with:

````markdown
`az boards query` is **not** usable here: on `az` 2.87.0 with azure-devops 1.0.4 it
exits 0 and prints **nothing at all** — not `[]`, zero bytes — in every output
format, verified against two organizations. Go through the REST escape hatch, which
returns the same query's rows correctly:

```bash
closed_list=$(printf "'%s'," $closed_states | sed 's/,$//')   # from Step 1
wiql="SELECT [System.Id] FROM WorkItems
WHERE [System.TeamProject] = @project
  AND [System.AreaPath] UNDER '$AZDO_PROJECT\\\\$AZDO_REPO'
  AND [System.State] NOT IN ($closed_list)
  AND [System.Tags] NOT CONTAINS 'parked'
  AND [System.Tags] NOT CONTAINS 'roadmap'
ORDER BY [System.CreatedDate] DESC"

az devops invoke --org "$org_url" --area wit --resource wiql \
  --route-parameters project="$AZDO_PROJECT" \
  --http-method POST --in-file /dev/stdin --api-version 7.1 \
  --output json --only-show-errors <<<"{\"query\": \"$wiql\"}"
```

The state list is **interpolated from Step 1** — never written out. State names are
template-specific: a Basic project derives `Closed, Completed, Done, Inactive,
Removed` while an Agile-derived one derives the same set *without* `Done`. No fixed
list is correct on both, which is the whole reason Step 1 exists.
````

- [ ] **Step 4: Document the two-call pattern**

Immediately after, add:

````markdown
### Step 2b — resolve the fields

WIQL returns **ids only**. The `SELECT`ed columns come back as a `columns[]`
*description*, not as values, so titles and states need a second call:

```bash
az devops invoke --org "$org_url" --area wit --resource workitemsbatch \
  --route-parameters project="$AZDO_PROJECT" \
  --http-method POST --in-file /dev/stdin --api-version 7.1 \
  --output json --only-show-errors \
  <<<"{\"ids\":[$ids],\"fields\":[\"System.Id\",\"System.Title\",\"System.State\",\"System.Tags\",\"System.IterationPath\"]}"
```

Fields land at `.value[].fields."System.Title"` and friends. **`System.Tags` is
absent from `fields` when a work item has no tags** — the key is missing, not null
or empty — so default it on every read rather than indexing it directly.
````

- [ ] **Step 5: Verify the documented commands produce the documented output**

Run Step 3's and Step 4's blocks in sequence against the sandbox, with the state
list derived from Step 1 rather than typed.

Expected: candidate ids `[4, 1]`, and the batch call returning item 1 titled
`A linked to an active PR (section 7)` with **no** `System.Tags` key, and item 4
titled `D plain control - should always appear` with tags containing `alpha`.
The missing-key case on item 1 is the point — confirm it, don't skip past it.

- [ ] **Step 6: Lint and commit**

```bash
markdownlint commands/issues.md
git add commands/issues.md
git commit -m "fix(issues): issue ADO's WIQL through a mechanism that returns data

az boards query exits 0 and prints zero bytes on az 2.87.0 with azure-devops
1.0.4 -- reproduced across two organizations, three projects and all four output
formats -- while the identical WIQL through az devops invoke returns rows. Step 2
was built entirely on the former, so the section could not work.

Also stop hardcoding the closed-state list Step 1 exists to derive: no fixed list
is correct across process templates, since Basic has a Done state that an
Agile-derived template does not, and both have Completed and Inactive that the
literal missed.

Document that WIQL returns ids only, so fields need a second workitemsbatch call,
and that System.Tags is absent rather than empty when a work item has no tags.

Refs #386"
```

---

### Task 2: Make the Area Path guard fire on the error that actually occurs

**Files:**
- Modify: `commands/issues.md` — `### Step 3 — the Area Path guard (do not skip this)`

**Interfaces:**
- Consumes: Task 1's WIQL invocation — the guard wraps its failure mode.
- Produces: the corrected `children[].name` listing pattern, which Task 3 mirrors for iterations.

- [ ] **Step 1: Observe the real failure mode**

```bash
direnv exec ~/repos/ado/personal bash -c '
az devops invoke --org "$AZURE_DEVOPS_ORG_URL" --area wit --resource wiql \
  --route-parameters project=agent-workflow-sandbox \
  --http-method POST --in-file /dev/stdin --api-version 7.1 --output json \
  <<<"{\"query\":\"SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = @project AND [System.AreaPath] UNDER '"'"'agent-workflow-sandbox\\\\no-such-repo'"'"'\"}"'
```

Expected: an **error** naming `TF51011` and quoting the path back — *not* an empty
result. This is why the current guard never fires: it waits for emptiness.

- [ ] **Step 2: Confirm the corrected area listing**

```bash
direnv exec ~/repos/ado/personal bash -c '
o="$AZURE_DEVOPS_ORG_URL"
echo "documented [].name:"
az boards area project list --org "$o" --project agent-workflow-sandbox --depth 3 \
  --output json --only-show-errors --query "[].name"
echo "corrected children[].name:"
az boards area project list --org "$o" --project agent-workflow-sandbox --depth 3 \
  --output json --only-show-errors --query "children[].name"'
```

Expected: the documented path prints **nothing**; the corrected one prints
`agent-workflow-sandbox`.

- [ ] **Step 3: Rewrite the guard**

Replace the Step 3 block with:

````markdown
### Step 3 — the Area Path guard (do not skip this)

A missing Area Path does **not** return zero rows — it fails the query outright:

```text
ERROR: TF51011: The specified area path does not exist.
       The error is caused by «'MyProject\my-repo'».
```

So branch on the error, not on emptiness. The two cases are different answers and
must not be conflated:

- **`TF51011` in stderr** → the area does not exist. List what does:

  ```bash
  az boards area project list --org "$org_url" --project "$AZDO_PROJECT" \
    --depth 3 --output json --only-show-errors --query 'children[].name'
  ```

  Then say exactly: *"no Area Path matching `<repo>` in project `<project>` — this
  project may not scope work items by repo"*, and **ask** whether to re-run
  project-wide. **Never widen automatically** — in a multi-repo project that
  silently presents other repos' work as this repo's, which is not a hypothetical:
  a real project was found with 7 of 10 repos mirrored into areas and 3 not.

- **A clean run returning no rows** → a legitimate "nothing open". Report it as
  that, not as a failure.

Two traps in the listing itself: the response is a **single object**, not an array,
so a top-level `[].name` silently yields nothing — hence `children[]`. And
`children` is `null` on a project with no child areas, so `length(children)`
*errors* rather than returning 0; use `children[]`, which yields nothing, or
`length(children || `[]`)`. `--depth` defaults to 1, so pass it.
````

- [ ] **Step 4: Verify both branches against the sandbox**

- Missing area → the command reports `TF51011`, lists `agent-workflow-sandbox`, and **asks**; confirm it does not widen on its own.
- Real area (`agent-workflow-sandbox\agent-workflow-sandbox`) → returns ids `[4, 1]`.

- [ ] **Step 5: Lint and commit**

```bash
markdownlint commands/issues.md
git add commands/issues.md
git commit -m "fix(issues): fire the ADO Area Path guard on TF51011, not on emptiness

A missing Area Path errors with TF51011 rather than returning zero rows, so the
guard -- which waited for an empty result -- never fired and the command hit an
unhandled error instead. Branch on the error, and report a genuinely empty result
as nothing open.

Also fix the area listing's --query: the response is a single object, so the
documented [].name silently yielded nothing. children[] is correct, and children
is null on a childless project, which makes length(children) error.

Refs #386"
```

---

### Task 3: Fix the iteration listing, which fails the same way

**Files:**
- Modify: `commands/issues.md` — `### Step 5 — the milestone argument maps to Iteration Path`

**Interfaces:**
- Consumes: the `children[]` pattern established in Task 2.
- Produces: nothing later tasks depend on.

- [ ] **Step 1: Confirm the failure and the fix**

```bash
direnv exec ~/repos/ado/personal bash -c '
o="$AZURE_DEVOPS_ORG_URL"
echo "documented:"; az boards iteration project list --org "$o" --project agent-workflow-sandbox \
  --depth 3 --output json --only-show-errors --query "[].{name:name,path:path}"
echo "corrected:";  az boards iteration project list --org "$o" --project agent-workflow-sandbox \
  --depth 3 --output json --only-show-errors --query "children[].{name:name,path:path}"'
```

Expected: documented prints nothing; corrected prints `Sprint 1` with its path.

- [ ] **Step 2: Confirm the `--depth` claim on real nested data**

```bash
direnv exec ~/repos/ado/personal bash -c '
o="$AZURE_DEVOPS_ORG_URL"
for d in 1 2 3; do printf "depth %s: " "$d"
  az boards iteration project list --org "$o" --project agent-workflow-sandbox --depth $d \
    --output json --only-show-errors --query "children[].{n:name,k:length(children || \`[]\`)}"; done
printf "default: "
az boards iteration project list --org "$o" --project agent-workflow-sandbox \
  --output json --only-show-errors --query "children[].{n:name,k:length(children || \`[]\`)}"'
```

Expected: depth 1 and the default both show `Sprint 1` with **0** children; depth 2
and 3 show **1** (`Week A`). The existing warning is correct — keep it.

- [ ] **Step 3: Correct the `--query` in Step 5**

Change the iteration listing to `children[].{name:name,path:path}` and add the same
`children: null` caveat as Task 2. Leave the surrounding prose about iterations
nesting and matching leaf name while filtering on full path **unchanged** — both
are verified correct.

- [ ] **Step 4: Lint and commit**

```bash
markdownlint commands/issues.md
git add commands/issues.md
git commit -m "fix(issues): correct the ADO iteration listing's --query path

az boards iteration project list returns a single root object like the area
listing, so the documented [].{name:name,path:path} yielded nothing. Same
children[] fix and the same children-is-null caveat.

The --depth warning it sits next to is verified correct against real nested data:
a nested iteration is hidden at depth 1 and at the default, visible from depth 2.

Refs #386"
```

---

### Task 4: Delete the tag rationale that describes a problem this forge does not have

**Files:**
- Modify: `commands/issues.md` — the two bullets under Step 2 explaining the tag clauses

**Interfaces:**
- Consumes: nothing.
- Produces: nothing.

- [ ] **Step 1: Confirm both halves of the rationale are false**

```bash
direnv exec ~/repos/ado/personal bash -c '
o="$AZURE_DEVOPS_ORG_URL"
echo "--- can an emoji tag exist at all? ---"
az boards work-item update --id 2 --org "$o" --fields "System.Tags=🧊 parked" --output json 2>&1 | head -2
echo "--- does CONTAINS parked match near-miss tags? ---"
az devops invoke --org "$o" --area wit --resource wiql --route-parameters project=agent-workflow-sandbox \
  --http-method POST --in-file /dev/stdin --api-version 7.1 --output json --only-show-errors \
  <<<"{\"query\":\"SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = @project AND [System.Tags] CONTAINS '"'"'parked'"'"'\"}"'
```

Expected: the write is **rejected** with `TF401407`, and the query matches **only
item 2** — items 3 and 4, tagged `parked-later`/`parkedx` and `unparked`, are
untouched. So there is no emoji tag to avoid, and no substring false-positive.

- [ ] **Step 2: Replace the two bullets**

Delete the "match the bare word … the cost is that a tag merely containing
'parked' would also be dropped" bullet entirely. Keep the `NOT CONTAINS` spelling
note, which is correct. Add in its place:

````markdown
- The tags are matched as bare words (`parked`, `roadmap`), which on this forge is
  simply what they are called: **Azure DevOps rejects emoji in tag names**
  (`TF401407`), so the `🧊 parked` form used on GitHub and Forgejo cannot exist
  here. The convention is therefore **not portable across forges** — see #397,
  which owns that decision.
- There is no substring false-positive to worry about: WIQL's `CONTAINS` on
  `System.Tags` matches **whole tags** despite its name. Verified — a `parked`
  filter leaves `unparked`, `parkedx` and `parked-later` untouched.
````

- [ ] **Step 3: Lint and commit**

```bash
markdownlint commands/issues.md
git add commands/issues.md
git commit -m "docs(issues): drop the ADO tag rationale that describes a non-problem

The section defended bare-word tag matching as a tradeoff with a stated cost. Both
halves are false on this forge: Azure DevOps rejects emoji in tag names entirely
(TF401407), so there is no non-ASCII literal to keep out of the query, and WIQL's
CONTAINS on System.Tags matches whole tags rather than substrings, so a parked
filter leaves unparked and parked-later alone.

Replaced with the consequence the section never mentioned -- the convention does
not port across forges -- pointing at #397, which owns that decision.

Refs #386"
```

---

### Task 5: Verify end to end and retire the epistemic caveat

**Files:**
- Modify: `commands/issues.md` — the `### Azure DevOps blockers` block at the end of the section

**Interfaces:**
- Consumes: every preceding task.
- Produces: the section's claim to be trustworthy, which #286 then copies.

- [ ] **Step 1: Run the whole section as written, against the sandbox**

Follow the section top to bottom as an agent would — derive states, build and issue
the WIQL, apply the Area Path guard, drop WIP by active PR, resolve fields, render.

Expected table:

```
  ID   STATE     TAGS           TITLE
  1    To Do     -              A linked to an active PR (section 7)
  4    To Do     alpha; beta    D plain control - should always appear
```

Item 2 excluded as `parked`, item 3 as `roadmap`, item 1 present because its PR is
abandoned, newest-first. **If the output differs in any respect, stop** — an earlier
task is wrong, and the caveat must not come out.

- [ ] **Step 2: Confirm the WIP branch both ways**

Reopen a PR against `feat/sandbox-pr` linking work item 1, re-run, and confirm item
1 **disappears**. Abandon it again and confirm it returns. This is the one branch
Step 1 cannot show, because the sandbox's PR is already abandoned.

- [ ] **Step 3: Remove the epistemic-status paragraph**

Delete the `### Azure DevOps blockers` block — the "Epistemic status" paragraph and
the `--query` warning under it. Replace with:

````markdown
### Verified

Every command, JSON shape, WIQL clause and `--query` path in this section has been
run against live Azure DevOps organizations (`az` 2.87.0, azure-devops 1.0.4) — see
`docs/ai-notes/2026-09-22-ado-manual-test-run.md` for the run and its findings.

Two things remain worth knowing. `az boards query` is unusable here — it exits 0
and prints nothing — which is why Step 2 goes through `az devops invoke`. And a
`--query` path that stops matching still fails **silently**, printing nothing
rather than erroring, so when a call returns empty where the web UI shows data,
re-run it with plain `--output json` and read the real shape before believing the
emptiness.
````

- [ ] **Step 4: Lint and commit**

```bash
markdownlint commands/issues.md
git add commands/issues.md
git commit -m "docs(issues): retire the ADO epistemic caveat, the section is verified

Every command, JSON shape, WIQL clause and --query path in the Azure DevOps
section has now been run against live organizations and the whole section
reproduces its documented output end to end against the sandbox project.

The caveat was defined as the marker that this had not happened, so removing it is
the definition of done. What survives it is the part still worth knowing: az
boards query is unusable, and a broken --query path fails silently rather than
erroring.

Closes #386"
```

---

## Verification

After all five tasks:

```bash
markdownlint commands/issues.md
grep -n 'az boards query' commands/issues.md            # expect: no matches
grep -nE "NOT IN \('[A-Z]" commands/issues.md           # expect: no hardcoded states
grep -n 'Epistemic status' commands/issues.md           # expect: no matches
grep -n 'children\[\]' commands/issues.md               # expect: 2+ matches
```

Then run the section end to end against `agent-workflow-sandbox` one final time and
confirm the two-row table.

**A green grep is not sufficient.** These greps only prove strings are present or
absent; they cannot tell you the section *works*. The end-to-end run is the
acceptance test, and it is the only one that is.
