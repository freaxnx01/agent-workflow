# Review Failures Are Not `block` Verdicts — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `review-pr.sh` report a review that could not produce a verdict as `review_failed` (own label `ai:review-failed`), retry an unusable agent reply once, and elide over-long diff lines so a minified data file no longer makes a small change unreviewable.

**Architecture:** All verdict logic stays in `scripts/review-pr.sh`: a retry wrapper around the agent call, a `write_failed_result` helper, and an awk pass that elides long diff lines before the size cap. Downstream, `post-auto-review-block.sh` picks the label by verdict, `ensure-issue-labels.sh` registers the new label, and `self-fix-loop.sh` treats `review_failed` as terminal. The workflow passes the review's reason to the blocked step. Only `approve` promotes, so the merge path doesn't change.

**Tech Stack:** Bash 5 (`set -euo pipefail`), `jq`, `awk` (run under `LC_ALL=C`), GitHub Actions YAML, Layer-1 tests in `tests/run-script-tests.sh` with mocks in `tests/mocks/`.

**Spec:** [`docs/superpowers/specs/2026-10-10-review-failed-outcome-design.md`](../specs/2026-10-10-review-failed-outcome-design.md)

## Global Constraints

- New verdict value is exactly `review_failed`. Agent verdicts stay exactly `approve|request_changes|block`; an agent that returns `review_failed` is treated as an invalid verdict.
- Retry happens **once** (two agent calls maximum). The retry prompt is the original prompt plus this line, verbatim: `Your previous reply was not a single JSON object. Reply with only the JSON object.`
- Raw output of each unusable attempt goes to **stderr**, first **4096** bytes, between `--- review agent output (attempt N, first 4096 bytes) ---` and `--- end ---`.
- `review_failed` result JSON: `{"verdict":"review_failed","summary":"<reason>","concerns":[]}`, built with `jq -n --arg`, never `printf` interpolation.
- `MAX_DIFF_LINE_CHARS` defaults to **10000**. A line longer than this (measured by `awk length()` under `LC_ALL=C`, i.e. bytes) is replaced with `[elided by review-pr.sh: a <N>-character line in <file> — too long to review]`.
- Over-cap after eliding → reason `diff size <bytes>B exceeds cap <cap>B after eliding long lines`, verdict `review_failed`. Never `block`.
- New label: `create ai:review-failed D73A4A 'Review could not run to a verdict; human look needed'`.
- `review-pr.sh` exits `0` for every verdict, including `review_failed`.
- Every script keeps `set -euo pipefail` + `IFS=$'\n\t'`; `shellcheck -x -e SC1091` and `actionlint` stay clean.
- Never modify a test to make it green. The existing tests that assert `block` for non-JSON, crash, invalid verdict and oversize are updated to `review_failed`, because that's the behaviour this issue changes.

## Review Focus

- A reviewer reason containing `"` or `\` (e.g. an invalid verdict `lg"tm`) must still produce a valid result JSON. Pinned in Task 1 Step 1 (test "quote in invalid verdict").
- A line of exactly 10000 chars must **not** be elided; 10001 must. Pinned in Task 2 Step 1.
- A deleted file (`+++ /dev/null`) with a long line must name the old path, not `/dev/null`. Pinned in Task 2 Step 1.
- A removed content line that happens to start with `-- a/` (diff line `--- a/…` inside a hunk) must not be mistaken for a file header. Pinned in Task 2 Step 1.
- `review_failed` after self-fix iterations must still get `ai:review-failed`, with the self-fix reason. Pinned in Task 3 Step 1.

---

### Task 1: Retry an unusable review once, then `review_failed`

**Files:**
- Modify: `scripts/review-pr.sh` (header contract lines 38-50; sections 3 and 4, lines ~208-292)
- Modify: `tests/mocks/agent-review`
- Create: `tests/fixtures/review-agent-review-failed.json`
- Test: `tests/run-script-tests.sh` (section `review-pr — verdict paths + idempotency + oversized diff`, ~line 1111)

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: `write_failed_result <reason>` (a shell function in `review-pr.sh`) that writes the `review_failed` JSON to `$RESULT_FILE`. Task 2 calls it, followed by `finish review_failed "$reason" "$RESULT_FILE"`. Mock seams `AGENT_CALL_LOG`, `AGENT_FIXTURE_SEQUENCE`, `AGENT_FAIL_TIMES` in `tests/mocks/agent-review`; Task 2 uses `AGENT_CALL_LOG`.

- [ ] **Step 1: Extend the mock and write the failing tests**

Replace `tests/mocks/agent-review` with:

```bash
#!/usr/bin/env bash
#
# agent-review — review-pr.sh AGENT_CMD mock for Layer-1 tests.
#
# Contract: AGENT_CMD <prompt-file> <result-file>
# We ignore the prompt and copy $AGENT_FIXTURE to $result-file. If
# $AGENT_FAIL is "1" we exit non-zero to simulate a runner crash.
#
# Optional seams (#490):
#   AGENT_CALL_LOG          file; one line per call: "call <n> nudge=<yes|no>".
#                           It is also the call counter the two seams below use.
#   AGENT_FIXTURE_SEQUENCE  comma-separated fixture paths; call n copies entry n
#                           (the last entry repeats). Overrides AGENT_FIXTURE.
#   AGENT_FAIL_TIMES        the first N calls exit non-zero (needs AGENT_CALL_LOG).
set -euo pipefail
IFS=$'\n\t'

n=1
if [[ -n "${AGENT_CALL_LOG:-}" ]]; then
  if [[ -f "$AGENT_CALL_LOG" ]]; then
    n=$(( $(wc -l < "$AGENT_CALL_LOG") + 1 ))
  fi
  nudge=no
  grep -q 'Reply with only the JSON object' "$1" && nudge=yes
  printf 'call %s nudge=%s\n' "$n" "$nudge" >> "$AGENT_CALL_LOG"
fi

if [[ "${AGENT_FAIL:-0}" == "1" ]] || (( n <= ${AGENT_FAIL_TIMES:-0} )); then
  printf 'agent-review mock: simulated failure\n' >&2
  exit 1
fi

if [[ -n "${AGENT_FIXTURE_SEQUENCE:-}" ]]; then
  IFS=',' read -ra seq <<< "$AGENT_FIXTURE_SEQUENCE"
  idx=$(( n - 1 ))
  (( idx < ${#seq[@]} )) || idx=$(( ${#seq[@]} - 1 ))
  cp "${seq[$idx]}" "$2"
  exit 0
fi

: "${AGENT_FIXTURE:?AGENT_FIXTURE must point at a review-*.json fixture}"
cp "$AGENT_FIXTURE" "$2"
```

Create `tests/fixtures/review-agent-review-failed.json`:

```json
{"verdict":"review_failed","summary":"the agent tried to pick the script's outcome","concerns":[]}
```

In `tests/run-script-tests.sh`, change these three existing assertions in the `review-pr — verdict paths` section (they encode the behaviour this issue changes):

```bash
# Malformed agent JSON → retried once, then review_failed (#490)
out="$(review_run review-malformed.json)"
assert_contains "$out" 'verdict=review_failed'   "malformed agent output → verdict=review_failed"
```

```bash
# Agent invocation failure → retried once, then review_failed (#490)
out="$(review_run review-approve.json env AGENT_FAIL=1)"
assert_contains "$out" 'verdict=review_failed'   "agent failure → verdict=review_failed"
```

```bash
assert_contains "$out" 'verdict=review_failed'   "unknown verdict string → verdict=review_failed"
```

(The last one replaces `assert_contains "$out" 'verdict=block' "unknown verdict string → verdict=block"`; the lines above it stay.)

Then add, directly before the `# Idempotency:` comment in that section:

```bash
# #490: an unusable reply is retried once with a nudge, then review_failed.
CALLS="$(mktemp)"; rm -f "$CALLS"
out="$(review_run review-approve.json env AGENT_CALL_LOG="$CALLS" \
        AGENT_FIXTURE_SEQUENCE="$FIXTURES/review-malformed.json,$FIXTURES/review-approve.json")"
assert_contains "$out" 'verdict=approve'          "non-JSON then valid JSON → retry's verdict (#490)"
assert_equals "$(grep -c . "$CALLS")" "2"          "non-JSON then valid → agent called twice (#490)"
assert_contains "$(sed -n 2p "$CALLS")" 'nudge=yes' "retry prompt carries the JSON-only nudge (#490)"
assert_contains "$(sed -n 1p "$CALLS")" 'nudge=no'  "first prompt has no nudge (#490)"
rm -f "$CALLS"

CALLS="$(mktemp)"; rm -f "$CALLS"
err="$( { review_run review-malformed.json env AGENT_CALL_LOG="$CALLS"; } 2>&1 >/dev/null )"
out="$(review_run review-malformed.json)"
assert_contains "$out" 'verdict=review_failed'    "non-JSON twice → review_failed (#490)"
assert_contains "$out" 'non-JSON'                  "review_failed reason names the cause (#490)"
assert_equals "$(grep -c . "$CALLS")" "2"          "non-JSON twice → exactly two agent calls (#490)"
assert_contains "$err" '--- review agent output (attempt 1, first 4096 bytes) ---' "attempt 1 raw output logged (#490)"
assert_contains "$err" '--- review agent output (attempt 2, first 4096 bytes) ---' "attempt 2 raw output logged (#490)"
assert_contains "$err" 'this is not JSON at all'   "raw agent text is in the log (#490)"
rm -f "$CALLS"

summary_file="$(review_run review-malformed.json | sed -n 's/^summary-file=//p')"
assert_equals "$(jq -r .verdict "$summary_file")" "review_failed" "result JSON carries verdict review_failed (#490)"

CALLS="$(mktemp)"; rm -f "$CALLS"
out="$(review_run review-approve.json env AGENT_CALL_LOG="$CALLS" AGENT_FAIL_TIMES=1)"
assert_contains "$out" 'verdict=approve'          "crash then valid → retry's verdict (#490)"
assert_equals "$(grep -c . "$CALLS")" "2"          "crash then valid → two calls (#490)"
rm -f "$CALLS"

out="$(review_run review-agent-review-failed.json)"
assert_contains "$out" 'verdict=review_failed'    "agent-emitted review_failed is invalid → review_failed (#490)"
assert_contains "$out" 'invalid verdict: review_failed' "reason names the invalid agent verdict (#490)"

CALLS="$(mktemp)"; rm -f "$CALLS"
out="$(review_run review-approve.json env AGENT_CALL_LOG="$CALLS")"
assert_equals "$(grep -c . "$CALLS")" "1"          "valid JSON first time → one agent call (#490)"
rm -f "$CALLS"

# Review Focus: a quote in the invalid verdict must not break the result JSON.
QUOTE_VERDICT="$(mktemp --suffix=.json)"
printf '{"verdict":"lg\\"tm","summary":"x","concerns":[]}\n' > "$QUOTE_VERDICT"
summary_file="$(review_run review-approve.json env AGENT_FIXTURE="$QUOTE_VERDICT" | sed -n 's/^summary-file=//p')"
if jq -e . "$summary_file" >/dev/null 2>&1; then
  pass "quote in invalid verdict → result JSON still valid (#490)"
else
  fail "quote in invalid verdict → result JSON still valid (#490)" "$(cat "$summary_file")"
fi
rm -f "$QUOTE_VERDICT"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/run-script-tests.sh 2>&1 | grep -E '✗|tests passed'`
Expected: FAIL. The new `#490` assertions and the three updated ones fail (verdict is still `block`, one agent call).

- [ ] **Step 3: Implement retry + `review_failed` in `scripts/review-pr.sh`**

In the header, replace the `# Output ($GITHUB_OUTPUT):` verdict line and the `# Exit codes:` block with:

```bash
#   verdict       approve | request_changes | block | review_failed
#                 (review_failed: no usable verdict — diff too large after
#                 eliding long lines, or the agent's reply was unusable twice;
#                 #490. block is reserved for a reviewer that refused.)
```

```bash
# Exit codes:
#   0   success (any verdict, including block and review_failed — agent
#       crashes and unusable output are retried once, then normalized to
#       verdict=review_failed, not a non-zero exit, so #15's gating wiring
#       sees a verdict either way)
#   2   required env missing or invalid
#   64  template / fixture missing or unreadable
```

In the `# --- helpers ---` section, after `finish()`, add:

```bash
# #490: the script's own "could not review" outcome. jq builds the JSON so a
# reason containing quotes or backslashes stays valid.
write_failed_result() {
  jq -n --arg r "$1" '{verdict:"review_failed", summary:$r, concerns:[]}' > "$RESULT_FILE"
}
```

Replace everything from the line `if ! "$AGENT_CMD" "$PROMPT_FILE" "$RESULT_FILE"; then` to the end of the file with:

```bash
# --- 4) run + validate, retrying an unusable reply once (#490) ------------

# Agents often wrap the JSON verdict in a ```json fence or a sentence of prose
# (#72). Try the output as-is; if it isn't valid JSON, salvage the object — the
# span from the first line containing `{` to the last line containing `}`, which
# also drops surrounding fences/prose — and re-validate. Returns 0 when
# $RESULT_FILE holds valid JSON; leaves the raw output in place otherwise.
salvage_json() {
  jq -e . "$RESULT_FILE" >/dev/null 2>&1 && return 0
  local salvaged="$WORK_DIR/review-result.salvaged.json"
  awk '
    { lines[NR] = $0 }
    END {
      first = 0; last = 0
      for (i = 1; i <= NR; i++) if (!first && index(lines[i], "{")) first = i
      for (i = NR; i >= 1; i--) if (!last  && index(lines[i], "}")) last  = i
      if (first && last && last >= first)
        for (i = first; i <= last; i++) print lines[i]
    }
  ' "$RESULT_FILE" > "$salvaged"
  if [[ -s "$salvaged" ]] && jq -e . "$salvaged" >/dev/null 2>&1; then
    mv "$salvaged" "$RESULT_FILE"
    return 0
  fi
  return 1
}

# One agent call against prompt $1. Returns 0 when $RESULT_FILE holds one of
# the three agent verdicts; otherwise sets ATTEMPT_REASON and returns 1.
run_review_attempt() {
  local prompt="$1" verdict
  : > "$RESULT_FILE"
  if ! "$AGENT_CMD" "$prompt" "$RESULT_FILE"; then
    ATTEMPT_REASON='agent invocation failed'
    return 1
  fi
  if ! salvage_json; then
    ATTEMPT_REASON='agent produced non-JSON output'
    return 1
  fi
  verdict="$(jq -r '.verdict // ""' "$RESULT_FILE" 2>/dev/null || true)"
  case "$verdict" in
    approve|request_changes|block) return 0 ;;
  esac
  ATTEMPT_REASON="agent returned invalid verdict: ${verdict:-<empty>}"
  return 1
}

# The raw reply is the only evidence of why a review failed (PR #122 left none).
log_unusable_output() {
  printf -- '--- review agent output (attempt %s, first 4096 bytes) ---\n' "$1" >&2
  if [[ -s "$RESULT_FILE" ]]; then
    head -c 4096 "$RESULT_FILE" >&2
    printf '\n' >&2
  else
    printf '<empty>\n' >&2
  fi
  printf -- '--- end ---\n' >&2
}

ATTEMPT_REASON=''
if ! run_review_attempt "$PROMPT_FILE"; then
  log_unusable_output 1
  first_reason="$ATTEMPT_REASON"
  RETRY_PROMPT_FILE="$WORK_DIR/review-prompt-retry.md"
  {
    cat "$PROMPT_FILE"
    printf '\n%s\n' 'Your previous reply was not a single JSON object. Reply with only the JSON object.'
  } > "$RETRY_PROMPT_FILE"
  if ! run_review_attempt "$RETRY_PROMPT_FILE"; then
    log_unusable_output 2
    reason="review failed after retry: ${ATTEMPT_REASON} (first attempt: ${first_reason})"
    write_failed_result "$reason"
    finish review_failed "$reason" "$RESULT_FILE"
  fi
fi

verdict="$(jq -r '.verdict' "$RESULT_FILE")"
reason="agent verdict: $verdict"
finish "$verdict" "$reason" "$RESULT_FILE"
```

The `# --- 3) invoke agent ---` section above stays as-is (it now only builds `AGENT_CMD`). The old `# --- 4) validate result ---` block is fully replaced by the code above.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tests/run-script-tests.sh 2>&1 | grep -E '✗|tests passed'`
Expected: all pass. The oversized-diff test still asserts `block` and still passes here, because Task 1 doesn't touch the size guard; Task 2 changes it.

- [ ] **Step 5: Lint**

Run: `shellcheck -x -e SC1091 scripts/review-pr.sh tests/mocks/agent-review tests/run-script-tests.sh`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add scripts/review-pr.sh tests/mocks/agent-review tests/fixtures/review-agent-review-failed.json tests/run-script-tests.sh
git commit -m "fix(review): retry an unusable review once, then report review_failed (#490)"
```

---

### Task 2: Elide over-long diff lines; over-cap is `review_failed`

**Files:**
- Modify: `scripts/review-pr.sh` (header optional-env block ~line 29; section `1) diff fetch + size guard`, ~lines 170-187)
- Modify: `scripts/lib/review-prompt.md` (just before the final `---` line)
- Modify: `tests/mocks/agent-review` (add `AGENT_PROMPT_COPY`)
- Test: `tests/run-script-tests.sh` (same section)

**Interfaces:**
- Consumes: `write_failed_result <reason>` and `finish review_failed "$reason" "$RESULT_FILE"` from Task 1; mock seam `AGENT_CALL_LOG` from Task 1.
- Produces: env var `MAX_DIFF_LINE_CHARS` (default 10000); the marker format `[elided by review-pr.sh: a <N>-character line in <file> — too long to review]`.

- [ ] **Step 1: Add the prompt-copy seam and write the failing tests**

In `tests/mocks/agent-review`, add to the seam comment block:

```bash
#   AGENT_PROMPT_COPY       if set, the prompt file is copied here on each call.
```

and directly after the `AGENT_CALL_LOG` block (before the failure check) add:

```bash
if [[ -n "${AGENT_PROMPT_COPY:-}" ]]; then
  cp "$1" "$AGENT_PROMPT_COPY"
fi
```

In `tests/run-script-tests.sh`, replace the existing oversized-diff block (from `# Oversized diff → block regardless of agent output` through `rm -f "$BIG_DIFF"`) with:

```bash
# Oversized diff (no long lines to elide) → review_failed, agent not invoked (#490)
BIG_DIFF="$(mktemp)"
head -c 1024 /dev/urandom | base64 > "$BIG_DIFF"
CALLS="$(mktemp)"; rm -f "$CALLS"
out="$(MAX_DIFF_BYTES=10 \
       review_run review-approve.json \
       env DIFF_FILE="$BIG_DIFF" AGENT_CALL_LOG="$CALLS")"
assert_contains "$out" 'verdict=review_failed'   "diff exceeds MAX_DIFF_BYTES → verdict=review_failed (#490)"
assert_contains "$out" 'after eliding long lines' "oversized reason says the cap applied after eliding (#490)"
if [[ -e "$CALLS" ]]; then fail "oversized diff → agent not invoked (#490)" "$(cat "$CALLS")"; else pass "oversized diff → agent not invoked (#490)"; fi
rm -f "$BIG_DIFF" "$CALLS"

# #490: a minified one-line data file is elided; the rest is reviewed.
long_line() { head -c "$1" /dev/zero | tr '\0' 'x'; }
LONG_DIFF="$(mktemp)"
{
  printf 'diff --git a/data/world.json b/data/world.json\n--- a/data/world.json\n+++ b/data/world.json\n@@ -1 +1 @@\n'
  printf -- '-%s\n' "$(long_line 20000)"
  printf '+%s\n' "$(long_line 20000)"
  printf 'diff --git a/src/game.js b/src/game.js\n--- a/src/game.js\n+++ b/src/game.js\n@@ -1 +1 @@\n-old\n+new\n'
} > "$LONG_DIFF"
PROMPT_COPY="$(mktemp)"
out="$(MAX_DIFF_BYTES=4000 review_run review-approve.json env DIFF_FILE="$LONG_DIFF" AGENT_PROMPT_COPY="$PROMPT_COPY")"
assert_contains "$out" 'verdict=approve'          "long minified line elided → review runs (#490)"
assert_contains "$(cat "$PROMPT_COPY")" '[elided by review-pr.sh: a 20001-character line in data/world.json — too long to review]' "marker names length and file (#490)"
assert_contains "$(cat "$PROMPT_COPY")" '+new'    "the reviewable rest of the diff is kept (#490)"
assert_not_contains "$(cat "$PROMPT_COPY")" "$(long_line 200)" "the long line itself is gone (#490)"
rm -f "$LONG_DIFF"

# Review Focus: the threshold is strict (> MAX_DIFF_LINE_CHARS).
EDGE_DIFF="$(mktemp)"
{
  printf 'diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n'
  printf '+%s\n' "$(long_line 9)"   # 10 chars total
  printf '+%s\n' "$(long_line 10)"  # 11 chars total
} > "$EDGE_DIFF"
out="$(MAX_DIFF_LINE_CHARS=10 review_run review-approve.json env DIFF_FILE="$EDGE_DIFF" AGENT_PROMPT_COPY="$PROMPT_COPY")"
assert_contains "$(cat "$PROMPT_COPY")" "+$(long_line 9)" "a line of exactly MAX_DIFF_LINE_CHARS is kept (#490)"
assert_contains "$(cat "$PROMPT_COPY")" 'a 11-character line in a' "one char over the threshold is elided (#490)"
rm -f "$EDGE_DIFF"

# Review Focus: a deleted file names the old path, not /dev/null.
DEL_DIFF="$(mktemp)"
{
  printf 'diff --git a/data/old.json b/data/old.json\ndeleted file mode 100644\n--- a/data/old.json\n+++ /dev/null\n@@ -1 +0,0 @@\n'
  printf -- '-%s\n' "$(long_line 20)"
} > "$DEL_DIFF"
out="$(MAX_DIFF_LINE_CHARS=10 review_run review-approve.json env DIFF_FILE="$DEL_DIFF" AGENT_PROMPT_COPY="$PROMPT_COPY")"
assert_contains "$(cat "$PROMPT_COPY")" 'line in data/old.json' "deleted file → marker names the old path (#490)"
rm -f "$DEL_DIFF"

# Review Focus: a removed content line that looks like a header is not one.
FAKE_DIFF="$(mktemp)"
{
  printf 'diff --git a/real.txt b/real.txt\n--- a/real.txt\n+++ b/real.txt\n@@ -1,2 +1 @@\n'
  printf -- '--- a/not-a-header\n'
  printf '+%s\n' "$(long_line 20)"
} > "$FAKE_DIFF"
out="$(MAX_DIFF_LINE_CHARS=10 review_run review-approve.json env DIFF_FILE="$FAKE_DIFF" AGENT_PROMPT_COPY="$PROMPT_COPY")"
assert_contains "$(cat "$PROMPT_COPY")" 'line in real.txt' "a header-like content line does not change the file (#490)"
rm -f "$FAKE_DIFF" "$PROMPT_COPY"

# The prompt tells the reviewer elided lines are out of scope.
assert_contains "$(cat "$ROOT/scripts/lib/review-prompt.md")" 'elided by review-pr.sh' "review prompt explains elided lines (#490)"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/run-script-tests.sh 2>&1 | grep -E '✗|tests passed'`
Expected: FAIL. The oversize test still gets `block`, no marker in the prompt copy, and the prompt sentence is missing.

- [ ] **Step 3: Implement eliding + `review_failed` on over-cap**

In the `review-pr.sh` header, after the `MAX_DIFF_BYTES` lines, add:

```bash
#   MAX_DIFF_LINE_CHARS  Diff lines longer than this are replaced with an
#                      "[elided by review-pr.sh: …]" marker before the size
#                      cap is measured (#490). Default 10000.
```

After `MAX_DIFF_BYTES="${MAX_DIFF_BYTES:-320000}"` add:

```bash
MAX_DIFF_LINE_CHARS="${MAX_DIFF_LINE_CHARS:-10000}"
```

Replace the block from `diff_bytes="$(wc -c < "$DIFF_FILE" | tr -d ' ')"` through the closing `fi` of the size check with:

```bash
# #490: one minified data line (e.g. a 2.6 MB JSON file) turns a small change
# into a multi-MB diff. Elide over-long lines so the cap measures reviewable
# content. File headers are read only between `diff --git` and the first `@@`,
# so a removed content line that looks like `--- a/x` is not mistaken for one.
ELIDED_DIFF="$WORK_DIR/pr.elided.diff"
LC_ALL=C awk -v max="$MAX_DIFF_LINE_CHARS" '
  /^diff --git / { in_header = 1; file = ""; old = "" }
  /^@@/          { in_header = 0 }
  in_header && /^--- a\// { old = substr($0, 7) }
  in_header && /^\+\+\+ / { file = ($0 == "+++ /dev/null") ? old : substr($0, 7) }
  {
    if (length($0) > max) {
      printf "[elided by review-pr.sh: a %d-character line in %s — too long to review]\n", length($0), (file == "" ? "<unknown file>" : file)
    } else {
      print
    }
  }
' "$DIFF_FILE" > "$ELIDED_DIFF"
DIFF_FILE="$ELIDED_DIFF"

diff_bytes="$(wc -c < "$DIFF_FILE" | tr -d ' ')"
if (( diff_bytes > MAX_DIFF_BYTES )); then
  reason="diff size ${diff_bytes}B exceeds cap ${MAX_DIFF_BYTES}B after eliding long lines"
  write_failed_result "$reason"
  finish review_failed "$reason" "$RESULT_FILE"
fi
```

`substr($0, 7)` drops the six-character prefix `+++ b/` or `--- a/`.

In `scripts/lib/review-prompt.md`, insert this paragraph directly above the final `---` line (the one followed by `{{DIFF}}`):

```markdown
Lines replaced by `[elided by review-pr.sh: …]` were too long to include
(typically minified data or generated files). They are out of scope: do not
flag them, and do not count them against the change.
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tests/run-script-tests.sh 2>&1 | grep -E '✗|tests passed'`
Expected: all `review-pr` assertions pass, including the ADR-002 prompt-template section (the new paragraph doesn't touch the auto-block rules).

- [ ] **Step 5: Lint**

Run: `shellcheck -x -e SC1091 scripts/review-pr.sh tests/mocks/agent-review tests/run-script-tests.sh`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add scripts/review-pr.sh scripts/lib/review-prompt.md tests/mocks/agent-review tests/run-script-tests.sh
git commit -m "fix(review): elide over-long diff lines; an over-cap diff is review_failed (#490)"
```

---

### Task 3: Label `review_failed` as `ai:review-failed`

**Files:**
- Modify: `scripts/post-auto-review-block.sh` (env defaults ~line 50; reason block ~lines 75-90; label block ~lines 107-117)
- Modify: `scripts/ensure-issue-labels.sh` (~lines 104-110)
- Modify: `.github/workflows/agent-implement.yml` (both `post-auto-review-block.sh` steps: AI-merge job ~line 1443, human-merge job ~line 1734)
- Test: `tests/run-script-tests.sh` (`POST_BLOCK` section ~line 1466; `ensure-issue-labels` section ~line 3244)

**Interfaces:**
- Consumes: verdict value `review_failed` and output `reason` from `review-pr.sh` (Tasks 1-2; step id `review`).
- Produces: env var `REVIEW_REASON` read by `post-auto-review-block.sh`; label `ai:review-failed`.

- [ ] **Step 1: Write the failing tests**

In the `POST_BLOCK` section of `tests/run-script-tests.sh`, after the self-mod ordering check, add:

```bash
# #490: review_failed gets its own label and says the review could not complete.
LOG="$(mktemp)"
PATH="$MOCKS:$PATH" GH_MOCK_LOG="$LOG" \
REPO=o/r ISSUE_NUMBER=42 PR_NUMBER=100 FOUND=true VERDICT=review_failed \
REVIEW_REASON='review failed after retry: agent produced non-JSON output (first attempt: agent produced non-JSON output)' \
  bash "$POST_BLOCK" >/dev/null
calls="$(cat "$LOG")"; rm -f "$LOG"
assert_contains "$calls" 'pr comment 100 --repo o/r --body Auto-merge held: review could not complete — review failed after retry: agent produced non-JSON output' "review_failed → comment says the review could not complete (#490)"
assert_contains "$calls" 'label create ai:review-failed --repo o/r' "review_failed → creates ai:review-failed (#490)"
assert_contains "$calls" 'issue edit 42 --repo o/r --add-label ai:review-failed' "review_failed → labels ai:review-failed (#490)"
assert_not_contains "$calls" '--add-label ai:review-blocked' "review_failed → not labelled ai:review-blocked (#490)"

LOG="$(mktemp)"
PATH="$MOCKS:$PATH" GH_MOCK_LOG="$LOG" \
REPO=o/r ISSUE_NUMBER=42 PR_NUMBER=100 FOUND=true VERDICT=block \
  bash "$POST_BLOCK" >/dev/null
calls="$(cat "$LOG")"; rm -f "$LOG"
assert_contains "$calls" 'issue edit 42 --repo o/r --add-label ai:review-blocked' "block → still ai:review-blocked (#490)"

# Review Focus: review_failed after self-fix iterations keeps the self-fix reason and the new label.
LOG="$(mktemp)"
PATH="$MOCKS:$PATH" GH_MOCK_LOG="$LOG" \
REPO=o/r ISSUE_NUMBER=42 PR_NUMBER=100 FOUND=true VERDICT=review_failed \
SELF_FIX_ITERATIONS=2 SELF_FIX_MAX=2 \
  bash "$POST_BLOCK" >/dev/null
calls="$(cat "$LOG")"; rm -f "$LOG"
assert_contains "$calls" 'self-fix exhausted after 2/2 iteration(s) — last verdict: review_failed' "review_failed after self-fix → self-fix reason (#490)"
assert_contains "$calls" '--add-label ai:review-failed' "review_failed after self-fix → ai:review-failed (#490)"

LOG="$(mktemp)"
PATH="$MOCKS:$PATH" GH_MOCK_LOG="$LOG" \
REPO=o/r ISSUE_NUMBER=42 PR_NUMBER=100 FOUND=true VERDICT=review_failed MODE=human-merge \
  bash "$POST_BLOCK" >/dev/null
calls="$(cat "$LOG")"; rm -f "$LOG"
assert_contains "$calls" '--body Review held: review could not complete — no usable verdict from the reviewer' "human-merge + no REVIEW_REASON → default reason (#490)"

# Both blocked steps hand the review reason to post-auto-review-block.sh (#490).
# shellcheck disable=SC2016  # literal GitHub Actions expression, not shell
assert_equals "$(grep -c 'REVIEW_REASON: ${{ steps.review.outputs.reason }}' "$ROOT/.github/workflows/agent-implement.yml")" "2" \
  "both blocked steps pass REVIEW_REASON (#490)"
```

In the `ensure-issue-labels` section, after the `ai:review-blocked` assertion, add:

```bash
assert_contains "$log" 'label create ai:review-failed --repo owner/repo' "creates ai:review-failed (#490)"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/run-script-tests.sh 2>&1 | grep -E '✗|tests passed'`
Expected: FAIL. All new `#490` assertions in these two sections fail.

- [ ] **Step 3: Implement**

In `scripts/post-auto-review-block.sh`, document the new env var in the header's optional-variables list:

```bash
#   REVIEW_REASON     review-pr.sh's reason output; used for the comment when
#                     VERDICT=review_failed and no self-fix ran (#490).
```

After `MODE="${MODE:-ai-merge}"` add:

```bash
REVIEW_REASON="${REVIEW_REASON:-}"
```

Replace the `elif [[ "$VERDICT" != 'approve' ]]; then` branch with:

```bash
elif [[ "$VERDICT" != 'approve' ]]; then
  if [[ "$SELF_FIX_ITERATIONS" != '0' ]]; then
    reason="self-fix exhausted after ${SELF_FIX_ITERATIONS}/${SELF_FIX_MAX} iteration(s) — last verdict: ${VERDICT:-<none>}"
  elif [[ "$VERDICT" == 'review_failed' ]]; then
    reason="review could not complete — ${REVIEW_REASON:-no usable verdict from the reviewer}"
  else
    reason="agent review verdict: ${VERDICT:-<none>} (gate 4)"
  fi
```

Replace the label block (from the `# Label the issue so a watcher…` comment through the final `gh issue edit` line) with:

```bash
# Label the issue so a watcher can filter for review-blocked work.
# #490: a review that produced no usable verdict is a different signal from a
# refusal, so it gets its own label — but only when that is why we are here
# (self-mod guard and no-PR keep ai:review-blocked).
label='ai:review-blocked'
label_desc='Auto-review left the PR draft; human action required'
if [[ "$SELF_MOD_BLOCKED" != 'true' && "$FOUND" == 'true' && "$VERDICT" == 'review_failed' ]]; then
  label='ai:review-failed'
  label_desc='Review could not run to a verdict; human look needed'
fi

# ensure-issue-labels.sh runs earlier in the implement job under
# `always() && !dry-run`, so the label usually exists by the time we
# get here. Belt-and-suspenders: idempotently create it first so a
# manually-deleted label, or a future refactor that splits implement
# and ai_review_ai_merge across separate workflows, doesn't break the
# `--add-label` call.
gh label create "$label" --repo "$REPO" --color D73A4A \
  --description "$label_desc" \
  >/dev/null 2>&1 || true
gh issue edit "$ISSUE_NUMBER" --repo "$REPO" --add-label "$label"
```

In `scripts/ensure-issue-labels.sh`, after the `create ai:checks-blocked …` line add:

```bash
create ai:review-failed D73A4A 'Review could not run to a verdict; human look needed'
```

and extend the "Three blocked states" comment above it to:

```bash
# Four blocked states, deliberately distinct:
#   ai:review-blocked  — the reviewer RAN and refused to promote the PR
#   ai:review-failed   — the reviewer ran but produced no usable verdict (#490)
#   ai:runner-blocked  — the reviewer NEVER STARTED; runner toolchain unmet (#384)
#   ai:checks-blocked  — the PR is fine; its required checks cannot run (#364)
```

In `.github/workflows/agent-implement.yml`, in **both** steps that run `bash .claude-pipeline/scripts/post-auto-review-block.sh` (the AI-merge job's and the human-merge job's), add to `env:` directly after the `VERDICT: ${{ steps.final.outputs.verdict }}` line:

```yaml
          REVIEW_REASON: ${{ steps.review.outputs.reason }}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tests/run-script-tests.sh 2>&1 | grep -E '✗|tests passed'`
Expected: all pass.

- [ ] **Step 5: Lint**

Run: `shellcheck -x -e SC1091 scripts/post-auto-review-block.sh scripts/ensure-issue-labels.sh tests/run-script-tests.sh && actionlint .github/workflows/agent-implement.yml`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add scripts/post-auto-review-block.sh scripts/ensure-issue-labels.sh .github/workflows/agent-implement.yml tests/run-script-tests.sh
git commit -m "fix(review): label a review that produced no verdict ai:review-failed (#490)"
```

---

### Task 4: Self-fix stops on `review_failed`

**Files:**
- Modify: `scripts/self-fix-loop.sh` (header lines ~9-10; stub loop ~line 119; real loop ~line 174)
- Test: `tests/run-script-tests.sh` (`self-fix-loop — bounded fix→re-review cycles` section ~line 1825)

**Interfaces:**
- Consumes: verdict value `review_failed` emitted by `review-pr.sh` (Task 1) through `$GITHUB_OUTPUT`.
- Produces: nothing new. `verdict` / `iterations-used` outputs are unchanged in shape.

- [ ] **Step 1: Write the failing tests**

In the self-fix-loop section, after the `# Fix succeeds but re-review blocks` block, add:

```bash
# #490: a re-review that could not produce a verdict ends the loop too.
LOG="$(mktemp)"
out="$(loop_run "$LOG" 'review_failed,approve')"
assert_contains "$out" 'verdict=review_failed'  "re-review review_failed → stops with verdict=review_failed (#490)"
assert_contains "$out" 'iterations-used=1'      "stops after 1 iteration on review_failed (#490)"
rm -f "$LOG"

go="$(mktemp)"
GITHUB_OUTPUT="$go" \
PR_NUMBER=42 REPO=o/r HEAD_SHA=initsha HEAD_REF=fix-branch \
INITIAL_VERDICT=request_changes MAX_ITERATIONS=3 \
STUB_VERDICT_SEQUENCE='request_changes,review_failed,approve' \
  bash "$SELF_FIX_LOOP" >/dev/null
out="$(cat "$go")"; rm -f "$go"
assert_contains "$out" 'verdict=review_failed'  "stub sequence stops at review_failed (#490)"
assert_contains "$out" 'iterations-used=2'      "stub sequence consumes 2 entries before review_failed (#490)"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/run-script-tests.sh 2>&1 | grep -E '✗|tests passed'`
Expected: FAIL. The loop runs on past `review_failed` (`verdict=approve`).

- [ ] **Step 3: Implement**

In `scripts/self-fix-loop.sh`, change the stub-loop break line to:

```bash
    [[ "$verdict" == "approve" || "$verdict" == "block" || "$verdict" == "review_failed" ]] && break
```

and the real-loop check to:

```bash
    # review_failed (#490): the re-review produced no usable verdict, so its
    # concerns file says nothing a further fix could act on — stop.
    if [[ "$verdict" == "approve" || "$verdict" == "block" || "$verdict" == "review_failed" ]]; then
      break
    fi
```

In the header, change the sentence ending `— a \`block\` or \`approve\` first verdict never reaches here.` to:

```bash
# verdict is `request_changes` and self-fix is enabled — a `block`,
# `review_failed` or `approve` first verdict never reaches here.
```

- [ ] **Step 4: Run the whole suite**

Run: `bash tests/run-all.sh 2>&1 | tail -3`
Expected: `failed: 0`.

- [ ] **Step 5: Lint everything this plan touched**

Run:

```bash
mapfile -t f < <(find scripts tests -type f -name '*.sh' | sort)
shellcheck -x -e SC1091 "${f[@]}" tests/mocks/agent-review
actionlint .github/workflows/agent-implement.yml
```

Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add scripts/self-fix-loop.sh tests/run-script-tests.sh
git commit -m "fix(self-fix): stop the loop when a re-review returns review_failed (#490)"
```

Then push the branch and open a **draft** PR that closes #490.
