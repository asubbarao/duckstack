---
name: jev-evaluate
description: Compatibility entrypoint for evaluating stored JEV judgments; routes to the JEV skill's evaluation guidance.
---

Use [jev](../jev/SKILL.md), especially “Evaluate stored answers.” Evaluation shares its input preservation, missing-answer handling, credential and cache requirements; it does not need a separate metrics framework.

Inspect human truth and stored predictions as rows first. DESCRIBE and SUMMARIZE handle profiling. Keep disagreements, missing answers and errors visible; handwritten predictions are not a model benchmark. Compute metrics only when requested and retain the contributing rows.
