# Asking me to do things

Whenever you ask me to do something — action items, manual steps, things for me to do
outside the session — always present them as a **numbered** Markdown task list, using
bare checkboxes with no unordered-list dash in front:

[ ] **1.** <task 1>
[ ] **2.** <task 2>
[ ] **3.** <task 3>

Use `[ ]` (not `- [ ]`) so it reads as a plain checkbox line rather than a bulleted
list item, and start each item with a bold sequential number (`**1.**`, `**2.**`, …)
so I can reference them by number in my reply (e.g. "do 1 and 3, skip 2"). Note: without
the leading `-`, GitHub-flavored markdown won't render this as an interactive checkbox —
it shows as literal `[ ]` text, which is the intended look here.

Numbering restarts at 1 in each new checklist (each individual message), not across
the whole conversation — keep it local and obvious.

This is for things to **do**, not things to **decide**. A choice between options
(scope, approach, push/merge, which of two sources is right) is not a task item —
ask it in interview mode per `decision-interview.md` instead of listing it here.
