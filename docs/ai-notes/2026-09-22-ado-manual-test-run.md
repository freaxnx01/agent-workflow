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
