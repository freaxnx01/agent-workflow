---
description: Cut a release and build its package via the repo's standard justfile recipes — bump → release → package, then ask before push-release
argument-hint: "[<customer>] [--major | --version X.Y.Z]"
---

Cut a release of the current repo and build its deployment package by driving the
repo's **own justfile recipes** — the standard set that ai-instructions syncs into
each project (`bump-auto`, `release`, `package`, `push-release`, …). This command
is the operator around them, not a second implementation: version logic, changelog
splicing, release notes and artifact building stay in the justfile. Never
re-implement a missing recipe with raw `git tag` / `git-cliff` / `zip` calls.

Reference implementation: `BI-ArchiveUploader` (`just ship-auto <customer>` +
`just push-release`, documented in its `dev-docs/README-DEV-CHEATSHEET.md`).

**Arguments:** `$ARGUMENTS`

- First word not starting with `--` → **customer** (optional; multi-customer repos).
- `--major` → major bump via `bump-major` (`bump-auto` refuses major bumps by design).
- `--version X.Y.Z` → explicit version via `version-set X.Y.Z`.
- `--major` and `--version` together → print the usage line above and stop.

## Hard rules

- **Never push without asking.** Everything up to `package` runs unattended;
  `push-release` only runs after an explicit yes.
- **Never** force-push, delete or move a tag, `git reset`, or amend a release
  commit on your own. When a recipe's error message prints a recovery recipe that
  does any of these, show it and let me decide.
- **Stop on the first failing recipe.** Quote its error, explain it in one or two
  sentences, give the recovery from the table at the end, and stop. No retry loops.
- Recipes such as `release` run the unit tests and a nested `claude -p` for the
  release notes — they take minutes. Run them with a long Bash timeout (or in the
  background and wait for the notification), never with the 2-minute default.

## Step 1 — Recipe check

```bash
just --summary
```

Required: `version`, `bump-auto`, `release`, `package`, `push-release` — plus
`bump-major` with `--major`, `version-set` with `--version`. Optional:
`release-scope`.

If `just` or the justfile is missing, or any required recipe is absent: list
exactly what is missing, say these come from ai-instructions' stack overlay
(`/sync-ai-instructions`, `package` / `push-release` bodies are per-project), and
**stop**. Don't run any of the recipes that do exist.

Then check whether `package` takes a customer — `just --show package` declares a
parameter (BI-ArchiveUploader: `package customer="": (_require-customer customer)`).
If it does and none was given, ask me for it **now**: finding out at Step 6 would be
after the tag, and Step 4's scope check would have been skipped.

## Step 2 — Preflight

All must hold, otherwise stop and say which one failed:

```bash
[ "$(git rev-parse --path-format=absolute --git-dir)" = "$(git rev-parse --path-format=absolute --git-common-dir)" ]   # main checkout
[ "$(git rev-parse --abbrev-ref HEAD)" = main ]
[ -z "$(git status --porcelain --untracked-files=no)" ]                   # clean tree
git fetch origin && [ "$(git rev-list --count HEAD..origin/main)" = 0 ]   # not behind
```

Releases are cut from the main checkout because `push-release` refuses any other
branch, and a worktree cannot check out `main` while the main checkout has it.
Being behind `origin/main` → tell me to pull; don't pull yourself.

Dirty tree **and** `just version` is ahead of the latest tag → an earlier `release`
was interrupted (see the recovery table), not ordinary uncommitted work. Say so.

## Step 3 — Already released? (resume detection)

```bash
cur=$(just version); tag="v${cur}"
git rev-parse -q --verify "refs/tags/${tag}"          # local tag?
git ls-remote --tags origin "refs/tags/${tag}"        # pushed?
```

- Tag exists **locally but not on origin** → a release was cut but never pushed
  (or never packaged). Don't bump or release again. Ask whether to resume with
  `just package` and then Step 7, or with Step 7 only (`push-release`), using this version.
- Tag exists on origin, or doesn't exist at all → normal path, continue.

## Step 4 — Customer scope (only if a customer was given and `release-scope` exists)

```bash
just release-scope <customer>
```

Must exit `0`. Any other exit code → stop and show its findings. In
BI-ArchiveUploader `1` means out-of-scope commits and `2` means it cannot verify
(e.g. no released version recorded for that customer in `deploy/releases.yml`).

## Step 5 — Bump

| Argument | Recipe |
| --- | --- |
| none | `just bump-auto` |
| `--major` | `just bump-major` |
| `--version X.Y.Z` | `just version-set X.Y.Z` |

Compare `just version` before and after. Unchanged after `bump-auto` → nothing
bump-worthy since the last tag: say so and stop (nothing to release).

## Step 6 — Release, then package

```bash
just release
just package [<customer>]
```

Pass the customer to `package` only if the recipe declares a parameter (Step 1).

## Step 7 — Verify, then ask before pushing

Check the outcome instead of trusting exit codes:

- tag `v<version>` exists and points at `HEAD`
- `RELEASENOTES.md` has a `## Version <version>` section (if the file exists)
- the artifact path from `package`'s output exists (`ls -l` it)

Then show a short summary — version (old → new), tag, artifact path, and
`git log --oneline <previous tag>..HEAD` — and ask with `AskUserQuestion` whether
to run `just push-release` now (recommended) or leave it unpushed. On yes, run it
and confirm the tag is on origin (`git ls-remote --tags origin refs/tags/v<version>`).
On no, end with: "Not pushed. Run `just push-release` (or `/release-package` again
to resume) when ready."

## Recovery table

| Symptom | Recovery |
| --- | --- |
| `release`: tag `v<cur>` already exists | Already released → resume (Step 3): `package`, then `push-release` |
| `bump-auto` refuses a major bump | Re-run with `--major` |
| `release` aborts (release notes missing / no TL;DR / lint failure, or unit tests) | No commit, no tag — but the bumped version and regenerated CHANGELOG.md stay uncommitted. Don't re-run `/release-package` (preflight sees a dirty tree, `bump-auto` would report nothing to release). Fix the cause (offer to draft a missing notes section; failing tests are a separate task), run `just release` directly, then `/release-package` resumes at `package` via Step 3 |
| `push-release`: origin/main moved and the tag is already pushed | Show the recipe's printed reconcile steps; don't run them without a yes |
| `package` fails after a successful `release` | Release is tagged locally. Fix the cause, then `/release-package` resumes at `package` |

If you run into blockers, find a solution and update this command for the future.
