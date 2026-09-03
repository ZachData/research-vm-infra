# ROADMAP — long-lived project orchestrator

Working tracker for the next phase of the fleet: **a general AMI plus one
long-lived orchestrator per project that maintains that project over months**.

`PROJECT.md` stays the source of truth for the fleet's core question (one image,
one boot path). This file tracks the new direction until the pieces stabilise,
at which point the settled claims fold back into `PROJECT.md` §5/§9.

Legend: ○ not started · ◐ in progress · ● done · ✗ abandoned

**Two directions were dropped on 2026-09-03 — see §7:**
- **No ASG.** The user starts / stops / terminates the orchestrator by hand.
  Expected pattern: stopped overnight, running during the day. Storage, not
  compute, is most of the monthly cost, so the saving is small and not worth an
  autoscaler that has already misbehaved once.
- **No Terraform, for now.** `infra/tf/` is parked. The substrate (IAM, launch
  templates, SSM, SG) is changed by the user only, in the AWS console. The
  orchestrator must never be able to edit its own permissions, and TF state /
  config in a repo the orchestrator can push to is exactly that risk.

---

## 1. Target picture

**The instance is cattle. The project is the pet. The user is the shepherd.**

Every piece of durable state lives in git (code, `PROJECT.md`, backlog) or S3
(venv cache, agent memory, transcripts, heartbeat). The box holds nothing that
cannot be lost. "Keep the orchestrator alive for a long time" means: after a
manual stop/start, a reboot, or a rebuild, the box boots the general AMI,
rehydrates from git + S3, and resumes the maintenance loop on its own.

```
manual: create the project repo, write the idea into PROJECT.md (second-agent
        review pass), push. Then `rvm launch <owner/repo>` — one on-demand
        orchestrator. Stop/start/terminate it by hand thereafter.
   │
   ▼
AMI (general): OS + git + gh + awscli + uv + Claude Code + login +
     /opt/rvm/infra clone. No project, no venv, no token.
   │
   ▼
boot: bootstrap.sh → cap-as-backstop, receipt, git auth from SSM, clone project,
      venv from S3 cache, memory pull → hand to the maintenance loop
   │
   ▼
maintenance loop (systemd, Restart=always): pick one unit of work
      (agent-labelled issue → PROJECT.md §10 → backlog) → fresh bounded Claude
      session → open a PR → reviewer-agent pass → push, memory push, transcript
      to S3, heartbeat → sleep → repeat. Idle between work is expected. Workers
      for fan-out are spot-only, launched from the worker template.
```

Cost safety is **alert, never kill**: an AWS Budget (account-wide is enough to
start; per-project once `RvmProject` is an activated cost-allocation tag), a
stalled-loop alarm, and the user stopping the box when it is not needed. The
automated time-stop and usage-stop that kept turning off working instances were
removed on 2026-09-03 and are not coming back.

---

## 2. Status board

| Area | Item | Status | Notes |
|---|---|---|---|
| Cost safety | Remove auto time-stop + usage-stop from EC2 template user-data | ● | They stopped instances mid-work. Removed from the launch-template user-data field |
| Cost safety | AWS Budget, SNS alert (no kill) | ○ | Start with an account-wide budget (no tags needed) in the Billing console. Per-project budgets later, once `RvmProject` is an activated cost-allocation tag |
| Cost safety | Stalled-loop alarm (heartbeat age), notify only | ○ | Depends on the loop emitting an `rvm/heartbeat_age_seconds` metric. Console-created CloudWatch alarm → SNS |
| Credentials | Split PAT: control-plane (Administration:write, my laptop) vs box (Contents+PR only) | ✗ | Deferred 2026-09-03. `/research-vm/github-pat` rescoped to **all-repositories** (read/write, administration, code, workflows) — G0 unblocked. Split is defense-in-depth; not needed while repo creation is manual and the box only pushes branches. Accepted: box token is all-repos + administration |
| Credentials | Harden SSM param: customer-managed KMS key, IAM scoped to one ARN, CloudTrail data events | ○ | |
| IaC | Terraform for the substrate | ✗ | Dropped 2026-09-03 (§7). Scope-creep / privilege risk: the orchestrator can push to this repo, so TF config or state here = the orchestrator editing its own permissions. Substrate stays console-managed by the user. `infra/tf/` to be removed or moved to a repo the fleet never clones |
| IaC | `infra/tf/` scaffold + `project-orchestrator` module | ✗ | Parked with the Terraform decision. Kept in git history; not wired to anything |
| Orchestrator | Generic launch template reads its project at runtime (tag/SSM), not via `sed` | ✗ | Was only needed for the ASG path. `rvm launch` does the `sed` substitution and that is fine for a hand-launched box |
| Orchestrator | `bootstrap.sh`: replace 4h cap + idle-stop with daemon hand-off | ◐ | Cap stays only as a wedged-loop backstop; idle-stop deleted. Worker cap now does `shutdown`→terminate (spot can't be stopped); default 2h. Orchestrator hand-off to `daemon.sh` still TODO |
| Orchestrator | Maintenance loop `daemon.sh` + systemd unit, `Restart=always` | ○ | Fresh Claude session per iteration; bounded by wall-clock + max-turns |
| Orchestrator | Heartbeat to S3/CloudWatch each iteration; `rvm ps` reads it | ○ | |
| Agent quality | Reviewer-agent pass on every PR before merge | ○ | Agent opens PRs only; never pushes to `main` |
| Agent quality | Reviewer-agent pass on hypothesis / PROJECT.md formation | ○ | Same mechanism, applied to the initial `PROJECT.md` skeleton |
| Agent quality | Stuck-task backoff: attempt counter, escalate to §10 after N failures | ○ | |
| Templates | Separate minimal `research-project-template` repo (not generated from this repo) | ○ | `PROJECT.md`, `CLAUDE.md`, `infra/rvm.env`, `infra/prompt.md`, `pyproject.toml`, `backlog/` |
| Cleanup | Reconcile `small_t4g_template` user-data with `boot/user-data.sh.tmpl` | ○ | Live template v11 is the legacy gh-only bootstrap, not the generic path — see §6 |
| Cleanup | Retire `/research-vm/github-deploy-key` | ○ | PROJECT.md §10 says deploy keys are gone; param may still exist |
| Cleanup | Tag or terminate the 2 stopped untagged `t4g.small` instances | ○ | `i-00e5e4b2964a3acc9`, `i-089f06ca9e53e701c` — no `Name`/`RvmProject` |

---

## 3. Work breakdown

### Phase A — Terraform adoption — ✗ DROPPED 2026-09-03 (§7)

### Phase B — cost safety (AWS console, user)
- [ ] Account-wide AWS Budget, 80% actual / 100% forecast → SNS email. No tags
      needed; immediate. (Billing console → Budgets → Create budget.)
- [ ] `research-vm-alerts` SNS topic + email subscription; confirm the email.
- [ ] Later: activate `RvmProject` as a cost-allocation tag (~24h backfill), then
      add per-project budgets filtered on it.
- [ ] Verify an alert actually arrives (drop a threshold temporarily).

### Phase C — long-lived orchestrator boot (code)
- [ ] `bootstrap.sh`: drop the idle CPU alarm; keep the hard cap only as a
      wedged-loop backstop; hand off to `daemon.sh` instead of `wrapper.sh`.
      *(Worker cap already fixed: `shutdown`→terminate, default 2h.)*
- [ ] `daemon.sh`: the loop in §1. systemd unit `rvm-daemon.service`, `Restart=always`.
- [ ] Heartbeat: `aws cloudwatch put-metric-data` (or an S3 object) each iteration.
- [ ] `rvm stop <project>` / `rvm start <project>` = `aws ec2 stop/start-instances`
      on the tagged orchestrator (no ASG).
- [ ] Prove one full rehydrate: stop the box, start it again, loop resumes on the
      same project with memory intact.

### Phase D — per-project ASG — ✗ DROPPED 2026-09-03 (§7)

### Phase E — agent quality
- [ ] Reviewer-agent pass wired into the loop before a PR is marked ready
- [ ] Same pass invoked on `PROJECT.md` skeleton creation
- [ ] Stuck-task attempt counter + escalation to `PROJECT.md` §10
- [ ] Decide the merge gate: me, or an approving reviewer-agent, or both

### Phase F — templates
- [ ] Create `research-project-template` repo (I do this by hand)
- [ ] Populate it; document the "new project" checklist (create repo → write idea →
      reviewer pass → push → `rvm launch`)

---

## 4. Dividing line (keep this honest)

The substrate — IAM roles/policies/profiles, launch templates, security group,
SSM parameter definitions, SNS topic, budgets, CloudWatch alarms, the S3 bucket
and its policy — is **the user's**, changed in the AWS console. No automation in
this repo touches it. The orchestrator can push to this repo, so anything in
here that could change the substrate is the orchestrator changing its own
permissions.

`rvm` (bash + AWS CLI, run on the box) does only *actions* within the permissions
it already has: launch a spot worker from the worker template, stop/start/
terminate a `Project=research-vm` instance, build/publish the env cache, pull
data caches, back up transcripts, read heartbeats.

---

## 5. Open questions / decisions needed

- ~~ASG user-data delivery~~ — moot, ASG dropped. `rvm launch` does the `sed`.
- ~~Does Terraform own the S3 bucket~~ — moot, Terraform dropped.
- **Merge gate.** Agent opens PRs only. Who merges — me, an approving
  reviewer-agent, or both required?
- **Fresh session vs `--continue` per loop iteration.** Leaning fresh: it forces
  `PROJECT.md` + memory to be sufficient context and sidesteps months of drift.
- **Work source priority.** Proposed: agent-labelled GitHub issues → `PROJECT.md`
  §10 open questions → `backlog/TASKS.md`. Confirm.
- **One project per instance, or several per box?** `lib/common.sh` still has
  multi-project-per-box scaffolding (venv-per-project root). Leaning one project
  per box — pick one and delete the other path.
- **Stalled-loop threshold.** Proposed: alert if no heartbeat for 3h. The loop
  sleeps ~1h when idle, so 3h = two missed cycles.
- **What to do with `infra/tf/`** now Terraform is dropped: delete it from this
  repo, or move it to a separate private repo the fleet never clones? Leaning
  delete — it can come back from git history. If it ever returns, its state must
  live in a bucket the instance roles cannot read (they can currently write
  `s3://research-vm-shared-.../terraform/`).
- **Daemon defaults — proposed 2026-09-03, awaiting confirmation:** one project
  per box (delete the multi-project venv-root path in `lib/common.sh`); a fresh
  bounded `claude` session per loop iteration (not `--continue`); work priority
  agent-labelled issues → `PROJECT.md` §10 → `backlog/TASKS.md`; merge gate =
  human (me), reviewer-agent pass advisory only, agent never pushes `main`.

---

## 6. Known drift & cleanup (found 2026-09-03)

- **`small_t4g_template` (lt-0eec91e84f9433c58) v11 user-data** is the legacy
  bootstrap that only installs `gh` and writes the PAT — it is **not**
  `boot/user-data.sh.tmpl`. `rvm launch` always overrides user-data, and with
  ASG dropped nothing launches the template raw, so this is low priority — but
  worth cleaning the stale user-data field so the template isn't a foot-gun.
- **`research-vm-worker-template` (lt-0c6bea8826a010179) v4** — default version,
  carries **no user-data** and the one-time spot market options. Launch verified
  end to end 2026-09-03 (spot instance booted, wrote to the bucket, terminated).
  v1–v3 have no spot options; do not pin them.
- **`/research-vm/github-deploy-key`** — confirmed **still present** 2026-09-03
  (SecureString, v1). Retire by hand:
  `aws ssm delete-parameter --name /research-vm/github-deploy-key`.
- **Untagged stopped instances** `i-00e5e4b2964a3acc9`, `i-089f06ca9e53e701c` —
  no longer present as of 2026-09-03 (terminated).
- **This box** (`i-037750095bbd298a7`) is now tagged `Name=Lora`. A second
  orchestrator `i-00ba65488bfbbcf1b` (`Name=Archetype`) is also running.

---

## 7. Decisions log

| Date | Decision | Why |
|---|---|---|
| 2026-09-03 | Remove automated time-stop and usage-stop entirely | They stopped instances that were still working. Cost safety moves to alert-only (Budget) + the user stopping the box by hand |
| 2026-09-03 | ~~Long-lived orchestrator supervised by an ASG of size 1~~ — **superseded same day** | See next row |
| 2026-09-03 | **No ASG.** The user starts/stops/terminates the orchestrator by hand; expected pattern is stopped overnight, running by day | The ASG misbehaved once already, and storage (not compute) is most of the monthly cost, so an autoscaler buys very little. `rvm stop/start` becomes `aws ec2 stop/start-instances` on the tagged box. The daemon (`Restart=always`) still gives resume-after-reboot |
| 2026-09-03 | ~~Terraform for the AWS substrate~~ — **superseded same day** | See next row |
| 2026-09-03 | **No Terraform, for now.** The substrate (IAM, launch templates, SSM, SG, budgets, SNS) is changed by the user in the AWS console only. `infra/tf/` is parked | The orchestrator can push to this repo. TF config or state in a repo the orchestrator can write to = the orchestrator able to change its own IAM. The isolation is worth more than the reproducibility here. If TF returns it lives in a repo the fleet never clones, with state in a bucket the instance roles cannot read |
| 2026-09-03 | Workers are spot-only, one-time, from `research-vm-worker-template`; enforced in IAM (`RunInstances` denied for anything else) | An on-demand worker is several times the price for identical output. Verified 2026-09-03: on-demand and no-template launches are denied; spot-from-template succeeds |
| 2026-09-03 | Worker hard cap does `shutdown`→terminate, not `aws ec2 stop-instances`; default 2h, raisable per project | A one-time spot instance cannot be stopped (`UnsupportedOperation`), so the old cap silently did nothing on a spot worker. An OS shutdown needs no EC2 permission and the worker template turns it into a terminate |
| 2026-09-03 | ~~Split the GitHub token: control-plane vs box~~ — **superseded same day** | See next row |
| 2026-09-03 | `/research-vm/github-pat` rescoped to all-repositories (read/write, administration, code, workflows); the split is deferred, not abandoned in principle | Repo creation is manual and the box only pushes PR branches, so the split is defense-in-depth. Revisit if a project ever runs untrusted code that could exfiltrate the SSM token |
| 2026-09-03 | S3 stays minimal; state does not move to git | The only load-bearing use is the venv cache (multi-GB, content-hashed, 13s restore vs 6min build). Boot receipts (written when git auth may itself have failed), heartbeat (a commit per iteration otherwise) and transcripts (history bloat) each have a specific reason not to be in git. "Smaller/simpler" = lifecycle rules, not an architecture change |
| 2026-09-03 | Repo creation stays manual | Not enough new project ideas to justify automating it. Some steps are allowed to be manual |
| 2026-09-03 | Projects start from a separate minimal `research-project-template`, not generated from `research-vm-infra` | Generating from this repo copies the infra scripts into every project and re-breaks the separation in PROJECT.md §9 |
| 2026-09-03 | Reviewer-agent pass on every PR and on `PROJECT.md` hypothesis formation; agent opens PRs only, never pushes `main` | The main risk of an unattended loop is days of unreviewed bad commits |

---

## 8. Session log

### 2026-09-03 — infra-as-code push, pre-Terraform

**Done**

- PAT `/research-vm/github-pat` rescoped to all-repositories (read/write,
  administration, code, workflows). G0 unblocked.
- S3 bucket versioning **enabled** (prerequisite for the Terraform S3 backend).
- Idle-stop CloudWatch alarm and the hard-stop `at` job **removed from the live
  `small_t4g_template` user-data** (console edit). `bootstrap.sh` in the repo
  still creates both — reconcile in Phase C.
- Reconnaissance from this box (`i-037750095bbd298a7`, role `research-vm-ssm-role`):
  - CAN: `ec2:Describe*`, `ssm:GetParameter` (by name), `s3:PutObject` under `terraform/`.
  - CANNOT: any `iam:*`, `s3:GetBucketVersioning`, `ssm:DescribeParameters`.
    → Phase A must run from a laptop with an admin profile.
  - `terraform` 1.16.1 is installed on the box.
  - `/research-vm/daemon-control` does **not** exist → make it a new TF resource,
    not an import (`imports.tf` currently has it as an import — will fail).
  - `/research-vm/github-deploy-key` **does** still exist (SecureString v1).
  - `git push` from the box works only over HTTPS via the `gh` PAT; `origin` is
    still the SSH URL and the only SSH key here is a deploy key for another repo.
- Full execution runbook drafted (Parts 1–7): Console cost steps, laptop setup,
  Terraform adoption, cost safety, generic boot, first ASG, cleanup.

**Next / awaiting the user**

- Enable Cost Explorer + activate the `Project` cost-allocation tag (24h clocks);
  optionally add an unfiltered account budget now as an immediate backstop.
- Laptop admin profile → `terraform init` → run the six `aws iam list-*` /
  `get-instance-profile` commands + two `describe-launch-template-versions` →
  paste output.
- Decide deploy-key retirement: import-and-destroy vs `aws ssm delete-parameter`.
- Confirm the four daemon defaults in §5.

**Next / mine, once the above lands**

- Fix `infra/tf/`: `daemon-control` → new resource; add `aws_sns_topic_policy`
  for `budgets.amazonaws.com`; fill the IAM `import` blocks from pasted output.
- Write `daemon.sh`, `rvm-daemon.service`, tag-based project resolution in
  `boot/user-data.sh.tmpl`, and a `daemon` role in `bootstrap.sh`.

### 2026-09-03 — doc accuracy pass + spot findings

**Fixed (factual corrections in this repo)**

- `CLAUDE.md` — stated that running AWS commands is this repo's job (launch/stop/
  terminate `Project=research-vm` instances, put metrics, S3); tightened the
  "Do not" bullet to the real exceptions (IAM, `CreateImage`, launch-template
  repointing, untagged resources).
- `PROJECT.md` — PAT scope marked RESOLVED (§10, G0 row, §2 secret row); added a
  direction note that `ROADMAP.md`'s daemon model supersedes §3/§5 where they
  disagree; instance RAM corrected to ~1.8 GB / no swap; §2 launch-template row
  now records that worker spot depends on v4 being the default version; idle
  alarm marked "being retired".
- `README.md` — idle-alarm line and PAT/deploy-key bullet updated.
- `infra/tf/backend.tf` — versioning prereq marked done.
- `templates/CLAUDE.md` — added "Workers" (spot-only, smallest-thing-that-works)
  and "Not yours to do" sections, modelled on Lora's.
- Pulled `Lora_inductionhead` (91 commits). Its `CLAUDE.md` already has correct
  spot-only + S3-bucket sections (commit `e000eda`) — the "no S3 bucket" text
  was the pre-pull copy.

**Open code bugs (unproven until a real launch)**

- **B1** `worker.sh` failure path and the `bootstrap.sh` hard cap both call
  `aws ec2 stop-instances`, which a one-time spot instance rejects
  (`UnsupportedOperation`). A failed spot worker has nothing that stops it →
  violates C5. Fix: spot → `terminate-instances` on both paths; diagnose from
  pushed partials + S3, not a stopped box.
- **B2** spot is inherited, not enforced: `bin/rvm` launches with no template
  version, so workers are spot only while worker-template v4 stays default.
  Proposed: pass `--instance-market-options` explicitly for `--role worker` +
  an `RVM_WORKER_SPOT=1` default that must be explicitly unset to go on-demand.
- **B3** `bootstrap.sh` still creates the idle CloudWatch alarm; `rvm launch`
  overrides user-data so it returns even though the live template lost it.
  Removed as part of the daemon rework (Phase C).
- **B4** no handler for the spot interruption notice
  (`.../meta-data/spot/instance-action`); a reclaim loses unflushed work.

**Contradictions for the user to resolve**

- **D1** `bin/rvm new` still scaffolds `PROJECT.md`/`CLAUDE.md` from `templates/`,
  which decision 2026-09-03 (separate `research-project-template` repo) rules
  out. Pick one.
- **D2** `templates/CLAUDE.md` is Lora-shaped (φ, closed-form oracles,
  `METRIC_VERSION`) — not generic. Genericise when templates move (D1).
- **D3** `PROJECT.md` §3/§5 still describe the ephemeral model end-to-end; only
  a banner points at the daemon model so far. Needs a real reconciliation pass.

### 2026-09-03 — ASG cut, Terraform parked, spot verified end to end

**Decisions** (details in §7): no ASG — user runs the orchestrator by hand;
no Terraform — `infra/tf/` parked, substrate is console-only and the user's.

**Spot worker test — real launch, ~2 min, ~1¢**

- Launched a one-time spot `t4g.small` from `research-vm-worker-template` (v4).
  IMDS `instance-life-cycle` reported `spot`. It wrote a hello-world file to
  `s3://research-vm-shared-176048535722/spot-test/` using the **worker role** —
  so `research-vm-worker-role` has `s3:PutObject` (closes half of a PROJECT.md
  §10 open question). `shutdown`/terminate path works.
- **B1 confirmed exactly:** `aws ec2 stop-instances` on that instance failed with
  `UnsupportedOperation` — "can't stop … one-time Spot Instance request". This is
  the "test passes but using it errors" bug.
- IAM matrix (dry-run): spot-from-worker-template ✅; on-demand-from-orchestrator-
  template ❌ (`iam:PassRole` denied); on-demand no-template ❌; spot no-template
  ❌. So **only spot, only from the worker template** — as intended.

**Code changes (unproven until a full worker launch through `bootstrap.sh`)**

- `bootstrap.sh` — worker cap (both the step-0 and the post-config reset) now
  runs `shutdown -h now` instead of `aws ec2 stop-instances`; orchestrator path
  unchanged. Logs the role.
- `worker.sh` — failure path terminates via `shutdown` instead of a
  `stop-instances` that can't work on spot; header comment corrected.
- `lib/common.sh` / `templates/rvm.env` — `RVM_WORKER_HOURS` default 3 → **2**.
- `bin/rvm` — `--role worker` passes `--instance-market-options … MarketType=spot`
  explicitly, so a template default that ever regresses can't yield on-demand.
- All four pass `bash -n`. `shellcheck` not installed on this box — run it on the
  laptop before relying on the diff.

**Still B3/B4:** `bootstrap.sh` idle CPU alarm still created (Phase C removes it);
no spot-interruption-notice handler.

**Next**

- Phase C: `daemon.sh` + `rvm-daemon.service`, drop the idle alarm, `rvm
  stop/start <project>` = `aws ec2 stop/start-instances` on the tagged box.
- Prove the worker code: `rvm launch <project> --role worker --worker-id 0`
  against a repo with a trivial `RVM_WORKER_CMD`, read the receipt, confirm it
  self-terminated at the cap.
- D1/D2/D3 still open. Decide `infra/tf/`: delete from this repo, or relocate.
