# /enrich-batch outside the target repo Implementation Plan (#618)

**Goal:** Make `/enrich-batch` work when the session runs outside the target repo
and when the default `gh` login cannot write labels.

**Architecture:** Markdown edits to `commands/enrich-batch.md`, guarded by
Layer-1 doc assertions in `tests/run-enrich-batch-doc-tests.sh`. No scripts.

**Spec:** `docs/superpowers/specs/2026-11-18-enrich-batch-foreign-repo-design.md`

## Global Constraints

- Touch only `commands/enrich-batch.md` and `tests/run-enrich-batch-doc-tests.sh`.
- Keep the last non-blank line of the command exactly: `If you run into blockers, find a solution and update this command for the future.`
- Never put a token value in the doc or a prompt template; only the wrapper form.
- Existing assertions in the test file must keep passing unchanged.

### Task 1: Failing tests

**Files:**
- Modify: `tests/run-enrich-batch-doc-tests.sh` (insert before the `# 11. Self-improvement closing line.` block)

- [ ] **Step 1: Write the failing test.** Insert this block:

```bash
# 10b. Outside the target repo (#618).
pre="$(section 'Step 0')"
check "has a Step 0 for target repo and credentials" "$pre" '^#+ .*Step 0.*(Target|credentials)' -Ei
check "Step 0 is a no-op in the in-repo case" "$pre" 'no-op|nothing below changes' -Ei
check "Step 0 takes --repo" "$pre" '--repo <owner/name>' -F
check "Step 0 resolves the target clone" "$pre" 'target clone' -Fi
check "Step 0 verifies the clone's origin" "$pre" 'remote get-url origin' -F
check "Step 0 falls back to the autopilot clone" "$pre" 'sync_autopilot_clone' -F
check "Step 0 probes label write with gh label" "$pre" 'gh label (create|edit) enrichment-ongoing' -E
check "Step 0 finds the wrapper with direnv status" "$pre" 'direnv status' -F
check "Step 0 wraps with direnv exec" "$pre" 'direnv exec' -F
check "Step 0 stops before dispatch when nothing can write labels" "$pre" 'before dispatch|do not dispatch' -Ei
check "Step 0 never logs in interactively" "$pre" 'interactive login' -Fi

disp="$(section 'Step 4')"
check "isolation worktree only when cwd is the target" "$disp" 'only when.*(cwd|current).*target' -Ei
check "creates the worktree in the target clone" "$disp" 'git -C <clone> worktree add <clone>/.worktrees/enrich-<n> -b enrich/<n> origin/main' -F
check "prompt names the worktree path and branch" "$disp" 'Your worktree' -F
check "prompt carries the auth wrapper" "$disp" '<wrapper> gh' -F
check "prompt bridges GH_TOKEN to GITHUB_TOKEN for push" "$disp" 'GITHUB_TOKEN="\$\{GH_TOKEN:-\$GITHUB_TOKEN\}"' -E
check "prompt never carries a token value" "$disp" 'never.*token' -Ei

check "cleanup removes the worktree via the owning clone" "$house" 'git -C "\$clone" worktree remove' -E
check "cleanup derives the clone from the git common dir" "$house" 'git-common-dir' -F
```

- [ ] **Step 2: Run it and confirm it fails.** `bash tests/run-enrich-batch-doc-tests.sh` exits 1 with the new checks listed as failed and every old check still passing.

### Task 2: Step 0 and the argument hint

**Files:**
- Modify: `commands/enrich-batch.md` (frontmatter line 4; new section before `### Step 1 — Select`)

- [ ] **Step 1: Change the argument hint** to `argument-hint: "[<issue>...] [--milestone <name>] [--repo <owner/name>]"`.

- [ ] **Step 2: Update the `$ARGUMENTS` sentence** under `## GitHub` to read: ``$ARGUMENTS`` may carry issue numbers, `--milestone <name>`, `--repo <owner/name>`, any mix, or nothing.

- [ ] **Step 3: Insert this section** immediately before `### Step 1 — Select`:

````markdown
### Step 0 — Target repo and credentials

Skip this step when the session's cwd is a clone of the target repo and the
default `gh` login can write labels: nothing below changes then, and every
command runs as written. Otherwise the two blockers of #618 apply. `/enrich`
itself is unchanged.

**Target repo.** `--repo <owner/name>` names it. Without the flag it is the
cwd's repo (`gh repo view --json nameWithOwner -q .nameWithOwner`). When the
target is not the cwd's repo, add `--repo <owner/name>` to every `gh` call in
this command and use the literal name where Step 1 runs `gh repo view`.

**Target clone.** Needed only when cwd is not a clone of the target. Use the
clone the user named; otherwise the autopilot cache clone:

```bash
source "$HOME/.claude/scripts/lib/autopilot-clone.sh"
sync_autopilot_clone "<owner/name>"
clone="$(autopilot_clone_dir "<owner/name>")"
git -C "$clone" remote get-url origin
```

The last line must name the target repo; if it does not, stop. A clone the user
named is only ever fetched (`git -C <clone> fetch origin`), never reset. Make
sure `.worktrees/` is ignored there, without touching tracked files:

```bash
git -C "<clone>" check-ignore -q .worktrees/probe \
  || echo '.worktrees/' >> "$(git -C "<clone>" rev-parse --path-format=absolute --git-path info/exclude)"
```

**Pre-flight: can this login write labels?** A read-only check does not prove
it, so do an idempotent label write. It is the same label and description
`/enrich` Step 2.5 creates, so it changes nothing that was not going to change:

```bash
gh label create enrichment-ongoing --repo "<owner/name>" --color FBCA04 \
  --description "Another /enrich session is actively enriching this issue — do not start a second one" 2>/dev/null \
  || gh label edit enrichment-ongoing --repo "<owner/name>" \
       --description "Another /enrich session is actively enriching this issue — do not start a second one"
```

Exit 0 means the default login is enough; there is no wrapper. On a non-zero
exit, look for an allowed direnv `.envrc` above the target clone, as the
user-level auth rule says. Run `direnv status` inside the clone (or cwd): it
must show `Found RC path` and `Found RC allowed true`. The wrapper is then
`direnv exec <rc-dir>`, with `<rc-dir>` the directory of that `.envrc`. Run the
probe again as `direnv exec <rc-dir> bash -c '<the probe above>'`.

- It passes: from here on, run every `gh` call of this session as
  `<wrapper> gh ...` and every push as
  `<wrapper> bash -c 'GITHUB_TOKEN="${GH_TOKEN:-$GITHUB_TOKEN}" git -C <dir> push ...'`
  (git's credential helper reads `GITHUB_TOKEN`, not `GH_TOKEN`).
- No `.envrc` is found, or the wrapped probe fails too: do not dispatch. Print
  the exact error and stop. Do not suggest an interactive login first and do
  not try other credentials.
````

- [ ] **Step 4: Run the tests.** The `Step 0` checks pass; the Step 4 and cleanup checks still fail.

### Task 3: Step 4 dispatch

**Files:**
- Modify: `commands/enrich-batch.md` (`### Step 4 — Dispatch`)

- [ ] **Step 1: Replace the first paragraph** ("One `Agent` call per issue, each in its own worktree. ...") with:

````markdown
One `Agent` call per issue, each in its own worktree. Run **at most 4** at once
(see [Concurrency](enrich.md#concurrency)): send up to four calls in one
message, and start the next issue only when one finishes.

**Where the worktree comes from.** `isolation: "worktree"` cuts the worktree from
the repo the *session* runs in. Use it only when cwd is a clone of the target
repo. Otherwise omit `isolation` and create each worktree yourself, serially,
in the target clone from Step 0, before the `Agent` call:

```bash
git -C "<clone>" fetch origin
git -C "<clone>" worktree add <clone>/.worktrees/enrich-<n> -b enrich/<n> origin/main
```

The prompt names that path and branch, so a cut-off run's worktree is known to
Step 6.
````

- [ ] **Step 2: In the prompt template,** make `isolation: "worktree",` read `isolation: "worktree",   # only when cwd is the target repo; otherwise omit`, and insert after the first paragraph of the prompt (before "Confirmed answers"):

```text
    [cwd is not the target] Your worktree: <clone>/.worktrees/enrich-<n> on
    branch enrich/<n>, already created from origin/main. Work only there:
    absolute paths, and `cd` into it inside every Bash call. Do not touch
    any other checkout.

    [wrapper resolved in Step 0] Run every gh call as `<wrapper> gh ...` and
    push with `<wrapper> bash -c 'GITHUB_TOKEN="${GH_TOKEN:-$GITHUB_TOKEN}"
    git -C <worktree> push ...'`. The default login cannot write labels; do
    not try to switch credentials any other way.
```

- [ ] **Step 3: After the template's closing fence add:** `The prompt carries the wrapper command only, never a token value.`

- [ ] **Step 4: Run the tests.** Only the cleanup checks still fail.

### Task 4: Step 6 cleanup

**Files:**
- Modify: `commands/enrich-batch.md` (`**Finished worktrees.**` block)

- [ ] **Step 1: In the bash block, after `branch="$(git -C "$wt" branch --show-current)"`, add**

```bash
clone="$(dirname "$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir)")"
```

and replace `git worktree remove "$wt" && git branch -D "$branch"` with

```bash
  git -C "$clone" worktree remove "$wt" && git -C "$clone" branch -D "$branch"
```

- [ ] **Step 2: Add one sentence under the block:** `Removal runs against the clone that owns the worktree, not the cwd: outside the target repo the cwd has neither the worktree nor the branch.`

- [ ] **Step 3: Run the full suite.** `bash tests/run-enrich-batch-doc-tests.sh` passes, then `bash tests/run-all.sh` passes.

- [ ] **Step 4: Commit.** `fix(enrich-batch): resolve target clone and credentials outside the target repo (#618)`
