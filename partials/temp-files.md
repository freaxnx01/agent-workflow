# Temp files — scratchpad first, never a hand-picked fixed folder

Scripts, logs, dumps, build output and other throwaway files go in the **session
scratchpad** when the harness provides one, otherwise in the OS temp dir
(`$env:TEMP` on Windows, `$TMPDIR` / `/tmp` on Linux/macOS). Don't invent a fixed
folder like `C:\Temp` or `~/tmp` out of habit.

**Why:** a fixed folder is shared by every session and never cleaned up. Over
months it fills with one-off scripts, numbered retry logs (`run7-err.log`),
duplicated build copies and full browser profiles — gigabytes nobody can
attribute any more, because the transcripts that wrote them have expired.

**Exception — another identity has to read it.** A web-server app pool, a
Windows service, an elevated process (`gsudo`/`sudo`), or Windows tools called
from WSL2 often can't read the per-user temp dir or the Linux filesystem. Only
then use a shared location such as `C:\Temp` — and in a **named subfolder per
task** (`C:\Temp\<task>-<date>\`), not loose files in the root.

**Clean up what you created.** Before the task is done, delete the temp files
and folders you made, or say explicitly which ones you're leaving behind and
why (e.g. "the deployed site at `C:\Temp\demo-site` is still bound in IIS").
Browser automation profiles (`--user-data-dir`) count — they run to hundreds of
MB and may hold live login cookies.
