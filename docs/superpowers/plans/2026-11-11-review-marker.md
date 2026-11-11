# Review Marker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Append one hidden `<!-- ai-review: {...} -->` line to every GitHub review comment `review-pr.sh` posts, so bridge (#382) can read verdict, head SHA, blocking/nit counts and self-fix state without regexes. The visible comment stays byte-identical.

**Architecture:** `review-pr.sh` gains `render_review_marker`, whose output is the last line of `render_comment`. `SELF_FIX_MAX` reaches it from the workflow's first-review steps and from `self-fix-loop.sh` on re-reviews. New ADR-022 documents the contract.

**Tech Stack:** Bash 5 (`set -euo pipefail`, `IFS=$'\n\t'`), `jq`, GitHub Actions YAML, Layer-1 tests in `tests/run-script-tests.sh`, `shellcheck`.

**Spec:** `docs/superpowers/specs/2026-11-11-review-marker-design.md`

## Global Constraints

- Visible comment unchanged: every byte `render_comment` printed before is still printed, in order; the only addition is one final line. `marker()` (`<!-- review-pr:<sha> -->`, the idempotency key) is untouched.
- Marker format exactly: prefix `<!-- ai-review: `, one compact JSON object, suffix ` -->`; last line of the comment, one `\n` after the `_Agent: …_` line.
- `v` is `1`. Fields and rules: see the spec's table. Omitted, never faked: no `null`, no `0` stand-ins.
- No free text in the marker: never the summary, a concern message or the reason.
- After `jq -nc`, every `<` becomes `<` and every `>` becomes `>`; the line contains `-->` exactly once, at its end.
- GitHub only: no marker when `FORGE != github`.
- Existing tests (`tests/run-script-tests.sh`, `tests/run-azdo-review-tests.sh`, `tests/run-forge-adapter-tests.sh`) pass **unmodified**.
- `post-auto-review-block.sh`, `check-merge-envelope.sh` and every gate are **not** changed.
- Conventional Commits, scope `review`; reference `#593`.

## Review Focus

1. Hostile values (`HEAD_SHA='a-->b<c'`, a concern severity of `x-->y`) keep the marker one HTML comment. Task 1.
2. `SELF_FIX_MAX` / `ITERATION` empty or non-numeric: `self_fix` omitted (or `iterations` defaulted), JSON valid. Task 1.
3. Visible body identical with and without the marker. Task 1.
4. `FORGE=azdo` emits no marker. Task 1.
5. The workflow wiring reaches both review jobs and the loop's re-review. Task 2.

---

### Task 1: `render_review_marker` in `review-pr.sh` (TDD)

**Files:**
- Modify: `scripts/review-pr.sh` (`render_comment`, new function above it; header docs)
- Modify: `tests/run-script-tests.sh` (new block after the existing `review_run` tests, before the idempotency block that starts with `# Idempotency: existing comment with the head-SHA marker`)

**Interfaces:**
- Consumes: `FORGE`, `HEAD_SHA`, `ITERATION` (optional, default 0), `SELF_FIX_MAX` (optional), the result JSON file (`.concerns[].severity`).
- Produces: `render_review_marker <verdict> <json_file>` printing one marker line, or nothing.

- [ ] **Step 1: Write the failing tests**

`review_run` runs with `DRY_RUN=1` and writes the comment to `$RUNNER_TEMP/review-comment.md`; set `RUNNER_TEMP` per case to read it back. Helper and cases:

```bash
# --- #593: ai-review marker ------------------------------------------------
marker_run() {
  # args: <fixture> [extra env assignments...]; prints the rendered comment
  local fixture="$1"; shift
  local tmp; tmp="$(mktemp -d)"
  review_run "$fixture" env RUNNER_TEMP="$tmp" "$@" >/dev/null
  cat "$tmp/review-comment.md"
  rm -rf "$tmp"
}
marker_line() { tail -n1 <<<"$1"; }
marker_json() { marker_line "$1" | sed -n 's/^<!-- ai-review: \(.*\) -->$/\1/p'; }

c="$(marker_run review-request-changes.json SELF_FIX_MAX=2 ITERATION=2)"
assert_contains "$(marker_line "$c")" '<!-- ai-review: {' "request_changes → last line is the marker (#593)"
j="$(marker_json "$c")"
assert_eq "$(jq -r '.v' <<<"$j")" "1" "marker v is 1"
assert_eq "$(jq -r '.verdict' <<<"$j")" "request_changes" "marker verdict"
assert_eq "$(jq -r '.head_sha' <<<"$j")" "abc123" "marker head_sha"
assert_eq "$(jq -r '.blocking' <<<"$j")" "2" "high+medium → blocking 2"
assert_eq "$(jq -r '.nits' <<<"$j")" "0" "no low concerns → nits 0"
assert_eq "$(jq -c '.self_fix' <<<"$j")" '{"iterations":2,"max":2,"exhausted":true}' "iterations>=max on request_changes → exhausted"

c="$(marker_run review-approve.json SELF_FIX_MAX=2)"
j="$(marker_json "$c")"
assert_eq "$(jq -r '.verdict' <<<"$j")" "approve" "approve verdict in marker"
assert_eq "$(jq -c '.self_fix' <<<"$j")" '{"iterations":0,"max":2,"exhausted":false}' "first review, ITERATION unset → iterations 0, not exhausted"

for bad in '' abc '3a'; do
  c="$(marker_run review-approve.json SELF_FIX_MAX="$bad")"
  j="$(marker_json "$c")"
  assert_eq "$(jq -r 'has("self_fix")' <<<"$j")" "false" "SELF_FIX_MAX='$bad' → self_fix omitted"
done

# Exactly one marker, and the visible body is the same with it stripped.
c="$(marker_run review-approve.json)"
assert_eq "$(grep -c '^<!-- ai-review: ' <<<"$c")" "1" "exactly one ai-review marker line"
assert_eq "$(grep -c -- '-->' <<<"$c")" "2" "only the review-pr marker and the ai-review marker close a comment"

# Hostile values cannot break out of the comment.
c="$(marker_run review-approve.json HEAD_SHA='a-->b<c')"
assert_eq "$(grep -c '^<!-- ai-review: ' <<<"$c")" "1" "hostile HEAD_SHA → still one marker"
assert_eq "$(jq -r 'has("head_sha")' <<<"$(marker_json "$c")")" "false" "non-hex HEAD_SHA → head_sha omitted"

# No marker off GitHub.
c="$(marker_run review-approve.json FORGE=azdo)"
assert_eq "$(grep -c 'ai-review' <<<"$c")" "0" "FORGE=azdo → no marker"
```

Notes for the implementer: use the helper names the file already has (`assert_contains`, `pass`/`fail`); if `assert_eq` does not exist, add a two-line one next to `assert_contains`. For `FORGE=azdo` the review script needs `DEFAULT_BRANCH` and an azdo diff source, so if the plain env override aborts, run that case through `tests/run-azdo-review-tests.sh`'s harness instead and assert there that the dry-run comment has no `ai-review`. Add a case with a concern severity of `x-->y` using a temp fixture (`jq` to mutate `review-request-changes.json`), asserting `blocking` counts it and the marker still has one `-->`.

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/run-script-tests.sh 2>&1 | tail -30`
Expected: the new assertions FAIL (no marker yet); all pre-existing assertions pass.

- [ ] **Step 3: Implement**

Insert above `render_comment` in `scripts/review-pr.sh`:

```bash
# #593 / ADR-022: one hidden, machine-readable line at the end of the review
# comment. Display data for consumers (bridge), never a trigger. Fields are
# omitted, never faked; no free text. `<` and `>` are \u-escaped after jq so the
# line can never contain a second `-->`.
render_review_marker() {
  local verdict="$1" json_file="$2"
  [[ "$FORGE" == "github" ]] || return 0

  local sha_arg=() counts='{}' self_fix='{}'
  if [[ "$HEAD_SHA" =~ ^[0-9a-f]{7,64}$ ]]; then
    sha_arg=(--arg head_sha "$HEAD_SHA")
  fi
  if [[ -s "$json_file" ]]; then
    counts="$(jq -c '(.concerns // []) | if type == "array"
      then {blocking: (map(select((.severity // "") != "low")) | length),
            nits: (map(select(.severity == "low")) | length)}
      else {} end' "$json_file" 2>/dev/null || true)"
    [[ -n "$counts" ]] || counts='{}'
  fi
  local max="${SELF_FIX_MAX:-}" iterations="${ITERATION:-0}"
  [[ "$iterations" =~ ^[0-9]+$ ]] || iterations=0
  if [[ "$max" =~ ^[0-9]+$ ]]; then
    self_fix="$(jq -nc --argjson i "$iterations" --argjson m "$max" --arg v "$verdict" \
      '{iterations: $i, max: $m, exhausted: ($v == "request_changes" and $m > 0 and $i >= $m)}')"
  fi

  local line
  line="$(jq -nc --arg verdict "$verdict" "${sha_arg[@]}" \
    --argjson counts "$counts" --argjson self_fix "$self_fix" \
    '{v: 1, verdict: $verdict}
     + (if $ARGS.named.head_sha then {head_sha: $ARGS.named.head_sha} else {} end)
     + $counts
     + (if $self_fix == {} then {} else {self_fix: $self_fix} end)')"
  line="${line//</\\u003c}"
  line="${line//>/\\u003e}"
  printf '<!-- ai-review: %s -->\n' "$line"
}
```

Then, as the last statement inside the `{ … } > "$COMMENT_FILE"` group of `render_comment`, directly after the `printf '_Agent: %s · head: `%s`_\n'` line, add:

```bash
    render_review_marker "$verdict" "$json_file"
```

Update the header comment of `review-pr.sh` (the `Optional environment variables` block) with `ITERATION` and `SELF_FIX_MAX`, and note the marker next to the "comment" description.

Check the `$ARGS.named.head_sha` use: when `head_sha` is not passed, `$ARGS.named.head_sha` is `null`, which the `if` treats as false. If the jq version rejects this, build the object in two steps instead.

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/run-script-tests.sh 2>&1 | tail -30 && bash tests/run-azdo-review-tests.sh 2>&1 | tail -5 && shellcheck scripts/review-pr.sh`
Expected: all PASS, shellcheck clean.

- [ ] **Step 5: Commit**

```bash
git add scripts/review-pr.sh tests/run-script-tests.sh
git commit -m "feat(review): append a machine-readable ai-review marker to the review comment (#593)"
```

---

### Task 2: Feed `SELF_FIX_MAX` to the review steps

**Files:**
- Modify: `.github/workflows/agent-implement.yml` (two `review` steps: the one with `id: review` near line 1398 in the AI-merge job and near line 1772 in the human-merge job)
- Modify: `scripts/self-fix-loop.sh` (the re-review invocation, line ~174)
- Modify: `tests/run-script-tests.sh` or the existing self-fix-loop tests (find with `grep -ln self-fix-loop tests/*.sh`)

**Interfaces:**
- Consumes: `inputs.self-fix-max-iterations` (workflow), `MAX_ITERATIONS` (loop).
- Produces: `SELF_FIX_MAX` in `review-pr.sh`'s environment on every review, first and re-review.

- [ ] **Step 1: Write the failing test.** In the self-fix-loop tests, use the `REVIEW_SCRIPT` override with a stub that records `$SELF_FIX_MAX` and `$ITERATION` to a file; run the loop with `MAX_ITERATIONS=2` and a `request_changes` start; assert the stub saw `SELF_FIX_MAX=2` and `ITERATION=1`.
- [ ] **Step 2: Run, expect FAIL** (`SELF_FIX_MAX` empty in the stub).
- [ ] **Step 3: Implement.** In `self-fix-loop.sh` change the re-review line to also pass `SELF_FIX_MAX="$MAX_ITERATIONS"` (same env-prefix list as `ITERATION="$i"`). In both `id: review` steps of `agent-implement.yml` add `SELF_FIX_MAX: ${{ inputs.self-fix-max-iterations }}` to `env:`. Do not touch the stub-review steps.
- [ ] **Step 4: Run, expect PASS.** Also run `actionlint .github/workflows/agent-implement.yml` if installed, and the full `bash tests/run-all.sh`.
- [ ] **Step 5: Commit** `feat(review): pass the self-fix cap to the review steps (#593)`.

---

### Task 3: ADR-022 and CHANGELOG

**Files:**
- Modify: `docs/DECISIONS.md` (append after ADR-021)
- Modify: `CHANGELOG.md` (`## [Unreleased]`)

- [ ] **Step 1: Append ADR-022** with these sections, mirroring ADR-021's structure (Status accepted, Context, Decision, Consequences). Date the heading with the day it lands:
  1. **One hidden line, at the end.** Literal prefix `<!-- ai-review: `, compact JSON, suffix ` -->`, last line of every GitHub review comment `review-pr.sh` posts, one `\n` after the `_Agent: …_` line. Example line from the spec.
  2. **Fields of `v: 1`.** The table from the spec (`v`, `verdict`, `head_sha`, `blocking`, `nits`, `self_fix.{iterations,max,exhausted}`) with source and presence rules.
  3. **Omitted, never faked; no free text; no breakout** (`jq -nc`, `<`/`>`).
  4. **One marker per review comment, per head SHA.** The verdict for a head is the latest marker whose `head_sha` equals the PR's current head; a consumer offering Merge requires `verdict == "approve"` and that match, and treats everything else, including `block` and `review_failed`, as not approved.
  5. **`exhausted` semantics and the "Review held" comment.** `exhausted` describes the final review on a head; the separate "Review held: self-fix exhausted after N/M iteration(s)" status comment stays human-readable only and has no marker. `exhausted:false` does not mean not held (an aborted loop leaves it false); `verdict` is the gate.
  6. **Versioning.** Same rule as ADR-021 item 7: optional fields are not a bump; rename/remove/retype bumps `v`; unknown `v` means no marker.
  7. **Trust rule for consumers.** (a) read markers only from comments authored by the pipeline's identities: `github-actions[bot]` for first reviews and, when the repo configures the pipeline GitHub App, that App's bot for re-reviews (they post with `steps.app_token.outputs.token || github.token`); (b) the marker is the last line, at most one per comment; (c) unknown `v` is no marker; (d) display and decide *not* to act, and re-check the PR's current head SHA at action time. State the inherited gap from ADR-019/#535.
  8. **Azure DevOps emits no review marker in v1** (same unverified round trip as ADR-021 item 9).
  9. Relation: **extends** ADR-021's pattern, does not amend it; the visible review comment and `<!-- review-pr:<sha> -->` idempotency marker are byte-identical.
- [ ] **Step 2: CHANGELOG.** Under `## [Unreleased]`, `### Added`: "Every GitHub review comment ends with a hidden, machine-readable `<!-- ai-review: {...} -->` line (ADR-022, #593). The visible comment is unchanged."
- [ ] **Step 3: Verify** `grep -c '^## ADR-022' docs/DECISIONS.md` prints `1`; markdown lint if the repo has it (`just lint` or `markdownlint` per `justfile`).
- [ ] **Step 4: Commit** `docs(review): ADR-022 the review marker contract (#593)`.

---

### Task 4: Full verification

- [ ] **Step 1:** `bash tests/run-all.sh` passes; `shellcheck scripts/review-pr.sh scripts/self-fix-loop.sh` clean.
- [ ] **Step 2:** Render a comment by hand with `DRY_RUN=1` and confirm `tail -n1` is the marker and `sed '$d'` of the new comment equals the comment produced by `git stash`-free comparison against `origin/main`'s script (run the old script from `git show origin/main:scripts/review-pr.sh` into a temp file) — visible text identical.
- [ ] **Step 3:** Open the PR (`feat(review): machine-readable ai-review marker (#593)`), `Closes #593`.
