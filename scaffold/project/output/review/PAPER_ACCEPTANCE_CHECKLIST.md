# Paper Acceptance Checklist

Use this checklist before final submission. It is a human/main-brain gate, not an automatic decision engine.

## Required Files
- [ ] Official front matter / required Word-derived pages are present or explicitly merged outside LaTeX.
- [ ] Host-visible acceptance PDF matches `project/paper/runtime/paper.env#PAPER_ACCEPT_PDF`.
- [ ] Host-visible acceptance log matches `project/paper/runtime/paper.env#PAPER_ACCEPT_LOG`.
- [ ] Source appendix / code appendix exists if required by the competition.
- [ ] AI-use statement / appendix exists if required by the competition.

## Paper Integrity
- [ ] Active entrypoint is confirmed with `bash scripts/paper.sh print-config`.
- [ ] Latest PDF was checked with `bash scripts/paper_acceptance_check.sh`.
- [ ] Page count is known and acceptable.
- [ ] Fatal LaTeX errors are absent from the latest log.
- [ ] Undefined references and undefined citations are absent or explicitly accepted.
- [ ] Overfull warnings that affect visible layout are fixed or explicitly accepted.

## Modeling Consistency
- [ ] `project/output/model_manifest.json` exists or main brain explicitly records why it is not needed.
- [ ] Canonical numbers in paper match code-side outputs and indexed handoffs.
- [ ] Tables include complete required result rows.
- [ ] Figures referenced by paper exist as host-visible files.
- [ ] Algorithm boundaries, enumeration limits, and optimality claims are stated.

## Final Package
- [ ] Final PDF opens from host filesystem.
- [ ] Required source/code attachments are present.
- [ ] Required official documents are included.
- [ ] Main brain has reviewed feedback / retrospective gates for final layout task.
