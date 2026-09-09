# German correspondence — capitalized address pronouns, real umlauts

Applies to **everything** written in German: mails, documents, issues, commit
messages, chat replies.

- **Capitalize the address pronouns.** `Du`, `Dir`, `Dich`,
  `Dein/Deine/Deinem/Deiner…`, and likewise the plural `Ihr`, `Euch`,
  `Euer/Eure/Eurem…`. This is the polite spelling in business correspondence, and
  it holds even for a familiar Swiss opener like „Hoi Martin“ — still `Du`, never
  `du`.

  **Exception: quoted foreign text is never touched.** An incoming mail that
  writes „kannst du mir sagen“ gets quoted exactly as it arrived.

- **Real umlauts, never transliteration.** Write `ä ö ü Ä Ö Ü` — never `ae oe ue`.
  So `übernehme`, `wären`, `möglich`; not `uebernehme`, `waeren`, `moeglich`.
  Using `ss` instead of `ß` stays correct (Swiss usage).

## Plain text vs. Outlook HTML — not a contradiction

If your user-level rules also mandate named HTML entities for Outlook mail (Word
renders the message body and mangles raw UTF-8), the two rules govern different
formats rather than conflicting:

- Plain text (`.txt`, terminal, Markdown, commit message) → **real umlauts** as
  UTF-8.
- Outlook HTML (`.html` destined for the clipboard) → **named entities**
  (`&auml;`, `&uuml;`, `&ouml;`, `&bdquo;`/`&ldquo;`), which render as real
  umlauts for the recipient.

The entity rule is this rule *encoded* for HTML, not an exception to it. When a
draft is produced in both formats, the `.txt` carries real umlauts and the
`.html` carries entities — both say the same thing.
