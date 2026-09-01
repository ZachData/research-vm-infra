# __PROJECT__

**State the question in one sentence, as a question, with the thing that could come out either way in it.**

This is the living specification and the source of truth. It is updated at the end of every working session. If a claim here contradicts the code, one of them is wrong — resolve it explicitly in §9 and never let both stand.

Delete every instruction line in this template as you fill it in. A section left as boilerplate is worse than a section deleted: it looks like a decision that was made.

---

## Status board

One row per unit of work that ends in a number or a verdict. Cheap falsification attempts first — a gate that can kill the project should run before anything expensive is built on top of it.

| Phase | Item | Status | Notes |
|---|---|---|---|
| Setup | Package skeleton, CI green on an empty suite | ○ | |
| Setup | Core definitions + unit tests against closed-form oracles | ○ | |
| Setup | Probes/readouts + discrimination tests | ○ | |
| G0 | *The cheapest measurement that could show the premise is false* | ○ | |
| G1 | *The prerequisite the main experiment assumes* | ○ | |
| G2 | *Positive control: does the method work where it must?* | ○ | |
| M1 | *First real measurement* | ○ | H1 |

Legend: ○ not started · ◐ in progress · ● done · ✗ failed/abandoned

Notes carry the number and the provenance, not a summary of effort: what was measured, on what, with which seed, and the record it landed in.

---

## 1. Framing

What is being claimed, and what would have to be true for it to be interesting. Then, explicitly: **what would make this a failure.** A project that cannot say in advance what a negative result looks like will find a positive one.

## 2. Substrate

The model, checkpoint revision, dataset, and hardware. Exact identifiers — a revision hash, not "the small one". Everything a stranger needs to rerun a cell.

## 3. Definitions

The mathematics. Every quantity that appears in a results record is defined here, exactly, before it is computed. If a definition has a closed form, state it: it becomes the oracle its test asserts against.

## 4. Metrics

| Metric | Definition | Known-positive | Known-negative |
|---|---|---|---|

Every readout needs the last two columns. A probe that has only ever been run on real data can be broken in a way no assertion catches; the discrimination test is what makes it a measurement rather than a number.

State decision bands here, including the ambiguous band. Ambiguous results stay ambiguous — they are never rounded into a verdict.

## 5. Pre-registered hypotheses

Thresholds fixed now, before data. Each null must be falsifiable by a comparison a machine can evaluate; if it cannot be written that way, it is too vague to be pre-registered and needs rewriting before any row depending on it runs.

### H1 — *name*

*One-sentence prediction.*

| Null | Statement | Falsified by |
|---|---|---|
| h0₁ | | |

Say which null carries the scientific content, and what the controls are that must be attached to any failure claim. A failure reported without its controls is a result about the optimizer, not about the system.

## 6. What can and cannot be concluded

The limits of the design, written before the results exist and quoted verbatim in the writeup. What confound remains, what the measurement is silent about, and which language is therefore off-limits.

## 7. Gates and protocol

Gates are ordered so the cheapest kill-shot comes first. Each gate names its pass criterion as a number fixed in advance, and what happens on failure — which is *stop*, not weaken.

## 8. Falsification discipline

- Do not propose new hypotheses or new falsification tests mid-run; they are fixed here by a human.
- Do not change a pre-registered threshold. If one looks wrong, say so in §9 and leave it.
- No failure claim without its controls attached.
- Ambiguous stays ambiguous.

## 9. Decisions log

| Date | Decision | Why |
|---|---|---|

Every non-obvious choice, with the reason, dated absolutely. This is the section that makes a result defensible three months later.

## 10. Open questions

Everything unresolved and consequential, stated sharply enough to be closeable. An open question that cannot be closed by any observation belongs in §6 as a limitation instead.

## 11. Reading

Papers and prior work this depends on, with what each one is actually being used for.
