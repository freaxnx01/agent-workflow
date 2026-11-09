# Azure DevOps ai-implement retry and attempt cap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Retry a failed Azure DevOps agent attempt inside the one guarded job, by the same policy as GitHub, and park a work item that has reached the attempt cap.

**Architecture:** The GitHub retry decision table moves out of `retry-dispatch.sh` into `scripts/lib/retry-policy.sh`, and both forges source it. `implement-azdo.sh` becomes a set of small functions with an attempt loop. Before every attempt the loop runs `check-attempt-cap.sh`. Each attempt runs the agent under `timeout`, classifies the outcome and posts a `## ai-implement run …` report. Then the loop retries from a clean workspace, opens the draft PR, or stops. The azdo branch of `forge_export_issue` turns HTML comment bodies into text, so the cap can count prior reports at all.

**Tech Stack:** Bash 5 (`set -euo pipefail`, `IFS=$'\n\t'`), `jq`, `python3` (stdlib `html`, `re`), GNU `timeout`, the `az` mock, a new `claude` mock and a `git` origin shim under `tests/mocks/`.

**Spec:** `docs/superpowers/specs/2026-11-09-azdo-retry-design.md`

## Global Constraints

- No re-queue, and no change to `azdo-tag-guard.sh` or `azdo-pipeline-run.sh`. Retry happens inside the one guarded job.
- No new environment variable may skip or weaken the guard. Test seams live on `PATH` (mocks), never in production code.
- Only one copy of the retry policy exists: `scripts/lib/retry-policy.sh`. The knobs keep their names and defaults:
  - `MAX_RETRIES_RATE=3`
  - `MAX_RETRIES_TRANS=3`
  - `MAX_RETRIES_TASK=1`
  - `DELAY_OVERRIDE_SEC`
- The delays stay as they are:
  - `rate_limit`: 300 s;
  - `transient`: `10 * 2^(attempt-1)`;
  - `task_failure`: 10 s.
- `retry-dispatch.sh` keeps its output and exit codes. The tests in `tests/run-script-tests.sh`, `tests/run-pipeline-alarm-tests.sh` and `tests/run-opencode-model-tests.sh` stay byte-for-byte unchanged and green.
- Every per-attempt report starts with `## ai-implement run (<context>, Azure DevOps) — attempt N`. Here `<context>` is `pipeline` or `local`, and `N` is `RUN_ATTEMPT`. The report carries `**Turns:**` and `**Cost:**` in `post-run-report.sh`'s shape. An unknown value is written as the word `unknown`, never `0` or `$0.00`.
- `MAX_ATTEMPTS` defaults to 2, through `check-attempt-cap.sh`. The park tag is that script's `PARK_LABEL` default, `parked`.
- `IMPLEMENT_TIMEOUT_MIN` defaults to 45. The guide documents `timeoutInMinutes: 240`.
- `pipeline_file_guard "origin/$DEFAULT_BRANCH"` (from the earlier plan) runs before **every** push.
- Public repo: no org, pool, host or work-repo names in code, fixtures, docs or the run note. Use placeholders as `docs/AZDO-PIPELINE-SETUP.md` does.
- A function called inside `if`, `&&` or `||` runs with errexit **off**. Every such function checks its own failures explicitly and returns non-zero.

## Review Focus

1. **The cap sees this run's own reports.** If `ISSUE_COMMENTS_JSON` stays the snapshot taken at start, the mid-run park can never fire. `post_report` appends each posted body to it. Test: transient ×3 with `MAX_ATTEMPTS=2` parks before attempt 3 (Task 4).
2. **A real attempt is never counted as a non-start.** A timed-out attempt, or one whose result is not JSON, must not report `Turns: 0` / `$0.00`. Test: the rendered report for a timeout is fed to `check-attempt-cap.sh`, which counts it as an attempt (Task 5).
3. **HTML entities and non-breaking spaces.** `&nbsp;` between `##` and `ai-implement` would break `startswith`. An escaped `&lt;` in a body must survive. Test: fixture cases in Task 2.
4. **Agent success followed by a failed PR step** (no branch, pipeline file touched, push refused, or PR create failed). This must still post a report, because it was a real attempt, and it must not retry. Test: the pipeline-file case in Task 3.
5. **A retry must not inherit the failed attempt's state.** That covers untracked files, a local branch and a remote branch it pushed. Tests: attempt 2 starts on `main` with a clean tree; the failed local branch is gone; the remote branch is named in the report (Task 4).

---

### Task 1: Extract the retry policy into `scripts/lib/retry-policy.sh`

**Files:**
- Create: `scripts/lib/retry-policy.sh`
- Create: `tests/run-retry-policy-tests.sh` (copy the pass/fail/assert helpers from `tests/run-implement-azdo-tests.sh:16-45`)
- Modify: `scripts/retry-dispatch.sh:49-99` (drop the `MAX_RETRIES_*` lines and the `case` block, then source the lib)

**Interfaces:**
- Produces: `retry_policy <class> <attempt>`. Sourced, not executed. It prints exactly two lines to stdout:

  ```text
  decision=<retry|stop>
  delay=<seconds>
  ```

  It reads `MAX_RETRIES_RATE` / `MAX_RETRIES_TRANS` / `MAX_RETRIES_TASK` (defaults 3/3/1) **at call time**. `DELAY_OVERRIDE_SEC`, when set and non-empty, replaces `delay` on **both** decisions. An unknown class prints `warn: unknown CLASS "<class>" — defaulting to stop` to stderr (the exact current text). It returns 0, and 2 when either argument is missing.

- [ ] **Step 1: Write the failing tests** in `tests/run-retry-policy-tests.sh`. Source the lib and assert the output of `retry_policy`, one case per class × attempt boundary:
  - `success 1` → `decision=stop`, `delay=0`
  - `rate_limit 1` → retry/300
  - `rate_limit 2` → retry/300
  - `rate_limit 3` → stop/0
  - `transient 1` → retry/10
  - `transient 2` → retry/20
  - `transient 3` → stop/0
  - `task_failure 1` → retry/10
  - `task_failure 2` → stop/0
  - `out_of_credits 1`, `model_not_found 1`, `api_auth 1`, `bug 1` → stop/0, with empty stderr
  - `nonsense 1` → stop, and stderr contains `unknown CLASS "nonsense"`
  - `MAX_RETRIES_TASK=2 task_failure 2` → retry
  - `DELAY_OVERRIDE_SEC=0 rate_limit 1` → `delay=0`
  - `DELAY_OVERRIDE_SEC=7 api_auth 1` → `decision=stop`, `delay=7` (the current override-on-stop behaviour)
  - `retry_policy` with no arguments → rc 2

- [ ] **Step 2: Run them and verify they fail.**
  Run: `bash tests/run-retry-policy-tests.sh`
  Expected: FAIL. The source fails because `scripts/lib/retry-policy.sh` does not exist.

- [ ] **Step 3: Implement `retry_policy` in `scripts/lib/retry-policy.sh`.**
  - Give the lib a header like `pause-reasons.sh`: purpose, "sourced, not executed", the exposed function, and the two callers.
  - Move the `case` block from `retry-dispatch.sh` verbatim, comments included.
  - In `retry-dispatch.sh`, source the lib after `require_env`. Read both lines with `sed -n 's/^decision=//p'` / `'s/^delay=//p'` into `decision` / `delay`. Leave everything from `emit()` down untouched.

- [ ] **Step 4: Run the new and existing tests, and verify they pass unchanged.**
  Run: `bash tests/run-retry-policy-tests.sh && bash tests/run-script-tests.sh && bash tests/run-pipeline-alarm-tests.sh && bash tests/run-opencode-model-tests.sh && git diff --exit-code tests/run-script-tests.sh tests/run-pipeline-alarm-tests.sh tests/run-opencode-model-tests.sh && shellcheck -x -e SC1091 scripts/lib/retry-policy.sh scripts/retry-dispatch.sh tests/run-retry-policy-tests.sh`
  Expected: all runners report 0 failed, `git diff` prints nothing, shellcheck is silent.

- [ ] **Step 5: Commit.**

  ```bash
  git add scripts/lib/retry-policy.sh scripts/retry-dispatch.sh tests/run-retry-policy-tests.sh
  git commit -m "refactor(retry): extract the retry decision table into lib/retry-policy.sh (#573)"
  ```

### Task 2: Azure DevOps comment bodies as plain text in `forge_export_issue`

**Files:**
- Modify: `scripts/lib/forge.sh:117-142` (the azdo comment mapping, for both `ISSUE_JSON` and `ISSUE_COMMENTS_JSON`)
- Create: `tests/fixtures/azdo-comments-report-html.json`
- Modify: `tests/run-forge-adapter-tests.sh` (the `az_read` block near line 316: also print a `C<<…>>` block of `ISSUE_COMMENTS_JSON`, then add a section)

**Interfaces:**
- Produces: `_forge_azdo_comments_text`. It reads an Azure DevOps comments document (`{"comments":[{"text":…}]}`) on stdin and prints a JSON array `[{"body": <text>}]` in API order. Both azdo assignments use it, so the conversion exists once.
- Text rules, applied in this order:
  1. `<br>`, `<br/>`, `<br />` (any case) → `\n`;
  2. `</div>`, `</p>` (any case) → `\n`;
  3. remove every other tag (`<[^>]+>`);
  4. `html.unescape`;
  5. ` ` → space;
  6. `.strip()` the whole body.

  Unescaping after the tags are stripped keeps an escaped `&lt;b&gt;` as the text `<b>`.
- Unchanged: the github branch, `azdo_comments` in `lib/azdo.sh`, `tests/fixtures/azdo-comments-locked.json`, `check-attempt-cap.sh`.

- [ ] **Step 1: Write the fixture and the failing tests.** The fixture `azdo-comments-report-html.json` holds three comments:
  - `<div>##&nbsp;ai-implement run (pipeline, Azure DevOps) — attempt 1</div><div><br></div><div>**Outcome:** failed: transient</div><div>**Duration:** 3s · **Turns:** 12 / cap 80 · **Cost:** $0.41</div>`;
  - the same with `**Turns:** 0 / cap 80 · **Cost:** $0.00`;
  - `<p>a &lt;b&gt; tag &amp; text</p>`.

  Assertions in a new section, "azdo comments become plain text":
  - `ISSUE_COMMENTS_JSON[0].body` starts with `## ai-implement run (pipeline, Azure DevOps) — attempt 1`;
  - `[0].body` contains `\n**Outcome:** failed: transient`;
  - `[2].body` equals `a <b> tag & text`;
  - `ISSUE_JSON.comments[0].body` equals `ISSUE_COMMENTS_JSON[0].body`;
  - **end to end:** `ISSUE_COMMENTS_JSON` passed to `check-attempt-cap.sh` (`ISSUE_NUMBER=42 REPO=o/r DRY_RUN=1`) prints `attempt=2` and `non-starts=1`;
  - the existing case `comments are normalised from .text to .body` still passes.

- [ ] **Step 2: Run them and verify they fail.**
  Run: `bash tests/run-forge-adapter-tests.sh`
  Expected: FAIL. The bodies still carry `<div>` and the cap prints `attempt=1`.

- [ ] **Step 3: Implement `_forge_azdo_comments_text` in `scripts/lib/forge.sh`.** Use the rules above. Call it in both places: `ISSUE_COMMENTS_JSON` pipes `$comments` into it, and the `ISSUE_JSON` python reads its output from the temp file in place of `cm`. Add a comment that says why: the comments API returns HTML, and `check-attempt-cap.sh` matches `startswith("## ai-implement run")`.

- [ ] **Step 4: Run the tests and verify they pass.**
  Run: `bash tests/run-forge-adapter-tests.sh && bash tests/run-build-agent-prompt-tests.sh && shellcheck -x -e SC1091 scripts/lib/forge.sh tests/run-forge-adapter-tests.sh`
  Expected: 0 failed, shellcheck silent.

- [ ] **Step 5: Commit.**

  ```bash
  git add scripts/lib/forge.sh tests/fixtures/azdo-comments-report-html.json tests/run-forge-adapter-tests.sh
  git commit -m "fix(forge): turn Azure DevOps comment HTML into text so the attempt cap counts reports (#573)"
  ```

### Task 3: Split `implement-azdo.sh` into functions, with the new per-attempt report

One attempt, no loop yet. Behaviour stays as today, apart from three changes:

- the report heading and metrics;
- a report is also posted when the attempt fails;
- the G5 text.

**Files:**
- Modify: `scripts/implement-azdo.sh` (whole file)
- Create: `tests/mocks/claude-implement/claude`. It is a scripted agent, kept in its own subdirectory so it never shadows `claude` for the other runners that put `$MOCKS` on PATH. If the earlier plan already added a `claude` mock or a bare-remote harness for the C6 cases, extend that one instead.
- Create: `tests/mocks/git-origin/git`, the origin shim
- Create: `tests/fixtures/result-transient.json`. Claude shape: `is_error: true`, `subtype: "error_during_execution"`, `result: "API Error: 529 Overloaded"`, `num_turns: 3`, `total_cost_usd: 0.05`. `classify-failure.sh` must print `class=transient` for it.
- Create: `tests/fixtures/azdo-pr-create.tsv` (one line: `42`)
- Modify: `tests/run-implement-azdo-tests.sh`

**Interfaces:**
- Consumes: `pipeline_file_guard <base-ref>` from `scripts/lib/pipeline-file-guard.sh`. It returns 0 when no pipeline file is touched and 1 when one is, with the offending paths on stderr.
- Produces, in `scripts/implement-azdo.sh`. The script ends with `if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi`, so tests can source it. Not the `[[ … ]] && main` form: when sourced, that returns 1 and kills a `set -e` caller. For that to work under `set -u`:
  - every global below is initialised to empty at top level;
  - `: "${ISSUE_NUMBER:?…}"` moves into `preflight`;
  - only the lib `source` lines and those initialisations stay at top level.

  Globals:

  | Name | Holds |
  |---|---|
  | `RUN_CONTEXT` | `pipeline` or `local` |
  | `DEFAULT_BRANCH` | the default branch |
  | `RUN_ATTEMPT` | 1-based attempt number within this run |
  | `PR_ID` | the draft PR's id; empty until `open_draft_pr` succeeds |
  | `HEAD_BRANCH` | the branch the attempt ended on |
  | `AGENT_RC` | the agent's exit code |
  | `ATTEMPT_CLASS` | the attempt's outcome class |
  | `ATTEMPT_SECONDS` | how long the attempt ran |
  | `ATTEMPT_ERROR` | why a PR step failed, one line |
  | `AGENT_NAME` | from `classify_issue` |
  | `TURNS_BUDGET` | from `classify_issue` |
  | `WORK_DIR` | `mktemp -d`, removed by one `trap … EXIT` |
  | `PROMPT_FILE`, `RESULT_FILE` | inside `WORK_DIR` |

  Functions:
  - `main` — orchestrates the phases, about 20 lines.
  - `preflight` — forge check, PAT and context. Exit 2 paths as today.
  - `print_banner`
  - `read_work_item` — `forge_export_issue`, and prints the tags and title. Exits 1 on failure.
  - `classify_issue` — runs `classify-agent.sh` / `classify-turns.sh` with `ATTEMPT=$RUN_ATTEMPT` exported. Sets `AGENT_NAME` and `TURNS_BUDGET`.
  - `resolve_default_branch` — query that prints the default branch. Keep today's `|| true` and its comment.
  - `run_attempt` — builds the prompt, runs the agent, sets `AGENT_RC`, `HEAD_BRANCH`, `ATTEMPT_SECONDS` and `ATTEMPT_CLASS`.
  - `classify_attempt <agent-rc> <result-file>` — query that prints the class. See the outcome mapping in Step 3.
  - `open_draft_pr` — in this order:
    1. the still-on-default check;
    2. `pipeline_file_guard "origin/$DEFAULT_BRANCH"`, with its stderr captured into `ATTEMPT_ERROR`;
    3. `push_branch "$HEAD_BRANCH"` unless `remote_branch_exists "$HEAD_BRANCH"`;
    4. `forge_pr_create_draft`.

    Sets `PR_ID` and returns 0. On failure it sets `ATTEMPT_ERROR` and returns 1.
  - `remote_branch_exists <branch>` — `git ls-remote --exit-code --heads origin <branch>` with the same `http.extraheader` Basic auth as `push_branch`. Returns 0 when the branch exists. Today's unauthenticated `ls-remote` fails on the server, and the "branch left on the server" line would then never appear live.
  - `push_branch <branch>` — pushes with the `http.extraheader` Basic auth used today. Returns non-zero on failure. The AI-review plan's self-fix push reuses it.
  - `report_metrics_line <result-file>` — query that prints:

    ```text
    **Duration:** <ATTEMPT_SECONDS>s · **Turns:** <n|unknown> / cap <TURNS_BUDGET> · **Cost:** <usd|unknown>
    ```

    Cost formatting uses the same awk rules as `format_usd` in `post-run-report.sh`: 0 → `$0.00`, under 0.01 → `%.4g`, otherwise `%.2f`. Use `unknown` when the file is missing, is not JSON, or lacks the field.
  - `render_report <outcome-text> <next-line>` — query that prints the report body. See Step 3.
  - `post_report <outcome-text> <next-line>` — renders the report into `WORK_DIR`, calls `forge_issue_comment`, and appends `{"body": <rendered>}` to `ISSUE_COMMENTS_JSON` with `jq`, even when the post fails (fail closed). Returns 0.

- [ ] **Step 1: Write the mocks and the harness.**

  `tests/mocks/git-origin/git` intercepts exactly one call. When `$1 $2 $3` is `remote get-url origin`, it prints `$GIT_MOCK_ORIGIN_URL`. Every other call runs `exec "$GIT_MOCK_REAL" "$@"`. It is needed because `url.*.insteadOf` also rewrites `git remote get-url`, and `detect_forge` would stop seeing an azdo remote.

  `tests/mocks/claude-implement/claude` behaves like this:
  - **Call log.** It consumes stdin and increments a counter in `$CLAUDE_MOCK_STATE`. It appends `call <n> branch=<abbrev HEAD> dirty=<git status --porcelain | wc -l>` to `$CLAUDE_MOCK_LOG`.
  - **Step selection.** It reads line `<n>` of `$CLAUDE_MOCK_STEPS`, then acts on that step, writing the fixture from `"$(dirname "$0")/../fixtures"` to stdout:

  | Step | Git side effect | Fixture | Exit |
  |---|---|---|---|
  | `success` | `checkout -b ai/7-ok-<n>`, commit `HELLO.md` | `result-success-cheap.json` | 0 |
  | `transient` | `checkout -b ai/7-try-<n>`, commit `a.txt`, leave untracked `junk.txt` | `result-transient.json` | 1 |
  | `transient-pushed` | as `transient`, plus `git push -q origin HEAD` | `result-transient.json` | 1 |
  | `task_failure` | as `transient` | `result-max-turns.json` | 1 |
  | `api_auth` | none | `result-api-auth.json` | 1 |
  | `pipeline-file` | `checkout -b ai/7-pf-<n>`, commit `azure-pipelines.yml` | `result-success-cheap.json` | 0 |
  | `hang` | none | none (it runs `sleep 30`) | — |

  In `tests/run-implement-azdo-tests.sh`, add `run_loop <steps-csv> [VAR=value …]`. It uses a fresh `$TMP/loop-<k>` per call:
  1. Create a bare repo with one commit on `main`, and `git clone` it to `work`, so `origin/HEAD` exists.
  2. Run the driver under `env -i` like `run_driver`. Pass:
     - `PATH="$MOCKS/claude-implement:$MOCKS/git-origin:$MOCKS:$PATH"`;
     - `GIT_MOCK_REAL="$(command -v git)"`;
     - `GIT_MOCK_ORIGIN_URL=https://dev.azure.com/contoso/MyProject/_git/my-repo`;
     - `AZURE_DEVOPS_EXT_PAT=pat`, `ISSUE_NUMBER=7`, `DELAY_OVERRIDE_SEC=0`;
     - `GIT_AUTHOR_NAME`/`GIT_AUTHOR_EMAIL`/`GIT_COMMITTER_NAME`/`GIT_COMMITTER_EMAIL` set to `test`/`t@example.invalid`;
     - `AZ_MOCK_LOG`, and the `CLAUDE_MOCK_*` files.
  3. Use an `AZ_MOCK_MAP` with these extra lines:
     - `work-item update` → `forge-workitem-azdo.json`;
     - `repos pr create` → a new `tests/fixtures/azdo-pr-create.tsv` containing `42`;
     - `resource comments` → `$FIXTURES/${AZ_COMMENTS:-forge-comments-azdo.json}`.
  4. Set `RC`, `OUT`, `ERR`, `AZLOG`, `CLAUDELOG` and `WORK` (the clone path).

  Count reports with `grep -c 'ai-implement run (local, Azure DevOps) — attempt' <<<"$AZLOG"`. The heading is `local` because `TF_BUILD` is unset.

- [ ] **Step 2: Write the failing tests** in a new section, "one attempt".

  **`success`:**
  - `RC=0`;
  - `AZLOG` contains `repos pr create` and `--work-items 7`;
  - one report, `— attempt 1`;
  - the report contains `**Outcome:** success`, `**Turns:** 4 / cap`, `**Cost:** $0.0042` and `draft PR: !42`;
  - `git -C "$bare" branch --list 'ai/7-ok-1'` is non-empty, so it was pushed;
  - `OUT` contains `draft PR  : #42`.

  **`api_auth`:**
  - `RC=1`;
  - one report, containing `**Outcome:** failed: api_auth`;
  - no `repos pr create` in `AZLOG`.

  **`pipeline-file`:**
  - `RC=1`;
  - no `repos pr create`;
  - the bare repo has no `ai/7-pf-1` branch;
  - one report that names `azure-pipelines.yml`.

  **G5:**
  - `OUT` does not contain `retry            : unavailable`;
  - no report contains `Retry and auto-merge are unavailable`.

  **Cap round-trip,** with `implement-azdo.sh` sourced in a subshell:
  - set `ATTEMPT_SECONDS=5`, `TURNS_BUDGET=80`, `RUN_CONTEXT=pipeline`, `RUN_ATTEMPT=1`, `RESULT_FILE="$FIXTURES/result-max-turns.json"`;
  - pass `render_report 'failed: task_failure' 'next: stopping'`, wrapped as `[{"body":…}]` with `jq -Rs`, to `check-attempt-cap.sh` as `ISSUE_COMMENTS_JSON`;
  - it prints `attempt=2`, `non-starts=0`;
  - the same with `result-api-auth.json` (1 turn, $0) prints `attempt=2`.

  All existing `run_driver` cases stay as they are.

- [ ] **Step 3: Run them and verify they fail.**
  Run: `bash tests/run-implement-azdo-tests.sh`
  Expected: FAIL on the heading, report-on-failure, G5 and sourcing cases. The existing DRY_RUN cases still pass.

- [ ] **Step 4: Restructure `scripts/implement-azdo.sh` into the functions above.**

  **`classify_attempt` outcome mapping:**

  | Agent rc / result | Class |
  |---|---|
  | rc `124` or `137` (timeout) | `transient`, without calling `classify-failure.sh` |
  | `classify-failure.sh` prints nothing (result missing or not JSON) | `bug` |
  | class `success` but rc ≠ 0 | `bug` |
  | anything else | `classify-failure.sh`'s class |

  **`render_report` body**, one line each:

  ```text
  ## ai-implement run (<RUN_CONTEXT>, Azure DevOps) — attempt <RUN_ATTEMPT>

  **Outcome:** <outcome-text>
  <report_metrics_line "$RESULT_FILE">
  - agent: <AGENT_NAME>, model: <MODEL>
  - draft PR: !<PR_ID>                       (only when PR_ID is set)
  - branch left on the server: <HEAD_BRANCH>  (only on failure, when remote_branch_exists)
  - <next-line>
  ```

  The closing line for a success is `Auto-merge is unavailable on this forge; review and merge the PR by hand.`.

  **Flow in `main` for this task:** `run_attempt` once.
  - On `success`, `open_draft_pr`:
    - if that works, `post_report success "next: review and merge !$PR_ID"`;
    - if it fails, `post_report "failed: $ATTEMPT_ERROR" "next: stopping"`, then exit 1.
  - On any other class, `post_report "failed: $ATTEMPT_CLASS" "next: stopping"`, then exit 1.

  **G5 text:**
  - Header comment (lines 10–24): replace the "No retry" bullet. Retries now happen in the job, per `lib/retry-policy.sh`, with a cap from `check-attempt-cap.sh`. Escalation is a no-op on this Claude-only path.
  - Banner line: `retry            : in-job, per lib/retry-policy.sh (cap MAX_ATTEMPTS=<n>)`.
  - Stop message: the "no retry on this forge" lines at 133–134 become `Stopping: <class> does not retry (or the retry budget is spent).`.

- [ ] **Step 5: Run the tests and verify they pass.**
  Run: `bash tests/run-implement-azdo-tests.sh && shellcheck -x -e SC1091 scripts/implement-azdo.sh tests/run-implement-azdo-tests.sh tests/mocks/claude-implement/claude tests/mocks/git-origin/git && bash tests/run-all.sh`
  Expected: 0 failed, shellcheck silent. The whole runner should take under 5 seconds.

- [ ] **Step 6: Commit.**

  ```bash
  git add scripts/implement-azdo.sh tests/mocks/claude-implement/claude tests/mocks/git-origin/git tests/fixtures/result-transient.json tests/fixtures/azdo-pr-create.tsv tests/run-implement-azdo-tests.sh
  git commit -m "refactor(azdo): split implement-azdo.sh into phase functions with a per-attempt report (#573)"
  ```

### Task 4: The attempt loop, cap check and workspace reset

**Files:**
- Modify: `scripts/implement-azdo.sh`
- Create: `tests/fixtures/azdo-comments-two-reports.json`. It holds two HTML-wrapped real reports, as in Task 2's first comment, with distinct ids.
- Modify: `tests/run-implement-azdo-tests.sh`

**Interfaces:**
- Consumes: `retry_policy` (Task 1), `post_report`, `run_attempt`, `open_draft_pr` (Task 3), and `ISSUE_COMMENTS_JSON` as text (Task 2).
- Produces:
  - `check_cap` runs `check-attempt-cap.sh` with `GITHUB_OUTPUT` set to a file in `WORK_DIR`. `ISSUE_NUMBER`, `REPO`, `ISSUE_COMMENTS_JSON` and `MAX_ATTEMPTS` are inherited. It sets `CAP_ATTEMPT` from `attempt=`. It returns 0 when `proceed=true` and 1 when the item was parked.
  - `decide_retry <class> <run-attempt>` sets `RETRY_DECISION` and `RETRY_DELAY`. The lib is sourced once at the top of the script. Call `retry_policy` **once** and parse the captured output, so an unknown class warns only once.
  - `reset_workspace` runs these, each checked:
    1. `git checkout --force "$DEFAULT_BRANCH"`;
    2. `git reset --hard "origin/$DEFAULT_BRANCH"`;
    3. `git clean -ffdx` when `ci_host` prints `pipelines`; `git clean -ffd` otherwise. A local run must keep ignored files such as `.envrc`. Add a test for each branch (`TF_BUILD=True` vs unset): an ignored file in the test repo is removed vs kept;
    4. `git branch -D "$HEAD_BRANCH"`, only when `HEAD_BRANCH` is set and not `DEFAULT_BRANCH`.

    It returns 1 on any failure. The caller then stops with exit 1, because a dirty workspace must not be retried.
  - `main` still calls `classify_issue` once before the DRY_RUN stop, so the dry run prints agent and turns as today.
  - `attempt_loop`, called by `main` after the DRY_RUN stop with `RUN_ATTEMPT=1`. It repeats:
    1. `check_cap`, or print `parked: cap reached (attempt <CAP_ATTEMPT> of <MAX_ATTEMPTS>)` and exit 0;
    2. `classify_issue`;
    3. `run_attempt`;
    4. on success, the Task 3 success path;
    5. otherwise `decide_retry`, then `post_report "failed: $ATTEMPT_CLASS" "next: retrying in <RETRY_DELAY>s"` or `"next: stopping"`;
    6. on stop, exit 1;
    7. on retry, `sleep "$RETRY_DELAY"`, `reset_workspace`, `RUN_ATTEMPT+1`.
  - Banner and report gain the cap attempt: `- cap: attempt <CAP_ATTEMPT> of <MAX_ATTEMPTS>`.

- [ ] **Step 1: Write the failing tests** in the section "retry loop".

  **`transient,success`:**
  - `RC=0`;
  - two reports, `— attempt 1` then `— attempt 2`;
  - the first contains `failed: transient` and `next: retrying in 0s`;
  - one `repos pr create`;
  - `CLAUDELOG` line 2 is `call 2 branch=main dirty=0`;
  - `git -C "$WORK" branch --list 'ai/7-try-1'` is empty.

  **`task_failure,task_failure`:**
  - `RC=1`;
  - two reports, the second with `next: stopping`;
  - no `repos pr create`.

  **`api_auth,success`:**
  - `RC=1`;
  - one report;
  - `CLAUDELOG` has one line, so there was no retry.

  **Cap reached at start:** `success` with `AZ_COMMENTS=azdo-comments-two-reports.json`.
  - `RC=0`;
  - `CLAUDELOG` is empty;
  - `AZLOG` contains `## ai-implement parked`;
  - no `— attempt` report;
  - `OUT` contains `parked`.

  **Mid-run park:** `transient,transient,success` with `MAX_ATTEMPTS=2`.
  - `RC=0`;
  - `CLAUDELOG` has two lines;
  - two attempt reports, then `## ai-implement parked`.

  **Remote branch named:** `transient-pushed,success`.
  - The first report contains `branch left on the server: ai/7-try-1`.

- [ ] **Step 2: Run them and verify they fail.**
  Run: `bash tests/run-implement-azdo-tests.sh`
  Expected: FAIL. With a single attempt, `transient,success` exits 1.

- [ ] **Step 3: Implement `check_cap`, `decide_retry`, `reset_workspace` and `attempt_loop`** with the signatures above. Keep each function under about 20 lines. `main` calls `attempt_loop` in place of Task 3's single attempt.

- [ ] **Step 4: Run all tests and verify they pass.**
  Run: `bash tests/run-implement-azdo-tests.sh && bash tests/run-all.sh && shellcheck -x -e SC1091 scripts/implement-azdo.sh tests/run-implement-azdo-tests.sh`
  Expected: `runners: N   failed: 0`, shellcheck silent.

- [ ] **Step 5: Commit.**

  ```bash
  git add scripts/implement-azdo.sh tests/fixtures/azdo-comments-two-reports.json tests/run-implement-azdo-tests.sh
  git commit -m "feat(azdo): retry failed attempts in-job and park at the attempt cap (#573)"
  ```

### Task 5: Per-attempt agent timeout

**Files:**
- Modify: `scripts/implement-azdo.sh` (`preflight`, `run_attempt`, header comment, Optional env list)
- Modify: `tests/run-implement-azdo-tests.sh`

**Interfaces:**
- Consumes: `classify_attempt` (rc `124`/`137` → `transient`) and `report_metrics_line` (`unknown`) from Task 3.
- Produces: `IMPLEMENT_TIMEOUT_MIN`, default `45`, must match `^[0-9]+([.][0-9]+)?$`. `preflight` exits 2 otherwise, with `error: IMPLEMENT_TIMEOUT_MIN must be a number of minutes`. `run_attempt` wraps the agent call in `timeout --kill-after=30s "${IMPLEMENT_TIMEOUT_MIN}m"`.

- [ ] **Step 1: Write the failing tests.**

  **`hang,success` with `IMPLEMENT_TIMEOUT_MIN=0.02`:**
  - `RC=0`;
  - two reports;
  - the first contains `failed: transient`, `**Turns:** unknown` and `**Cost:** unknown`.

  **Cap round-trip:** a sourced `render_report`, with `RESULT_FILE` pointing at an empty file, fed to `check-attempt-cap.sh`, prints `attempt=2` and `non-starts=0`.

  **Validation:** `run_driver IMPLEMENT_TIMEOUT_MIN=abc AZURE_DEVOPS_EXT_PAT=pat` gives `RC=2`.

- [ ] **Step 2: Run them and verify they fail.**
  Run: `bash tests/run-implement-azdo-tests.sh`
  Expected: FAIL. The hang runs 30 s, which is the mock's sleep, and the `abc` case exits 0.

- [ ] **Step 3: Implement** the validation in `preflight` and the `timeout` wrapper in `run_attempt`. Document `IMPLEMENT_TIMEOUT_MIN` and `MAX_ATTEMPTS` under "Optional" in the header.

- [ ] **Step 4: Run the tests and verify they pass.**
  Run: `time bash tests/run-implement-azdo-tests.sh && shellcheck -x -e SC1091 scripts/implement-azdo.sh`
  Expected: 0 failed, total under about 5 s.

- [ ] **Step 5: Commit.**

  ```bash
  git add scripts/implement-azdo.sh tests/run-implement-azdo-tests.sh
  git commit -m "feat(azdo): bound each agent attempt with IMPLEMENT_TIMEOUT_MIN (#573)"
  ```

### Task 6: Setup guide — retry, cap, timeout, unpark

**Files:**
- Modify: `docs/AZDO-PIPELINE-SETUP.md` (§7 variables, and a new §11 "Retry, attempt cap and job timeout". §9 and §10 are added by the PR-validation and tool-chain plans, which land first; use §11 regardless and do not renumber)

**Interfaces:**
- Consumes: the names fixed in Tasks 1–5: `MAX_ATTEMPTS`, `IMPLEMENT_TIMEOUT_MIN`, the `parked` tag, `lib/retry-policy.sh`.

- [ ] **Step 1: Write the guide text.**

  **§7, two optional variables,** both with *Let users override* **off**:
  - `MAX_ATTEMPTS` (default 2);
  - `IMPLEMENT_TIMEOUT_MIN` (default 45).

  **§11 policy table:**

  | Class | Attempts in one run | Delay before the retry |
  |---|---|---|
  | `rate_limit` | 3 | 300 s |
  | `transient` (including a timed-out attempt) | 3 | 10 s, 20 s |
  | `task_failure` | 2 | 10 s |
  | anything else | no retry | — |

  **§11 cap:** `MAX_ATTEMPTS` real attempts per work item, counted from the `## ai-implement run` reports across runs. A human re-tag counts toward the cap. Since the cap is checked before every attempt, it usually ends a run before the per-class limit does.

  **§11 workspace:** every retry starts from `origin/<default>`, after `git clean -ffdx` (pipeline runs; local runs keep ignored files). A remote branch that a failed attempt pushed is left in place and named in its report.

  **§11 job timeout:** the snippet

  ```yaml
  jobs:
    - job: implement
      timeoutInMinutes: 240
  ```

  and the budget breakdown:
  - 3 × 45 min of attempts;
  - 10 min of delays;
  - 2 × (20 + 10) min of review and self-fix;
  - about 205 min in total.

  **§11 unpark:**
  1. remove the `parked` tag;
  2. if the cap is the reason, raise `MAX_ATTEMPTS` on the pipeline;
  3. re-add `ai-implement`.

- [ ] **Step 2: Verify.**
  Run: `git add docs/AZDO-PIPELINE-SETUP.md && pre-commit run markdownlint-cli2 --files docs/AZDO-PIPELINE-SETUP.md && pre-commit run typos --files docs/AZDO-PIPELINE-SETUP.md && grep -c 'timeoutInMinutes: 240\|MAX_ATTEMPTS\|IMPLEMENT_TIMEOUT_MIN\|parked' docs/AZDO-PIPELINE-SETUP.md`
  Expected: both hooks pass, and the count is at least 4.

- [ ] **Step 3: Commit.**

  ```bash
  git commit -m "docs(azdo): document in-job retry, attempt cap, timeouts and unparking (#573)"
  ```

### Task 7: Orchestrator-run live proof (sandbox)

**Run by the orchestrator, not a subagent.** It needs the sandbox org and pipeline, and the maintainer's authorization for outward sandbox actions. Record results in `docs/ai-notes/2026-11-XX-azdo-retry-run.md`, with the date filled in. Use placeholders only: no org, pool, host or repo names.

**Files:**
- Create: `docs/ai-notes/2026-11-XX-azdo-retry-run.md`
- Create: `tests/fixtures/azdo-comments-report-live.json` (a trimmed real payload)
- Modify: `tests/run-forge-adapter-tests.sh` (one case on the live fixture)
- Modify: `scripts/lib/forge.sh`, only if the real format needs it (see check 4)

- [ ] **Step 1: Prepare the sandbox.**
  - Point the sandbox pipeline's `AGENT_WORKFLOW_REF` at the branch head.
  - Set `timeoutInMinutes: 240` in the sandbox YAML.

- [ ] **Step 2: Choose the failure injection, with no production bypass.** The recommended method is a sandbox-YAML-only step that puts a `claude` wrapper first on `PATH`:
  - on its first call, it writes a transient-shaped result (`API Error: 529 Overloaded`) and exits 1;
  - after that, it `exec`s the real `claude`.

  Two alternatives do not work, because one knob cannot fail attempt 1 and pass attempt 2:
  - **`MODEL`:** an invalid Claude model id most likely classifies as `bug`, which never retries.
  - **`IMPLEMENT_TIMEOUT_MIN`:** a short value times out every attempt.

  Record the chosen method in the run note.

- [ ] **Step 3: Run the checks and record each run number and its result.**
  1. **Retry.** Tag a fresh item. Expect:
     - attempt 1 fails `transient`;
     - attempt 2 succeeds;
     - one draft PR, linked;
     - exactly two `## ai-implement run (pipeline, Azure DevOps) — attempt N` comments;
     - the job is green.
  2. **Cap.** Re-tag the same item twice more, until the cap is reached (2 real reports). The next tag must:
     - post `## ai-implement parked`;
     - set the `parked` tag;
     - make no agent call;
     - give a green job.
  3. **Remote branch.** If the injection stub pushed nothing, record that the "branch left on the server" line could not be shown live. Otherwise confirm it appears.
  4. **Workspace.** The run log shows `git clean -ffdx` did not touch the agent-workflow clone in `$(Agent.TempDirectory)`. Attempt 2 started on the default branch.
  5. **Real comment format.** Fetch a posted report back with `az devops invoke --area wit --resource comments …` and check what the API really returns:
     - Does the converted body start with `## ai-implement run`?
     - Do `**Turns:**` and `**Cost:**` survive as text?

     If ADO rendered markdown into `<h2>` or `<strong>`, fix `_forge_azdo_comments_text`, not the cap, and add a Layer-1 case for that format.
  6. **Fixture.** Trim one real payload to `{"comments":[{"id":…,"text":…}]}`. Drop `createdBy`, names, emails, URLs and org data. Run the leak-term grep from memory. Save it as `tests/fixtures/azdo-comments-report-live.json`. Add a forge-adapter case: `check-attempt-cap.sh` counts it as one real attempt.
  7. **Timing.** Record the job duration against the 240-minute budget.

- [ ] **Step 4: Verify.**
  Run: `bash tests/run-all.sh && shellcheck -x -e SC1091 scripts/lib/forge.sh`
  Expected: `failed: 0`.

- [ ] **Step 5: Commit** the run note, the fixture and the test, plus any converter fix.

  ```bash
  git add docs/ai-notes/2026-11-XX-azdo-retry-run.md tests/fixtures/azdo-comments-report-live.json tests/run-forge-adapter-tests.sh
  git commit -m "docs(azdo): record the in-job retry and cap live proof (#573)"
  ```
