# Private-feed pre-restore: restore targets beyond the repo root (#682)

## Intent

`feed_solutions` (`scripts/lib/private-feed-restore.sh`) restores the `*.sln` /
`*.slnx` files at the repository root, and when there are none, runs
`dotnet restore` with no argument there. In a root that holds neither a solution
nor a project that stops with `MSB1003` ("Specify a project or solution file"),
and `restore_private_feeds` then refuses the run with the Feed-Reader hint,
which points at the wrong cause. Any consumer whose solution lives in a
subdirectory cannot use the private-feed path at all.

## Decided (by the user, 2026-11-23)

- **A new pipeline variable `AWF_NUGET_RESTORE`** lists the restore targets:
  relative paths to `.sln`, `.slnx`, `.csproj` or `.fsproj` files, separated by
  spaces.
- **Unset or blank:** today's default, the solutions at the root, or its
  projects when the root holds no solution.
- **No target at all** (unset and neither at the root): a clear refusal that
  names `AWF_NUGET_RESTORE`, never `MSB1003`.

## Non-goals

- Automatic discovery in subdirectories.
- Any change for consumers with a root solution or without `AWF_NUGET_FEEDS`.

## Approaches

1. **An explicit variable, with a clear refusal (chosen).** Predictable, and
   restores only what the consumer names.
2. **Discover solutions up to a depth.** Rejected: it would also restore
   sample and test solutions nobody asked for.
3. **Refusal only.** Rejected: it leaves those consumers without the feed path.

## Design

- **Target validation in `preflight_restore`,** which runs before the worktree
  exists, so it checks syntax only. Each entry must:
  - be relative (no leading `/`);
  - contain no `..` path segment;
  - end in `.sln`, `.slnx`, `.csproj` or `.fsproj`;
  - consist only of `[A-Za-z0-9._/-]`.

  A failure refuses with `private feed setup: AWF_NUGET_RESTORE entry '<entry>' is not a relative solution or project path`.
- **`feed_restore_targets <worktree>`** replaces `feed_solutions`. It sets the
  array `FEED_TARGETS`:
  - **`AWF_NUGET_RESTORE` set:** each entry must be a regular file the seed
    commit tracks at that exact path. A symlink, or a path reaching through a
    symlinked directory, is refused, because it could point outside the commit.
    Anything not in the commit makes it return 2 with
    `AWF_NUGET_RESTORE entry '<entry>' is not in the seed commit`.
  - **Unset:** the root `*.sln` / `*.slnx`, falling back to the root `*.csproj`
    / `*.fsproj` when the root holds no solution — the no-argument
    `dotnet restore` this replaces handled such a root. When there is neither,
    it returns 2 with
    `no solution or project at the repository root; set AWF_NUGET_RESTORE to the solution or project to restore`.
- **`feed_pre_restore`** returns **2** when there is no target, and 1 on a
  restore failure as before. Cleanup runs on both paths.
- **`restore_private_feeds`:**
  - On rc 2, it refuses with `private feed restore: <first stderr line>`.
  - On rc 1, it keeps today's Feed-Reader text.
  - Both point to §14.
- **`feed_restore_one`** receives each target's relative path, which
  `dotnet restore <path>` accepts, run from the worktree root as today.
- **`docs/AZDO-PIPELINE-SETUP.md` §14** documents `AWF_NUGET_RESTORE`, its
  default, and the refusal.

## Acceptance criteria

- [ ] With `AWF_NUGET_RESTORE=samples/dotnet/Sample.sln`, the pre-restore
      restores exactly that solution.
- [ ] With the variable unset and a root solution, behaviour is unchanged.
- [ ] With the variable unset and a root project but no root solution, that
      project is restored.
- [ ] With the variable unset and neither at the root, the run is refused before
      the agent, with the "set AWF_NUGET_RESTORE" text. No `dotnet` call is made.
- [ ] An absolute path, a `..` segment, a wrong extension or a disallowed
      character is refused in preflight. No `dotnet` call is made.
- [ ] An entry missing from the seed commit, or a symlink, is refused with its
      own message. Cleanup still runs.
- [ ] A real restore failure still gives the Feed-Reader message.
- [ ] §14 documents the variable.
