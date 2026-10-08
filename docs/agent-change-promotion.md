# Local agent change promotion

Agents may freely improve local files. Publication is a separate state change with a smaller,
explicit review boundary. A dirty shared worktree is normal; it is not a reason to mix unrelated
changes or to leave a coherent improvement permanently uncommitted.

## States

1. **Local draft** — an agent may edit and verify in scope. No repository claim is implied.
2. **Review bundle** — a concrete manifest of owned paths (and, when necessary, owned hunks),
   its purpose, observed verification, and the current base commit.
3. **Promoted** — exactly that manifest is staged, reviewed, committed, and pushed. Everything
   outside the manifest remains in the worktree for another review.

Local-only guidance becomes promotable by giving it a canonical repository destination, usually
an existing `skills/<name>/SKILL.md` or a focused file under that skill's `references/`. Prefer
merging a lesson into an existing skill over creating a duplicate skill or loose root artifact.

## Scoped ownership review

For each promotion:

- Read the complete diff for the proposed paths and state why every path belongs together.
- Use `duck_tails.git_status` for the whole inventory. Record all other modified/untracked paths
  as explicitly excluded; do not clean, stash, restore, or stage them.
- If a proposed file contains unrelated hunks, either split those hunks deliberately or leave the
  whole file for its own review. A path is not “owned” merely because one agent touched it last.
- Stage only the manifest. Inspect the staged diff and run `git diff --cached --check` plus the
  relevant behavioral validation. Abort if any staged path is outside the manifest.
- Recheck the branch tip immediately before committing. If another agent advanced it, rebuild the
  review bundle from the new tip rather than assuming the earlier review still applies.
- Commit and push the scoped bundle. Report the commit and the excluded dirty paths separately.

This provides a promotion gate without restricting local experimentation: approval applies to a
review bundle, not to the entire shared worktree.
