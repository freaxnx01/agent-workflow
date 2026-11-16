# WIQL ordering trap Implementation Plan (#501)

**Goal:** Document that sorting ids to drop WIP destroys the WIQL order, in the ADO
sections of `/issues` and `/queue`.

**Architecture:** Markdown edits only. No code, no tests.

**Spec:** `docs/superpowers/specs/2026-11-16-wiql-order-trap-design.md`

## Global Constraints

- Touch only `commands/issues.md` and `commands/queue.md`.
- Do not change `scripts/lib/azdo.sh`, `commands/triage.md`, or the GitHub/Forgejo sections.
- Plain ASCII in the added text.

### Task 1: Trap note in issues.md step 4

**Files:**
- Modify: `commands/issues.md` (Step 4, directly after the paragraph ending
  "...verify the shape before trusting the empty set.")

- [ ] **Step 1: Insert this block**

````markdown
**Filter with an order-preserving tool, never `comm`/`sort`.** Step 2 returns ids
newest first (`ORDER BY [System.CreatedDate] DESC`) and the render step depends on
that. The obvious set difference destroys it silently:

```bash
keep=$(comm -23 <(echo "$ids" | sort) <(echo "$wip" | sort))   # WRONG
```

`comm` needs sorted input, so it returns ids in **numeric** order. Observed live:
WIQL returned `7 6 4 1` and this produced `1 4 6 7`, exactly reversed, with no
error. Filter the ordered list instead and leave it in place:

```bash
if [ -n "$wip" ]; then
  keep=$(echo "$ids" | grep -vxFf <(echo "$wip"))
else
  keep=$ids          # no active PRs: nothing is WIP
fi
```

The guard matters: `grep -vxF ""` matches every line, so an empty `$wip` would
drop every work item. `azdo_active_pr_work_items` is `sort -u` on purpose, since
its output is a set; only the candidate list carries an order. GitHub and Forgejo
do not have this problem because they sort at render time.
````

- [ ] **Step 2: Verify the snippet**

Run:
```bash
ids=$'7\n6\n4\n1'; wip=$'6'
echo "$ids" | grep -vxFf <(echo "$wip") | tr '\n' ' '
```
Expected: `7 4 1 `

### Task 2: Pointer in queue.md

**Files:**
- Modify: `commands/queue.md` (ADO section, after the "In flight means an active PR..." paragraph)

- [ ] **Step 1: Insert this paragraph**

```markdown
`ids` is in newest-first WIQL order and `wip` is sorted. Mark in-flight items with
a membership test (`grep -qxF`), never a `comm` over sorted lists, which would
return the ids in numeric order. See the trap note in `commands/issues.md` step 4.
```

- [ ] **Step 2: Verify**

Run: `git diff --stat`
Expected: 2 files changed, insertions only.

- [ ] **Step 3: Commit**

`git commit -am "docs(issues): warn that sorting ids to drop WIP destroys the WIQL order (#501)"`
