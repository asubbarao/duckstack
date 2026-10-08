---
name: clean-room
description: Prove declared SQL skill recipes run with stock DuckDB and no workstation setup.
---

# Clean-room skill checks

Run `check.sql` from the repository root. It discovers the `skills/` tree with hostfs, executes
the declared portable recipes through generated ShellFS commands in fresh homes, and checks their
SQL text for workstation-only dependencies. The command receipts include exit status, stdout and
stderr heads, and duration.

The allowlist is deliberately explicit: a recipe is portable only when it is named in
`check.sql`. This keeps extension-specific or credential-dependent skills out of a clean-room
claim until they have their own portable contract.

The checker requires only DuckDB and community extensions installed by the SQL itself. It does
not use uv, uvx, Python, a local Quack service, or a user's home directory for the child recipe.
