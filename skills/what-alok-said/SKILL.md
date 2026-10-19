---
name: what-alok-said
description: Collect everything Alok typed to Claude and Codex (his messages only, aggregated per session, from dev's agent stream), analyse it for his corrections and rules, and write it up as one document. Use when asked what he has said or asked for, to mine his corrections into rules or hooks, before changing RULES.md or a skill he has opinions on, or when he asks for the writeup.
---

# What Alok said

The output is a **writeup**, not rows. Three steps:

## 1. Collect (dev, one query)

Run [collect.sql](collect.sql) on dev through `mcp__dev__query`. It returns `agent.sessions` for every session active
in the window: activity, files, models, tools, cwd, branch, and `prompts`, each typed prompt as its whole
`stream.blocks` row in order (`prompts[n].message_content` is the text). The window is the one `INTERVAL` in it.

Nothing is stored: each reader in step 2 runs collect.sql with `AND session_id IN (<its group>)`.

## 2. Analyse (one Opus 5.5 reader per group of sessions)

Split the sessions into groups of about 200 KB of prompt text (`list_sum([strlen(p.message_content) FOR p IN prompts])`), keeping each session whole, and run one `Agent`
(`model: "opus"`) per group in parallel. Each reader reads its sessions in order, since a correction makes sense next
to the messages before it, and returns:

- **Rule:** the rule in plain words, as an instruction an agent can follow.
- **When:** the date(s) he said it.
- **Quote:** his words, short, paraphrased if profane.
- **Status:** new, or which rule in `skills/self-dispatch/RULES.md` or which hook check it sharpens or contradicts.
- **Checkable:** whether a hook can catch it, and how.

The readers skip anything he did not type: pasted agent briefs, side-session notes, skill text.

## 3. Write up (one document)

Merge the readers' rules into `writeups/<date>.md` beside this file:

1. **What he keeps saying:** the five to ten themes, most repeated first, each with how many sessions raised it.
2. **The rules, by theme:** each rule once, with dates and one quote. Where two of his messages conflict, the
   newer wins; say which one.
3. **Already enforced:** rules a hook check already blocks, by check id.
4. **Not yet enforced:** rules a hook could catch, with the check to add.
5. **Never mechanically checkable:** process rules no hook can check.
6. **Contradicts RULES.md:** his messages that disagree with RULES.md, for him to rule on; RULES.md stands until he does.
7. **Changed since the last writeup:** new rules and reversed rules.

Then show him the writeup inline. Rules that change RULES.md or the hooks go in a PR through the review queue.
