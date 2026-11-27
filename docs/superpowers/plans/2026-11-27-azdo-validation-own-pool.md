# PR validation on its own agent pool — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Document and pin that Azure DevOps PR build validation runs on its own agent pool, so no PR code ever runs on the registration that takes `ai-implement` jobs (#703).

**Architecture:** No script changes. The separation is operator setup enforced by Azure DevOps pool permissions. The deliverables are the validation template's pool placeholder, the setup doc, the cutover runbook, the unit example, an ADR, and Layer-1 tests that pin each of them.

**Tech Stack:** Markdown, Azure Pipelines YAML template, Bash Layer-1 tests (`tests/run-*-tests.sh`, discovered by `tests/run-all.sh`).

**Spec:** `docs/superpowers/specs/2026-11-27-azdo-validation-own-pool-design.md`

## Global Constraints

- Placeholders only: `<pool>` (implement pool), `<validation-pool>` (new), `<name>`, `<volume>`, `<image>`, `<org>`, `<project>`. No real organization, host, pool or repo name anywhere, including tests and commit messages.
- `<pool>` keeps its existing meaning everywhere it already appears outside §9 and the template. Do not rename it.
- Anchor every doc edit to a **section heading**, never a line number: #699 rewrote parts of §9 and §14 of `docs/AZDO-PIPELINE-SETUP.md` just before this issue.
- The new setup-doc subsection's heading text is exactly `Run validation on its own pool`, numbered as the next free `### 9.N` after the last existing `### 9.x` (9.7 if #699 added 9.6).
- New test files follow the existing `tests/run-azdo-cutover-doc-tests.sh` shape: `set -euo pipefail`, `IFS=$'\n\t'`, `pass`/`fail` counters, exit 1 on any failure, a `passed: N   failed: M` summary.
- No change to any file under `scripts/` or `docker/azp-agent/boundary/`.
- `just lint` (shellcheck) and `bash tests/run-all.sh` stay green.

## Review Focus

- A reader following §9 top to bottom still authorizes the validation pipeline on `<pool>` somewhere (a leftover sentence in §9.2 or §9.3). Test: the setup-doc test asserts §9.2 names `<validation-pool>` and no `### 9.` subsection says to authorize it on `<pool>`.
- The template still carries `pool: <pool>` (e.g. in a comment) so a copy-paste keeps the old value. Test: the template test asserts `pool: <pool>` is absent.
- The open-access trap: the doc says "authorize ai-implement on `<pool>`" but not that *Grant access permission to all pipelines* must be off, so any pipeline still lands there. Test: the setup-doc test asserts the new subsection contains `Grant access permission to all pipelines`.
- The validation agent is set up by reusing the implement agent's name, silently replacing it (§10.1 `--replace`). Test: the new subsection mentions `--replace` or links §10.1's warning.
- A leak: a real pool or org name typed into an example. Test: the existing cutover leak checks stay green; the new test greps the files it touches for `dev.azure.com/[A-Za-z]` outside `<org>`.

---

### Task 1: Template uses `<validation-pool>`

**Files:**
- Modify: `templates/azdo/pr-validation.yml` (the `pool:` line and the header comment)
- Test: `tests/run-azdo-templates-tests.sh` (the `template_has_pool_placeholder` assertion)

**Interfaces:**
- Produces: the placeholder name `<validation-pool>`, used by Tasks 2 and 3.

- [ ] **Step 1: Write the failing test**

In `tests/run-azdo-templates-tests.sh`, replace the `template_has_pool_placeholder` assertion with:

```bash
assert_contains "template_has_validation_pool_placeholder" "pool: <validation-pool>" "$TEXT"
if [[ "$TEXT" == *"pool: <pool>"* ]]; then
  fail "template_has_no_implement_pool" "template still contains 'pool: <pool>'"
else
  pass "template_has_no_implement_pool"
fi
assert_contains "template_names_own_pool_section" "Run validation on its own pool" "$TEXT"
```

(Use the file's existing `pass`/`fail` helpers; adapt the call shape if `fail` there takes different arguments.)

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run-azdo-templates-tests.sh`
Expected: FAIL on `template_has_validation_pool_placeholder`, `template_has_no_implement_pool`, `template_names_own_pool_section`.

- [ ] **Step 3: Edit the template**

`pool: <pool>` becomes `pool: <validation-pool>`. Add to the header comment, after the "See docs/AZDO-PIPELINE-SETUP.md section 9." line:

```yaml
# `pool:` must be the validation pool, never the ai-implement pool: the
# implement pool admits only the ai-implement pipeline, so this pipeline gets
# no agent there. See "Run validation on its own pool" in section 9.
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run-azdo-templates-tests.sh && bash tests/run-all.sh`
Expected: all pass.

- [ ] **Step 5: Commit and push**

```bash
git add templates/azdo/pr-validation.yml tests/run-azdo-templates-tests.sh
git commit -m "feat(azdo): validation template targets its own pool (#703)"
git push
```

---

### Task 2: Setup doc — validation on its own pool

**Files:**
- Modify: `docs/AZDO-PIPELINE-SETUP.md` — the `## 9. PR build validation` intro, `### 9.2 Create the pipeline` step 4, a new `### 9.N Run validation on its own pool`, `## 10. Route .NET jobs to the dotnet agent`, `## 13. Agent user boundary`
- Create: `tests/run-azdo-validation-pool-tests.sh`

**Interfaces:**
- Consumes: `<validation-pool>` from Task 1.
- Produces: the heading `Run validation on its own pool`, which Task 1's template comment and Task 3's cutover item reference.

- [ ] **Step 1: Write the failing test**

Create `tests/run-azdo-validation-pool-tests.sh` (executable, same prelude and helpers as `tests/run-azdo-cutover-doc-tests.sh`). `SETUP_DOC="$ROOT/docs/AZDO-PIPELINE-SETUP.md"`. A helper `subsection <regex>` prints the body of the `### ` heading matching the regex up to the next `### ` or `## ` heading. Assertions:

| Test name | Assertion |
|---|---|
| `setup_doc_HasOwnPoolSubsection` | `grep -qE '^### 9\.[0-9]+ Run validation on its own pool$'` |
| `setup_doc_OwnPool_NamesValidationPool` | the subsection contains `<validation-pool>` |
| `setup_doc_OwnPool_ImplementPoolOnlyAiImplement` | the subsection contains `Pipeline permissions` and `ai-implement` |
| `setup_doc_OwnPool_OpenAccessOff` | the subsection contains `Grant access permission to all pipelines` |
| `setup_doc_OwnPool_NamesTheft` | the subsection contains `.credentials_rsaparams` |
| `setup_doc_OwnPool_WarnsReplace` | the subsection contains `--replace` or `10.1` |
| `setup_doc_OwnPool_HasCheck` | the subsection has a line starting `Check:` |
| `setup_doc_9_2_AuthorizesValidationPool` | the `### 9.2 ` subsection contains `<validation-pool>` |
| `setup_doc_13_PointsToOwnPool` | the `## 13. ` section contains `Run validation on its own pool` |
| `setup_doc_NoRealOrgUrl` | `grep -oE 'dev\.azure\.com/[^ )>]+'` over the doc yields only `dev.azure.com/<org>` forms |

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run-azdo-validation-pool-tests.sh`
Expected: FAIL on every assertion except `setup_doc_NoRealOrgUrl`.

- [ ] **Step 3: Edit the doc**

- `## 9.` intro: append one sentence: validation runs on its own agent pool; see *Run validation on its own pool*.
- `### 9.2` step 4: authorize on `<validation-pool>` (*Project settings > Agent pools > `<validation-pool>` > Security > Pipeline permissions*), not `<pool>`.
- New `### 9.N Run validation on its own pool` after the last `### 9.x`. Content, in this order:
  1. **Why.** A build step runs as the agent's user, which owns `/azp/agent`, including the registration files `.credentials` and `.credentials_rsaparams`. PR code can copy them and impersonate the agent from anywhere, receiving the next `ai-implement` job with its secrets, or rewrite the agent binaries the next job runs. The section 13 boundary does not cover this: it protects an implement run from its own agent, not from an earlier job on the same registration. A `pool:` value in the PR's YAML is no boundary (9.4: the PR controls that YAML).
  2. **Set up.** A second agent exactly like 10.1: own `<name>` (for example `<name>-validation`), `AZP_AGENT_NAME`, `<volume>`, one-shot registration (section 2 with `AZP_POOL=<validation-pool>`) and unit (section 3). Repeat the 10.1 `--replace` warning in one line. Use the dotnet image if the validation builds .NET.
  3. **Permissions.** *Project settings > Agent pools > `<pool>` > Security > Pipeline permissions*: turn **Grant access permission to all pipelines** off and list only the `ai-implement` pipeline. On `<validation-pool>`, authorize the validation pipeline (9.2 step 4).
  4. `Check:` open a test PR whose `azure-pipelines-pr.yml` names `<pool>`; its validation build gets no agent (it waits for pool authorization), and the policy stays unsatisfied. Abandon the PR.
  5. **What it does not cover.** The validation agent's own identity is still readable by PR code; stolen, it yields validation jobs only, plus whatever those jobs carry (the feed-read token from section 14, if set).
- `## 10.`: one line under the intro: the validation agent (*Run validation on its own pool*) needs the dotnet image when the repo's validation builds .NET.
- `## 13.`: one line: an earlier validation job is kept off this registration by *Run validation on its own pool*; the boundary here does not cover it.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run-azdo-validation-pool-tests.sh && bash tests/run-all.sh`
Expected: all pass, including the existing cutover doc tests.

- [ ] **Step 5: Commit and push**

```bash
git add docs/AZDO-PIPELINE-SETUP.md tests/run-azdo-validation-pool-tests.sh
git commit -m "docs(azdo): run PR validation on its own agent pool (#703)"
git push
```

---

### Task 3: Cutover runbook, unit example and ADR-026

**Files:**
- Modify: `docs/AZDO-CUTOVER.md` — `## 6. Set up Azure DevOps`, the PR build validation checklist item
- Modify: `docker/azp-agent/azp-agent.service.example` — header comment
- Modify: `docs/DECISIONS.md` — append a new ADR at the end
- Test: `tests/run-azdo-cutover-doc-tests.sh`, `tests/run-azdo-validation-pool-tests.sh`

**Interfaces:**
- Consumes: `<validation-pool>` (Task 1), the heading `Run validation on its own pool` (Task 2).

- [ ] **Step 1: Write the failing tests**

In `tests/run-azdo-cutover-doc-tests.sh`, add:

| Test name | Assertion |
|---|---|
| `cutover_doc_Step6_ValidationPool` | `section 6` contains `<validation-pool>` and `ai-implement` pipeline |

In `tests/run-azdo-validation-pool-tests.sh`, add:

| Test name | Assertion |
|---|---|
| `unit_example_OneUnitPerAgent` | `docker/azp-agent/azp-agent.service.example` contains `validation agent` and `own volume` |
| `decisions_HasOwnPoolAdr` | `docs/DECISIONS.md` has a line matching `^## ADR-[0-9]+ — PR validation runs on its own agent pool` |
| `decisions_OwnPoolAdr_RejectsWrapper` | that ADR's body (to the next `## ADR-`) mentions `awf-agent` and `read-only` |

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/run-azdo-cutover-doc-tests.sh; bash tests/run-azdo-validation-pool-tests.sh`
Expected: FAIL on the four new assertions only.

- [ ] **Step 3: Edit the three files**

- Cutover step 6, the "PR build validation equivalent to the GitHub CI (9)" item: append "on its own pool `<validation-pool>`, with the `<pool>` pipeline permissions listing only the `ai-implement` pipeline (9, *Run validation on its own pool*)".
- Unit example header, after the existing first comment block: "One unit per agent. The validation agent (docs/AZDO-PIPELINE-SETUP.md, *Run validation on its own pool*) gets its own unit, container name and own volume — never the implement agent's volume."
- `docs/DECISIONS.md`: append `## ADR-026 — PR validation runs on its own agent pool (<today's date>)` (use the next free number if 026 is taken), `**Status:** accepted`, then **Context** (validation runs the PR's YAML as `azp`; `/azp/agent` holds `.credentials_rsaparams`, readable by that user, confirmed on a sandbox agent 2026-11-27; ADR-024's third bullet names the impersonation risk; its boundary covers the implement run's own agent only), **Decision** (own pool, own registration, volume and unit; the implement pool's pipeline permissions list only the `ai-implement` pipeline with open access off; enforced by Azure DevOps, not YAML), **Rejected** (a `sudo`-to-`awf-agent` wrapper in the validation YAML: the PR controls it; a read-only volume mount: the agent writes `_diag/` at runtime and reading stays possible; a start-time integrity check: covers tampering, not theft), **Consequences** (a second agent container per consumer; the validation agent's identity stays exposed, yielding validation jobs and, with #699, the feed-read token).

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run-all.sh && just lint`
Expected: all pass.

- [ ] **Step 5: Commit and push**

```bash
git add docs/AZDO-CUTOVER.md docker/azp-agent/azp-agent.service.example docs/DECISIONS.md tests/run-azdo-cutover-doc-tests.sh tests/run-azdo-validation-pool-tests.sh
git commit -m "docs(azdo): ADR-026 and runbook for the validation pool (#703)"
git push
```
