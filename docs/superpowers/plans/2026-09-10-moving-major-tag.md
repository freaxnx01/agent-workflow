# Moving Major Tag Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publishing a release tag `vX.Y.Z` automatically moves the moving major tag `vX` to that commit — but only when the pushed tag is the highest non-prerelease tag in its major line, so a late hotfix can never drag the moving tag backwards.

**Architecture:** A new `scripts/update-moving-tag.sh` owns all the decision logic and prints its verdict; it is pure with respect to git when handed a tag list, so Layer-1 fixtures can drive every branch with no repository. `.github/workflows/release.yml` — which already fires on a pushed semver tag, from whatever branch the release was cut on — gains a second job that runs the script and force-updates exactly one ref. Docs record the convention.

**Tech Stack:** Bash 5 (`set -euo pipefail`), GitHub Actions, `sort -V` for semver ordering, `shellcheck`, `actionlint`, fixture-driven bash tests in `tests/run-script-tests.sh`.

**Spec:** `docs/superpowers/specs/2026-09-10-moving-major-tag-design.md`

## Global Constraints

- Every bash script starts with `#!/usr/bin/env bash`, `set -euo pipefail`, `IFS=$'\n\t'`. Quote every variable expansion. Use `[[ ... ]]`, never `[ ... ]`. No `eval`.
- Exit codes are API: `0` success (moved **or** deliberately skipped), `2` required env missing or a malformed tag.
- **A skip is not an error.** "This tag is not the newest in its line" is a correct, expected outcome and must exit `0` — a non-zero exit would fail the release workflow on a perfectly good hotfix release.
- No inline bash longer than 5 lines in a YAML step — the logic lives in `scripts/`.
- Do not pin GitHub Actions to floating tags. Do not loosen workflow `permissions:` — `contents: write` goes on the new job only, never at workflow scope.
- The script force-updates exactly one ref pattern, `refs/tags/v<major>`. It must never touch `refs/heads/*` or any other tag.
- Commit messages follow Conventional Commits. **Commit AND PUSH after every task** — every task's final step ends `git commit ... && git push -u origin HEAD`. Work that is committed but never pushed dies with the runner.
- **If the branch already has commits when you start, you are resuming.** Read `git log --oneline origin/main..HEAD`, match subjects against the task list, skip what is already committed, continue from the first that is not.

**Testability contract** (recurs in every task): the script reads its candidate tag list from `$ALL_TAGS` when that variable is set, and only shells out to `git tag -l` when it is not. This mirrors the `ISSUE_LABELS` / `ISSUE_BODY` overrides `classify-turns.sh` already uses, and is what lets the Layer-1 suite cover every ordering branch in milliseconds with no fixture repository.

---

### Task 1: The decision script

All logic, no git writes. Given a pushed tag and the set of existing tags, decide whether the moving tag should move and to what.

**Files:**
- Create: `scripts/update-moving-tag.sh`
- Test: `tests/run-script-tests.sh` (new section, place it after the `classify-turns` section)

**Interfaces:**
- Produces: a script run as `bash scripts/update-moving-tag.sh`.
- Env in: `RELEASE_TAG` (required, e.g. `v1.13.0`); `ALL_TAGS` (optional, newline-separated; skips `git tag -l`); `APPLY` (optional, `true`/`false`, default `false`).
- Writes `moving-tag=<vX|>` and `should-move=<true|false>` and `reason=<text>` to `$GITHUB_OUTPUT` when set; always prints `chosen: <verdict> (<reason>)` to stdout.
- Task 2 wires it.

- [ ] **Step 1: Write the failing tests**

Add to `tests/run-script-tests.sh`:

```bash
section "update-moving-tag — forward-only moves, semver ordering, prerelease refusal"

MOVING_TAG="$ROOT/scripts/update-moving-tag.sh"

# Missing RELEASE_TAG → exit 2
ec="$(run_capture_ec env ALL_TAGS='v1.0.0' bash "$MOVING_TAG")"
assert_equals "$ec" "2" "missing RELEASE_TAG → exit 2"

# Newest in its line → move
out="$(RELEASE_TAG=v1.12.0 ALL_TAGS=$'v1.11.1\nv1.12.0' bash "$MOVING_TAG")"
assert_contains "$out" 'chosen: move v1 → v1.12.0' "newest in line → move"

# NOT newest → skip, and exit 0 (a hotfix release must not fail the workflow)
out="$(RELEASE_TAG=v1.11.2 ALL_TAGS=$'v1.11.1\nv1.11.2\nv1.13.0' bash "$MOVING_TAG")"
assert_contains "$out" 'chosen: skip' "older than an existing release → skip"
assert_contains "$out" 'v1.13.0' "skip reason names the newer tag"
ec="$(run_capture_ec env RELEASE_TAG=v1.11.2 ALL_TAGS=$'v1.11.1\nv1.13.0' bash "$MOVING_TAG")"
assert_equals "$ec" "0" "skip is not an error"

# Semver ordering, not lexical: v1.10.0 > v1.9.0
out="$(RELEASE_TAG=v1.10.0 ALL_TAGS=$'v1.9.0\nv1.10.0' bash "$MOVING_TAG")"
assert_contains "$out" 'chosen: move v1 → v1.10.0' "v1.10.0 beats v1.9.0 (semver, not lexical)"
out="$(RELEASE_TAG=v1.9.0 ALL_TAGS=$'v1.9.0\nv1.10.0' bash "$MOVING_TAG")"
assert_contains "$out" 'chosen: skip' "v1.9.0 loses to v1.10.0 (semver, not lexical)"

# Major derived from the tag, never hardcoded
out="$(RELEASE_TAG=v2.0.0 ALL_TAGS=$'v1.13.0\nv2.0.0' bash "$MOVING_TAG")"
assert_contains "$out" 'chosen: move v2 → v2.0.0' "major derived from the pushed tag"

# A v2 release must not consider v1 tags when picking the newest
out="$(RELEASE_TAG=v2.0.0 ALL_TAGS=$'v1.99.99\nv2.0.0' bash "$MOVING_TAG")"
assert_contains "$out" 'chosen: move v2 → v2.0.0' "v1.99.99 does not block a v2 release"

# Pre-release tags are refused outright
for pre in v1.14.0-rc.1 v1.14.0-alpha.2 v1.14.0-beta.10; do
  ec="$(run_capture_ec env RELEASE_TAG="$pre" ALL_TAGS="$pre" bash "$MOVING_TAG")"
  assert_equals "$ec" "2" "pre-release $pre → exit 2"
done

# Pre-release tags in ALL_TAGS never win the "newest" comparison
out="$(RELEASE_TAG=v1.13.0 ALL_TAGS=$'v1.13.0\nv1.14.0-rc.1' bash "$MOVING_TAG")"
assert_contains "$out" 'chosen: move v1 → v1.13.0' "a newer -rc does not block the release tag"

# Idempotent: the tag is already the newest and already what vX points at
out="$(RELEASE_TAG=v1.13.0 ALL_TAGS=$'v1.11.1\nv1.13.0' bash "$MOVING_TAG")"
assert_contains "$out" 'chosen: move v1 → v1.13.0' "re-running for the same tag is a no-op move"

# Malformed input
ec="$(run_capture_ec env RELEASE_TAG=1.13.0 ALL_TAGS='1.13.0' bash "$MOVING_TAG")"
assert_equals "$ec" "2" "tag without a leading v → exit 2"
ec="$(run_capture_ec env RELEASE_TAG=v1.13 ALL_TAGS='v1.13' bash "$MOVING_TAG")"
assert_equals "$ec" "2" "two-component tag → exit 2"
```

Run `bash tests/run-script-tests.sh` and confirm these fail for the right reason — the script does not exist yet.

- [ ] **Step 2: Write the script**

Create `scripts/update-moving-tag.sh`. Required behaviour, in order:

1. Standard prelude; `require_env RELEASE_TAG` (exit `2`, mirroring `classify-turns.sh`'s helper).
2. Validate `RELEASE_TAG` against `^v[0-9]+\.[0-9]+\.[0-9]+$`. Anything else — a missing `v`, two components, any pre-release or build suffix — exits `2` with a message naming what was received. This is the guard that makes the script safe to call by hand; the workflow trigger already filters, but the script does not trust that.
3. Derive `major="${RELEASE_TAG%%.*}"` → `v1`. Never hardcode.
4. Candidate list: `${ALL_TAGS:-$(git tag -l "${major}.*.*")}`.
5. Filter the candidates to well-formed non-prerelease tags in this major line only — the same regex as step 2, anchored on `^${major}\.`. This is what stops `v1.99.99` from being considered during a `v2` release, and what stops a `-rc` from winning.
6. Pick the newest with `sort -V | tail -1`. **Use `sort -V`; do not hand-roll comparison and do not use plain `sort`** — the `v1.9.0` vs `v1.10.0` tests exist precisely to catch lexical sorting.
7. If the newest is `RELEASE_TAG`, print `chosen: move <major> → <RELEASE_TAG> (<reason>)` and set `should-move=true`. Otherwise print `chosen: skip (<newest> is newer than <RELEASE_TAG>)` and set `should-move=false`. **Both exit `0`.**
8. Write `moving-tag`, `should-move` and `reason` to `$GITHUB_OUTPUT` when it is set.
9. Only when `APPLY` is `true` **and** `should-move` is `true`, perform the write:

```bash
git tag -f "$major" "$RELEASE_TAG^{}"
git push -f origin "refs/tags/$major"
```

   Dereference with `^{}` so an annotated release tag resolves to its commit rather than to the tag object.

Header comment must record *why* the forward-only rule exists (a late `v1.11.2` after `v1.13.0` would silently downgrade every consumer) — this is the non-obvious part and the next reader needs it.

- [ ] **Step 3: Verify**

```bash
bash tests/run-script-tests.sh
shellcheck -x -e SC1091 scripts/update-moving-tag.sh
```

All green, no shellcheck findings.

- [ ] **Step 4: Commit and push**

```bash
git add scripts/update-moving-tag.sh tests/run-script-tests.sh
git commit -m "feat(release): decide when the moving major tag should move (#261)" && git push -u origin HEAD
```

---

### Task 2: Wire it into the release workflow

**Files:**
- Modify: `.github/workflows/release.yml`

**Interfaces:**
- Consumes: `scripts/update-moving-tag.sh` from Task 1.
- Produces: nothing downstream.

- [ ] **Step 1: Add the job**

Add a second job to `release.yml`, alongside the existing `release` job. It must:

- `needs: release` — do not move the moving tag if publishing the GitHub Release failed.
- Carry `permissions: contents: write` **on the job**, not at workflow scope. The existing workflow-level `permissions: contents: read` stays as it is.
- `timeout-minutes: 5`.
- Check out with `fetch-depth: 0` and `fetch-tags: true` — the script compares against every tag in the major line, and a shallow checkout has none of them.
- Run the script as a single `run:` line with `RELEASE_TAG: ${{ github.ref_name }}` and `APPLY: 'true'` in `env:`. One line, so the no-inline-bash constraint holds.
- Append the script's verdict to `$GITHUB_STEP_SUMMARY` so a skip is visible without opening logs.

Configure the pushing identity before the tag push (`git config user.name/user.email` to the `github-actions[bot]` identity) — a bare runner has no committer identity and `git tag -f` on an annotated tag would fail.

- [ ] **Step 2: Verify**

```bash
actionlint
```

Clean. Confirm by reading the file back that `permissions:` at workflow scope is still `contents: read` and that the only `contents: write` is inside the new job.

- [ ] **Step 3: Commit and push**

```bash
git add .github/workflows/release.yml
git commit -m "feat(release): move the moving major tag when a release is published (#261)" && git push -u origin HEAD
```

---

### Task 3: Document the convention

**Files:**
- Modify: `docs/CONSUMER-SETUP.md` (the `@v1` pinning guidance around lines 33–34 and 96–100)
- Modify: `docs/DECISIONS.md` (new ADR)
- Modify: `CHANGELOG.md` (`[Unreleased]` → `### Added`)

**Interfaces:** none — docs only.

- [ ] **Step 1: `docs/CONSUMER-SETUP.md`**

State the contract plainly for a consumer deciding what to pin:

- `@vX` is a **moving** tag that follows the newest non-prerelease `vX.*.*` release.
- It moves automatically when a release is published, so a consumer pinned to `@vX` picks up the new pipeline on its **next dispatch**, with no review step.
- It may point at a commit that is **not on `main`** — a backport release is still a release. `v1` currently points at the `v1.13.0` backport line. "What is released" is answered by the tags, never by `main`.
- Consumers who want pipeline changes to arrive as reviewable PRs should pin an exact `@vX.Y.Z` instead and use Dependabot.

Correct line 33–34's "Use `@v1` once real tags exist; until then a `v1` branch … also resolves" — real tags exist now and that fallback is stale.

- [ ] **Step 2: `docs/DECISIONS.md`**

Add an ADR recording: the moving-tag convention, that it is enforced by `release.yml` rather than by a `justfile` recipe (the `justfile` route assumes `main` and would have missed `v1.12.0`/`v1.13.0`, which were cut on a backport branch), and the forward-only rule with the late-hotfix rationale. Follow the numbering and section shape of the existing ADRs in that file.

- [ ] **Step 3: `CHANGELOG.md`**

One entry under `[Unreleased]` → `### Added`, naming #261 and stating that `@vX` consumers now track releases automatically.

- [ ] **Step 4: Verify**

```bash
just lint
bash tests/run-script-tests.sh
```

Both clean.

- [ ] **Step 5: Commit and push**

```bash
git add docs/CONSUMER-SETUP.md docs/DECISIONS.md CHANGELOG.md
git commit -m "docs(release): record the moving major tag convention (#261)" && git push -u origin HEAD
```

---

## Out of scope

- **The one-time catch-up** (`v1` `v1.11.1` → `v1.13.0`). It force-updates a tag every consumer follows and stays a manual maintainer action, tracked on #261.
- **Logging the resolved pipeline ref** in run output, so "which pipeline version am I running?" is answerable from a log. Raised in #261's 2026-08-27 comment; file separately.
- **Offering consumers exact pinning + a Dependabot entry.** Also raised on #261; separate change.
