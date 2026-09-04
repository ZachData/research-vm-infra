# CLAUDE.md

Operational rules. `PROJECT.md` is the source of truth for what the project *is* — the question, thresholds, status board, decisions log. Read it before doing anything non-trivial. This file only covers how to work.

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

The dominant risk in unattended agentic work is *silent failure*: a function that returns a constant, or empty, or the same value for every input looks fine in logs and poisons every downstream result. Tests exist to catch that at the source, not to check that code runs.

**1. Oracles where they exist.** Where `PROJECT.md` gives an exact expected answer — a closed form, a known dataset, a reference implementation — test to that precision, not to a tolerance tuned until it passed.

**2. Invariants.** Properties that must hold over random inputs: conservation, ordering, range, idempotence, round-trip. `hypothesis` for these.

**3. Silent-failure guards.** Anything that could plausibly return a wrong-but-plausible-looking value needs a test that would catch it: a known-good and a known-bad input that must produce *different* answers; an empty or degenerate input that must raise or return a sentinel, never a number that looks fine.

**4. Schema tests, if the project produces structured records.** A results record is invalid unless it carries whatever the project has decided is load-bearing — inputs, config, the verdict, a version tag for anything whose definition could silently change.

**5. Smoke test.** One test runs the entire path end to end on the smallest input that exercises it, in under a minute. It asserts nothing about the actual result; it exists so integration breakage surfaces early rather than hours into a real run.

**Version anything whose silent change would invalidate prior results.** If a metric, scoring function, or schema changes meaning without its version tag changing, every prior result using it is now misleadingly labeled. Where this risk exists, CI should catch a definition change with no matching version bump — how depends on what the project actually has (a hash of the defining function, a fixture-based regression test, whatever fits).

### When to write a test

| Write one if… | Skip it if… |
|---|---|
| The output is depended on elsewhere | It only produces something a human will look at once |
| Failure is silent | Failure is loud and immediate |
| There is a known-correct value to check against | The expected value would just be whatever the code returns now |
| More than one caller depends on it | It is a one-off analysis script |
| It defines something — a metric, a schema, an invariant | It orchestrates things that are themselves tested |

**Test definitions and silent failures; don't test exploration.** A regression test whose expected value was copied from current output tests nothing except that the code has not changed.

### Numerical tolerance

State the tolerance in the test with a one-line comment saying where it comes from. **Never widen a tolerance to make a test pass** — that converts a real disagreement into a silent one.

---

## Beyond tests

### Computable verdicts

If the project produces pass/fail verdicts from stored data, the verdict must be **recomputable from the stored inputs**, and CI should recompute it where that's feasible. A pipeline that runs correctly but whose stated conclusion doesn't follow from its own numbers is a failure mode no unit test catches.

### Provenance

Every result worth keeping carries enough to reproduce it later: code version, config, random seed, data/checkpoint identity, library versions, wall-clock, hardware. A record without provenance is unusable later and hard to defend in review. Seed everything at run start and record the seed.

### Config as data

One frozen, serializable config per run, hashed. The hash can *be* the run ID. Resumability then comes free: write results incrementally, and on restart skip whatever already has a record for that hash. Instances are ephemeral and capped — losing a long run to a stop is a self-inflicted wound.

### Fail fast in production paths

Assertions inside `src/`, not only in `tests/`: sanity checks after anything that could silently go wrong, shape/range assertions at boundaries. **Raise, don't clamp.** A clamped value looks plausible and is a lie.

### Adversarial self-review

Any commit touching something load-bearing (a metric, a schema, a core algorithm) includes a short **"how this could be wrong"** note in the body — the most plausible way the change produces a confident wrong result, not a summary of the diff. Anything it cannot resolve goes in `REVIEW.md` for human eyes. There is no reviewer in the loop by default; this is the substitute, and it is a weak one, so keep the queue short and read it.

### Hygiene

Delete dead code rather than commenting it out. Type hints where the project uses them; keep the type checker in CI if there is one. Analysis that produces a figure should write it to disk from a script, not a notebook, so every figure has a reproducible command behind it.

---

## CI

A tiering pattern that scales with how expensive each check is — adapt the specifics to what the project actually has:

| Tier | Contents | Budget |
|---|---|---|
| 0 | lint, format, types | seconds |
| 1 | fast unit tests against known-correct values, no heavy setup | < 30 s |
| 2 | property tests + a smoke test of the full path | < 2 min |
| 3 | slow integration tests — real data/checkpoints; on demand or nightly | minutes |

If the project has versioned metrics/schemas and verdict recomputation (see above), run those over every existing record, not just new ones, so a definition change surfaces as a failure on all affected historical records rather than leaving them quietly stale.

---

## Working on a status-board row

1. Read the row and the `PROJECT.md` section it references.
2. Write the test file first. If the row is a gate, the test *is* the pass/fail criterion — encode it, don't eyeball it.
3. Implement until the fast tiers are green.
4. Run the row. Emit a results record if the project produces one.
5. Update the status board. Decisions to §9, new uncertainties to §10.
6. Commit, push, wait for CI.

**A gate that fails stops the phase.** Record the failure in §9 with the decision taken. Do not route around it, do not weaken its criterion, and do not proceed on the assumption it will pass later.

## Fleet

This repo runs on the shared research fleet; see `infra/rvm.env` for how. `RVM_PYTHON` must match CI. Results and transcripts are backed up to S3 before an instance terminates, but **the repo is the only durable record** — an unpushed commit does not exist.

### Workers

Launching workers is allowed and expected — it is the answer whenever work does not fit on the orchestrator, before you conclude you are blocked or hand back to a human. Put the fan-out in `sweep_manifest.json` and let `infra/wrapper.sh` launch it; each entry may set its own `cmd` and `instance_type`.

- **Spot only.** Every worker is a one-time spot instance. Never launch on-demand, never pass your own `--instance-market-options`, never "fall back to on-demand because spot failed" — a spot failure is a finding: record it and stop.
- **Smallest thing that works.** Start at the launch-template default size; step up one size only on a *demonstrated* OOM, never on a guess. Prefer many small workers to one big one. Never launch a GPU instance without human sign-off recorded in `PROJECT.md`.
- A reclaim kills a worker mid-run, so write results incrementally and sync to S3 as you go. "The instance is gone" is never "the work is done" — the pushed result commit is the completion signal.

### Not yours to do

Provisioning outside the worker pattern: resizing/stopping/starting the orchestrator, IAM changes, creating or repointing launch-template versions, or touching any resource not tagged `Project=research-vm`.

## When finishing

Update the status board. Append decisions to §9, uncertainties to §10. Leave the tree clean and pushed.
