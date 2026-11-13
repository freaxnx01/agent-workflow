# Self-updating Software Factory knowledge bundle — design (#601)

## Why

The "Software Factory" Claude Project needs 18 docs from agent-workflow, bridge
and ai-instructions as knowledge. Adding them one by one through the GitHub
picker is tedious and a manual upload goes stale. One generated file in this
repo, synced through the Project's GitHub integration, is add-once, always
current.

## Goal

- `docs/knowledge-bundle.txt` is the only place that lists the sources.
- `scripts/build-knowledge-bundle.sh` concatenates them into
  `docs/generated/software-factory-knowledge.md`, deterministically.
- `.github/workflows/knowledge-bundle.yml` regenerates it on demand, nightly and
  on docs pushes, and lands a change on `main` through an auto-merged PR.

## Non-goals

- Changing the source docs, or anything in bridge or ai-instructions (issue).
- Weakening branch protection (issue; decision 1 below).
- Splitting the bundle by topic, or trimming sources (see author call 1).

## Decisions (operator)

Taken 2026-11-12; they override the issue where they differ.

1. **Write target: App PR plus auto-merge.** `main` is classically protected:
   required checks `gate-selftest` and `test` (both run on every PR, no path
   filter), no reviews, admins not enforced, `allow_auto_merge` true. The
   workflow mints a token with `actions/create-github-app-token`
   (`fee1f7d63c2ff003460e3d139729b119787bc349`, v2.2.2, the pin at
   `.github/workflows/agent-implement.yml:459`) from `PIPELINE_APP_ID` /
   `PIPELINE_APP_PRIVATE_KEY`. It force-pushes the fixed branch
   `chore/knowledge-bundle`, opens a PR or reuses the open one, and runs
   `gh pr merge --auto --squash` with subject
   `chore(docs): regenerate knowledge bundle [skip ci]`. App-authored PRs trigger
   CI; `GITHUB_TOKEN`-authored ones would not. Branch protection is untouched.
2. **`[skip ci]` only on the squash-merge subject**, not on the PR head commit.
   On the head commit the required checks would never run and auto-merge would
   stall.
3. **Token split.** All three repos are public, so the sibling checkouts use the
   default `GITHUB_TOKEN` (`contents: read`). The App token is used only for the
   push, PR and auto-merge step.

## Design

Items marked **(call)** are the author's choices, not the operator's.

### List file `docs/knowledge-bundle.txt`

One `<repo>/<path>` per line; `#` comments and blank lines ignored. Initial set:
the 18 files of the issue. **(call)** Surrounding whitespace and a trailing CR
are trimmed; a `#` after content is not a comment (paths never contain it).

### Script `scripts/build-knowledge-bundle.sh [--root <dir>] [--out <file>]` (call)

- Bash, `set -euo pipefail`, `IFS=$'\n\t'`, shellcheck-clean.
- `--root`: directory that contains `agent-workflow/`, `bridge/` and
  `ai-instructions/` as sibling checkouts. Default: two levels above the script,
  i.e. the parent of the agent-workflow checkout. For
  `~/repos/github/freaxnx01/public/agent-workflow` that is
  `~/repos/github/freaxnx01/public`. From a `.worktrees/<name>` checkout the
  default is wrong, so pass `--root`.
- `--out`: default `<root>/agent-workflow/docs/generated/software-factory-knowledge.md`.
- The list is read from `<root>/agent-workflow/docs/knowledge-bundle.txt`, so the
  directory name `agent-workflow` is part of the contract (CI checks out into it).
- **Preflight before any output.** Every entry is validated first: shape
  `<repo>/<path>`, no `..` segment, the file exists, its repo is a git checkout,
  not shallow, and `git log` knows the path. First failure prints
  `error: ...` naming `<repo>/<path>` and exits 1 (malformed entry or bad
  arguments: exit 2). Only then is the bundle written to a temp file next to the
  target and moved into place, so a failure never leaves a partial or truncated
  bundle and never touches an existing one.
- **Bundle layout.** A fixed preamble (title, "generated, do not edit", "this is
  a snapshot, live state comes from the bridge MCP", how to read the headers),
  then per file a blank line, `# FILE: <repo>/<path> (@<sha>)`, a blank line, the
  file body with a final newline ensured. No timestamp, no run id, no source
  count anywhere.

### No-diff detection and SHAs (call)

- The header SHA is the **last commit touching that path**
  (`git log -1 --format=%H -- <path>`, first 7 characters), not the repo HEAD. An
  unrelated bridge commit therefore does not change the bundle. A content change
  to a file always changes its last-touching commit, so the SHA never hides a
  change; and a rewritten history with identical content changes only the SHA,
  which is a correct diff.
- Short SHA is cut to 7 characters from the full hash, not `%h`, so the length
  cannot vary with the object count of the clone.
- Because that needs history, every checkout in CI uses `fetch-depth: 0`. A
  shallow checkout would report the single commit as "last touching" for every
  file and make the bundle churn (or at least lie), so the script refuses shallow
  repos instead of guessing.
- Change detection runs in the workflow: regenerate, then
  `git status --porcelain -- docs/generated/`. Deviation from "`git diff --quiet`":
  `git diff` does not see an untracked file, so the very first run (no bundle on
  `main` yet) would report "unchanged". `status --porcelain` covers both the
  first run and later ones. Empty output: exit 0, no branch push, no PR.

### Workflow `.github/workflows/knowledge-bundle.yml`

- Triggers: `workflow_dispatch`; `schedule` nightly (`17 3 * * *`, off the
  hour); `push` to `main` with `paths: [README.md, docs/**,
  docs/knowledge-bundle.txt, '!docs/generated/**']`. **(call)** One `paths` list
  with a negation, because GitHub rejects `paths` together with `paths-ignore`.
  Loop safety is layered: the generated file is excluded by path, and the squash
  subject carries `[skip ci]`.
- `concurrency: { group: knowledge-bundle, cancel-in-progress: false }`: a
  running publish finishes; a queued one regenerates from the newer `main`.
- `permissions: contents: read` at workflow level; no job widens it.
- **(call)** The job only runs on `freaxnx01/agent-workflow` at
  `refs/heads/main`: a fork, or a dispatch from a feature branch, must not
  force-push the shared branch from the wrong base.
- Steps: checkout self to `factory/agent-workflow`, bridge to `factory/bridge`,
  ai-instructions to `factory/ai-instructions` (all `fetch-depth: 0`,
  `persist-credentials: false`); build with `--root factory`; detect change; if
  changed, mint the App token, commit on `chore/knowledge-bundle`, force-push,
  create or reuse the PR, enable auto-merge. The head commit message is
  `chore(docs): regenerate knowledge bundle`; the squash subject adds
  ` [skip ci]` (decision 2).
- The push uses an authenticated URL built from the App token for that one
  command; the checkout stores no credential.

### Tests (call)

New runner `tests/run-knowledge-bundle-tests.sh`, picked up by
`tests/run-all.sh` discovery (so `just test` and the CI `test` job run it). Not
added to the 4,600-line `run-script-tests.sh`: the repo's newer scripts have
dedicated runners (`run-caller-permissions-tests.sh` is the model). Fixture repos
are made with `git init` in a temp dir, hermetic (`GIT_CONFIG_GLOBAL=/dev/null`).
Cases: concatenation and header format; last-touching SHA unaffected by an
unrelated commit; comment, blank, CRLF and whitespace handling; missing file
(exit 1, `<repo>/<path>` named, no output file, an existing output untouched);
malformed and traversal entries (exit 2); shallow clone refused; determinism (two
runs byte-identical, also after an unrelated commit). Workflow checks use the
`awk`/`grep` structural idiom of `run-script-tests.sh` (job-body extraction), as
`actionlint` already runs in pre-commit but cannot assert our policy: triggers,
permissions, concurrency, App-token pin equals `agent-implement.yml`'s,
`fetch-depth: 0` on all three checkouts, `[skip ci]` on the merge subject and not
on the commit, `--auto --squash`, no push to `main`.

## Lint interaction (measured)

`pre-commit run --all-files` runs on every PR (`lint.yml`) and would see
`docs/generated/*.md`. Findings:

- `.markdownlint-cli2.yaml` has `globs: "**/*.md"` and no `docs/generated`
  ignore: the bundle would be linted, and heading duplication
  (`# FILE:` plus each source's own `# H1`, MD025 / MD001 / MD024) would fail.
  Fix: add `docs/generated/**` to its `ignores`.
- `trailing-whitespace`, `end-of-file-fixer`, `typos` and `check-added-large-files`
  (500 KB default) have no exclude for it. Sources are clean today (checked: no
  CR, no trailing whitespace in the sampled sources), but a generated file is
  not ours to fix and a hook that rewrites it would fight the generator. Fix:
  `exclude: ^docs/generated/` on those four hooks. `gitleaks` stays on.
- Size: the 18 sources sum to about 357 KB, 71 percent of the 500 KB limit, with
  `DECISIONS.md` (104 KB) the largest.

## Measured: sources exist

All 18 listed files exist on `origin/main` of the three local checkouts
(`~/repos/github/freaxnx01/public/{agent-workflow,bridge,ai-instructions}`,
fetched 2026-11-12). Nothing is missing. Last-touching vs HEAD, for instance:
`agent-workflow/docs/DECISIONS.md` is `e30ea36` against HEAD `b9fd79b`;
`bridge/docs/positioning.md` is `e9529a8` against HEAD `39e99b7`.

## Acceptance criteria

- [ ] Running the workflow on demand produces/updates
      `docs/generated/software-factory-knowledge.md` (via the PR in decision 1).
- [ ] The bundle changes only when content or a source's last-touching commit
      changed (no daily empty PRs); no timestamp, header SHAs only.
- [ ] The **squash-merge subject** is
      `chore(docs): regenerate knowledge bundle [skip ci]`, so the merge to `main`
      triggers no pipelines; the PR head commit carries no `[skip ci]`, so the
      required checks run and auto-merge can complete. *(Reworded from the issue,
      decision 2.)*
- [ ] A missing source file fails the job with `<repo>/<path>` named and writes
      no bundle.
- [ ] The script also runs locally with `--root ~/repos/github/freaxnx01/public`.
- [ ] The README has a short section on the bundle and how to change the list.
- [ ] `pre-commit run --all-files` is green with a generated bundle present.

## Review Focus

1. Loop and stall safety: `[skip ci]` only on the squash subject, `paths`
   negation, App token for the push. Task 3.
2. No partial bundle on any failure; shallow clones refused. Task 1.
3. Determinism: nothing but file content and last-touching SHAs in the output.
   Task 1.
4. Lint exclusions cover every hook that would touch the generated file. Task 4.

## Author calls (accepted by the operator with the design, 2026-11-12)

1. **Bundle size.** 357 KB now, `DECISIONS.md` 29 percent of it; the Claude
   Project's per-file limit is unverified. Call: ship as is,
   dispatch once and watch the Project's sync; trim or split only if it
   complains.
2. **Stale PR.** If the bundle becomes identical to `main` again while the
   PR is open (a revert), the no-diff exit leaves that PR open. Call: accept; it merges to a no-op diff or is closed by hand.

## Discovered, not acted on

- The first bundle is not committed here; the first workflow run creates it,
  so the repo never carries a hand-generated one.
