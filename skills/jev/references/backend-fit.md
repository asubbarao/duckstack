# Possible InFrame uses

These are proposals from a read-only source review at commit 0364849b5a9b905a9d380005e5a6c2130e40a157. No backend data or model inference was tested, and no integration was implemented.

- **Document matching:** ask whether a document supplies a requested evidence item. Keep the document/request pair and coverage period visible; missing pages can make a judgment unreliable.
- **Endorsement comparison:** classify a source form relative to a catalog form as equivalent, broader, narrower, unrelated or insufficient evidence. Preserve direction and actual coverage text; a title alone cannot establish equivalence.
- **Proposal conflicts:** inspect whether a proposed account fact agrees with existing facts and all pending proposals for the same period. An isolated row can miss conflicts between proposals.

The existing backend already uses model judgment in these paths. JEV's possible benefit is making answers inspectable alongside SQL data; improved accuracy, cost and compatibility remain unproved. Start with a bounded labelled sample and retain raw judgments/errors for human review. These experiments do not authorize evidence fulfilment, mapping acceptance or automatic approval.

[Archived source notes](archive/backend-fit-source-notes.md) contain the original paths, fields and line references if implementation work needs them. Revalidate that snapshot before changing backend code.
