# Handoff

_Read this first when resuming work on `research-vm-infra`. Updated at checkpoints.
Last update: 2026-09-03, ~21:30 UTC._

## Current goal

Turn the fleet into "a real thing": one general AMI + one long-lived
daemon-orchestrator per project. `ROADMAP.md` is the working tracker; `PROJECT.md`
is the source of truth for the core question. This file is the short "resume here"
version.

## State of the tree

Branch **`spot-worker-cap-fix`** pushed to origin, 3 commits:

1. `Docs: record no-ASG / no-Terraform decisions; fix stale claims`
2. `Spot worker cap: terminate, not stop; default 2h; assert spot at launch`
3. `Phase C: daemon role — maintenance loop under systemd, no idle alarm`

**PR not opened** — the box PAT lacks `pull_requests: write` (`gh pr create` →
"Resource not accessible by personal access token"). Open it by hand:
https://github.com/ZachData/research-vm-infra/pull/new/spot-worker-cap-fix

Still untracked and deliberately uncommitted: `infra/` (the parked Terraform —
its fate is an open decision).

`git push` from this box: origin is an SSH URL whose only key is a deploy key for
another repo. Push over HTTPS via the `gh` PAT:
`git push https://github.com/ZachData/research-vm-infra.git HEAD:<branch>`.

## What was done — 2026-09-03

**Earlier session:** cut ASG; parked Terraform; verified a real spot worker end
to end (IMDS `instance-life-cycle`=`spot`, wrote to the bucket with the worker
role, `stop-instances` failed with `UnsupportedOperation` as expected, terminate
worked); doc-accuracy pass; pulled `Lora_inductionhead` (91 commits).

**This session:**

- Committed + pushed the branch (3 commits above).
- **Phase C core, all on the branch, all `bash -n` clean:**
  - `daemon.sh` (new) — the loop: renew lease → heartbeat (local file + S3
    object + best-effort CloudWatch) → poll `/research-vm/daemon-control`
    (`run` | `pause`) → one `RVM_NO_TERMINATE=1 wrapper.sh` cycle → sleep
    `RVM_DAEMON_POLL_SECONDS` → repeat.
  - `systemd/rvm-daemon.service` (new) — `Restart=always`, `User=ubuntu`.
    `systemd-analyze verify` passes (bar a path check that only holds on a real
    AMI at `/opt/rvm/infra`).
  - `bootstrap.sh` — `daemon` role: cap = `RVM_MAX_LIFETIME_HOURS` ceiling
    (never renewed), then install + `systemctl enable --now rvm-daemon`. Idle
    CPU alarm block deleted (B3). `wrapper.sh` — matching idle-alarm delete
    removed.
  - `bin/rvm` — `rvm stop|start <owner/repo>`: find the orchestrator/daemon box
    by tag, `aws ec2 stop/start-instances`.

## New finding this session

**The box PAT cannot open PRs** (`pull_requests: write` missing). This blocks
`gh pr create` *and* the daemon's designed "open a PR" step. Needs the user to
add `Pull requests: write` to `/research-vm/github-pat`'s fine-grained scopes.
Until then the daemon can only push branches, and Phase E's merge-gate design
is on hold.

## To do — in rough priority order

1. **Open the PR** for `spot-worker-cap-fix` (user; link above). Add
   `Pull requests: write` to the PAT while there.
2. **Prove Phase C + the worker cap fix with real launches:**
   - `rvm launch <repo> --role worker --worker-id 0` against a repo with a
     trivial `RVM_WORKER_CMD`; read the receipt; confirm it self-terminates at
     the 2h cap.
   - `rvm launch <repo> --role daemon`; confirm `rvm-daemon.service` is active,
     the loop logs a cycle, a heartbeat object appears under
     `s3://…/heartbeat/<project>/latest`, and `rvm stop <repo>` stops the box.
   - CLAUDE.md rule 5: all of Phase C is "unproven" until these.
3. **Cost backstop** (user, AWS console, ~3 min): account-wide AWS Budget, 80%
   actual / 100% forecast → SNS email. No tags needed.
4. **Stalled-loop alarm** (console): CloudWatch alarm on `rvm/heartbeat_age_seconds`
   (namespace `rvm`, dimension `project`), `treat-missing-data=breaching`, → SNS.
   Only useful once (2) shows the metric is actually being published (role may
   lack `cloudwatch:PutMetricData` — the put is best-effort).
5. **B4** — spot interruption notice handler
   (`http://169.254.169.254/latest/meta-data/spot/instance-action`): flush +
   push before the ~2-min reclaim. Lower priority if projects sync incrementally.
6. **Run `shellcheck`** on all shell scripts — not installed on this box.
7. **Retire `/research-vm/github-deploy-key`** (user): `aws ssm delete-parameter
   --name /research-vm/github-deploy-key`.
8. **Clean the stale user-data on `small_t4g_template` v11** (low priority).

## Not yet done in Phase C (needs decisions / the PAT fix)

- The daemon still runs `wrapper.sh` as-is, which pushes to the working branch
  and expects CI green. The "agent opens a PR, never pushes `main`, human
  merges" model (ROADMAP §7) is not wired — it needs the PAT `Pull requests`
  scope and confirmation of the merge gate.
- Work-source priority (agent-labelled issues → `PROJECT.md` §10 →
  `backlog/TASKS.md`) is not encoded anywhere yet — it belongs in the prompt
  the daemon feeds `claude`. `templates/prompt.md` is the place.

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
