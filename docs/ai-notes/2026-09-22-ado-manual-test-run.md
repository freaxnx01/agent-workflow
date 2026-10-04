# Azure DevOps manual test plan — read-only pass (2026-09-22)

Ran §1–§6, §9 (partial) and §10 of `TODO.md`'s "Azure DevOps — manual test plan"
against a **live organization** for the first time. Sections §7, §8 and the write
half of §9 are still open — they need a sandbox project.

- **Org:** `bossinfo` (Boss Info AG production). **Projects used:** `bossDMS`,
  `Boss Core`, `Boss Info Internal Actions`, `DMS Release Management`.
- **Clone:** `/home/admin/repos/ado/bossDMS/knowledge-base`.
- **Toolchain:** `az` 2.87.0, `azure-devops` extension 1.0.4.
- **Auth:** PAT from the allowed `.envrc` at `/home/admin/repos/ado/.envrc`,
  reached with `direnv exec /home/admin/repos/ado …`.
- **Nothing was written.** No work item, tag, iteration, area or PR was created
  or modified. Every call below is a read.

Method followed the plan's golden rule throughout: run each call with plain
`--output json` first, look at the real shape, and only then add the `--query`.

---

## Verdict

The **metadata half of the design is correct and now verified**. The **query half
is not** — one command it depends on returns nothing at all, two `--query` paths
are silently wrong, the Area Path guard is built on a premise that does not hold,
and the example WIQL contradicts the step above it. Five defects, four of which
fail *quietly*.

| # | Finding | Severity |
|---|---|---|
| 1 | `az boards query` returns **exit 0 and zero bytes** — Step 2 cannot work | blocker |
| 2 | Area Path miss **errors (TF51011)**, it does not return empty — the guard's premise is inverted | high |
| 3 | `az boards area project list --query '[].name'` returns nothing — object-wrapped | high |
| 4 | `az boards iteration project list --query '[].{...}'` returns nothing — same cause | high |
| 5 | Step 2's example hardcodes closed states that Step 1 exists to derive | high |
| 6 | `resolve_azdo_context` misparses `ssh://host:PORT/v3/...` | medium |

---

## 1 — Detection and context

`detect_forge` → `azdo dev.azure.com`, and `resolve_azdo_context` yields
`bossinfo / bossDMS / knowledge-base` on the real clone. Remote-form matrix
(synthetic throwaway repos, no network):

| Form | Result |
|---|---|
| `https://dev.azure.com/o/p/_git/r` | pass |
| `https://o@dev.azure.com/o/p/_git/r` | pass |
| `git@ssh.dev.azure.com:v3/o/p/r` | pass |
| `ssh://git@ssh.dev.azure.com/v3/o/p/r` | pass |
| `https://o.visualstudio.com/p/_git/r` | pass |
| `%20` in project name (https **and** ssh) | pass — decodes to `ONLY Stores AG` |
| **`ssh://git@ssh.dev.azure.com:22/v3/o/p/r`** | **FAIL** |

### Finding 6 — the port breaks the parse, silently

```
ssh://git@ssh.dev.azure.com:22/v3/bossinfo/bossDMS/knowledge-base
  → org=[22] project=[v3] repo=[knowledge-base]      # every field shifted
```

Cause is `_forge_url_path` in `scripts/lib/detect-forge.sh`: its
`s#^[^:/]+[:/]##` strips the host up to the **first** `:`, leaving the port as
the first path segment. `path=${path#v3/}` then no longer matches, so the `v3`
prefix is never removed and each field takes the previous one's value.
`_forge_host` is unaffected, so `detect_forge` still says `azdo` — the failure
produces plausible garbage rather than an error. Any port breaks it, not just 22.

The plan's named ssh form (scp-style) passes, so this is an extra form beyond the
checkbox — but git writes the `ssh://host:port/` spelling itself in some setups.

---

## 2 — Auth failure path

With `AZURE_DEVOPS_EXT_PAT` unset and no `az devops login`, `az` **errors in 0s**
and names the fix. It does **not** prompt and does **not** hang. Passes.

---

## 3 — Work-item metadata (the section that removes template guessing)

This is the design's strongest claim and it **holds**.

- `az devops invoke --area wit --resource workitemtypes --api-version 7.1`:
  resource name and api-version are both **correct** — 15 types returned.
- The response really does carry `.value[].states[]`, and each state has exactly
  `{name, category, color}`. Categories seen: `Proposed`, `InProgress`,
  `Resolved`, `Completed`, `Removed`.
- Across four projects, state **names** differ (`bossDMS` alone has `Groomed`,
  `Offered`, `Cust Approved`, `Risk Estimation`, `Specified`, `Waiting`;
  `Internal Actions` adds `In Review`, `Ready to Work`) while the derived closed
  set is **identical everywhere**: `Closed, Completed, Inactive, Removed`.

So ADR-012's "read it from metadata, key off category" decision is **vindicated**.

> Caveat, stated honestly: all four projects appear to run inherited variants of
> one process template. Names differing across them is real, but this is not the
> stock Basic-vs-Agile-vs-Scrum comparison the plan asked for. The claim is
> supported, not yet maximally stressed.

### Finding 5 — Step 2 ignores what Step 1 derives

Step 1 computes the closed list from metadata. Step 2's example query then
hardcodes `[System.State] NOT IN ('Closed', 'Done', 'Removed')`. Against every
project tested that literal is **wrong in both directions**:

- `Done` **does not exist** in any of the four projects.
- `Completed` and `Inactive` **are** closed here and are **not** excluded — so
  closed work items would be listed as open.

The doc says "interpolate the closed-state list from step 1"; the code block
beneath it does not. The example is what gets copied, so the example is the bug.

---

## 4 — The WIQL query

### Finding 1 (blocker) — `az boards query` produces nothing

```
az boards query --org … --project bossDMS --output json \
  --wiql "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = @project"
→ exit 0, 0 bytes
```

Zero bytes, not `[]`. Reproduced on **two** projects and in **all four** output
formats (`json`, `table`, `tsv`, `yaml`). It is not auth and not the query: the
same WIQL through the REST escape hatch works and returns rows —

```
az devops invoke --area wit --resource wiql --route-parameters project=bossDMS \
  --http-method POST --in-file … --api-version 7.1
→ {"workItems":[{"id":120867,…},{"id":120871,…}, …]}
```

So this is `az boards query` in extension 1.0.4, and **Step 2 of the command
cannot work as written on this toolchain.** The section should go through
`az devops invoke --area wit --resource wiql` instead.

### Finding 2 (high) — the Area Path guard's premise is inverted

Step 3 is built on: *"Scoping by Area Path fails **silently** … returns zero rows
… so when step 2 comes back empty, check whether the area even exists."*

It does not fail silently. A missing area is a hard error:

```
ERROR: TF51011: The specified area path does not exist.
       The error is caused by «'bossDMS\knowledge-base'».
```

The guard therefore **never fires as written** — it waits for an empty result
that never arrives, and the command hits an unhandled error instead. The guard is
still wanted, but it has to catch **TF51011**, not emptiness.

Silver lining, and its own checkbox: the **single backslash survived** bash → `az`
→ REST → the WIQL parser intact — the error quotes it back as
`'bossDMS\knowledge-base'`. That one passes.

### What the query response actually contains

Not the selected fields. WIQL returns **ids only** (`workItems[].id` + `url`);
`SELECT`ed columns come back as a `columns[]` description, not as values. Getting
Title/State/Tags needs a **second** call:

```
az devops invoke --area wit --resource workitemsbatch --http-method POST …
→ .value[].fields."System.Title"   ← the real path
```

The plan asked "where do the fields actually live"; the answer is `.fields.<ref>`
but **only on the batch call**, and Step 2 as written never makes it. Note also
that `System.Tags` is **absent** from `fields` when a work item has no tags — the
key is missing, not null. Parse defensively.

---

## 5 — Every `--query` path

Two right, two quietly wrong. This is exactly the failure class the epistemic
note predicted, and it predicted it correctly.

| Call | Documented `--query` | Real shape | Verdict |
|---|---|---|---|
| `az repos pr list` | `[].pullRequestId` | top-level array | **pass** — returned 11 ids |
| `az repos pr work-item list` | `[].id` | top-level array | **pass** — returned `197398` |
| `az boards area project list` | `[].name` | **single object** | **FAIL — empty** |
| `az boards iteration project list` | `[].{name:name,path:path}` | **single object** | **FAIL — empty** |

### Findings 3 & 4 — the two classification-node listings are object-wrapped

Both return one root node, not a list:

```json
{ "name": "bossDMS", "path": "\\bossDMS\\Area",
  "hasChildren": false, "children": null, "structureType": "area", … }
```

`[].name` against an object yields **nothing at all** — exit 0, no output, no
error. The corrected paths are `children[].name` and
`children[].{name:name,path:path}`, which return the real data
(`Boss Core` → 7 areas: ObservabilityServices, LightweightDMS, EmailServices,
Types, AuditService, SagaEngine, ServiceRegistry).

Guard when correcting: `children` is `null` on a childless project, so
`length(children)` **errors** rather than returning 0.

---

## 6 — Area Path guard, both cases

- **Negative — `bossDMS`:** `hasChildren: false`, no child areas at all. It does
  **not** mirror repo names. This is the case the guard exists for, and per
  Finding 2 it arrives as TF51011, not as an empty list.
- **Positive — `Boss Core`:** 7 of its 10 repos have an identically-named area
  (`AuditService`, `SagaEngine`, `ObservabilityServices`, `EmailServices`,
  `ServiceRegistry`, `Types`, `LightweightDMS`). Real-world confirmation that the
  convention does occur — and that it is a convention, not a rule: 3 repos
  (`Boss Core`, `Common`, `NugetServer`) have no matching area.

The "never widen automatically" rule is **well motivated**: `Boss Core` is a
genuine multi-repo project where widening would show six other repos' work items
as this repo's.

---

## 9 — Iteration depth (partial)

`--depth` made **no difference** on any project tested: default, `--depth 1`,
`--depth 2` and `--depth 3` all returned the same 3 iterations / 7 areas. But
nothing in this org is actually nested (`children` of each child is `null`), so
the documented "`--depth` defaults to 1 and hides nested iterations" trap is
**neither confirmed nor refuted** — it needs a nested iteration, which is a write.
Parked with §9.

---

## 10 — Guards on the other 11 commands

Verified **by inspection**, deliberately: the thing under test is whether a guard
stops before a write, and executing a broken `/new` or `/work` on a live customer
project *is* the write it is supposed to prevent.

`commands/{new,work,milestone,prs,triage}.md` each carry an identical
`## Azure DevOps` section: *"this command has no Azure DevOps section yet. Say
exactly that and **stop**"*, followed by an explicit "Do **not** fall back to the
GitHub or Forgejo section". Unambiguous hard stops, no `gh`/`tea` call reachable.

Also confirmed: all six installed commands in `~/.claude/commands/` are
**byte-identical** to the repo, so this run tested the real artifact.

---

## Still open — needs the sandbox project

- **§7** WIP derivation — link a work item to an active PR, then complete/abandon it.
- **§8** Tags — write `🧊 parked` and `roadmap`, confirm bare-word `CONTAINS 'parked'`
  matches a tag whose stored value carries the emoji, and that
  `--fields "System.Tags=a;b"` lands both.
- **§9** write half — create a nested iteration and settle the `--depth` question.

## Closing the loop

The epistemic-status paragraph in `commands/issues.md` **stays** for now. Removing
it is defined as the marker that this pass is complete, and §7–§9 are not — nor
should it come out while Findings 1–5 are unfixed, since the section does not yet
work end to end on a live org.

---

# Write pass — sections 7, 8, 9 (2026-09-23)

The read-only pass above left §7, §8 and the write half of §9 open for want of a
project that could safely be written to. `bossinfo` turned out not to offer one —
the org has **no "+ New project" button** for this account, confirming the
identity lacks org-level project-create rights. Testing moved to the user's own
organization instead.

- **Org:** `AndreasImboden0022` (personal). **Project:** `agent-workflow-sandbox`,
  created for this run with the **Basic** process template.
- **Repo:** `agent-workflow-sandbox`, auto-created with the project, initialized
  here with `main` + `feat/sandbox-pr`.
- **Area path:** `agent-workflow-sandbox\agent-workflow-sandbox`, created to match
  the repo name so §6's positive case is real rather than incidental.
- **Work items:** four `Issue`s, ids 1–4.
- **PAT:** separate token for this org, from Passbolt, in
  `~/repos/ado/personal/.envrc`. The `bossinfo` PAT is org-scoped and returns
  `requires user authentication` against this org — PATs do not span orgs unless
  explicitly created for all accessible ones.

## Verdict

**§7 and §9 pass as designed. §8 does not — and cannot.** One new blocker, three
new behaviours worth documenting, and §3 is now hardened from "supported" to
"proven". The corrected end-to-end flow was run and works.

| # | Finding | Severity |
|---|---|---|
| 7 | `🧊 parked` is **impossible** as an ADO tag — `TF401407`. Emoji are rejected outright | blocker for the cross-forge convention |
| 7b | WIQL `CONTAINS` on tags is **whole-tag**, not substring — the section's stated "cost" does not exist | medium |
| 8 | `--fields "System.Tags=…"` **appends**; it cannot replace or clear tags | medium |
| 9 | Tags are stored `; `-separated (semicolon **and space**) | low |
| 3+ | Basic's derived closed set **differs** from bossDMS's — hardcoding is provably wrong | upgrades Finding 5 |

---

## Finding 7 (blocker) — the emoji tag cannot exist on Azure DevOps

```
az boards work-item update --id 2 --fields "System.Tags=🧊 parked"
→ ERROR: TF401407: The tag name is invalid. It contains invalid characters.   (rc=1)
```

Rejected with **or** without the space (`🧊parked` fails identically). This is
not a Unicode restriction — `übung` stores fine. Azure DevOps refuses emoji in
tag names specifically.

The `## Azure DevOps` section currently frames bare-word matching as a *clever
workaround*:

> They match the bare word `parked`, not the full `🧊 parked`, on purpose: it
> keeps a non-ASCII literal out of a query string that crosses `az`, the REST
> layer and WIQL's own parser. The cost is that a tag merely *containing*
> "parked" would also be dropped.

That reasoning is now moot, and the stated "cost" is not a cost at all. **There is
no emoji tag on this forge to avoid** — the tag simply *is* `parked`. The real
consequence is one the section does not mention and should:

> **The parked/roadmap convention is not portable.** GitHub and Forgejo use
> `🧊 parked`; Azure DevOps must use a bare `parked`, because the emoji form is
> rejected by the server. Any doc, command or onboarding step that tells a user to
> apply "the `🧊 parked` label" is wrong on ADO.

Good news for the query itself: bare-word matching **works**. With `parked` and
`roadmap` applied, `NOT CONTAINS` filtered exactly as intended (below).

## Finding 7b — WIQL `CONTAINS` on tags is **whole-tag**, so the stated "cost" is fiction

The section defends bare-word matching by naming a tradeoff:

> The cost is that a tag merely *containing* "parked" would also be dropped —
> acceptable, since the convention is exactly one parked tag.

Tested directly, with three near-miss tags spread over two work items:

| Work item | Tags | `CONTAINS 'parked'` |
|---|---|---|
| #2 | `parked; roadmap; übung` | **matched** |
| #3 | `parked-later; parkedx; roadmap` | not matched |
| #4 | `alpha; beta; unparked` | not matched |

```
CONTAINS 'parked'        → [2]          ← only the exact tag
NOT CONTAINS 'parked'    → [1, 3, 4]
CONTAINS 'parked-later'  → [3]          ← exact match on the longer tag works too
```

Despite its name, WIQL's `CONTAINS` on `System.Tags` matches **whole tags**, not
substrings within a tag — `unparked`, `parkedx` and `parked-later` are all
untouched by a `parked` filter.

So the caveat should be **deleted, not reworded**: there is no false-positive
risk, and the convention does not depend on there being "exactly one parked tag".
Combined with Finding 7 (the emoji cannot exist at all), the entire rationale
paragraph in the section is describing a problem that does not exist on this forge.

## Finding 8 — `System.Tags` on update appends, and cannot clear

Successive updates accumulate rather than replace:

```
--fields "System.Tags=parked"          → stored [parked]
--fields "System.Tags=übung"           → stored [parked; übung]
--fields "System.Tags=parked;roadmap"  → stored [parked; roadmap; übung]
--fields "System.Tags="                → stored [parked; roadmap; übung]   (no-op)
```

So `work-item update` is **additive** for this field, and an empty value does not
clear it. Any command that means to *set* tags needs a different mechanism (a
json-patch `replace`), and `/parked`-style "unpark" verbs cannot be built on
`--fields` alone. Worth settling before the `/parked` and `/roadmap` ports in #286.

Note: `az devops invoke … --media-type application/json-patch+json` failed with an
internal `'type'` traceback in extension 1.0.4, so the patch route needs its own
investigation.

## Finding 9 — separator is `; `, not `;`

Input `alpha;beta` is stored and returned as `alpha; beta`. Splitting on a bare
`;` leaves leading whitespace on every tag after the first. Confirms the design's
claim that `work-item create` has **no `--tags` flag** and the field is the way in.

Re-confirmed from the read pass: **`System.Tags` is absent from `fields`** when a
work item has no tags — the key is missing, not null or empty.

---

## §3 hardened — the derived closed set genuinely differs by template

The read pass could only compare four `bossinfo` projects, all inherited variants
of one template, so all four derived the same closed list and the note recorded
the claim as *supported but not maximally stressed*. A **Basic** project settles it:

| Project | Template | Derived closed states |
|---|---|---|
| `bossDMS` + 3 others | Agile-derived (inherited) | `Closed, Completed, Inactive, Removed` |
| `agent-workflow-sandbox` | **Basic** | `Closed, Completed, **Done**, Inactive, Removed` |

Basic introduces `To Do / Doing / Done`, and `Done` correctly carries category
`Completed`. So:

- The **category mechanism is template-independent** — deriving from
  `.states[].category` produced the right answer on both templates. ADR-012's
  decision is **proven**, not merely plausible.
- The **derived list itself is not** stable across templates. Which is exactly why
  it must be derived.

This promotes Finding 5 from "the hardcoded list is wrong here" to **no single
hardcoded list can be right**: `NOT IN ('Closed','Done','Removed')` misses
`Completed` and `Inactive` on *both* templates, while `Done` exists on one and not
the other.

---

## 6 — Area Path guard, positive case (controlled)

With an area created to match the repo name, `[System.AreaPath] UNDER
'agent-workflow-sandbox\agent-workflow-sandbox'` returned **all four** work items.
Area-path scoping works when the area exists; per Finding 2 its absence is
`TF51011`, not an empty set.

## 7 — WIP derivation

| Step | Result |
|---|---|
| PR #1 created from `feat/sandbox-pr` → `main` with `--work-items 1` | `status=active` |
| `az repos pr list --status active --query '[].pullRequestId'` | `1` — **documented path correct** |
| `az repos pr work-item list --id 1 --query '[].id'` | `1` — **documented path correct** |
| → work item 1 is WIP and excluded | as designed |
| `az repos pr update --id 1 --status abandoned` | `abandoned` |
| `--status active` afterwards | `[]` |
| → work item 1 returns | **as designed** |

Both `--query` paths that the read pass confirmed against `bossinfo` are
re-confirmed here with data this run created. `active`-only WIP semantics behave
exactly as the section claims: an abandoned PR does not make a work item WIP.

## 9 — the `--depth` trap is real

The read pass could not settle this, because nothing in `bossinfo` was nested.
Creating `Sprint 1\Week A` settles it:

| Listing | `Sprint 1`'s children |
|---|---|
| `--depth 1` | **0 — nested iteration hidden** |
| **default (no `--depth`)** | **0 — same as depth 1** |
| `--depth 2` | 1 — `Week A` visible |
| `--depth 3` | 1 |

The documented claim — *"`--depth` defaults to 1 … so a depth-1 listing hides the
sprints that actually hold work items"* — is **correct**. Pass `--depth`.

(Basic pre-creates a `Sprint 1`, so the first create returned `VS402371` name-in-use;
the nested `Week A` under it succeeded.)

---

## End-to-end, with every correction applied

Ran the whole `/issues` flow as it *should* read after #386, against the sandbox:

1. Derived closed states from metadata → `'Closed','Completed','Done','Inactive','Removed'`
2. WIQL **via `az devops invoke --area wit --resource wiql`** (not `az boards query`),
   with that list interpolated, area filter, and both tag filters → candidates `[4, 1]`
3. Active-PR work items → none (PR abandoned)
4. Fields via `workitemsbatch` → `.value[].fields."System.Title"`

```
  ID   STATE     TAGS           TITLE
  1    To Do     -              A linked to an active PR (section 7)
  4    To Do     alpha; beta    D plain control - should always appear
```

Correct on every axis: #2 dropped as `parked`, #3 dropped as `roadmap`, #1 back
now that its PR is abandoned, #4 the untouched control, ordered newest-first.

**The design is sound. The implementation's query layer is not.** #386 has what it
needs to fix it, and this is the shape to fix it to.

## Sandbox state

Left in place, not torn down — it is the only reachable ADO project where writes
are safe, and #386 will need it to verify a fix. Contents: 4 work items, 1
abandoned PR, an area path matching the repo, and `Sprint 1\Week A`. Delete the
project in the UI when it has served its purpose.

## Closing the loop

The "Epistemic status" paragraph in `commands/issues.md` **still stays**. Every
section of the manual test plan has now been run — but the section does not work
end to end as written, and removing the caveat before #386 lands would assert a
confidence the code has not earned.
