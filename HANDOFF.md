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

## BLOCKER — live IAM regression, found 2026-09-03 late session

`ec2:RunInstances` on `research-vm-ssm-role` now fails for **every** combination
tried, including the exact spot/`t4g.small`/worker-template call that launched
successfully earlier this session. The failure differs by case:

- Spot `t4g.small` from `research-vm-worker-template`, no overrides — denied on
  `resource: image/ami-0d469967250a418da` (a NEW failure mode; this exact call
  worked a few hours earlier in this same session).
- `g5g.xlarge` (GPU, spot-inherited) — denied on `resource: instance/*`, same
  pattern as any wrong-instance-type attempt.
- On-demand from the orchestrator template — still denied on `iam:PassRole`,
  unchanged.
- `ec2:DescribeImages` — now also denied (wasn't earlier).

Nobody on this side touched IAM (no `iam:*` from this box, confirmed twice).
Something changed the `research-vm-ssm-role` policy between the earlier
successful real launch and now — check whether the `RunInstances` statement's
`Resource` list still covers `image/ami-0d469967250a418da`.

**On-demand is still correctly blocked wherever reachable** — that part holds.
GPU access is unconfirmed either way until the spot path works again, since the
one call that's supposed to succeed is currently denied too.

**Do not attempt real launches until this is confirmed fixed.** The throwaway
Lora branch `infra-smoketest` (trivial `RVM_WORKER_CMD`, not merged) is ready
for the worker-cap proof the moment it is.

**RESOLVED 2026-09-04.** Re-checked with `aws ec2 run-instances --dry-run`
from this same role: spot `t4g.small` from `research-vm-worker-template`
(no overrides) now returns `DryRunOperation` (would succeed). On-demand from
the orchestrator template is still correctly denied on `iam:PassRole`;
`g5g.xlarge` is still correctly denied (wrong instance type). Whatever
transient policy state caused the regression is gone — real launches are
unblocked again. `ec2:DescribeImages` is still denied (contradicts the
"role CAN `ec2:Describe*`" note below); low priority since the AMI id is
hardcoded in the launch template, not looked up at boot.

**Real proof launches, 2026-09-04:**
- `rvm launch ZachData/Lora_inductionhead --role worker --worker-id 0 --branch
  infra-smoketest` launched: `i-0489b42000a50f0d2`, confirmed spot
  (`InstanceLifecycle=spot`), `t4g.small`, running at launch (14:39:22 UTC).
  **Outcome is inconclusive, not a pass — do not mark C4/C5 proven from this
  run:**
  - It ran for ~3h00m then began terminating (`shutting-down` at 17:39 UTC),
    which lines up suspiciously well with this project's
    `RVM_WORKER_HOURS=3` — looks like its own hard cap fired, not (only) a
    random spot reclaim, though the state-reason (`Server.
    SpotInstanceTermination`) doesn't cleanly confirm which.
  - **No boot receipt landed in S3.** `s3://…/boot-receipts/` has nothing
    but an old `_selftest/` prefix — checked both
    `boot-receipts/Lora_inductionhead/` specifically and the whole prefix.
    This isn't unique to this run: across everything this repo's docs
    describe as "verified end to end" (the 2026-09-03 spot test included),
    **no boot receipt has ever actually landed in S3.** PROJECT.md's "Boot
    receipts ●" row says "verified locally against a synthetic invocation" —
    that phrasing is the tell; it has never been verified against a real
    boot. Treat C4 as unverified, not done.
  - **No commit landed** on `infra-smoketest` (`origin/infra-smoketest` is
    still at `6eec162`, the pre-existing throwaway commit) — `worker.sh`
    never reached its push step, or the push silently failed.
  - Cannot diagnose further from any box in the fleet: `research-vm-ssm-role`
    denies `ec2:GetConsoleOutput`, `ec2:DescribeSpotInstanceRequests`, and
    `ec2:DescribeTags` — all read-only, all things CLAUDE.md/this file's
    "Environment notes" claim the role *can* do (`ec2:Describe*`). That
    claim is wrong; the actual Describe allowlist is narrower. Worth asking
    the user to grant these three (read-only, no write/cost risk) so a
    future bad boot is debuggable without console access, and worth fixing
    the docs either way.
  - **Needs the user to pull the EC2 console/system log for
    `i-0489b42000a50f0d2` from the AWS console** (this role can't) to see
    what bootstrap.sh was actually doing for 3 hours. Prime suspect:
    something in the boot path hangs on an interactive prompt when run with
    no tty — this session independently hit exactly that failure mode
    installing `shellcheck` via plain `apt-get install -y` (a pending-kernel
    -upgrade whiptail prompt, `Failed to open terminal`); `bootstrap.sh`'s
    own `apt-get install -y at ...` and `bake-prep.sh`'s package installs
    are not obviously guarded with `DEBIAN_FRONTEND=noninteractive` — check
    that first.

**Fix applied, re-tested, STILL FAILING — 2026-09-04.** Applied
`DEBIAN_FRONTEND=noninteractive` + `timeout 120` to the `at` install
(commit `c59e001`, pushed to `main` before the retest launched), then
relaunched: `rvm launch ZachData/Lora_inductionhead --role worker
--worker-id 1 --branch infra-smoketest` → `i-08239a05869300769`, launched
2026-09-04T19:01:38Z. **Still running at 19:35:52Z (34 min elapsed, no
cap fired yet — `RVM_WORKER_HOURS=3`), no boot receipt, no pushed
commit.** Same symptom as the first failure, so either the apt-get fix
didn't address the actual cause, or there's a second, different hang
further into the boot path (worth checking: the `uv` interpreter fetch,
the `git clone` of the project repo, the env-cache restore/build in
`lib/envcache.sh`, or `rvm_setup_git_auth`'s `gh auth login`).

**Left running deliberately, not terminated** — this role cannot see
console output (`ec2:GetConsoleOutput` denied) and has no other way to
diagnose it. **Needs the user to check the EC2 console system log for
`i-08239a05869300769` directly, or SSM Session Manager / SSH in if
reachable, before it either finishes or hits its 3h cap (~22:01 UTC).**
Do not relaunch a third time blind — get real signal from this one first.
Two consecutive real launches with the exact same "no receipt, no push,
runs long past when a trivial cell should finish" symptom means the boot
path has a real, unidentified defect, not bad luck twice.

**Terminated by the user 2026-09-04** without a console check (no AWS
access available at the time). A likely root cause was found instead by
reading the code and git history, not by inspecting the box — and it's
already fixed:

**ROOT CAUSE (confirmed from git history, not just inferred): the env
cache has been serving a guaranteed miss for every project since
2026-09-03.** Commit `2c836ae` ("Long-lived daemon box: per-project
venvs...") changed `RVM_VENV` from a fixed path to
`${RVM_VENV_ROOT}/<project-name>` so a hypothetical multi-project daemon
wouldn't evict one project's venv for another's. `rvm_env_hash` includes
`venv=$(basename "${RVM_VENV}")` — the commit's own message says "the
venv name joins the cache key," so the author knew this, but the hash's
`v3` prefix was never bumped even though its *value* now differs for
every existing project (`venv=Lora_inductionhead` vs. the `venv=venv`
that the existing cached artifact,
`envs/aarch64/py3.11/Lora_inductionhead/f65d45e18cec9a44.tar.zst`
(373 MB, published 2026-09-01), was almost certainly built under). This
is CLAUDE.md rule 4's exact failure mode: "the cache will serve a stale
environment that looks completely fine" — except here it's worse than
stale, it's *unreachable*, so every boot since silently fell back to a
full `pip install -e '.[dev]'` build of Lora's complete dependency set
instead of a ~13s restore. That set has grown across 91 commits since
the ~6-minute build figure in PROJECT.md §4 was measured; a much slower
real build time (tens of minutes, possibly worse under pip's resolver on
a large scientific-Python dependency graph) is a very plausible
explanation for both worker "hangs" being genuinely slow builds, not
stuck processes.

**Already fixed, already pushed, not yet validated by a real launch:**
commit `d23fb15` (this session, motivated independently by the
one-project-per-box decision) reverted `RVM_VENV` to a single fixed path,
which restores the *original* hash calculation and should make the
existing 2026-09-01 cached artifact reachable again — a fast restore
instead of a slow rebuild. **Next real worker launch against
`Lora_inductionhead` is the actual test of this theory:** watch for
`env <hash>: cache hit, restoring …` in the boot log / a receipt landing
within roughly a minute, not tens of minutes. If it's still slow, this
theory is wrong or incomplete and the apt-get fix + this fix together
still don't explain the full picture.
- `rvm launch ZachData/Lora_inductionhead --role daemon` **failed**, same
  `iam:PassRole` denial as on-demand launches generally. This is structural,
  not a bug: the daemon/orchestrator template needs `iam:PassRole` on
  `research-vm-ssm-role`, and an instance running under that role cannot pass
  it to launch another instance carrying the same role. **A daemon-role box
  can only be launched from the user's own credentials (laptop/console),
  never from a box already in the fleet.** Update `ROADMAP.md`/`PROJECT.md`
  if this constraint isn't already written down there — it means Phase C's
  daemon proof needs the user to run the launch, not an agent on any
  in-fleet box.

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
