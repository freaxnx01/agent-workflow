# Consolidate Claude Provisioning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the three CLAUDE.md partials and the Claude bootstrap out of `freaxnx01/config` into `freaxnx01/agent-workflow`, so one repo owns all Claude content *and* its provisioning, with no cross-repo clone in either direction.

**Architecture:** A new top-level `partials/` directory holds the `@`-imported CLAUDE.md fragments. A new `setup/link-partials.sh` installs them into `~/.claude/CLAUDE.md` via an idempotent, marker-delimited `awk` rewrite that also sweeps the legacy `config`-era block and stray `config/claude` `@`-lines. `setup/bootstrap.sh` moves here and chains the three `link-*.sh` steps. `config` keeps only a forwarding deprecation stub. Sequenced as two PRs: `agent-workflow` lands first, `config` second.

**Tech Stack:** Bash 5 (`set -euo pipefail`), `awk`, `git`, `jq` (required by `link-hooks.sh`), and the existing `tests/run-script-tests.sh` fixture harness.

## Global Constraints

Values below are copied verbatim from the spec (`docs/superpowers/specs/2026-07-21-consolidate-claude-provisioning-design.md`) and ADR-005/006. Every task's requirements implicitly include this section.

- **Sequencing (hard):** the `agent-workflow` PR must be **merged** before the `config` PR is opened. Reversing it leaves a window with no working bootstrap.
- **Current marker:** `<!-- BEGIN provisioned:claude-partials (managed by setup/link-partials.sh) -->`
- **Legacy marker:** `<!-- BEGIN provisioned:claude-partials (managed by setup/00-claude-partials.sh) -->`
- **Shared end marker (both blocks):** `<!-- END provisioned:claude-partials -->`
- **Canonical import prefix:** `~/repos/github/freaxnx01/public/agent-workflow/partials` — emitted with a literal `~`, never an expanded `$HOME`, so the same line resolves on WSL2, Linux and Windows.
- **New bootstrap URL:** `https://raw.githubusercontent.com/freaxnx01/agent-workflow/main/setup/bootstrap.sh`
- **Old bootstrap URL (must keep working):** `https://raw.githubusercontent.com/freaxnx01/config/main/setup/bootstrap.sh`
- **Version bump:** `1.7.0` → `1.8.0` (minor; new surface, no breaking change for pipeline consumers).
- **ADR number:** 007.
- **Scripts stay `set -euo pipefail`.** Every script keeps the header-comment style of its neighbours in `setup/`.
- **No `markdownlint` / `pre-commit` / `npx` on this host** — CI is the first lint gate. Do not attempt to run them.
- **Writes to `freaxnx01/*` need the `.envrc` token:**
  `direnv exec /home/admin/repos/github/freaxnx01 bash -c '... GH_TOKEN="${GH_TOKEN}" gh ...'`
  For `git push`, bridge the name: `GITHUB_TOKEN="${GH_TOKEN}" git push`.

---

## File Structure

**`agent-workflow`** (branch `docs/133-consolidate-claude-provisioning`, PR #1):

| File | Responsibility |
|---|---|
| `partials/task-checklist.md` | NEW (moved) — numbered-checklist instruction |
| `partials/skill-authoring.md` | NEW (moved) — skill-authoring instruction |
| `partials/subagent-driven-default.md` | NEW (moved) — subagent-driven default |
| `partials/README.md` | NEW (moved) — explains the surface; **not** `@`-imported |
| `setup/link-partials.sh` | NEW — installs partials into `~/.claude/CLAUDE.md`; owns the migration sweep |
| `setup/bootstrap.sh` | NEW (moved) — clone/pull + chain the three link steps |
| `tests/run-script-tests.sh` | MODIFY — append a `setup/` section (first-ever coverage there) |
| `commands/update-commands.md` | MODIFY — repoint off `config/setup/01-claude-commands.sh` |
| `README.md` | MODIFY — document `partials/`, new bootstrap URL, related-repos row |
| `docs/DECISIONS.md` | MODIFY — append ADR-007 |
| `docs/TODO.md` | MODIFY — close the deferred consolidation item |
| `CHANGELOG.md`, `VERSION` | MODIFY — 1.8.0 |

**`config`** (PR #2, opened only after PR #1 merges):

| File | Responsibility |
|---|---|
| `setup/bootstrap.sh` | REWRITE — deprecation stub, forwards to the new URL |
| `setup/00-claude-partials.sh` | DELETE |
| `setup/01-claude-commands.sh` | DELETE |
| `setup/02-claude-hooks.sh` | DELETE |
| `claude/` (4 files) | DELETE |
| `README.md` | MODIFY — honest machine-setup repo; point Claude users here |

---

## Findings from pre-plan verification

Three things were confirmed on this host before writing this plan. They change the implementation and are **not** optional.

1. **`BASH_SOURCE[0]` is unset under `curl … | bash`.** Verified: `echo 'echo "${BASH_SOURCE[0]:-unset}"' | bash` prints `unset`, and `dirname` of it yields `.`. The spec directs `link-partials.sh` to resolve its source dir relative to `BASH_SOURCE` (as `link-hooks.sh:30` does) — but that alone **breaks the advertised one-line bootstrap**, because `./../partials` resolves against an unrelated cwd. Task 1 therefore uses BASH_SOURCE-relative resolution *with a fallback to `$REPO_DIR/partials`*, resolved **after** the clone step. This is a latent bug in `link-hooks.sh`; fixing that script is **out of scope** (noted in Task 3's ADR).
2. **`link-commands.sh:31` uses the `$HOME`-derived `SRC_DIR`**, not the `BASH_SOURCE` form. So it cannot run against a scratch `$HOME`. Task 2's passthrough test therefore symlinks the real repo into the scratch `$HOME` rather than changing `link-commands.sh`. Also out of scope.
3. **`--copy` is already the default in `link-commands.sh:34`** (`mode="copy"`, ADR-005's hazard resolution); the flag is accepted "for compatibility". The spec's rationale — "losing it means Windows silently gets symlinks" — is therefore **stale**: the risk is now inverted, and `--copy` is a no-op. The passthrough test is still worth having (the argument channel must survive stub → bootstrap → link), so Task 2 tests it using `--link`, the flag that actually changes observable behaviour, and additionally asserts `--copy` is accepted without error.

One accepted behaviour change: `link-partials.sh` **enumerates** `partials/*.md` (sorted, excluding `README.md`) instead of hardcoding a list. Adding a partial now installs it automatically. Side effect: import order becomes alphabetical (`skill-authoring`, `subagent-driven-default`, `task-checklist`) rather than the old hardcoded order. The imports are independent instruction blocks, so order carries no meaning.

---

### Task 1: `partials/` + `setup/link-partials.sh` + migration tests

**Files:**
- Create: `partials/task-checklist.md`, `partials/skill-authoring.md`, `partials/subagent-driven-default.md`, `partials/README.md`
- Create: `setup/link-partials.sh`
- Modify: `tests/run-script-tests.sh` (append a section immediately before the `# --- summary ---` block at line ~1736)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `setup/link-partials.sh`, invoked by Task 2's `setup/bootstrap.sh` as `bash "$REPO_DIR/setup/link-partials.sh"`. It accepts one flag, `--no-sync` (skip clone/pull), and exits non-zero if its source `partials/` directory holds no importable `.md`.

- [ ] **Step 1: Copy the four partials in from `config`**

The source repo is already cloned at `/home/admin/repos/github/freaxnx01/public/config` on `main`. Copy (do not `git mv` — separate repos; per-file history stays in `config`'s log, matching ADR-005 §4's precedent):

```bash
cd /home/admin/repos/github/freaxnx01/public/agent-workflow
mkdir -p partials
cp /home/admin/repos/github/freaxnx01/public/config/claude/task-checklist.md          partials/
cp /home/admin/repos/github/freaxnx01/public/config/claude/skill-authoring.md         partials/
cp /home/admin/repos/github/freaxnx01/public/config/claude/subagent-driven-default.md partials/
cp /home/admin/repos/github/freaxnx01/public/config/claude/README.md                  partials/
ls -1 partials/
```

Expected: exactly four files listed.

- [ ] **Step 2: Update `partials/README.md` for its new home**

It was written for `config/claude/`. Read it, then correct every path and installer reference:
- `config/claude/` → `partials/`
- `setup/00-claude-partials.sh` → `setup/link-partials.sh`
- the bootstrap URL → `https://raw.githubusercontent.com/freaxnx01/agent-workflow/main/setup/bootstrap.sh`

Add a line stating that `README.md` itself is **not** `@`-imported (the installer skips it), and that any new `*.md` dropped in this directory **is** imported automatically on the next run.

- [ ] **Step 3: Write the failing test**

Append to `tests/run-script-tests.sh`, immediately **before** the `# --- summary ---` line. The harness already defines `ROOT`, `section`, `pass`, `fail`, `assert_contains`, `assert_not_contains`, `assert_equals` and `run_capture_ec`; use them, add no new helpers.

```bash
# --- setup/link-partials.sh -------------------------------------------------

section "setup/link-partials.sh"

LINK_PARTIALS="$ROOT/setup/link-partials.sh"

# Fresh machine: empty HOME -> block created, all three partials imported.
lp_home1="$(mktemp -d)"
env HOME="$lp_home1" bash "$LINK_PARTIALS" --no-sync >/dev/null 2>&1
lp_md1="$(cat "$lp_home1/.claude/CLAUDE.md")"
assert_contains "$lp_md1" \
  "<!-- BEGIN provisioned:claude-partials (managed by setup/link-partials.sh) -->" \
  "fresh HOME -> managed block created"
assert_contains "$lp_md1" \
  "@~/repos/github/freaxnx01/public/agent-workflow/partials/task-checklist.md" \
  "fresh HOME -> task-checklist imported"
assert_contains "$lp_md1" \
  "@~/repos/github/freaxnx01/public/agent-workflow/partials/skill-authoring.md" \
  "fresh HOME -> skill-authoring imported"
assert_contains "$lp_md1" \
  "@~/repos/github/freaxnx01/public/agent-workflow/partials/subagent-driven-default.md" \
  "fresh HOME -> subagent-driven-default imported"
assert_not_contains "$lp_md1" "partials/README.md" \
  "fresh HOME -> README.md is not imported"

# Idempotency: two consecutive runs leave CLAUDE.md byte-identical.
cp "$lp_home1/.claude/CLAUDE.md" "$lp_home1/snapshot"
env HOME="$lp_home1" bash "$LINK_PARTIALS" --no-sync >/dev/null 2>&1
if diff -q "$lp_home1/snapshot" "$lp_home1/.claude/CLAUDE.md" >/dev/null 2>&1; then
  pass "re-run is byte-idempotent"
else
  fail "re-run is byte-idempotent" \
    "$(diff "$lp_home1/snapshot" "$lp_home1/.claude/CLAUDE.md" | head -5)"
fi

# Migration: seeded legacy block + a stray config/claude line, plus unrelated
# user content that must survive verbatim and in order.
lp_home2="$(mktemp -d)"
mkdir -p "$lp_home2/.claude"
cat > "$lp_home2/.claude/CLAUDE.md" <<'LP_EOF'
# My personal instructions

Always be concise.

<!-- BEGIN provisioned:claude-partials (managed by setup/00-claude-partials.sh) -->
@~/repos/github/freaxnx01/public/config/claude/task-checklist.md
@~/repos/github/freaxnx01/public/config/claude/skill-authoring.md
<!-- END provisioned:claude-partials -->

## A later section

@~/repos/github/freaxnx01/public/config/claude/subagent-driven-default.md

Trailing user note.
LP_EOF
env HOME="$lp_home2" bash "$LINK_PARTIALS" --no-sync >/dev/null 2>&1
lp_md2="$(cat "$lp_home2/.claude/CLAUDE.md")"

assert_not_contains "$lp_md2" "config/claude" \
  "migration -> zero config/claude references remain"
assert_not_contains "$lp_md2" "00-claude-partials.sh" \
  "migration -> legacy marker swept"
assert_equals "$(grep -c 'BEGIN provisioned:claude-partials' "$lp_home2/.claude/CLAUDE.md")" "1" \
  "migration -> exactly one managed block"
assert_contains "$lp_md2" \
  "@~/repos/github/freaxnx01/public/agent-workflow/partials/task-checklist.md" \
  "migration -> new paths present"

# Non-destructive: unrelated user content survives, order preserved.
assert_contains "$lp_md2" "# My personal instructions" "migration -> user heading survives"
assert_contains "$lp_md2" "Always be concise."         "migration -> user prose survives"
assert_contains "$lp_md2" "## A later section"         "migration -> later section survives"
assert_contains "$lp_md2" "Trailing user note."        "migration -> trailing note survives"
lp_seq="$(grep -o 'My personal instructions\|A later section\|Trailing user note' \
  "$lp_home2/.claude/CLAUDE.md" | tr '\n' '|')"
assert_equals "$lp_seq" "My personal instructions|A later section|Trailing user note|" \
  "migration -> user content order preserved"

# Guard: an empty partials/ must hard-fail, never report success having copied nothing.
lp_scratch="$(mktemp -d)"
mkdir -p "$lp_scratch/setup" "$lp_scratch/partials"
cp "$LINK_PARTIALS" "$lp_scratch/setup/link-partials.sh"
lp_home3="$(mktemp -d)"
lp_ec="$(run_capture_ec env HOME="$lp_home3" bash "$lp_scratch/setup/link-partials.sh" --no-sync)"
assert_equals "$lp_ec" "1" "empty partials/ -> hard fail, not silent success"
```

- [ ] **Step 4: Run the tests to verify they fail**

```bash
cd /home/admin/repos/github/freaxnx01/public/agent-workflow
tests/run-script-tests.sh 2>&1 | tail -20
```

Expected: FAIL. `setup/link-partials.sh` does not exist yet, so every assertion in the new section fails (the `cat` of a missing `CLAUDE.md` yields an empty string).

- [ ] **Step 5: Write `setup/link-partials.sh`**

This script is **verified working** — it was prototyped and exercised against all six scenarios above before this plan was written. Write it exactly as given, then add a header comment matching the style of `link-hooks.sh` (purpose, idempotency note, both usage forms).

```bash
#!/usr/bin/env bash
# setup/link-partials.sh
#
# Install agent-workflow's CLAUDE.md partials by @-importing them into the
# user-level ~/.claude/CLAUDE.md.
#
# Idempotent: re-running rewrites the marker block in place, byte-for-byte.
# All unrelated user content is preserved verbatim and in order.
#
# MIGRATION (remove once every machine has run this at least once): this script
# also sweeps the pre-consolidation block written by config's
# setup/00-claude-partials.sh, plus any free-floating @-line pointing into
# config/claude/. Without that sweep the old block survives -- the installer only
# strips markers it matches exactly -- and since the config clone remains on disk,
# BOTH sets of partials load. That failure is silent: no error, no missing file,
# just duplicated instructions.
#
# Usage (existing machine, repo already cloned):
#   ~/repos/github/freaxnx01/public/agent-workflow/setup/link-partials.sh [--no-sync]
#
# Usage (new machine, nothing cloned yet -- single-line bootstrap):
#   curl -fsSL https://raw.githubusercontent.com/freaxnx01/agent-workflow/main/setup/link-partials.sh | bash

set -euo pipefail

REPO_URL="https://github.com/freaxnx01/agent-workflow.git"
REPO_DIR="$HOME/repos/github/freaxnx01/public/agent-workflow"
CLAUDE_MD="$HOME/.claude/CLAUDE.md"

# Emitted with a literal ~ so Claude resolves it on whatever machine you're on
# (WSL2/Linux and Windows both expand ~ to the home dir). Never $HOME-expanded.
CANON="~/repos/github/freaxnx01/public/agent-workflow/partials"

BEGIN="<!-- BEGIN provisioned:claude-partials (managed by setup/link-partials.sh) -->"
LEGACY_BEGIN="<!-- BEGIN provisioned:claude-partials (managed by setup/00-claude-partials.sh) -->"
END="<!-- END provisioned:claude-partials -->"

sync=1
for arg in "$@"; do
  case "$arg" in
    --no-sync) sync=0 ;;
  esac
done

# 1) Clone or fast-forward at the canonical path (unless --no-sync).
if [ "$sync" = 1 ]; then
  if [ ! -d "$REPO_DIR/.git" ]; then
    echo "→ cloning agent-workflow repo to $REPO_DIR"
    mkdir -p "$(dirname "$REPO_DIR")"
    git clone "$REPO_URL" "$REPO_DIR"
  else
    echo "→ pulling latest at $REPO_DIR"
    git -C "$REPO_DIR" pull --ff-only
  fi
fi

# 2) Resolve the source dir AFTER any clone. Prefer this script's own checkout so
#    a scratch $HOME (tests) reads real partials rather than silently finding none.
#    Fall back to the canonical path because under `curl … | bash` BASH_SOURCE is
#    UNSET -- dirname yields "." and the relative guess would resolve against an
#    unrelated cwd. Verified on bash 5.2.
_src_guess="$(dirname "${BASH_SOURCE[0]:-$0}")/../partials"
if [ -d "$_src_guess" ]; then
  SRC_DIR="$(cd "$_src_guess" && pwd)"
else
  SRC_DIR="$REPO_DIR/partials"
fi

# 3) Enumerate the partials to import. README.md documents the surface and is not
#    an instruction fragment, so it is excluded -- same convention as
#    link-commands.sh. Sorted for a deterministic, byte-idempotent block.
mapfile -t partial_files < <(find "$SRC_DIR" -maxdepth 1 -type f -name '*.md' ! -name 'README.md' | sort)
if [ ${#partial_files[@]} -eq 0 ]; then
  echo "✗ no partials found in $SRC_DIR" >&2
  exit 1
fi

PARTIALS=()
for f in "${partial_files[@]}"; do
  PARTIALS+=("$CANON/$(basename "$f")")
done

# 4) Make sure ~/.claude/CLAUDE.md exists.
mkdir -p "$(dirname "$CLAUDE_MD")"
[ -f "$CLAUDE_MD" ] || : > "$CLAUDE_MD"

# 5) Compose the desired marker block.
block_file="$(mktemp)"
tmp="$(mktemp)"
trap 'rm -f "$block_file" "$tmp" "$tmp.trim"' EXIT
{
  printf '%s\n' "$BEGIN"
  for p in "${PARTIALS[@]}"; do printf '@%s\n' "$p"; done
  printf '%s\n' "$END"
} > "$block_file"

# 6) Normalize in a single awk pass: strip the current block (idempotency), the
#    legacy block (migration), and any stray @-line pointing at either partials
#    location. Everything else is passed through untouched.
echo "→ normalizing $CLAUDE_MD"
awk -v beg="$BEGIN" -v legacy="$LEGACY_BEGIN" -v end="$END" '
  $0 == beg || $0 == legacy { skip=1; next }
  $0 == end                 { skip=0; next }
  skip                      { next }
  /^@/ && (index($0, "/config/claude/") || index($0, "/agent-workflow/partials/")) { next }
  { print }
' "$CLAUDE_MD" > "$tmp"

# Trim trailing blank lines so re-runs are byte-idempotent (otherwise each run
# accumulates an extra blank line before the block).
awk 'BEGIN{n=0} {buf[++n]=$0} END{
  while (n>0 && buf[n]=="") n--
  for (i=1; i<=n; i++) print buf[i]
}' "$tmp" > "$tmp.trim" && mv "$tmp.trim" "$tmp"

# Append exactly one separating blank line + the managed block.
[ -s "$tmp" ] && printf '\n' >> "$tmp"
cat "$block_file" >> "$tmp"
mv "$tmp" "$CLAUDE_MD"

echo "✓ done — start a new Claude Code session to pick up the partials"
```

Then make it executable — the other `setup/` scripts are mode `755`:

```bash
chmod +x setup/link-partials.sh
```

- [ ] **Step 6: Run the tests to verify they pass**

```bash
tests/run-script-tests.sh 2>&1 | tail -25
```

Expected: PASS, with 14 new assertions under the `── setup/link-partials.sh ──` section and the overall count risen by 14. The final line must read `✓ N/N tests passed`.

- [ ] **Step 7: Commit**

```bash
git add partials/ setup/link-partials.sh tests/run-script-tests.sh
git commit -m "feat(setup): own CLAUDE.md partials and add link-partials.sh (#133)

Move the three @-imported partials out of freaxnx01/config into partials/,
and add setup/link-partials.sh to install them. The installer sweeps the
legacy config-era marker block and stray config/claude @-lines, so a machine
does not silently load both sets after migrating.

Resolves the source dir from BASH_SOURCE with a fallback to the canonical
path: BASH_SOURCE is unset under \`curl | bash\`, so the relative form alone
would break the one-line bootstrap.

First test coverage for setup/ (14 assertions)."
```

---

### Task 2: `setup/bootstrap.sh` + flag passthrough + `update-commands.md`

**Files:**
- Create: `setup/bootstrap.sh`
- Modify: `commands/update-commands.md`
- Modify: `tests/run-script-tests.sh` (append after Task 1's section, before `# --- summary ---`)

**Interfaces:**
- Consumes: `setup/link-partials.sh` from Task 1 (invoked as `bash "$REPO_DIR/setup/link-partials.sh" "$@"`).
- Produces: `setup/bootstrap.sh`, the single machine entry point. Forwards all arguments verbatim to each link step. Recognises `--no-sync` itself (skip its own clone/pull) and passes it down.

> **Why `update-commands.md` is in this task and not Task 3:** the spec's hazard table requires it be fixed "in the same commit as the move", because it *is* the recovery path — a stale installed copy cannot repair itself. It points at `config/setup/01-claude-commands.sh`; its replacement is the `setup/bootstrap.sh` created here.

- [ ] **Step 1: Write the failing test**

Append to `tests/run-script-tests.sh`, before `# --- summary ---`.

`link-commands.sh:31` derives `SRC_DIR` from `$HOME`, not `BASH_SOURCE`, so it cannot read a scratch `$HOME`. Symlink the real repo into the scratch home rather than modifying that script (out of scope).

```bash
# --- setup/bootstrap.sh -----------------------------------------------------

section "setup/bootstrap.sh"

BOOTSTRAP="$ROOT/setup/bootstrap.sh"

# link-commands.sh resolves its source from $HOME (not BASH_SOURCE), so a scratch
# HOME needs the canonical path to point back at the real checkout.
bs_home="$(mktemp -d)"
mkdir -p "$bs_home/repos/github/freaxnx01/public"
ln -s "$ROOT" "$bs_home/repos/github/freaxnx01/public/agent-workflow"

# Default (no flags): commands are COPIED (link-commands.sh's default since ADR-005).
bs_out="$(env HOME="$bs_home" bash "$BOOTSTRAP" --no-sync 2>&1)"
assert_contains "$bs_out" "copied" "bootstrap default -> commands copied"
assert_contains "$bs_out" "normalizing" "bootstrap -> link-partials step ran"
assert_contains "$bs_out" "installing hooks" "bootstrap -> link-hooks step ran"
assert_contains "$(cat "$bs_home/.claude/CLAUDE.md")" \
  "@~/repos/github/freaxnx01/public/agent-workflow/partials/task-checklist.md" \
  "bootstrap -> partials landed in CLAUDE.md"

# Argument passthrough: --link must survive bootstrap -> link-commands.sh and
# flip the observable install mode. This is the channel --copy also travels.
bs_home2="$(mktemp -d)"
mkdir -p "$bs_home2/repos/github/freaxnx01/public"
ln -s "$ROOT" "$bs_home2/repos/github/freaxnx01/public/agent-workflow"
bs_out2="$(env HOME="$bs_home2" bash "$BOOTSTRAP" --no-sync --link 2>&1)"
assert_contains "$bs_out2" "linked" "--link passes through bootstrap to link-commands"
assert_not_contains "$bs_out2" "  copied  " "--link -> nothing copied"

# --copy is accepted end-to-end (it is already the default, so it is a no-op --
# but the flag must not error, since old notes and the deprecation stub pass it).
bs_home3="$(mktemp -d)"
mkdir -p "$bs_home3/repos/github/freaxnx01/public"
ln -s "$ROOT" "$bs_home3/repos/github/freaxnx01/public/agent-workflow"
bs_ec="$(run_capture_ec env HOME="$bs_home3" bash "$BOOTSTRAP" --no-sync --copy)"
assert_equals "$bs_ec" "0" "--copy accepted end-to-end"
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
tests/run-script-tests.sh 2>&1 | tail -20
```

Expected: FAIL — `setup/bootstrap.sh` does not exist, so `bash "$BOOTSTRAP"` errors and every assertion in the new section fails.

- [ ] **Step 3: Write `setup/bootstrap.sh`**

```bash
#!/usr/bin/env bash
# setup/bootstrap.sh — one-shot setup of every Claude surface this repo owns.
#
# Clones (or pulls) agent-workflow, then runs all three link steps in order:
#   link-partials  → @-imports into ~/.claude/CLAUDE.md
#   link-commands  → slash commands into ~/.claude/commands/
#   link-hooks     → handoff-resume SessionStart(clear) hook + settings.json wiring
#
# No other repo is cloned at any point: this repo owns all Claude content AND its
# provisioning (ADR-007).
#
# Idempotent — safe to re-run to update a machine after a `git pull`.
#
# New machine, nothing cloned yet (single line):
#   curl -fsSL https://raw.githubusercontent.com/freaxnx01/agent-workflow/main/setup/bootstrap.sh | bash
#
# Flags are forwarded verbatim to every step, e.g. --link to symlink commands
# while actively editing them:
#   curl -fsSL .../setup/bootstrap.sh | bash -s -- --link

set -euo pipefail

REPO_URL="https://github.com/freaxnx01/agent-workflow.git"
REPO_DIR="$HOME/repos/github/freaxnx01/public/agent-workflow"

sync=1
for arg in "$@"; do
  case "$arg" in
    --no-sync) sync=0 ;;
  esac
done

# Sync once here; each link step then runs with --no-sync so three consecutive
# pulls don't race the same checkout.
if [ "$sync" = 1 ]; then
  if [ ! -d "$REPO_DIR/.git" ]; then
    echo "→ cloning agent-workflow repo to $REPO_DIR"
    mkdir -p "$(dirname "$REPO_DIR")"
    git clone "$REPO_URL" "$REPO_DIR"
  else
    echo "→ pulling latest at $REPO_DIR"
    git -C "$REPO_DIR" pull --ff-only
  fi
fi

bash "$REPO_DIR/setup/link-partials.sh" --no-sync "$@"
bash "$REPO_DIR/setup/link-commands.sh" --no-sync "$@"
bash "$REPO_DIR/setup/link-hooks.sh"    --no-sync "$@"

echo
echo "✓ bootstrap complete — start a new Claude Code session, then run /commands and /memory to verify."
```

```bash
chmod +x setup/bootstrap.sh
```

> Note: `--no-sync` is passed explicitly *and* may appear again in `"$@"`. All three link steps parse flags in a `for … case` loop where a repeated flag is idempotent, so this is safe.

- [ ] **Step 4: Run the tests to verify they pass**

```bash
tests/run-script-tests.sh 2>&1 | tail -25
```

Expected: PASS — 7 new assertions under `── setup/bootstrap.sh ──`, overall count up 21 from the pre-Task-1 baseline.

- [ ] **Step 5: Repoint `commands/update-commands.md`**

Rewrite so it no longer references `config`. Three specific changes:

1. The body paragraph currently reading "``config`` keeps the CLAUDE.md partials and remains the one-URL machine bootstrap; its installer delegates both commands and hooks to agent-workflow." — replace with a statement that `agent-workflow` now owns partials, commands, hooks **and** the bootstrap, and `config` no longer takes part.
2. Step 1's command block: replace
   `bash ~/repos/github/freaxnx01/public/config/setup/01-claude-commands.sh`
   with
   `bash ~/repos/github/freaxnx01/public/agent-workflow/setup/bootstrap.sh`
   and update the prose above it — it pulls agent-workflow once, then runs all three link steps.
3. Step 2's diff block: drop the `config` line, keep only the `agent-workflow` one:

```bash
git -C ~/repos/github/freaxnx01/public/agent-workflow log --oneline @{1}.. 2>/dev/null
```

Leave the closing Notes section (the read-only note and the `/sync-ai-instructions` disambiguation) intact.

- [ ] **Step 6: Verify no stale reference remains in the command**

```bash
grep -n "config" commands/update-commands.md
```

Expected: no line referencing `config/setup` or `freaxnx01/config`. (A match inside the `/sync-ai-instructions` note is fine only if it does not name `config` as an installer.)

- [ ] **Step 7: Commit**

```bash
git add setup/bootstrap.sh commands/update-commands.md tests/run-script-tests.sh
git commit -m "feat(setup): move bootstrap here and repoint /update-commands (#133)

setup/bootstrap.sh becomes the single machine entry point, chaining the three
link steps with no cross-repo clone. Flags are forwarded verbatim.

/update-commands pointed at config/setup/01-claude-commands.sh. It is the
recovery path, so a stale installed copy cannot repair itself -- repointed in
the same commit that creates its replacement.

7 assertions covering the flag-passthrough channel."
```

---

### Task 3: Documentation, ADR-007, and the 1.8.0 bump

**Files:**
- Modify: `README.md` (lines ~126-135 "Refreshing", line ~152 related-repos row)
- Modify: `docs/DECISIONS.md` (append after ADR-006)
- Modify: `docs/TODO.md` (the "Deferred" item at ~line 76)
- Modify: `CHANGELOG.md` (new section above `## [1.7.0]`)
- Modify: `VERSION`

**Interfaces:**
- Consumes: `setup/bootstrap.sh` (Task 2) and `setup/link-partials.sh` (Task 1) — both referenced by name in the docs written here.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Update `README.md` — the "Refreshing" section**

Replace the code block at line ~129 and the paragraph beneath it:

````markdown
```bash
# partials + commands + hooks — one idempotent installer, one repo
bash ~/repos/github/freaxnx01/public/agent-workflow/setup/bootstrap.sh
```

`/update-commands` is a thin wrapper around exactly that, and reports what changed.
This repo is now the one-URL machine bootstrap: it owns the partials, the commands
and the hooks, so nothing else is cloned.
````

- [ ] **Step 2: Update `README.md` — the related-repos row**

Replace the `config` row at line ~152:

```markdown
| [`config`](https://github.com/freaxnx01/config) | Machine setup: shell, oh-my-posh prompt, Windows tooling. No Claude content |
```

- [ ] **Step 3: Document the `partials/` surface in `README.md`**

Section "1 — This repo: the user-level console" (line 31) describes `commands/` and `hooks/`. Add a short subsection documenting `partials/`: three `@`-imported CLAUDE.md fragments installed by `setup/link-partials.sh`, applying to every project; `README.md` in that directory is not imported; new `*.md` files are picked up automatically. Add the one-line new-machine bootstrap:

```bash
curl -fsSL https://raw.githubusercontent.com/freaxnx01/agent-workflow/main/setup/bootstrap.sh | bash
```

- [ ] **Step 4: Append ADR-007 to `docs/DECISIONS.md`**

Match the house format exactly — `## ADR-NNN — Title (YYYY-MM-DD)` then `### Context`, `### Decision`, `### Consequences` with `+`-prefixed bullets. Append after ADR-006, separated by `---`.

```markdown
## ADR-007 — agent-workflow owns Claude content and its provisioning (2026-07-21)

### Context

ADR-005 moved the operator console here but left `config` as the bootstrap
orchestrator; #128 moved the remaining commands and the `handoff-resume` hook.
What stayed behind was the awkward part: `config` held the three CLAUDE.md
partials and all four setup scripts, so it owned the provisioning contract for a
surface that lives entirely here. Two of its four scripts existed only to clone
this repo and call its link steps.

Moving `setup/` alone would not remove that cross-repo clone — it would
**invert** it: `00-claude-partials.sh` `@`-imports config's own `claude/*.md`, so
a relocated bootstrap would have to clone `config` to find them. Only moving the
partials and the bootstrap together eliminates the dependency.

### Decision

1. **`partials/` is a new top-level surface here**, alongside `commands/` and
   `hooks/`. `setup/link-partials.sh` installs it.
2. **`setup/bootstrap.sh` moves here** and becomes the one-URL machine entry
   point. It clones nothing but this repo.
3. **`config/setup/01-claude-commands.sh` and `02-claude-hooks.sh` are deleted** —
   pure shims once `bootstrap.sh` sits beside the link steps they delegated to.
4. **The old bootstrap URL keeps working** via a deprecation stub in `config` that
   forwards arguments and prints the new URL. Old notes and muscle memory do not
   break.
5. **Files are copied, not history-grafted** — per-file history stays in `config`'s
   log, as in ADR-005 §4.

### Consequences

+ `config` becomes an honest machine-setup repo: shell, prompt, Windows tooling.
  Its README no longer has to describe two unrelated jobs.
+ **Sequencing is load-bearing.** The `agent-workflow` PR must land before the
  `config` PR; reversing it leaves a window where no bootstrap works.
+ **Migration is silent if botched.** `link-partials.sh` sweeps the legacy marker
  block and stray `config/claude` `@`-lines, because the installer only strips
  markers it matches exactly — and the `config` clone stays on disk, so a
  surviving old block loads a second, duplicate set of instructions with no error
  and no missing file. Covered by a migration test; the sweep can be removed once
  every machine has run the new installer at least once.
+ `setup/` gains its **first test coverage** (21 assertions in
  `tests/run-script-tests.sh`). It was entirely untested before.
+ **`BASH_SOURCE` is unset under `curl … | bash`.** `link-partials.sh` therefore
  resolves its source dir relative to `BASH_SOURCE` *with a fallback* to the
  canonical path. `link-hooks.sh` uses the relative form alone and advertises a
  `curl` usage in its header — a latent bug, left unfixed here to keep this change
  scoped; worth a follow-up.
+ **`link-commands.sh` still derives its source dir from `$HOME`**, so it cannot
  run against a scratch `$HOME`; the bootstrap test symlinks the real checkout in.
  Also left for a follow-up.
```

- [ ] **Step 5: Close the deferred item in `docs/TODO.md`**

The item beginning "**`config` still does two jobs.**" (~line 76) described a pre-consolidation state: "After the 2026-07-21 consolidation it holds only CLAUDE.md partials + the bootstrap". That is now wrong — it holds neither. Rewrite the item to reflect the true remaining question, and keep the user-consultation flag:

```markdown
- [ ] **`config`'s remaining content has no clear home.** ADR-007 removed all
  Claude content and the bootstrap from `config`, leaving `oh-my-posh/` (3 files)
  and `windows/` (8 files) — both installed manually. The repo name no longer
  describes them.

  **The user asked to be consulted before this is started** (2026-07-21).
  `dotfiles` is not a candidate — it was archived the same day. Open question:
  a new repo, a rename, or leave it and fix the README.
```

Add a follow-up item near the other script items:

```markdown
- [ ] `link-hooks.sh` and `link-commands.sh` source-dir resolution — the first
  breaks under `curl | bash` (BASH_SOURCE unset), the second cannot run against a
  scratch `$HOME`. `link-partials.sh` has the correct pattern; port it (ADR-007).
```

- [ ] **Step 6: Bump `VERSION` and write the `CHANGELOG.md` entry**

```bash
printf '1.8.0\n' > VERSION
```

Insert above `## [1.7.0]`, matching the Keep-a-Changelog format already used:

```markdown
## [1.8.0](https://github.com/freaxnx01/agent-workflow/releases/tag/v1.8.0) - 2026-07-21

### Added — this repo is now the machine bootstrap

**`partials/` and `setup/bootstrap.sh` move here from `freaxnx01/config`** (ADR-007,
#133). agent-workflow now owns every Claude surface — partials, commands, hooks —
*and* the provisioning that installs them. No cross-repo clone remains.

New machine, one line:

```bash
curl -fsSL https://raw.githubusercontent.com/freaxnx01/agent-workflow/main/setup/bootstrap.sh | bash
```

The old `config` URL still works — it forwards, and prints the new one.

**Existing machines:** re-run the bootstrap above (or `/update-commands`). The
installer sweeps the old `config`-era marker block automatically, so the partials
do not load twice. No manual edit of `~/.claude/CLAUDE.md` is needed.

- **setup:** `partials/` surface + `link-partials.sh` with legacy-block migration (#133)
- **setup:** `bootstrap.sh` moves here; verbatim flag passthrough to all link steps (#133)
- **tests:** first coverage for `setup/` — 21 assertions (#133)

### Changed

- **commands:** `/update-commands` runs this repo's bootstrap, not config's installer (#133)
- **docs:** README documents the `partials/` surface and the new bootstrap URL (#133)
```

Nothing in this release changes the reusable-workflow interface, so consumers need no action — state that explicitly if the changelog's house style includes a consumer-impact line (check the 1.7.0 entry and match).

- [ ] **Step 7: Verify the whole suite still passes and no stale paths remain**

```bash
tests/run-script-tests.sh 2>&1 | tail -5
grep -rn "config/setup\|config/claude" --include=*.md --include=*.sh . | grep -v '^./.git/' | grep -v 'docs/superpowers/'
```

Expected: suite green. The grep must return **no** hits outside `docs/superpowers/` (specs and plans legitimately quote the old paths as history).

- [ ] **Step 8: Commit**

```bash
git add README.md docs/DECISIONS.md docs/TODO.md CHANGELOG.md VERSION
git commit -m "docs: ADR-007, README partials surface, 1.8.0 (#133)

Record the consolidation as ADR-007, document the partials/ surface and the
new bootstrap URL, correct the now-stale TODO item, and bump to 1.8.0.

Notes two follow-ups found while implementing: link-hooks.sh breaks under
curl|bash (BASH_SOURCE unset) and link-commands.sh cannot run against a
scratch HOME."
```

---

### Task 4: Open and land the `agent-workflow` PR

**Files:** none — this task is the release gate.

**Interfaces:**
- Consumes: Tasks 1-3, all committed on `docs/133-consolidate-claude-provisioning`.
- Produces: a merged `main` containing `setup/bootstrap.sh`, which Task 5's deprecation stub forwards to. **Task 5 cannot start until this merges.**

- [ ] **Step 1: Confirm the branch is clean and the suite is green**

```bash
cd /home/admin/repos/github/freaxnx01/public/agent-workflow
git status -sb
tests/run-script-tests.sh 2>&1 | tail -3
```

Expected: clean tree, three new commits ahead of origin, suite green.

- [ ] **Step 2: Push**

```bash
direnv exec /home/admin/repos/github/freaxnx01 bash -c \
  'GITHUB_TOKEN="${GH_TOKEN}" git push -u origin docs/133-consolidate-claude-provisioning'
```

- [ ] **Step 3: Open the PR**

```bash
direnv exec /home/admin/repos/github/freaxnx01 bash -c \
  'GH_TOKEN="${GH_TOKEN}" gh pr create \
     --repo freaxnx01/agent-workflow \
     --base main \
     --head docs/133-consolidate-claude-provisioning \
     --title "feat: consolidate Claude provisioning into agent-workflow (#133)" \
     --body-file -' <<'PR_EOF'
Closes #133. Implements ADR-007.

Moves the three CLAUDE.md partials and the machine bootstrap out of
`freaxnx01/config`. This repo now owns every Claude surface *and* the
provisioning that installs them — no cross-repo clone in either direction.

## What changed

- `partials/` — the three `@`-imported fragments, plus a README (not imported)
- `setup/link-partials.sh` — idempotent marker-block install, **plus** a migration
  sweep of the legacy `config`-era block and stray `config/claude` `@`-lines
- `setup/bootstrap.sh` — single entry point, chains the three link steps,
  forwards flags verbatim
- `/update-commands` repointed off `config/setup/01-claude-commands.sh` — in the
  same commit that creates its replacement, since it is the recovery path
- ADR-007, README, TODO, CHANGELOG; 1.7.0 → 1.8.0

## Why the sweep matters

The installer only strips markers it matches exactly, and the `config` clone stays
on disk. Without sweeping the old block, a migrated machine loads **both** sets of
partials — no error, no missing file, just silently duplicated instructions.

## Tests

`setup/` had **no** coverage before this. Adds 21 assertions: fresh machine,
byte-idempotency, migration, non-destructiveness (content *and* order),
empty-source guard, and flag passthrough through `bootstrap.sh`.

## Sequencing

**This PR must merge before the `config` PR.** The `config` side replaces its
bootstrap with a stub that forwards here; reversing the order leaves a window
with no working bootstrap.

## Follow-ups found, not fixed here

- `link-hooks.sh` resolves its source dir from `BASH_SOURCE`, which is **unset**
  under `curl … | bash` — its own advertised usage. `link-partials.sh` has the
  fallback pattern; port it.
- `link-commands.sh` derives its source dir from `$HOME`, so it cannot run against
  a scratch `$HOME`.
PR_EOF
```

- [ ] **Step 4: Wait for CI, then merge**

CI is the first lint gate (no `markdownlint` on this host). Check it, and **report the result to the user rather than merging unilaterally** — merging is outward-facing and gates Task 5.

```bash
direnv exec /home/admin/repos/github/freaxnx01 bash -c \
  'GH_TOKEN="${GH_TOKEN}" gh pr checks --repo freaxnx01/agent-workflow --watch'
```

Expected: all checks pass. If markdown lint fails, fix in a follow-up commit and push — do not merge red.

---

### Task 5: The `config` PR — deprecation stub and deletions

> **DO NOT START until Task 4 has merged.** The stub written here forwards to a URL that only resolves once `setup/bootstrap.sh` exists on `agent-workflow`'s `main`.

**Files (in `/home/admin/repos/github/freaxnx01/public/config`):**
- Rewrite: `setup/bootstrap.sh`
- Delete: `setup/00-claude-partials.sh`, `setup/01-claude-commands.sh`, `setup/02-claude-hooks.sh`
- Delete: `claude/` (all 4 files)
- Modify: `README.md`

**Interfaces:**
- Consumes: `https://raw.githubusercontent.com/freaxnx01/agent-workflow/main/setup/bootstrap.sh`, live on `main` as of Task 4.
- Produces: nothing.

- [ ] **Step 1: Branch**

```bash
cd /home/admin/repos/github/freaxnx01/public/config
git checkout main && git pull --ff-only
git checkout -b chore/133-hand-claude-provisioning-to-agent-workflow
```

- [ ] **Step 2: Replace `setup/bootstrap.sh` with the forwarding stub**

```bash
#!/usr/bin/env bash
# setup/bootstrap.sh — DEPRECATED. Claude provisioning moved to agent-workflow.
#
# Kept so the old one-line bootstrap URL, and any notes or muscle memory that
# still use it, keep working. It forwards every argument to the new entry point
# and prints the URL you should use from now on (ADR-007 in agent-workflow).
#
# New URL:
#   curl -fsSL https://raw.githubusercontent.com/freaxnx01/agent-workflow/main/setup/bootstrap.sh | bash

set -euo pipefail

NEW_URL="https://raw.githubusercontent.com/freaxnx01/agent-workflow/main/setup/bootstrap.sh"

echo "⚠ DEPRECATED: Claude provisioning now lives in freaxnx01/agent-workflow." >&2
echo "  Update your bookmark to:" >&2
echo "    curl -fsSL $NEW_URL | bash" >&2
echo "  Forwarding there now…" >&2
echo >&2

curl -fsSL "$NEW_URL" | bash -s -- "$@"
```

Note the `bash -s -- "$@"` form: without it, arguments are silently dropped between the stub and the real bootstrap.

- [ ] **Step 3: Delete the moved content**

```bash
git rm setup/00-claude-partials.sh setup/01-claude-commands.sh setup/02-claude-hooks.sh
git rm -r claude/
ls -1 setup/ && ls -1
```

Expected: `setup/` contains only `bootstrap.sh`; no `claude/` directory remains.

- [ ] **Step 4: Verify the stub actually forwards**

This is the one step that needs network. Run it against a scratch `$HOME` so it cannot touch the real one:

```bash
stub_home="$(mktemp -d)"
env HOME="$stub_home" bash setup/bootstrap.sh 2>&1 | head -20
grep -c 'agent-workflow/partials' "$stub_home/.claude/CLAUDE.md"
```

Expected: the deprecation notice on stderr, then the real bootstrap's output; `3` importable partials in the scratch `CLAUDE.md`. If this fails, Task 4 has not merged — stop.

- [ ] **Step 5: Update `config/README.md`**

Read it first. It currently describes "Claude Code configuration plus other personal config". Rewrite so it: describes a machine-setup repo (shell, oh-my-posh, Windows tooling); states that all Claude content and provisioning moved to `freaxnx01/agent-workflow` on 2026-07-21; and gives the new bootstrap one-liner for anyone who lands here looking for it. Remove every reference to `claude/` and to the deleted setup scripts.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "chore: hand Claude provisioning to agent-workflow (#133)

The partials and the bootstrap now live in freaxnx01/agent-workflow
(ADR-007 there). Deletes claude/ and the three setup scripts; 01 and 02
were pure shims that cloned agent-workflow to call its link steps.

setup/bootstrap.sh stays as a forwarding deprecation stub so the old URL
keeps working, passing arguments through via 'bash -s -- \"\$@\"'.

config is now what its contents say it is: machine setup."
```

- [ ] **Step 7: Push and open the PR**

```bash
direnv exec /home/admin/repos/github/freaxnx01 bash -c \
  'GITHUB_TOKEN="${GH_TOKEN}" git push -u origin chore/133-hand-claude-provisioning-to-agent-workflow'

direnv exec /home/admin/repos/github/freaxnx01 bash -c \
  'GH_TOKEN="${GH_TOKEN}" gh pr create \
     --repo freaxnx01/config \
     --base main \
     --title "chore: hand Claude provisioning to agent-workflow (#133)" \
     --body-file -' <<'PR_EOF'
Second half of the agent-workflow #133 consolidation. **The agent-workflow PR has
already merged** — this side is safe to land.

- `claude/` and the three setup scripts are deleted. `01-claude-commands.sh` and
  `02-claude-hooks.sh` were pure shims: they cloned `agent-workflow` to call its
  link steps.
- `setup/bootstrap.sh` becomes a forwarding deprecation stub, so the old one-line
  URL and any notes using it keep working. Arguments pass through.
- README rewritten: this is a machine-setup repo (shell, prompt, Windows tooling).

Verified end-to-end against a scratch `$HOME`: the stub forwards and installs all
three partials from their new home.
PR_EOF
```

- [ ] **Step 8: Report to the user**

Report both PR URLs and the CI status of each. Do not merge the `config` PR without confirming with the user.

---

## Self-Review

**1. Spec coverage** — every section mapped to a task:

| Spec section | Task |
|---|---|
| Inventory → Moves (4 partials) | 1 |
| Inventory → Moves (`bootstrap.sh`) | 2 |
| Inventory → Rewritten (`link-partials.sh`) | 1 |
| Inventory → Deleted (01, 02 shims) | 5 |
| Edited: `update-commands.md` | 2 (same commit as its replacement, per hazard) |
| Edited: `README.md`, `DECISIONS.md`, `TODO.md`, `CHANGELOG.md`, `VERSION` | 3 |
| Bootstrap flow (no `config` clone) | 2 |
| `link-partials.sh` behaviour (3 strip rules) | 1, Step 5 `awk` |
| Legacy handling carries a removal note | 1, Step 5 header comment |
| Hazard: `update-commands.md` same commit | 2 |
| Hazard: stale marker → double load | 1 (migration test) |
| Hazard: `--copy` lost | 2 (passthrough test) |
| Hazard: old URL invoked | 5 (stub) |
| Testing: all 5 table rows | 1 (4 rows) + 2 (passthrough) |
| Sequencing (`agent-workflow` first) | 4 gates 5, stated in Global Constraints |
| Non-goals | Untouched — no task references `oh-my-posh/`, `windows/`, `agent-skills`, renames, `retry-dispatch.sh`, or #114 |

No gaps.

**2. Placeholder scan** — none. Every script is given in full and was executed before this plan was written; every path, marker string, commit message and PR body is concrete. The only "read it first, then rewrite" steps are Task 1 Step 2, Task 3 Step 3 and Task 5 Step 5, where the target is prose whose current wording must be seen to be corrected — each specifies exactly which strings must change.

**3. Type consistency** — `link-partials.sh` is called with `--no-sync` in tests (Task 1) and by `bootstrap.sh` (Task 2); both match the flag the script parses. The three marker strings are byte-identical between the script (Task 1 Step 5), the test fixture (Task 1 Step 3) and Global Constraints. `CANON` in the script matches the `@`-paths asserted in both tasks' tests. `$ROOT` is the harness's existing variable, unmodified.

**4. Deviations from the spec, flagged for the user** — three, all documented under "Findings from pre-plan verification": the `BASH_SOURCE` fallback (spec's instruction alone would break `curl | bash`), the `--copy` rationale being stale (it is already the default, so the test uses `--link`), and partials being enumerated rather than hardcoded (changes import order to alphabetical).
