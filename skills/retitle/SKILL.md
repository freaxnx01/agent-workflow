---
name: retitle
description: Use when the user runs /retitle [name], or asks to rename / label / title the current tab or session ("name this tab X", "rename herdr tab and session"). Gives the current Herdr tab and the Claude Code session the same name in one step.
---

# Retitle — Herdr tab + Claude Code session, same name

Goal: one name, shown in two places — the **Herdr tab label** and the **Claude Code
session title** (what `/rename` sets, and what `/resume` lists). Works from bash
(Linux, WSL2, Git Bash) and from PowerShell (native Windows).

## Pick the name

- Use the argument verbatim if given (`/retitle BI-ArchiveUploader #123`).
- No argument: propose something short from context (repo basename + issue/branch, or
  the session's topic), use it, and say which name you picked.

## 1. Herdr tab

Only when `HERDR_ENV` is `1`; otherwise skip this step and say so in one line (normal
on native Windows, where Herdr doesn't run).

```bash
herdr tab rename "$HERDR_TAB_ID" "<name>"
```

```powershell
herdr tab rename $env:HERDR_TAB_ID "<name>"
```

Target `HERDR_TAB_ID` (the caller's tab), never the UI-focused tab. JSON on stdout =
success; JSON error on stderr + exit 1 = report it.

## 2. Claude Code session title

The built-in `/rename` is a CLI command — a skill **cannot invoke it**. What it does is
append a `{"type":"custom-title","customTitle":…,"sessionId":…}` record to the session
transcript, so do the same. `/resume` picks up the last one.

bash (uses `jq` when present; the fallback escapes `\` and `"` itself):

```bash
name="<name>"
f=$(ls ~/.claude/projects/*/"$CLAUDE_CODE_SESSION_ID".jsonl | head -1)
if command -v jq >/dev/null; then
  jq -cn --arg t "$name" --arg s "$CLAUDE_CODE_SESSION_ID" \
    '{type:"custom-title",customTitle:$t,sessionId:$s}' >> "$f"
else
  esc=$(printf '%s' "$name" | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf '{"type":"custom-title","customTitle":"%s","sessionId":"%s"}\n' \
    "$esc" "$CLAUDE_CODE_SESSION_ID" >> "$f"
fi
```

PowerShell 7 (`utf8NoBOM` keeps the JSONL clean — never let a BOM or CRLF in):

```powershell
$name = "<name>"
$f = Get-ChildItem "$HOME\.claude\projects\*\$env:CLAUDE_CODE_SESSION_ID.jsonl" | Select-Object -First 1
$line = [ordered]@{ type = 'custom-title'; customTitle = $name; sessionId = $env:CLAUDE_CODE_SESSION_ID } |
  ConvertTo-Json -Compress
[IO.File]::AppendAllText($f.FullName, "$line`n", [Text.UTF8Encoding]::new($false))
```

If `CLAUDE_CODE_SESSION_ID` is empty or no transcript matches, skip this step, say so,
and rely on the `/rename` line below.

## 3. Live label — hand over `/rename`

The **running** UI may keep showing the old name, so always end by giving the user the
native command as the guaranteed path — `/rename <name>` — and put it on the clipboard
with whatever this machine has:

| Machine | Clipboard |
|---|---|
| has `wclip` (srvdmsk8s01) | `printf '/rename %s' "<name>" \| wclip` — "no receiver" → just print it |
| WSL2 | `printf '/rename %s' "<name>" \| clip.exe` |
| Git Bash on Windows | `printf '/rename %s' "<name>" \| clip` |
| PowerShell | `Set-Clipboard "/rename <name>"` |

Don't retry a failing clipboard; print the line instead.

## Report

One line per target: tab renamed ✓/skipped, session title written ✓/skipped, plus the
`/rename <name>` line (and whether it's on the clipboard).

If you run into blockers, find a solution and update this skill for the future
(master copy: `agent-workflow/skills/retitle/SKILL.md`, then re-run `setup/link-skills.sh`).
