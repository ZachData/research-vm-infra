# research-vm-infra

**Can one image and one boot path serve every project in this account — such that starting a new project costs a config file and a launch argument, and no dependency, interpreter, tool, or project change ever requires rebuilding the AMI?**

This is the living specification and the source of truth for the fleet. It is updated at the end of every working session. If a claim here contradicts the code, one of them is wrong — resolve it explicitly in §9 and never let both stand.

The system is infrastructure, not science, but the discipline is the same: every claim below is stated so that it can fail, with a criterion fixed before the measurement. Infrastructure that is never falsifiable is infrastructure that is quietly broken.

---

## Status board

| Phase | Item | Status | Notes |
|---|---|---|---|
| Setup | Generic boot path: user-data → infra repo → bootstrap | ● | `boot/user-data.sh.tmpl` renders to 1.4 KB with the project as the only variable; no placeholders survive substitution; parses under `bash -n` |
| Setup | PAT-based git auth replacing the per-repo deploy key | ● | Deploy keys are scoped to one repo, which is what made the old setup single-project. Credential-store helper, token never written into a remote URL |
| Setup | Env cache: hash → S3 → restore | ● | Lora_inductionhead 3.11: build 6 min → publish 356 MB → **restore 13 s** → 435 unit tests pass → second call a no-op. Measured on this instance, not on a cold boot (see §6) |
| Setup | Per-project interpreter via `uv` | ● | `RVM_PYTHON=3.11` fetched at boot. Closes the 3.12 skew that made Lora's tier-0 metric-hash gate fail locally while CI was green: 434 passed/1 failed under 3.12 → **461 passed/0 failed** under 3.11 |
| Setup | CPU torch on GPU-less instances | ● | torch resolves to a CUDA build on aarch64 by default: 2.9 GB of unusable libraries. CPU index → venv 5.2 GB → 1.5 GB, cache artifact 2.7 GB → 356 MB |
| Setup | Agent memory survives terminate | ● | `s3://…/memory/<project>/`, pushed by `rvm backup`, restored by bootstrap. Untested against a real memory write (§10) |
| Setup | Boot receipts | ● | Every exit path writes status + elapsed + log tail to `s3://…/boot-receipts/`. Verified locally against a synthetic invocation |
| Setup | Hard cap set before anything that can fail | ● | Was set at the end of bootstrap, under `set -e`: a failed clone left an instance running with no cap. Now first, then reset to the project's value once config is read |
| G0 | Cold start on a second project, from a real launch | ○ | **The gate that matters.** Everything above is measured on a warm, hand-configured box. Blocked on PAT repository scope (§10) |
| G1 | Bake the generic image; relaunch both projects from it | ○ | `bake-prep.sh` written and reviewed, not yet run. One bake, then rarely |
| G2 | Sweep fan-out under the generic worker path | ○ | Worker path is a rewrite of a mechanism that worked; it has not run a real cell |
| G3 | A dependency change costs no AMI rebuild, demonstrated end to end | ○ | Edit `pyproject.toml` → boot → observe a miss, a build, a publish, and a hit on the next boot |

Legend: ○ not started · ◐ in progress · ● done · ✗ failed/abandoned

---

## 1. Framing

The previous setup baked one project into the image: repo cloned at bake time, venv built at bake time, launch-template user-data naming `Lora_inductionhead` in four places. A second project meant a second AMI. A dependency change meant rebuilding one. Both are expensive enough that they don't happen, so the image drifts from the repo and instances run against stale dependencies — the failure that the `pip install -e` line in the old `wrapper.sh` was added to paper over.

The inversion: **the image holds only what never changes; everything that changes arrives at boot.** The test of the design is not that it works once but that the AMI stops being on the critical path for any routine change.

**What would make this a failure.** If, six months from now, starting a project still requires a bake; or if the cache is so often missed that boots are slow anyway; or if a boot failure leaves no evidence and the fleet has to be debugged by hand — then this is worse than the thing it replaced, because it is more moving parts for the same outcome.

## 2. Substrate

| | |
|---|---|
| Account / region | `176048535722` / `us-east-2` |
| Bucket | `research-vm-shared-176048535722` — put and get, **no `s3:DeleteObject`** (§10) |
| Roles | `research-vm-ssm-role` (orchestrator), `research-vm-worker-role` (worker) |
| Launch templates | `small_t4g_template`, `research-vm-worker-template` — supply AMI, IAM profile, security group; `rvm launch` overrides user-data and instance type, so one pair serves every project |
| Instances | `t4g.small`, arm64, 2 vCPU / 2 GB, no GPU |
| Secret | `/research-vm/github-pat` in SSM. Must be able to see and push to every project repo |
| Image | Currently `ami-0d469967250a418da` (Lora-specific). To be replaced once, by `bake-prep.sh` |

## 3. Mechanism

```
AMI ──> user-data (project name substituted; everything else fixed)
         └─ clone/reset research-vm-infra
            └─ bootstrap.sh <owner/repo> <role>
               0.  hard cap (before anything that can fail)
               0b. receipt trap
               1.  git auth from SSM
               2.  clone/reset the project repo
               3.  venv: hash → restore, or build → publish
               4.  data caches; 4b. agent memory
               5.  ~/.rvm-current, shell autostart
               6.  cap reset to the project's value; idle alarm
               7.  wrapper.sh | worker.sh
```

**The env-cache key.** `envs/<arch>/py<version>/<project>/<hash>.tar.zst`, where the hash covers, and must cover, everything that can change the resulting `site-packages`:

| In the hash | Why |
|---|---|
| dependency file contents (`RVM_ENV_FILES`) | the obvious input |
| `RVM_PYTHON` | a venv for one minor version does not work under another |
| architecture | compiled wheels are not portable |
| GPU presence | decides the CUDA vs CPU torch build |
| `RVM_ENV_INSTALL` verbatim | the install command is itself an input |

Anything that changes the environment and is *not* in this list produces a silently stale environment served from cache — the one failure mode of this design that no test currently catches (§6).

**Non-relocatability.** A venv's scripts carry absolute shebangs, so a tarball is only valid extracted to the path it was built at. `RVM_VENV` is therefore fixed at `/home/ubuntu/venv` rather than per-project, and restore extracts to scratch and swaps, so an interrupted download cannot leave a half-populated venv that later looks valid.

## 4. Metrics

| Metric | Definition | Measured |
|---|---|---|
| `restore_seconds` | wall-clock, cache hit to usable venv | 13 s (Lora, 356 MB, warm instance) |
| `build_seconds` | wall-clock, cache miss to publish | ~360 s (Lora 3.11) |
| `cold_start_seconds` | instance launch to `ok` receipt | **unmeasured** — G0 |
| `receipt_rate` | boots leaving a receipt / boots | unmeasured; target 1.0 |
| `image_age_cost` | changes since the last bake that required a rebuild | target 0 |

## 5. Pre-registered claims

Criteria fixed now, before G0 runs. Each is a comparison a machine can evaluate against a boot receipt.

| | Claim | Falsified by |
|---|---|---|
| C1 | A project new to the fleet boots to a working env with no change to this repo | any new project requiring a commit here that is not its own `projects/<name>.env` override |
| C2 | A cache hit restores in under 60 s | `restore_seconds ≥ 60` on a cold boot |
| C3 | A dependency change requires no AMI rebuild | a boot that cannot produce a working env without a new image |
| C4 | Every boot leaves a receipt, success or failure | any instance that reaches `running` and writes no receipt |
| C5 | No instance is ever left running without a cap | any instance found running past its cap with no `at` job |

C4 and C5 are the ones with teeth. C1–C3 fail visibly; C4 and C5 fail silently, and their failure mode is a bill.

## 6. What can and cannot be concluded

- The 13 s restore was measured **on this instance's own volume, warm, with the AMI's page cache and an existing venv directory**. It is evidence that the mechanism works; it is *not* a cold-start number. Nothing may be claimed about cold start until G0 produces a receipt.
- The Python-version finding is a fact about `ast.dump`, already recorded in Lora's own §11 before this work started. What is new is that the fleet now *fixes* it rather than documenting it as a local limitation.
- The stale-cache failure mode in §3 is unguarded: if a project's environment depends on something outside the hash inputs (a system library, an apt package, a `~/.netrc`), the cache will serve a wrong env confidently. There is no test for this, and a test would have to enumerate exactly the thing that is hard to enumerate.
- `bake-prep.sh` has been reviewed, not run. Its riskiest steps — `cloud-init clean`, machine-id truncation, `at` queue flush — are exactly the ones whose failure is invisible until a *future* instance misbehaves.

## 7. Protocol

1. Change the boot path only in this repo. Instances fetch it at boot, so a fix ships by push.
2. Every change to `bootstrap.sh`, `worker.sh` or `user-data.sh.tmpl` must be proven by a real launch producing an `ok` receipt. `bash -n` is not evidence about a boot.
3. A gate that fails stops the phase. Record it in §9 with the decision taken; do not route around it.
4. Never widen IAM to make something work without recording why in §9. The absence of `ec2:CreateImage` and `s3:DeleteObject` from the instance roles is deliberate.

## 8. Discipline

- **Do not bake anything project-specific.** The image's value is that it is boring.
- **Do not put a secret in the image.** Every credential is re-established at boot from SSM.
- **Do not hardcode a project name** anywhere in this repo outside `projects/`.
- **Do not change the env-hash inputs without bumping the `v` prefix** in `rvm_env_hash`. Old entries would otherwise be served under a key whose meaning changed.
- **Do not delete from S3 by hand** to "clean up" a cache. The roles cannot, deliberately; a lifecycle rule is the supported path.

## 9. Decisions log

| Date | Decision | Why |
|---|---|---|
| 2026-09-01 | Infra lives in its own git repo, cloned at boot, not in S3 and not copied per project | A fix reaches every future instance by push. Copies drift; S3 has no history or review |
| 2026-09-01 | Auth by account PAT over HTTPS, not per-repo deploy keys | A deploy key is scoped to one repo. Generality is impossible with them |
| 2026-09-01 | The venv is an S3 artifact keyed by content hash, not an image layer | Removes the AMI from the critical path for every dependency change |
| 2026-09-01 | `uv` in the image; interpreters fetched at boot | One image serves projects on different Python versions. Directly motivated by Lora's 3.11/3.12 skew |
| 2026-09-01 | CPU torch when no GPU is present, GPU flag in the cache key | 2.9 GB of unusable CUDA libraries per restore is a permanent tax on every boot |
| 2026-09-01 | Hard cap set first, then reset after config load | Under `set -e`, a cap at the end is a cap that a failed boot never sets |
| 2026-09-01 | Boot receipts to S3 | An unattended fleet with no evidence channel is debugged by guessing |

## 10. Open questions

- **PAT repository scope.** The token is scoped to selected repositories: it can push to `Lora_inductionhead` and `MetastableStateAnalysis` but 404s on `research-vm-infra`. Until it is switched to all-repositories, every new project needs a manual token edit — which defeats C1. This is the current G0 blocker.
- **No `s3:DeleteObject`.** Nothing prunes the env cache; entries accumulate at 0.3–3 GB each. A superseded 2.7 GB py3.12 artifact is already stranded. Needs a lifecycle rule on `envs/`, set from the console.
- **Worker-role S3 permissions are unverified.** The orchestrator role can put; whether `research-vm-worker-role` can read the env cache and write receipts has not been tested. If it cannot, every worker takes the slow build path or dies before its cap is set.
- **Concurrent publish.** Several workers missing the same key will each build and each upload. Wasteful, not incorrect — last writer wins on identical content. Worth a guard only if it is ever observed.
- **Memory sync is untested against real memory writes.** The directories exist and are empty; the sync has never round-tripped an actual memory file.
- **The image is region-locked.** An AMI lives in `us-east-2`; nothing here handles a region change, and it would need a copy plus two launch-template edits.
- **Claude Code credentials in the image.** Baking the login is what makes unattended runs possible and is also the one credential deliberately left in the image. Revisit if the image is ever shared.
