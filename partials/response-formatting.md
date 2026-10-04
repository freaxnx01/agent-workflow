# Response formatting

Formatting rules for how answers should look, not what they say.

- **Bold key terms** — the specific word or short phrase that matters, not whole
  sentences. Keep it sparing; bolding everything bolds nothing.
- If an answer runs longer than two sentences, give it a `TL;DR:` line that
  summarizes it in one sentence, and **lead with it**. Once the answer is long
  enough to scroll off the terminal, repeat it as the closing line as well:
  the opening copy orients before reading but has scrolled out of view by the
  time rendering stops, and the closing copy is the one still on screen. Both
  copies say the same thing — don't split the summary across them. On an answer
  that fits a single screen, the leading `TL;DR:` alone is enough; repeating it
  there is just noise.
- **Write the marker bold *and* backticked** — the literal source is
  ``**`TL;DR:`**``, never a bare `TL;DR:`. Bold alone reads as ordinary
  emphasis and the code span alone is easy to skim past; together the marker
  separates cleanly from the sentence it introduces. Coloring it orange is
  **not** available — Claude Code renders markdown, not raw ANSI escapes
  (those come through as literal garbage), and the inline-code color is
  fixed by the theme, not settable per string. Confirmed 2026-09-10.
- Any comma-separated run of items (e.g. "auth, logging, and caching") becomes a
  bullet list instead, one item per line, rather than staying inline.
- Leave a blank line between list items so they're easier to scan.

These are layout rules only — they don't change which skill or process applies,
just how the final answer is laid out on the page.
