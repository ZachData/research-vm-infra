# Handoff

_Read this first when resuming work on `research-vm-infra`. Updated at checkpoints.
Last update: 2026-09-03, ~19:30 UTC. Resuming in ~90 min._

## Current goal

Turn the fleet into "a real thing": one general AMI + one long-lived
daemon-orchestrator per project. `ROADMAP.md` is the working tracker; `PROJECT.md`
is the source of truth for the core question. This file is the short "resume here"
version.

## State of the tree — NOTHING IS COMMITTED

`git status`: 10 modified files + untracked `ROADMAP.md` and `infra/`.
All of this session's work is working-tree only. The box persists across a stop
(EBS), so a 90-min gap is fine, but **an unpushed change does not exist** for any
instance that boots from `origin/main`.

Modified this session:

| File | Why |
|---|---|
| `bootstrap.sh` | worker hard cap → `shutdown -h now` (terminate) instead of `aws ec2 stop-instances`, which a one-time spot instance rejects. Orchestrator path unchanged. |
| `worker.sh` | failure path terminates via `shutdown` instead of `stop-instances`; header comment corrected |
| `lib/common.sh`, `templates/rvm.env` | `RVM_WORKER_HOURS` default 3 → **2** |
| `bin/rvm` | `--role worker` passes `--instance-market-options MarketType=spot` explicitly (belt-and-braces; IAM is the real gate) |
| `CLAUDE.md` | "running AWS commands is this repo's job"; tightened the "Do not" bullet to the real exceptions |
| `PROJECT.md` | PAT scope RESOLVED; direction banner → ROADMAP daemon model; RAM ~1.8 GB/no swap; spot-depends-on-v4 recorded |
| `README.md` | idle-alarm line; PAT/deploy-key bullet |
| `templates/CLAUDE.md` | new "Workers" (spot-only) + "Not yours to do" sections |
| `.gitignore` | (pre-existing change, not mine) |
| `ROADMAP.md`, `infra/` | untracked; created in earlier sessions |

`git push` from this box: origin is an SSH URL whose only key is a deploy key for
another repo. Push over HTTPS via the `gh` PAT:
`git push https://github.com/ZachData/research-vm-infra.git HEAD:<branch>`
(or `git remote set-url origin https://github.com/ZachData/research-vm-infra.git`).

## What was done this session

- **Cut ASG.** User runs the orchestrator by hand (stop overnight / run by day).
  `rvm stop/start <project>` becomes `aws ec2 stop/start-instances` on the tagged
  box. Recorded in `ROADMAP.md` §7; Phases A and D struck.
- **Parked Terraform.** `infra/tf/` stays in the repo but is wired to nothing.
  Reason: the orchestrator can push to this repo, so TF config/state here = the
  orchestrator able to edit its own IAM. Substrate stays console-only, the user's.
- **Spot worker verified end to end** (real launch, ~2 min, ~1¢):
  - Spot `t4g.small` from `research-vm-worker-template` v4; IMDS `instance-life-cycle`
    = `spot`; wrote hello-world to `s3://research-vm-shared-176048535722/spot-test/`
    with the **worker role** (so `research-vm-worker-role` has `s3:PutObject`).
  - **Bug reproduced:** `aws ec2 stop-instances` on it → `UnsupportedOperation`
    ("one-time Spot Instance request"). This is why the old worker cap silently
    did nothing on spot.
  - IAM dry-run matrix: spot-from-worker-template ✅; on-demand any path ❌. So
    **only spot, only from the worker template** — as intended.
- Doc-accuracy pass across `CLAUDE.md` / `PROJECT.md` / `README.md` / templates
  (details in `ROADMAP.md` §8).
- Pulled `Lora_inductionhead` (91 commits, fast-forward).

## To do — in rough priority order

1. **Commit + push** this session's work on a branch (doc fixes + spot-cap fixes),
   open a PR. Nothing is safe until this happens.
2. **Phase C code** (`ROADMAP.md` §3):
   - `daemon.sh` — the maintenance loop (pick one unit of work: agent-labelled
     issue → `PROJECT.md` §10 → `backlog/TASKS.md`; fresh bounded `claude`
     session; open a PR; heartbeat to an S3 object + `rvm/heartbeat_age_seconds`
     CloudWatch metric; sleep; repeat).
   - `rvm-daemon.service` — systemd, `Restart=always`, per-iteration wall-clock +
     max-turns bound.
   - `bootstrap.sh` — remove the `research-vm-idle-*` CloudWatch alarm block (B3);
     keep the hard cap only as a wedged-loop backstop; add a `daemon` role.
   - `rvm stop <project>` / `rvm start <project>` = `aws ec2 stop/start-instances`
     on the tagged orchestrator (no ASG).
3. **Prove the worker cap fix** — `rvm launch <project> --role worker --worker-id 0`
   against a repo with a trivial `RVM_WORKER_CMD`; read the boot receipt; confirm
   it self-terminates at the 2h cap. (CLAUDE.md rule 5: unproven until this.)
4. **Cost backstop** (user, AWS console, ~3 min): account-wide AWS Budget, 80%
   actual / 100% forecast → SNS email. No tags needed, immediate.
5. **B4** — handle the spot interruption notice
   (`http://169.254.169.254/latest/meta-data/spot/instance-action`): force a
   flush + push before the ~2-min reclaim. Lower priority if projects sync
   incrementally.
6. **Run `shellcheck`** on `bootstrap.sh` / `worker.sh` / `bin/rvm` / `lib/common.sh`
   — not installed on this box; do it on the laptop.
7. **Retire `/research-vm/github-deploy-key`** (user): `aws ssm delete-parameter
   --name /research-vm/github-deploy-key`.
8. **Clean the stale user-data field on `small_t4g_template` v11** (low priority;
   `rvm launch` overrides it, and with ASG gone nothing runs it raw).

## Open decisions (need the user)

- **`infra/tf/` fate** — delete from this repo, or move to a repo the fleet never
  clones? (`ROADMAP.md` §5.)
- **D1** — `bin/rvm new` still scaffolds `PROJECT.md`/`CLAUDE.md` from `templates/`,
  which the "separate `research-project-template` repo" decision rules out.
- **D2** — `templates/CLAUDE.md` is Lora-shaped (φ, closed-form oracles,
  `METRIC_VERSION`), not generic.
- **D3** — `PROJECT.md` §3/§5 still describe the ephemeral model end to end; only
  a banner points at the daemon model. Needs a real reconciliation pass.
- **Four daemon defaults** (`ROADMAP.md` §5), proposed, unconfirmed: one project
  per box; fresh `claude` session per iteration; work priority as above; merge
  gate = human, reviewer-agent advisory only.

## Environment notes

- This box: `i-037750095bbd298a7`, tag `Name=Lora`, role `research-vm-ssm-role`,
  `t4g.small`, ~1.8 GB, no swap, `us-east-2a`, `subnet-0caf8f8bee91d80a0`.
- A second orchestrator `i-00ba65488bfbbcf1b` (`Name=Archetype`) is also running.
- This role CAN: `ec2:Describe*`, `ec2:RunInstances` (spot from worker template
  only), `ec2:TerminateInstances`/`StopInstances`, `ssm:GetParameter` by name,
  `s3:*Object` on the shared bucket. CANNOT: any `iam:*`,
  `s3:GetBucketVersioning`, `ssm:DescribeParameters`, `ec2:CreateImage`.
- `research-vm-worker-template`: default = v4 = one-time spot, no user-data.
  v1–v3 have no spot options — never pin them.
- Spot test evidence left at
  `s3://research-vm-shared-176048535722/spot-test/20260903T192331Z-i-0f9a7d3893a9e2287.txt`
  (role has no `s3:DeleteObject`, so it stays).
- Branch: `main`. Terraform 1.16.1 is on the box (unused now).

## Useful paths

- Working tracker: `ROADMAP.md` (§7 decisions, §8 session log, §5 open questions)
- Source of truth: `PROJECT.md`
- Boot path: `boot/user-data.sh.tmpl` → `bootstrap.sh` → `wrapper.sh` | `worker.sh`
- CLI: `bin/rvm` (`launch`, `new`, `env`, `cache`, `backup`, `ps`, `doctor`)
- Parked IaC: `infra/tf/`
