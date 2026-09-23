# `/issues` Azure DevOps section — make it work against a live org (#386)

**Date:** 2026-09-23
**Issue:** [#386](https://github.com/freaxnx01/agent-workflow/issues/386)
**Status:** approved
**Evidence:** `docs/ai-notes/2026-09-22-ado-manual-test-run.md`

## Problem

PR #307 shipped the `## Azure DevOps` section of `commands/issues.md` with an
explicit "Epistemic status" caveat: flags were checked against `--help`, but no
JSON shape, WIQL clause or `--query` path had ever been run against a live
organization. The manual test plan has now run in full against two organizations.
**Five defects, four of which fail silently.**

Failing silently matters more than the count: an empty result from this command is
also its legitimate "no open work items" answer, so every one of these reads as
success.

## The defects

### D1 — `az boards query` returns nothing at all (blocker)

```
az boards query --org … --project … --output json \
  --wiql "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = @project"
→ exit 0, 0 bytes
```

Not `[]` — **zero bytes**. Reproduced across:

- **two independent organizations** (`bossinfo`, `AndreasImboden0022`)
- **three projects**, including one with four known work items
- **all four output formats** (`json`, `table`, `tsv`, `yaml`)

It is neither auth nor the query: the identical WIQL through the REST escape hatch
returns rows in the same shell, with the same PAT, against the same project.

Step 2 of the section is built entirely on `az boards query`, so **the section
cannot work as written** on `az` 2.87.0 with azure-devops 1.0.4.

### D2 — the Area Path guard's premise is inverted

Step 3 states: *"Scoping by Area Path fails silently: a project that does not mirror
repo names into its area tree returns zero rows … so when step 2 comes back empty,
check whether the area even exists."*

It does not return zero rows. It errors:

```
ERROR: TF51011: The specified area path does not exist.
       The error is caused by «'bossDMS\knowledge-base'».
```

So the guard waits for a condition that never arrives and **never fires**; the
command hits an unhandled error instead. The guard is still wanted — the danger it
protects against (silently widening to project scope and presenting other repos'
work as this repo's) is real, and confirmed real: `Boss Core` is a genuine
multi-repo project where 7 of 10 repos have a matching area and 3 do not.

### D3/D4 — two `--query` paths return nothing

Both classification-node listings return a **single root object**, not an array:

```json
{ "name": "bossDMS", "path": "\\bossDMS\\Area",
  "hasChildren": false, "children": null, "structureType": "area" }
```

`[].name` against an object yields no output, no error, exit 0.

| Call | Documented | Verdict |
|---|---|---|
| `az repos pr list` | `[].pullRequestId` | **correct** — top-level array |
| `az repos pr work-item list` | `[].id` | **correct** — top-level array |
| `az boards area project list` | `[].name` | **empty** → `children[].name` |
| `az boards iteration project list` | `[].{name:name,path:path}` | **empty** → `children[].{…}` |

### D5 — Step 2 hardcodes the states Step 1 derives

Step 1 reads closed states from project metadata; Step 2's example then hardcodes
`[System.State] NOT IN ('Closed', 'Done', 'Removed')`. Measured against two
genuinely different process templates:

| Project | Template | Derived closed states |
|---|---|---|
| `bossDMS` (+3 others) | Agile-derived (inherited) | `Closed, Completed, Inactive, Removed` |
| `agent-workflow-sandbox` | Basic | `Closed, Completed, `**`Done`**`, Inactive, Removed` |

The literal is wrong on **both**: it misses `Completed` and `Inactive` everywhere,
and `Done` exists on one template but not the other. **No single hardcoded list can
be correct** — which is precisely the argument Step 1 makes and Step 2 ignores.

The prose says "interpolate the closed-state list from step 1"; the code block does
not. The code block is what gets copied.

### D6 — the bare-word rationale describes a problem that does not exist

The section defends matching `parked` rather than `🧊 parked` as a tradeoff:

> The cost is that a tag merely *containing* "parked" would also be dropped —
> acceptable, since the convention is exactly one parked tag.

Both halves are false on this forge:

- **Azure DevOps rejects emoji in tag names** (`TF401407`), so `🧊 parked` cannot
  exist and there is no non-ASCII literal to avoid.
- WIQL's `CONTAINS` on `System.Tags` matches **whole tags**, not substrings.
  Verified: `CONTAINS 'parked'` matched only the item tagged exactly `parked`,
  while `unparked`, `parkedx` and `parked-later` were untouched.

So the paragraph is deleted rather than reworded. What replaces it is a pointer to
the real, unmentioned consequence — the convention is **not portable** — which is
**#397**'s decision, not this issue's.

## What is verified correct and must not be "fixed"

- `az devops invoke --area wit --resource workitemtypes --api-version 7.1` — the
  resource name and api-version were guesses; both are right. 15 types returned.
- `.value[].states[]` carries exactly `{name, category, color}`.
- Deriving closed states from `category ∈ {Completed, Removed}` gives the correct
  answer on both templates tested.
- `az repos pr list --status active --query '[].pullRequestId'` and
  `az repos pr work-item list --query '[].id'`.
- `--status` takes `active`/`completed`/`abandoned`/`all`; "not WIP" means no
  **active** PR. Verified by abandoning a PR and watching the item return.
- The single backslash in `'Project\Repo'` survives bash → `az` → REST → WIQL.
- `--depth` genuinely defaults to 1 and hides nested iterations.

## Design

### Replace `az boards query` with the REST escape hatch

```bash
wiql='SELECT [System.Id] FROM WorkItems WHERE …'
az devops invoke --org "$org_url" --area wit --resource wiql \
  --route-parameters project="$AZDO_PROJECT" \
  --http-method POST --in-file /dev/stdin --api-version 7.1 \
  --output json --only-show-errors <<<"{\"query\": \"$wiql\"}"
```

The WIQL text itself is unchanged — it was never the problem.

### Accept that WIQL returns ids only

The response carries `workItems[].id` plus a `columns[]` *description* of the
selected fields — **not their values**. Resolving titles/states/tags needs a second
call:

```bash
az devops invoke --org "$org_url" --area wit --resource workitemsbatch \
  --route-parameters project="$AZDO_PROJECT" \
  --http-method POST --in-file /dev/stdin --api-version 7.1 \
  --output json --only-show-errors \
  <<<"{\"ids\":[$ids],\"fields\":[\"System.Id\",\"System.Title\",\"System.State\",\"System.Tags\",\"System.IterationPath\"]}"
```

Fields land at `.value[].fields."System.Title"`. **`System.Tags` is absent from
`fields` when an item has no tags** — the key is missing, not null or empty — so
every read of it needs a default.

This two-call shape is not a workaround; it is how the WIQL API works.

### Invert the Area Path guard

Catch the error, not the emptiness:

- `TF51011` in stderr → the area does not exist. Say *"no Area Path matching
  `<repo>` in project `<project>` — this project may not scope work items by
  repo"*, then **ask** whether to re-run project-wide. Never widen automatically.
- A clean run returning zero rows → a legitimate "nothing open". Report it as such.

The two cases are now distinguishable, which they were not before.

### Fix the two `--query` paths

`children[].name` and `children[].{name:name,path:path}`. Guard `children: null` on
a childless project — `length(children)` **errors** rather than returning 0, so use
`children[]` (which yields nothing) or `length(children || \`[]\`)`.

### Interpolate the derived closed-state list

Step 2's example must build its `NOT IN (…)` clause from Step 1's output. No state
name appears as a literal anywhere in the section.

### Delete the bare-word rationale

Replace with a short portability note pointing at #397.

## Verified end-to-end shape

Run against `agent-workflow-sandbox` with all corrections applied:

1. Derive closed states → `'Closed','Completed','Done','Inactive','Removed'`
2. WIQL via `az devops invoke` with that list interpolated → candidates `[4, 1]`
3. Active-PR work items → none
4. `workitemsbatch` → fields

```
  ID   STATE     TAGS           TITLE
  1    To Do     -              A linked to an active PR (section 7)
  4    To Do     alpha; beta    D plain control - should always appear
```

Correct on every axis: the `parked` item dropped, the `roadmap` item dropped, item
1 back after its PR was abandoned, newest-first. **This is the target.**

## Acceptance criteria

- [ ] Step 2 issues its WIQL through `az devops invoke --area wit --resource wiql`; `az boards query` appears nowhere in the section
- [ ] The section documents the two-call pattern and states that WIQL returns ids only
- [ ] Every field read defaults `System.Tags`, whose key is absent when unset
- [ ] The Area Path guard triggers on `TF51011`, and a clean empty result is reported as "nothing open"
- [ ] The guard still refuses to widen scope without asking
- [ ] Both classification-node `--query` paths are `children[]`-prefixed, with the `children: null` case handled
- [ ] No state name appears as a literal in Step 2 — the list is interpolated from Step 1
- [ ] The bare-word "cost" paragraph is gone, replaced by a portability pointer to #397
- [ ] The four verified-correct items above are unchanged
- [ ] A live run against `agent-workflow-sandbox` reproduces the table above
- [ ] The "Epistemic status" paragraph is **removed** — this issue is what earns that

## Testing

There is no fixture harness for command markdown, and one should not be invented
here: the artifact is a prompt, and its failure mode is an agent misreading it, not
a function returning the wrong value. Verification is the live run against
`agent-workflow-sandbox`, which is preserved for exactly this purpose and holds 4
work items, an area path matching the repo, an abandoned PR and a nested iteration.

`markdownlint` must stay clean, as for any doc change in this repo.

## Out of scope

- **#397** — what the parked tag is *called* per forge. This issue only stops
  claiming a cost that does not exist.
- **#387** — the `ssh://` port parse in `detect-forge.sh`.
- **#286** — porting the other 11 sections. This issue produces the template they
  copy, which is why it blocks them.
- Fixing `az boards query` upstream. Worth reporting to Azure CLI, but the section
  cannot wait on it.
