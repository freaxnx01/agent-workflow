# Azure DevOps AI review and self-fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After `implement-azdo.sh` opens its draft PR, run the same `review-pr.sh` and (opt-in) `self-fix-loop.sh` against it. Post each review as one Azure DevOps PR thread per head commit, and report the final verdict on the work item.

**Architecture:** Four new forge verbs in `scripts/lib/forge.sh` (`forge_pr_diff`, `forge_pr_head_sha`, `forge_pr_comment`, `forge_pr_comments_json`) replace the four `gh` calls in `review-pr.sh` / `self-fix-loop.sh`. Their github branches are those exact calls. Both scripts default `FORGE=github`, so the GitHub path never even runs `detect_forge`. A small azdo `FIX_CMD` wrapper (`scripts/azdo-self-fix.sh`) runs `self-fix-pr.sh` without pushing, then runs the pipeline-file guard, then pushes with `push_branch`. `implement-azdo.sh` gains `review_draft_pr`, called once on the success path after the success report. It never fails the run, and it posts a separate `## ai-review verdict` comment that the attempt cap does not count.

**Tech Stack:** Bash 5 (`set -euo pipefail`, `IFS=$'\n\t'`), `jq`, `python3` (stdlib `json`), git, `az devops invoke`, the `az`/`curl`/`gh` mocks, the retry plan's `claude-implement` and `git-origin` mocks.

**Spec:** `docs/superpowers/specs/2026-11-09-azdo-ai-review-design.md`

**Lands after:** `2026-11-09-azdo-pr-validation.md`, `2026-11-09-azdo-agent-toolchain.md`, `2026-11-09-azdo-retry.md`. Their Interfaces blocks are the source of the names used here.

## Global Constraints

- **The agent never votes, approves, completes or publishes the PR.** No code path may call the vote, reviewers or complete APIs, `az repos pr update`, or `--draft false`. Task 5 enforces this by grep and by an end-to-end run.
- The review stays `scripts/lib/agent-cmd-claude.sh` (`--print`, no tools).
- **G4: the GitHub path is unchanged.** Every task that touches `review-pr.sh`, `self-fix-*.sh` or `forge.sh` must leave `git diff --exit-code tests/run-script-tests.sh .github/workflows/agent-implement.yml` empty and `bash tests/run-all.sh` green. The github branch of each new verb is the current `gh` call, character for character.
- Pipeline variables, exact names and defaults: `AI_REVIEW=1`, `SELF_FIX=0`, `SELF_FIX_MAX_ITERATIONS=2`. They only reduce or bound work. None of them reaches the guard.
- `pipeline_file_guard "origin/$DEFAULT_BRANCH"` (PR-validation plan; 0 ok, 1 pipeline file touched, 2 diff failed) runs before **every** self-fix push. Any non-zero means no push.
- Self-fix commits on Azure DevOps use the identity `ai-implement <ai-implement@noreply.invalid>`.
- The PAT never goes into a remote URL, `.git/config` or a log. Pushes use `push_branch` (the retry plan's `http.extraheader` Basic auth).
- The retry plan's global `WORK_DIR` is scratch. It is never exported. `self-fix-pr.sh` gets `WORK_DIR="$PWD"` (the checkout) explicitly.
- Review and self-fix run only after the draft PR opens, outside the retry decision. Any failure in them gives a reported verdict and exit 0. It never causes a retry or a red job.
- The setup guide section is **§12**. Do not renumber §9 (PR validation), §10 (tool chain) or §11 (retry).
- Public repo: no org, pool, host, project or work-repo names. Fixtures keep `contoso/MyProject/my-repo`.
- New tests are Layer-1 and hermetic. A new `tests/run-*-tests.sh` is auto-discovered, so do not edit `tests/run-all.sh` or the `justfile`.
- `shellcheck -x -e SC1091` must pass on every new or changed `.sh` file. Run it only after `git add`.
- Commits use Conventional Commits with scope `azdo` (or `review` for the shared scripts) and `(#573)` in the subject.

## Review Focus

1. **The verdict comment counted as an attempt.** `check-attempt-cap.sh` counts work-item comments starting `## ai-implement run`. The verdict comment must start `## ai-review verdict`, and feeding it to the cap must leave the attempt count unchanged. Task 4 tests this.
2. **The re-review sees a stale diff or SHA.** The second thread's marker must be the post-fix `HEAD`, and the second review prompt must contain the fix's file. Task 4's end-to-end case tests this.
3. **The marker does not survive Azure DevOps.** If the thread `content` comes back altered, every run on the same SHA posts a duplicate. Task 2 round-trips the POST body through the GET parser. Task 7 checks it live and saves a trimmed live fixture.
4. **The implement agent's leftovers committed by the fix.** `self-fix-pr.sh` runs `git add -A` in the job's checkout, which (unlike GitHub's fresh clone) may hold untracked files. If `git status --porcelain` is non-empty before self-fix, skip self-fix and say why. Task 4 tests this.
5. **The PAT leaking through the self-fix push.** Use a sentinel PAT. It must appear in no log, no remote URL and not in `.git/config` after the run. Task 3 tests this.

---

### Task 1: Four PR forge verbs

**Files:**
- Modify: `scripts/lib/forge.sh`. Add `_forge_kind` and the four verbs after `forge_pr_create_draft`, and list them in the header.
- Create: `tests/fixtures/azdo-pr-threads-empty.json` (`{"value":[],"count":0}`)
- Create: `tests/fixtures/azdo-pr-threads-marker.json`. Two threads. One is a system thread with a `content`-less comment. The other has a comment whose `content` is `<!-- review-pr:abc123 -->\n\n## Automated review — verdict: \`approve\``.
- Create: `tests/fixtures/azdo-pr-thread-created.json` (`{"id":7,"status":"active"}`)
- Modify: `tests/run-forge-adapter-tests.sh`. Add the section "PR verbs".

**Interfaces:**
- Consumes: `detect_forge`, `resolve_azdo_context`, `azdo_org_url`, and `AZDO_PROJECT` / `AZDO_REPO` (existing).
- Produces, all in `scripts/lib/forge.sh`:
  - `_forge_kind`. A query that echoes `$FORGE` when it is set and non-empty, otherwise `detect_forge | awk '{print $1}'`.
  - `forge_pr_diff <pr>`. Writes the unified diff to stdout.
    - github: `gh pr diff "$pr" --repo "$REPO"`.
    - azdo: `git diff --no-color --no-ext-diff --src-prefix=a/ --dst-prefix=b/ "origin/${DEFAULT_BRANCH}...HEAD"`. If `DEFAULT_BRANCH` is unset or empty, print `forge_pr_diff: DEFAULT_BRANCH must be set on azdo` to stderr and return 1. Never guess `main`.
  - `forge_pr_head_sha <pr>`. Echoes the SHA.
    - github: `gh pr view "$pr" --repo "$REPO" --json headRefOid --jq '.headRefOid'`.
    - azdo: `git rev-parse HEAD`.
  - `forge_pr_comment <pr> <body-file>`.
    - github: `gh pr comment "$pr" --repo "$REPO" --body-file "$f"`.
    - azdo: a jq-built body `{"comments":[{"parentCommentId":0,"content":<file text>,"commentType":1}],"status":"active"}` piped to `az devops invoke --org "$(azdo_org_url)" --area git --resource pullRequestThreads --route-parameters project="$AZDO_PROJECT" repositoryId="$AZDO_REPO" pullRequestId="$pr" --http-method POST --in-file /dev/stdin --api-version 7.1 --output none --only-show-errors`. Use `az devops invoke` rather than `curl -K -` because this is a plain JSON body, as in `azdo_wiql` / `azdo_fields`.
  - `forge_pr_comments_json <pr>`. **Despite the spec's name, it echoes comment bodies as text, not JSON**, because that is what the `review-pr.sh` marker check consumes.
    - github: `gh pr view "$pr" --repo "$REPO" --json comments --jq '.comments[].body'`.
    - azdo: GET the same resource without `--http-method`, with `--output json`. Python prints `content` for every comment of every thread in `value`, skipping comments without `content`.
  - All four:
    - require `REPO` on github;
    - on azdo, call `_forge_source_azdo; resolve_azdo_context || return 1`;
    - on any other forge, return 2 with `forge.sh: no PR adapter for this forge yet (#253)`.
  - Document the verb contract above in the header block. The name mismatch is deliberate.

- [ ] **Step 1: Write the failing tests** in "PR verbs". Each case runs in a subshell that sources `detect-forge.sh` and `forge.sh`.

  **github argv**, with `FORGE=github`, `REPO=o/r`, the gh mock and `GH_MOCK_LOG`, run from a temp dir that is **not** a git repo (this proves no `detect_forge`). Each verb's log line equals exactly:
  - `forge_pr_diff 42` logs `pr diff 42 --repo o/r`;
  - `forge_pr_head_sha 42` logs `pr view 42 --repo o/r --json headRefOid --jq .headRefOid`;
  - `forge_pr_comment 42 "$f"` logs `pr comment 42 --repo o/r --body-file $f`;
  - `forge_pr_comments_json 42` logs `pr view 42 --repo o/r --json comments --jq .comments[].body`;
  - the gh log has no `auth token` line.

  **azdo cases**, with `FORGE=azdo` in a `make_repo`-style repo whose origin is the contoso URL:
  - `pr_comment_posts_one_active_thread`:
    - `AZ_MOCK_FIXTURE=azdo-pr-thread-created.json`;
    - the az log has exactly one line, containing `--area git --resource pullRequestThreads`, `pullRequestId=42`, `repositoryId=my-repo` and `--http-method POST`;
    - the stdin log parses as JSON with `.status == "active"`, and `.comments[0].content` equals the body file byte for byte. Use a body with a backtick, a `$` and a newline.
  - `pr_comments_json_round_trip`: build a GET fixture from the captured stdin log (`jq -s '{value: ., count: length}'`). `forge_pr_comments_json 42` output contains the posted body's first line.
  - `pr_comments_json_skips_contentless`: with `azdo-pr-threads-marker.json`, the output contains `<!-- review-pr:abc123 -->` and no `None` / `null`.
  - `pr_diff_azdo_three_dot`:
    - in a repo with `main` → `update-ref refs/remotes/origin/main`, then branch `agent/x` committing `src/a.txt`, run with `DEFAULT_BRANCH=main`;
    - the output contains `diff --git a/src/a.txt b/src/a.txt`;
    - with `git config diff.noprefix true` set in that repo, it still contains `a/src/a.txt`.
  - `pr_diff_azdo_requires_default_branch`: with `DEFAULT_BRANCH` unset, rc 1 and stderr contains `DEFAULT_BRANCH must be set`.
  - `pr_head_sha_azdo`: equals `git rev-parse HEAD`, and the az log is empty.
  - `pr_verbs_refuse_unknown_forge`: `FORGE=forgejo` gives rc 2 for each verb.

- [ ] **Step 2: Run them and confirm they fail.**
  Run: `bash tests/run-forge-adapter-tests.sh`
  Expected: FAIL with `forge_pr_diff: command not found` (or similar) for the new cases. The existing cases pass.

- [ ] **Step 3: Implement `_forge_kind` and the four verbs** in `scripts/lib/forge.sh`, each with a one-paragraph comment as the other verbs have. Keep each function at 20 lines or fewer. Put the azdo thread-parsing python in `_forge_azdo_thread_bodies` (stdin → text).

- [ ] **Step 4: Run them and confirm they pass, with G4 intact.**
  Run: `bash tests/run-forge-adapter-tests.sh && bash tests/run-all.sh && git diff --exit-code tests/run-script-tests.sh .github/workflows/agent-implement.yml`
  Expected: 0 failed everywhere, and an empty diff.

- [ ] **Step 5: Lint and commit.**

  ```bash
  git add scripts/lib/forge.sh tests/run-forge-adapter-tests.sh tests/fixtures/azdo-pr-threads-empty.json tests/fixtures/azdo-pr-threads-marker.json tests/fixtures/azdo-pr-thread-created.json
  shellcheck -x -e SC1091 scripts/lib/forge.sh tests/run-forge-adapter-tests.sh
  git commit -m "feat(azdo): add PR diff, head-sha and thread forge verbs (#573)"
  ```

### Task 2: `review-pr.sh` and `self-fix-loop.sh` call the verbs

**Files:**
- Modify: `scripts/review-pr.sh`:
  - source `lib/detect-forge.sh` and `lib/forge.sh` after `SCRIPT_DIR`;
  - set `FORGE="${FORGE:-github}"` and export it;
  - replace the three `gh` calls;
  - document `FORGE` and, for azdo, `DEFAULT_BRANCH` in the header.
- Modify: `scripts/self-fix-loop.sh`: the same sourcing and `FORGE` default; replace the `gh pr view` call; document `FORGE`.
- Create: `tests/run-azdo-review-tests.sh`, a new runner. Copy the pass/fail/assert helpers from `tests/run-implement-azdo-tests.sh`.

**Interfaces:**
- Consumes: the four verbs from Task 1.
- Produces:
  - In `review-pr.sh`:
    - `forge_pr_diff "$PR_NUMBER" > "$DIFF_FILE"`, only when `DIFF_FILE` is unset (the seam keeps precedence);
    - `existing="$(forge_pr_comments_json "$PR_NUMBER" 2>/dev/null || true)"`, only when `EXISTING_COMMENTS` is unset;
    - `forge_pr_comment "$PR_NUMBER" "$COMMENT_FILE" >/dev/null`.
  - In `self-fix-loop.sh`: `elif ! head_sha="$(forge_pr_head_sha "$PR_NUMBER")"; then abort_iteration "gh pr view failed after fix" "$i"`. The message stays verbatim, because it is GitHub-path output (G4). The `NEW_HEAD_SHA` seam keeps precedence.
  - Both scripts export `FORGE`, so the `REVIEW_SCRIPT` and `FIX_CMD` children inherit it.
  - Keep the existing comments next to each call, such as the `--patch` rationale.

- [ ] **Step 1: Write the failing azdo review tests** in `tests/run-azdo-review-tests.sh`.

  **Harness.** The repo `R` has origin `https://dev.azure.com/contoso/MyProject/_git/my-repo`, a commit on `main`, `update-ref refs/remotes/origin/main`, and branch `agent/x` committing `src/a.txt`. Add `review_azdo [VAR=value …]`. It runs `review-pr.sh` with `cd "$R"` and:
  - `PATH="$MOCKS:$PATH"`, `FORGE=azdo`, `DEFAULT_BRANCH=main`;
  - `PR_NUMBER=42`, `REPO=MyProject/my-repo`, `HEAD_SHA=abc123`, `AGENT=claude`;
  - `AGENT_CMD="$MOCKS/agent-review"`, `AGENT_FIXTURE="$FIXTURES/review-approve.json"`, `AGENT_PROMPT_COPY="$T/prompt"`;
  - `AZ_MOCK_MAP`, `AZ_MOCK_LOG`, `AZ_MOCK_STDIN_LOG`, `GITHUB_OUTPUT="$T/go"`, `RUNNER_TEMP="$T/rt"`.

  It sets `RC`, `GO` and `AZLOG`.

  Cases:
  - `azdo_review_posts_one_thread`. The map sends `--http-method POST` to `azdo-pr-thread-created.json` and then `pullRequestThreads` to `azdo-pr-threads-empty.json`, in that order (first match wins).
    - `RC=0`;
    - `GO` has `posted=true` and `verdict=approve`;
    - one POST in `AZLOG`;
    - the stdin log's `.comments[0].content` starts with `<!-- review-pr:abc123 -->`;
    - the prompt copy contains `src/a.txt`, so the diff came from `forge_pr_diff`;
    - there is no `gh` in `PATH` use: run with `GH_MOCK_LOG` unset, and the gh mock would then exit non-zero.
  - `azdo_review_same_sha_posts_nothing`. A second run whose GET fixture is built from the first run's stdin log (`jq -s '{value: ., count: length}'`).
    - `GO` has `posted=false`;
    - no POST in `AZLOG`.
  - `azdo_review_new_sha_posts_again`. The same GET fixture with `HEAD_SHA=def456` gives `posted=true`.
  - `azdo_review_diff_failure_is_loud`. With `DEFAULT_BRANCH` unset, `RC` is non-zero and no POST is made. The `implement-azdo.sh` caller (Task 4) turns this into a reported `review_failed`.

  **Self-fix loop on azdo**, using the existing stubs (`self-fix-loop-fix-stub`, `self-fix-loop-review-stub`). Run in `R` with `FORGE=azdo`, `NEW_HEAD_SHA` unset, `PR_NUMBER=42`, `REPO=MyProject/my-repo`, `HEAD_SHA=initsha`, `HEAD_REF=agent/x`, `INITIAL_VERDICT=request_changes`, `MAX_ITERATIONS=2` and `REVIEW_VERDICTS=request_changes,approve`:
  - `azdo_loop_head_sha_from_git`: output `head-sha=` equals `git -C "$R" rev-parse HEAD`;
  - `verdict=approve`;
  - `iterations-used=2`.

- [ ] **Step 2: Run them and confirm they fail.**
  Run: `bash tests/run-azdo-review-tests.sh`
  Expected: FAIL. `review-pr.sh` calls `gh pr diff`, and without `GH_MOCK_LOG` the gh mock exits non-zero.

- [ ] **Step 3: Make the replacements** in both scripts, per Interfaces.

- [ ] **Step 4: Run the new and the GitHub tests, and confirm G4.**
  Run: `bash tests/run-azdo-review-tests.sh && bash tests/run-script-tests.sh && bash tests/run-all.sh && git diff --exit-code tests/run-script-tests.sh .github/workflows/agent-implement.yml`
  Expected: 0 failed. The existing assertion `review fetches the PR diff via gh pr diff (#490)` still passes unchanged, and the diff is empty.

- [ ] **Step 5: Lint and commit.**

  ```bash
  git add scripts/review-pr.sh scripts/self-fix-loop.sh tests/run-azdo-review-tests.sh
  shellcheck -x -e SC1091 scripts/review-pr.sh scripts/self-fix-loop.sh tests/run-azdo-review-tests.sh
  git commit -m "refactor(review): route PR diff, head SHA and comments through forge verbs (#573)"
  ```

### Task 3: The azdo self-fix command (guard, then authenticated push)

**Files:**
- Modify: `scripts/self-fix-pr.sh`. Add optional `FIX_GIT_NAME` / `FIX_GIT_EMAIL`, defaulting to `github-actions[bot]` / `github-actions[bot]@users.noreply.github.com`, used in the existing `git -c user.name=… -c user.email=… commit`. Document them in the header. Nothing else changes.
- Create: `scripts/azdo-self-fix.sh`
- Modify: `tests/mocks/git-origin/git` (from the retry plan). When `GIT_MOCK_LOG` is set, append the space-joined argv. Replace any argument matching `http.extraheader=Authorization: Basic *` with `http.extraheader=Authorization: Basic <redacted>`.
- Modify: `tests/run-azdo-review-tests.sh`. Add the section "azdo self-fix command".

**Interfaces:**
- Consumes:
  - `pipeline_file_guard <base-ref>` (`scripts/lib/pipeline-file-guard.sh`);
  - `push_branch <branch>` from the sourceable `scripts/implement-azdo.sh` (retry plan). Sourcing it initialises its globals to empty, so read every env input **before** the `source`.
- Produces: `scripts/azdo-self-fix.sh <pr-number> <concerns-json-file>`, the `FIX_CMD` contract of `self-fix-loop.sh`.
  - Env:
    - required: `HEAD_REF`, `ITERATION`, `REPO`, `DEFAULT_BRANCH`, `AZURE_DEVOPS_EXT_PAT`;
    - optional: `AGENT`, `MODEL`, `SELF_FIX_STOP_FILE`.
  - Steps:
    1. Run `timeout --kill-after=30s 20m bash "$HERE/self-fix-pr.sh" "$1" "$2"` with `SKIP_CLONE=1 SKIP_PUSH=1 WORK_DIR="$PWD" FIX_GIT_NAME=ai-implement FIX_GIT_EMAIL=ai-implement@noreply.invalid`. Use a fixed 20-minute constant with a comment pointing at §11's budget. Do not add a knob.
    2. `pipeline_file_guard "origin/$DEFAULT_BRANCH"`, with stderr captured.
    3. `push_branch "$HEAD_REF"`.
  - Exit codes:
    - 0: fixed and pushed;
    - 1: the fix failed or timed out;
    - 3: the guard refused (any non-zero from it);
    - 4: the push failed.
  - On exit 3 or 4, write one line to `SELF_FIX_STOP_FILE` (when set):
    - `self-fix stopped: the fix changed pipeline files: <paths, comma-joined>`;
    - or `self-fix stopped: could not push the fix to <HEAD_REF>`.
  - On exit 3, also print the same line to stderr.

- [ ] **Step 0: Confirm the landed names.**
  Run: `grep -n '^[a-z_]*()' scripts/implement-azdo.sh; ls tests/mocks/git-origin tests/mocks/claude-implement tests/mocks/claude 2>&1; grep -n 'BASH_SOURCE\[0\]' scripts/implement-azdo.sh`
  Expected: `push_branch`, `remote_branch_exists`, `open_draft_pr` and `main` exist; the git-origin shim exists; the script ends with the `BASH_SOURCE` guard. If a name differs, use the landed name everywhere in this plan and note it in the commit body.
  Also run `bash -c 'source scripts/implement-azdo.sh; trap -p EXIT; printf "[%s]\n" "$WORK_DIR"'`. It must print no trap and `[]`. If either check fails, sourcing the driver is unsafe: move `push_branch` into `scripts/lib/azdo-push.sh`, have `implement-azdo.sh` source it, and source that lib here instead.

- [ ] **Step 1: Write the failing tests.**

  **Harness.** A bare repo `B` with `main`. A clone `W` on branch `agent/x` with one commit, pushed to `B`. Run the command in `W` with:
  - `PATH="$MOCKS/git-origin:$MOCKS:$PATH"`;
  - `GIT_MOCK_REAL="$(command -v git)"`;
  - `GIT_MOCK_ORIGIN_URL=https://dev.azure.com/contoso/MyProject/_git/my-repo`;
  - `GIT_MOCK_LOG`;
  - `AZURE_DEVOPS_EXT_PAT=tok-SECRET-5e1c`;
  - `HEAD_REF=agent/x`, `ITERATION=1`, `REPO=MyProject/my-repo`, `DEFAULT_BRANCH=main`;
  - `SELF_FIX_STOP_FILE="$T/stop"`;
  - `FIX_AGENT_CMD` set to a mock.

  Cases:
  - `self_fix_pushes_with_extraheader` (`FIX_AGENT_CMD="$MOCKS/self-fix-agent"`):
    - rc 0;
    - `git -C B rev-parse agent/x` equals `git -C W rev-parse HEAD`;
    - that commit's author is `ai-implement <ai-implement@noreply.invalid>`;
    - the git log has a `push` line containing `http.extraheader=Authorization: Basic <redacted>`;
    - the stop file is absent or empty.
  - `self_fix_secret_never_persisted`, after the case above:
    - `tok-SECRET-5e1c` and its base64 appear in none of: the git log, stdout/stderr, `git -C W config --list`, `git -C W remote -v`;
    - `git -C W config --get-all http.extraheader` is empty.
  - `self_fix_guard_blocks_pipeline_file`. A fix-agent mock that writes `azure-pipelines.yml`:
    - rc 3;
    - `B`'s `agent/x` is unchanged;
    - no `push` line in the git log;
    - the stop file contains `the fix changed pipeline files: azure-pipelines.yml`.
  - `self_fix_guard_fails_closed`. Delete `refs/remotes/origin/main` in `W` first:
    - rc 3;
    - no push.
  - `self_fix_agent_failure`. With `self-fix-agent-fail`:
    - rc 1;
    - no push;
    - the stop file is empty.
  - `self_fix_pr_default_identity_unchanged`. The existing `self-fix-pr.sh` happy path, with no `FIX_GIT_*`, has author `github-actions[bot]`.

- [ ] **Step 2: Run them and confirm they fail.**
  Run: `bash tests/run-azdo-review-tests.sh`
  Expected: FAIL. `scripts/azdo-self-fix.sh` does not exist.

- [ ] **Step 3: Implement** the `FIX_GIT_*` override, `scripts/azdo-self-fix.sh` (header: contract, env, exit codes, why the push is not done in `self-fix-pr.sh`), and the shim's log.

- [ ] **Step 4: Run all tests and confirm G4.**
  Run: `bash tests/run-azdo-review-tests.sh && bash tests/run-implement-azdo-tests.sh && bash tests/run-all.sh && git diff --exit-code tests/run-script-tests.sh .github/workflows/agent-implement.yml`
  Expected: 0 failed, and an empty diff.

- [ ] **Step 5: Lint and commit.**

  ```bash
  git add scripts/self-fix-pr.sh scripts/azdo-self-fix.sh tests/mocks/git-origin/git tests/run-azdo-review-tests.sh
  shellcheck -x -e SC1091 scripts/self-fix-pr.sh scripts/azdo-self-fix.sh tests/mocks/git-origin/git tests/run-azdo-review-tests.sh
  git commit -m "feat(azdo): guarded, extraheader-authenticated self-fix push (#573)"
  ```

### Task 4: Review and self-fix in `implement-azdo.sh`

**Files:**
- Modify: `scripts/implement-azdo.sh`:
  - the header: replace the "No AI review and no auto-merge" bullet with "No auto-merge", and describe the review/self-fix and the never-vote rule;
  - document `AI_REVIEW` / `SELF_FIX` / `SELF_FIX_MAX_ITERATIONS` under Optional;
  - `preflight`;
  - `print_banner`;
  - the success path;
  - the new functions below.
- Modify: `tests/mocks/claude-implement/claude`. Dispatch on argv **before** consuming a step (details in Step 1).
- Modify: `tests/run-implement-azdo-tests.sh`:
  - `run_loop` passes `AI_REVIEW=0` by default, so the retry plan's assertions stay untouched;
  - add map lines `--http-method POST` → `azdo-pr-thread-created.json` and `pullRequestThreads` → `azdo-pr-threads-empty.json`, in that order;
  - add `AZ_MOCK_STDIN_LOG` and `GIT_MOCK_LOG`;
  - add the section "AI review".

**Interfaces:**
- Consumes:
  - `forge_pr_head_sha` (Task 1);
  - `review-pr.sh` with `FORGE` (Task 2);
  - `scripts/azdo-self-fix.sh` (Task 3);
  - `PR_ID`, `DEFAULT_BRANCH`, `HEAD_BRANCH`, `WORK_DIR`, `RUN_CONTEXT`, `post_report` and the success path (retry plan).
- Produces, in `scripts/implement-azdo.sh`:
  - **Globals**, initialised empty at top level: `REVIEW_VERDICT`, `REVIEW_NOTE`, `REVIEW_SUMMARY_FILE`, `REVIEW_HEAD_SHA`, `SELF_FIX_ITERATIONS`, `SELF_FIX_STOP`.
  - **`validate_review_config`**, called from `preflight`. It applies the defaults, then exits 2 on:
    - `AI_REVIEW` not `0` or `1`: `error: AI_REVIEW must be 0 or 1`;
    - `SELF_FIX` not `0` or `1`: `error: SELF_FIX must be 0 or 1`;
    - `SELF_FIX_MAX_ITERATIONS` not `^[0-9]+$`: `error: SELF_FIX_MAX_ITERATIONS must be a non-negative integer`.
  - **Banner line:** `ai review        : on|off, self-fix: on (max N)|off`.
  - **`run_review`**:
    - `mkdir -p "$WORK_DIR/review"`;
    - `REVIEW_HEAD_SHA="$(forge_pr_head_sha "$PR_ID")"`;
    - runs `review-pr.sh` with `FORGE=azdo DEFAULT_BRANCH REPO PR_NUMBER="$PR_ID" HEAD_SHA="$REVIEW_HEAD_SHA" AGENT=claude AGENT_CMD="$HERE/lib/agent-cmd-claude.sh" MODEL="${MODEL:-claude-sonnet-5}" RUNNER_TEMP="$WORK_DIR/review" GITHUB_OUTPUT="$WORK_DIR/review.out"`;
    - sets `REVIEW_VERDICT` and `REVIEW_SUMMARY_FILE` from that output;
    - on a non-zero rc or an empty verdict, sets `REVIEW_VERDICT=review_failed` and `REVIEW_NOTE="review-pr.sh exited <rc>"`;
    - always returns 0.
  - **`run_self_fix`**:
    - if `git status --porcelain` is non-empty, set `SELF_FIX_STOP="self-fix skipped: the checkout has uncommitted or untracked files"` and return 0;
    - otherwise run `self-fix-loop.sh` with `FORGE=azdo DEFAULT_BRANCH PR_NUMBER="$PR_ID" REPO HEAD_SHA="$REVIEW_HEAD_SHA" HEAD_REF="$HEAD_BRANCH" INITIAL_VERDICT="$REVIEW_VERDICT" CONCERNS_FILE="$REVIEW_SUMMARY_FILE" MAX_ITERATIONS="$SELF_FIX_MAX_ITERATIONS" FIX_CMD="$HERE/azdo-self-fix.sh" FIX_AGENT=claude FIX_MODEL="${MODEL:-claude-sonnet-5}" AGENT=claude AGENT_CMD=… MODEL=… RUNNER_TEMP="$WORK_DIR/review" SELF_FIX_STOP_FILE="$WORK_DIR/self-fix-stop" GITHUB_OUTPUT="$WORK_DIR/self-fix.out"`;
    - sets `REVIEW_VERDICT`, `SELF_FIX_ITERATIONS` and `REVIEW_HEAD_SHA` from the output, and `SELF_FIX_STOP` from the stop file;
    - always returns 0.
  - **`render_review_report`**, a query that prints:

    ```text
    ## ai-review verdict: <REVIEW_VERDICT>

    - draft PR: !<PR_ID>
    - head: <REVIEW_HEAD_SHA>
    - self-fix: <off | not needed | N iteration(s)>
    - <REVIEW_NOTE>        (only when set)
    - <SELF_FIX_STOP>      (only when set)
    - The PR stays a draft; a human reviews, votes and completes it.
    ```

  - **`review_draft_pr`**:
    - return 0 unless `AI_REVIEW=1` and `PR_ID` is set;
    - `run_review`;
    - when `SELF_FIX=1`, the verdict is `request_changes` and `SELF_FIX_MAX_ITERATIONS > 0`, `run_self_fix`;
    - render the report into `WORK_DIR`;
    - `forge_issue_comment "$ISSUE_NUMBER" <file>`, warning on failure;
    - print `ai review : <verdict>`;
    - return 0.

    It is called once, on the success path, right after the success `post_report`. It is never inside the retry decision. It does not append to `ISSUE_COMMENTS_JSON`.

- [ ] **Step 0: Confirm the landed success path.**
  Run: `grep -n 'post_report success\|open_draft_pr\|attempt_loop' scripts/implement-azdo.sh; grep -n 'review / merge' tests/run-implement-azdo-tests.sh`
  Expected: one success-path `post_report`, which is the insertion point. Any test that asserts the old banner text keeps passing, because this task adds a line and does not change one.

- [ ] **Step 1: Extend the mock and write the failing tests.**

  **The mock dispatches on argv:**
  - Argv containing `--output-format json` is an implement call: the existing step logic, unchanged.
  - Argv containing `--allowedTools` is a fix call:
    - append `fix <n>` to `$CLAUDE_MOCK_FIX_LOG`;
    - append a line to `${CLAUDE_MOCK_FIX_TOUCH:-FIX.md}` in the cwd;
    - exit 0.
  - Anything else is a review call:
    - append `review <n> args=<argv>` to `$CLAUDE_MOCK_REVIEW_LOG`;
    - copy stdin to `$CLAUDE_MOCK_REVIEW_DIR/review-<n>.md` when set;
    - print the fixture named by entry `n` of the comma-separated `$CLAUDE_MOCK_REVIEWS` (the last entry repeats), from `tests/fixtures`.

  None of these calls consume an implement step.

  **Cases,** all `run_loop success` unless noted:
  - `review_off_by_default_in_harness`: the existing success case. No `pullRequestThreads` in `AZLOG`, and no review log.
  - `review_posts_thread_and_verdict` (`AI_REVIEW=1`, `CLAUDE_MOCK_REVIEWS=review-approve.json`):
    - `RC=0`;
    - one POST to `pullRequestThreads` with `pullRequestId=42`;
    - the thread marker equals `review-pr:<git -C WORK rev-parse HEAD>`;
    - `AZLOG` contains `## ai-review verdict: approve` and `!42`;
    - `OUT` contains `ai review : approve`.
  - `review_call_has_no_tools`: the review log line has `--print` and contains neither `--allowedTools` nor `bypassPermissions`.
  - `self_fix_round_trip` (`AI_REVIEW=1 SELF_FIX=1`, `CLAUDE_MOCK_REVIEWS=review-request-changes.json,review-approve.json`):
    - `RC=0`;
    - two thread POSTs, the second with the marker of the post-fix `HEAD`, which differs from the first;
    - `review-2.md` contains `FIX.md` and `review-1.md` does not;
    - the bare repo's branch tip equals `WORK`'s `HEAD`, with author `ai-implement`;
    - the verdict comment says `approve` and `self-fix: 1 iteration(s)`.
  - `self_fix_bounded` (`SELF_FIX_MAX_ITERATIONS=2`, every review `request_changes`):
    - three thread POSTs;
    - the fix log has 2 lines;
    - the verdict is `request_changes`, with `self-fix: 2 iteration(s)`.
  - `self_fix_guard_reported` (`SELF_FIX=1`, `CLAUDE_MOCK_FIX_TOUCH=azure-pipelines.yml`, reviews `request_changes`):
    - `RC=0`;
    - one thread POST;
    - the verdict comment contains `the fix changed pipeline files: azure-pipelines.yml`.
  - `self_fix_skipped_on_dirty_checkout`. A `success` step variant that leaves untracked `junk.txt` (add `success-dirty` to the mock's step table):
    - no fix call;
    - the verdict comment contains `self-fix skipped`.
  - `review_failure_stays_green`. The POST map line points at an error `.txt` fixture, so `az` exits 1:
    - `RC=0`;
    - exactly one `— attempt` report;
    - the verdict comment exists (it reports whatever `review-pr.sh` returned, or `review_failed` with `review-pr.sh exited`);
    - one implement call in `CLAUDELOG`, so there was no retry.
  - `config_rejected`: `run_driver AI_REVIEW=yes AZURE_DEVOPS_EXT_PAT=pat` gives `RC=2`. Do the same for `SELF_FIX=2` and `SELF_FIX_MAX_ITERATIONS=-1`.
  - `verdict_comment_not_counted_by_cap`:
    - `render_review_report` (sourced, with globals set) wrapped as `[{"body":…}]` and fed to `check-attempt-cap.sh` with `ISSUE_NUMBER=42 REPO=o/r DRY_RUN=1` prints `attempt=1`;
    - with one real attempt report added, it prints `attempt=2`.

- [ ] **Step 2: Run them and confirm they fail.**
  Run: `bash tests/run-implement-azdo-tests.sh`
  Expected: the new cases FAIL (no thread POST, no verdict comment, `AI_REVIEW=yes` exits 0). The retry plan's cases still pass.

- [ ] **Step 3: Implement** the functions and the wiring per Interfaces, each about 20 lines or fewer. Call them inside `if` or with `|| …` and explicit checks: errexit is off in those contexts.

- [ ] **Step 4: Run all tests and confirm G4.**
  Run: `bash tests/run-implement-azdo-tests.sh && bash tests/run-all.sh && git diff --exit-code tests/run-script-tests.sh .github/workflows/agent-implement.yml`
  Expected: 0 failed, and an empty diff. The implement-azdo runner still takes about 5 s or less.

- [ ] **Step 5: Lint and commit.**

  ```bash
  git add scripts/implement-azdo.sh tests/mocks/claude-implement/claude tests/run-implement-azdo-tests.sh
  shellcheck -x -e SC1091 scripts/implement-azdo.sh tests/mocks/claude-implement/claude tests/run-implement-azdo-tests.sh
  git commit -m "feat(azdo): AI review and opt-in self-fix after the draft PR opens (#573)"
  ```

### Task 5: B6, never vote, complete or publish (grep and an executed run)

**Files:**
- Modify: `tests/run-implement-azdo-tests.sh`. Add a section "B6: never vote". It reuses Task 4's `run_loop`, so no harness is copied.

**Interfaces:**
- Consumes: the Task 4 harness and mocks, and `CURL_MOCK_LOG` / `CURL_MOCK_BODY_LOG` from the curl mock.
- Produces: `forbidden_hits <file>…`, which prints `file:line:text` for each matching line, and `forbidden_hits_raw <file>…`. The first is for source files: it drops lines matching `^\s*#` first. The second is for log files and greps them raw, because the az argv log carries the multi-line `--discussion` body, whose lines start with `##`. Both use these ERE patterns:
  - `set-vote`
  - `repos pr reviewer`
  - `repos pr update`
  - `autoCompleteSetBy`
  - `--auto-complete`
  - `isDraft`
  - `--draft[ =]false`
  - `"vote"`
  - `pullRequestReviewers`
  - `/reviewers`
  - `--resource pullRequests( |$)`
  - `"status" *: *"completed"`

- [ ] **Step 1: Write the tests.**
  - `canaries_detected`. A temp file holding one line per pattern, as real-looking calls (for example `az repos pr update --id 1 --status completed`, `{"vote": 10}`, `az repos pr create --draft false`), gives one hit per line. A commented copy of the same lines gives none. This proves the grep can fail.
  - `azdo_sources_clean`. `forbidden_hits` is empty for:
    - `scripts/implement-azdo.sh`;
    - `scripts/azdo-self-fix.sh`;
    - `scripts/lib/forge.sh`;
    - `scripts/lib/azdo.sh`;
    - `scripts/review-pr.sh`;
    - `scripts/self-fix-loop.sh`;
    - `scripts/self-fix-pr.sh`.
  - `e2e_run_never_votes`. `run_loop success` with:
    - `AI_REVIEW=1 SELF_FIX=1`;
    - `CLAUDE_MOCK_REVIEWS=review-request-changes.json,review-approve.json`;
    - `curl` mock on PATH with `CURL_MOCK_FIXTURE` set to an empty JSON file;
    - `CURL_MOCK_LOG`, `CURL_MOCK_BODY_LOG`, `AZ_MOCK_STDIN_LOG` and `GIT_MOCK_LOG`.

    Assertions:
    - **Positive control first.** `AZLOG` has at least 2 `pullRequestThreads` POSTs, the git log has at least 2 `push` lines (initial plus fix), and the work item got a `## ai-review verdict` comment. Without this, a clean log only proves nothing ran.
    - `forbidden_hits_raw` over the az argv log, the az stdin log, the curl argv and body logs, and the git log is empty.
    - `AZLOG` contains no `repos pr` call other than `repos pr create`.
    - Every `repos pr create` line contains `--draft`.

- [ ] **Step 2: Run them.**
  Run: `bash tests/run-implement-azdo-tests.sh`
  Expected: all pass. To prove it is not vacuous, temporarily add `az repos pr update --id "$PR_ID" --status completed || true` to `review_draft_pr`. Both `azdo_sources_clean` and `e2e_run_never_votes` must fail. Revert it, and record this in the commit body.

- [ ] **Step 3: Lint, full suite, commit.**

  ```bash
  git add tests/run-implement-azdo-tests.sh
  shellcheck -x -e SC1091 tests/run-implement-azdo-tests.sh
  bash tests/run-all.sh
  git commit -m "test(azdo): prove the agent never votes, completes or publishes a PR (#573)"
  ```

### Task 6: Setup guide §12 and changelog

**Files:**
- Modify: `docs/AZDO-PIPELINE-SETUP.md`:
  - §7 gains three optional variables;
  - add a new `## 12. AI review and self-fix`.
- Modify: `CHANGELOG.md`, `[Unreleased]` → `### Added`.

**Interfaces:**
- Consumes: the variable names and defaults, the `## ai-review verdict` heading, the `ai-implement` identity, and the guard behaviour.

- [ ] **Step 1: Write the text.**

  **§7:** `AI_REVIEW` (1), `SELF_FIX` (0), `SELF_FIX_MAX_ITERATIONS` (2), each with *Let users override* **off**.

  **§12:**
  1. **What runs.** After the draft PR opens, the same `review-pr.sh` reviews it. One PR thread is posted per head commit, carrying the verdict and concerns, and the work item gets a `## ai-review verdict` comment with the PR link.
  2. **Self-fix.** With `SELF_FIX=1` and a `request_changes` verdict, up to `SELF_FIX_MAX_ITERATIONS` fix → re-review passes run. Fixes are committed as `ai-implement` and pushed to the PR branch. The fix is skipped when the checkout is not clean.
  3. **Never votes.** The PR stays a draft. The agent never votes, approves, completes or publishes; a human does. Merge gates stay branch policies (§6, §9).
  4. **Pipeline files.** A fix that touches a §9.4 glob is not pushed. The loop stops, and the verdict comment names the files. No variable can skip this.
  5. **Permissions.** The thread POST uses §5's *Contribute to pull requests*. If it is missing, the run stays green and the verdict comment says the review failed.
  6. **Time budget.** The review takes up to 10 min, and each self-fix iteration up to 20 + 10 min. That is about 70 min at the default of 2. Each extra iteration adds 30 min against §11's `timeoutInMinutes: 240`.

  **CHANGELOG:** AI review and opt-in self-fix on Azure DevOps (`AI_REVIEW`, `SELF_FIX`, `SELF_FIX_MAX_ITERATIONS`, guide §12) (#573).

- [ ] **Step 2: Verify.**
  Run: `git add docs/AZDO-PIPELINE-SETUP.md CHANGELOG.md && pre-commit run markdownlint-cli2 --files docs/AZDO-PIPELINE-SETUP.md CHANGELOG.md && grep -n '^## 12\. AI review and self-fix' docs/AZDO-PIPELINE-SETUP.md && grep -c 'SELF_FIX_MAX_ITERATIONS' docs/AZDO-PIPELINE-SETUP.md`
  Expected: the hook passes, the heading is found, and the count is at least 2. Check by eye that the diff names no real org, pool or host.

- [ ] **Step 3: Commit.**

  ```bash
  git commit -m "docs(azdo): document AI review and self-fix (#573)"
  ```

### Task 7: Orchestrator-run live proof (sandbox)

**Run by the orchestrator, not an implementer subagent.** It needs the sandbox organization and pipeline, and the maintainer's authorization for outward sandbox actions. Point the sandbox pipeline's `AGENT_WORKFLOW_REF` at the branch head. Sandbox names stay out of this repo.

**Files:**
- Create: `docs/ai-notes/2026-11-XX-azdo-ai-review-run.md`, with the date filled in and placeholders only.
- Create: `tests/fixtures/azdo-pr-threads-live.json`, a trimmed real GET payload.
- Modify: `tests/run-forge-adapter-tests.sh`, with one case on the live fixture.
- Modify: `scripts/lib/forge.sh`, only if check 3 shows that the real shape needs it.

- [ ] **Step 1: Approve path.** Tag an item whose change is plainly fine (`AI_REVIEW=1`, `SELF_FIX=0`). Record:
  - the run number;
  - one PR thread with verdict `approve` and the marker for the PR's head SHA;
  - the `## ai-review verdict: approve` work-item comment with `!<id>`;
  - the PR is still a **draft** with no votes;
  - the job is green.
- [ ] **Step 2: Self-fix path.** With `SELF_FIX=1`, tag an item seeded to draw a concern (for example "add a function, no test required"). Record:
  - the first thread is `request_changes`;
  - a fix commit by `ai-implement` is on the PR branch;
  - a second thread carries the new SHA's marker;
  - the final verdict comment shows the iterations;
  - the PR is still a draft with no votes;
  - `.git/config` in the job has no `extraheader`;
  - the log has no PAT.

  If the verdict comment says `self-fix skipped`, record the checkout's `git status --porcelain` output. The CLI or the build may leave files on every real run. Do not loosen the check without a maintainer decision.
- [ ] **Step 3: Marker round trip and resource name.**
  - Confirm that `--area git --resource pullRequestThreads` was accepted. If it was not, switch `forge_pr_comment` to the `curl -K -` helper style and add a Layer-1 case.
  - GET the threads back with `az devops invoke` and confirm `content` holds `<!-- review-pr:<sha> -->` verbatim.
  - Re-run `review-pr.sh` by hand against the same SHA, with `FORGE=azdo` and the real env, and confirm `posted=false` and no new thread.
- [ ] **Step 4: Fixture.**
  - Trim the payload to `{"value":[{"id":…,"comments":[{"content":…}]}],"count":…}`, dropping identities, URLs and dates.
  - Run the public-repo leak-term grep.
  - Save it as `tests/fixtures/azdo-pr-threads-live.json`.
  - Add a case: `forge_pr_comments_json` output contains the marker.
- [ ] **Step 5: Timing.** Record the job duration against the 240-minute budget.
- [ ] **Step 6: Verify and commit.**
  Run: `bash tests/run-all.sh`
  Expected: `failed: 0`.

  ```bash
  git add docs/ai-notes/2026-11-XX-azdo-ai-review-run.md tests/fixtures/azdo-pr-threads-live.json tests/run-forge-adapter-tests.sh
  git commit -m "docs(azdo): record the AI review and self-fix live proof (#573)"
  ```
