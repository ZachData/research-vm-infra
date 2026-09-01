# CLAUDE.md

Operational rules. `PROJECT.md` is the source of truth for what the experiment *is* — hypotheses, thresholds, metric definitions, status board, decisions log. Read it before doing anything non-trivial. This file only covers how to work.

## What this repo is

*One paragraph: the question, the substrate, the deliverable.*

## Stack

*Language and version — and it must match what CI runs. A version skew between CI and the instance produces tests that pass in one and fail in the other, which costs a session before anyone suspects the interpreter. Pin it in `infra/rvm.env` as `RVM_PYTHON`.*

## Commands

```
pytest tests/unit tests/property -q      # must pass before any commit
pytest tests/integration -q               # slow, not on every push
pip install -e ".[dev]"
```

---

## TDD contract

**The test file is the spec. Write or read it first.**

The dominant risk in a research codebase is *silent failure*: a readout that returns a constant, or empty, or the same number for every input looks fine in logs and poisons every downstream claim. Tests exist to catch that at the source, not to check that code runs.

**1. Closed-form oracles.** Where `PROJECT.md` §3 gives an exact answer, test to machine precision — not to a tolerance tuned until it passed.

**2. Invariants.** Properties that must hold over random inputs: conservation, orthogonality, range, equivariance. `hypothesis` for these.

**3. Discrimination tests — the silent-failure guards.** Every probe must be shown to return *different* answers on a known-positive and a known-negative, both constructed by hand. Every readout, given an all-zeros or all-constant input, must raise or return a sentinel — never a plausible-looking number.

**4. Schema tests.** A results record is invalid unless it carries the null tested, the pre-registered criterion, the observed value, the verdict, and `METRIC_VERSION`.

**5. Smoke test.** One test runs the entire path — tiny model → train a few steps → every probe → a results record → schema validation — in under a minute. It asserts nothing about science; it exists so integration breakage surfaces early rather than hours into a real run.

**Metric-version enforcement.** CI hashes the metric-defining functions. If the hash changes and `METRIC_VERSION` did not, the build fails. Changing a metric definition silently invalidates every prior result; this makes that impossible rather than merely discouraged.

### When to write a test

| Write one if… | Skip it if… |
|---|---|
| The output lands in a results record | It only produces a plot a human will look at |
| Failure is silent | Failure is loud and immediate |
| There is a closed form to check against | The expected value would just be whatever the code returns now |
| More than one caller depends on it | It is a one-off analysis script |
| It defines something — a metric, a schema, an invariant | It orchestrates things that are themselves tested |

**Test definitions and silent failures; don't test exploration.** A regression test whose expected value was copied from current output tests nothing except that the code has not changed.

### Numerical tolerance

State the tolerance in the test with a one-line comment saying where it comes from. **Never widen a tolerance to make a test pass** — that converts a real disagreement into a silent one.

---

## Beyond tests

### Computable verdicts

A results record stores the observed value, the pre-registered criterion, and the verdict. **The verdict must be recomputable from the other two**, and CI recomputes it. If the stored and recomputed verdicts disagree, the build fails.

This is the most important check in the repo. Tests catch broken code; this catches a correctly-functioning pipeline whose conclusion does not follow from its own numbers — the characteristic failure of unattended agentic research, and the one no unit test detects.

### Provenance

Every record carries: git SHA, `METRIC_VERSION`, config hash, RNG seed, checkpoint revision, eval-set hash, library versions, wall-clock, hardware. A record without provenance is unusable later and cannot be defended in review. Seed everything at run start and record the seed.

### Config as data

One frozen dataclass per run, serialized to JSON, hashed. The hash *is* the run ID. Resumability then comes free: write results incrementally, one record per cell, and on start skip cells whose hash already has a record. Instances are ephemeral and capped — losing a long sweep to a stop is a self-inflicted wound.

### Fail fast in production paths

Assertions inside `src/`, not only in `tests/`: NaN/Inf checks after every training step, shape assertions at tensor boundaries, range guards on every metric. **Raise, don't clamp.** A clamped metric looks plausible and is a lie.

### Adversarial self-review

Any commit touching a metric or schema module includes a short **"how this could be wrong"** note in the body: the most plausible way the change produces a confident wrong number. Not a summary of the diff. Anything it cannot resolve goes in `REVIEW.md` for human eyes. There is no reviewer in the loop; this is the substitute, and it is a weak one, so keep the queue short and read it.

### Hygiene

Delete dead code rather than commenting it out. Type hints everywhere in `src/`; mypy in CI. No notebooks — analysis scripts that write figures to disk, so every figure has a reproducible command behind it.

---

## CI

Tiers 0–2 gate every push; the slow tier runs on demand.

| Tier | Contents | Budget |
|---|---|---|
| 0 | lint, format, types, metric-hash check | seconds |
| 1 | `tests/unit` — pure math vs closed-form oracles, no model loading | < 30 s |
| 2 | `tests/property` + fixture-model tests + smoke test | < 2 min |
| 2.5 | Schema validation + **verdict recomputation over all records** | seconds |
| 3 | `tests/integration` — real checkpoints; on demand or nightly | minutes |

Tier 2.5 runs over every record in the repo, not just new ones, so a metric-version bump surfaces as a failure on all affected historical records rather than leaving them quietly stale.

---

## Working on a status-board row

1. Read the row and the `PROJECT.md` section it references.
2. Write the test file first. If the row is a gate, the test *is* the pass/fail criterion — encode it, don't eyeball it.
3. Implement until tiers 1–2 are green.
4. Run the row. Emit a results record.
5. Update the status board. Decisions to §9, new uncertainties to §10.
6. Commit, push, wait for CI.

**A gate that fails stops the phase.** Record the failure in §9 with the decision taken. Do not route around it, do not weaken its criterion, and do not proceed on the assumption it will pass later.

## Fleet

This repo runs on the shared research fleet; see `infra/rvm.env` for how. `RVM_PYTHON` must match CI. Results and transcripts are backed up to S3 before an instance terminates, but **the repo is the only durable record** — an unpushed commit does not exist.

## When finishing

Update the status board. Append decisions to §9, uncertainties to §10. Leave the tree clean and pushed.
