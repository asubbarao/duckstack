# Backend JEV fit — read-only source investigation

Source snapshot: /Users/aloksubbarao/inframe at 0364849b5a9b905a9d380005e5a6c2130e40a157. Committed source read through dev duck_tails. Dirty CLAUDE.md and untracked agent artifacts preserved. No backend database, customer data, credentials, staging or production read. No model inference was run. JEV opportunities below are proposals, not verified integration behavior.

## 1. Document × requested-evidence semantic match — strongest first pilot

Source-backed current path: intake/document_triage.py:214-241 loads still-unfulfilled submission evidence as (id,label); :286-303 passes labels and document preview to classify_with_checklist; :333-348 converts returned positions to evidence IDs and conditionally fulfils evidence rows. classification/prompts.py:157-174 explicitly asks whether THIS document fulfils each request, permitting several or no matches and refusing uncertain matches. Preview reads two PDF pages with an image fallback (document_triage.py:44-60,138-178). Full extraction later supersedes the preview classification (:7-14).

Source entities/columns: StoredFile.id and classification columns document_type, coverage_lines, classification_confidence, classifier_model, classified_at (:320-330); requested evidence id/label; DocumentParseResult content_hash, organization_id, markdown, chunks_json, grounding_json (models/file/document_extraction.py:49-90).

Proposed semantic question: “Does this document actually supply the information requested by this evidence item, for the stated coverage and period?” Use a relational candidate set of document ID × evidence ID; preserve document hash, request label, explicit period/context, question version, raw judgment and error. jev_prob over that evidence bundle gives match_probability; jev_choice with supports/does_not_support/insufficient_evidence gives match_status. SQL can rank each request’s matching documents, show uncovered requests and review ambiguous ties. Independent choice/probability calls may disagree; do not pretend they are one calibrated distribution.

Why SQL alone cannot settle it: a policy and a loss-run request both mention the same coverage, while only the loss-run actually supplies history. Equality/search can shortlist; document purpose and supplied information require semantic reading. This code already delegates that reading to an LLM.

Limits: text-only JEV input is not proven equivalent to the existing vision fallback. Two-page previews can omit relevant material. No automatic evidence fulfilment in the pilot; preserve the existing concurrent-write guard and broker review. First evaluate synthetic/deidentified bounded examples without customer egress.

## 2. Endorsement × catalog relationship — reusable pair classification

Source-backed current path: policy_proposals/endorsement_normalization.py:425-435 settles exact normalized form-number/edition matches deterministically. :464-555 uses two model passes: shortlist catalog entries, then compare against at most three resolved candidates; hallucinated candidate forms are rejected. :1003-1039 stores proposed mappings with organization_id, endorsement_type_id, mapped_type_id, equivalence, llm_reasoning, llm_confidence and PENDING status. endorsement_normalization_prompts.py:143-153 defines equivalent/broader/narrower by coverage meaning and requires actual coverage language rather than titles.

Source entities/columns: PolicyEndorsement.id, endorsement_type_id, policy_coverage_id, file_id, page_start; source endorsement_text, form_number, title, coverage_line; catalog entry id, form_number, edition and description; EndorsementTypeMapping columns above. These fields are consumed in normalization.py:438-451,478-519,783-801,1031-1039.

Proposed semantic question: “Relative to this catalog form, does the source endorsement provide equivalent, broader, narrower, unrelated or insufficiently evidenced coverage?” jev_choice over an explicit source/candidate bundle becomes relationship; jev_prob for a fixed equivalence question becomes equivalence_support. Keep directional source_type_id and candidate_type_id: broader/narrower reverses if sides reverse. SQL can build an inspectable candidate mapping table, group unmatched forms and compare current reviewed mappings with judgments.

Why SQL alone cannot settle it: normalized identity answers whether this is the same numbered edition, but different carrier forms can express the same operative coverage and similar titles can conceal exclusions. Current code explicitly makes a semantic comparison after deterministic lookup.

Limits: comparison material currently includes catalog descriptions, which may not contain full operative form text; missing text must yield insufficient_evidence. Do not use normalized scalar ordering to pretend broader is simply “better” than equivalent: relationship is directional and multidimensional. Keep mappings pending; never auto-link reviewed policy rows from a probability. Candidate-set recall remains separate from judgment accuracy.

## 3. Proposal coherence against account snapshot and siblings — useful analysis, risky replacement

Source-backed current path: profile_proposals/coherence.py:1-20 explains why a whole pending set and profile are scored together and records the confidence-versus-coherence distinction. :64-106 defines PendingProposal key/kind/label/proposed_value/current_value/source and ProposalAssessment coherence/note. :126-178 requires both conflicting siblings to score low, distinguishes renewal updates from contradictions and fails cautiously. :352 onward check_coherence renders the whole set and calls the existing structured LLM. profile_proposals/auto_approve.py:290-316 consumes those assessments against PICK_AUTO_APPROVE_MIN_COHERENCE. ProfileFieldProposal persists organization_id, field_id, proposed_value, extraction_id, content_hash, schema_name, source_field_path, batch_id, confidence and status (models/account/profile_proposal.py:35-82).

Proposed semantic question: “Can this proposed statement coexist with the account facts and all these pending statements, accounting for effective period and source?” Evaluate a grouped account snapshot including siblings; emit proposal_id, coherence_score, contradiction_kind and review_needed as analytical columns. jev_score_norm ordered labels may support a review ranking, but its number is not established as equivalent to existing coherence probability. A pair table can expose candidate contradictions, yet each row must retain sufficient shared context.

Why SQL alone cannot settle it: same-field unequal values are easy to flag, but a renewal legitimately changes carrier/address/limits and two differently rendered names can mean the same entity. Operations versus business description and payroll versus headcount need interpretation. The existing code already uses contextual judgment for this gap.

Limits: do not replace whole-set evaluation with isolated per-proposal rows; that loses sibling conflicts. Current source explicitly escapes/fences customer content, bounds values/profile context and redacts model notes before audit/log persistence (coherence.py:49-62,215-319). JEV’s inference path has not been proved to preserve these protections, provider policy, retry semantics or calibration. This is a read-side review experiment, not a new unattended approval threshold.

## Suggested reusable relation

judgment_candidates(subject_id, candidate_id, organization_id, source_hash, context_json, question_id, question_version) → judgments(..., choice, score, raw_eval, error, evaluated_at).

Deterministic SQL owns candidate generation, scope, dates, versions, join keys and aggregation. JEV provides the bounded semantic column. Materialize and reuse judgments by source/context/question versions, preserve errors as unknown, and review results before any business writes. The codebase already contains these semantic operations; the gain to evaluate is composability and visibility in SQL, not an assumption of better accuracy or lower cost.

Tool note: fledgling query is read-only and disables filesystem operations; the selected dev query/ShellFS/native git tools worked. That connector is not the selected dev tool and should not be silently substituted. No real inference was verified because no TypeSafe key is available.

