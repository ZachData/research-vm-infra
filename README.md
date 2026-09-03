# research-vm-infra

One EC2 fleet, any number of research projects, and an AMI you almost never
rebuild.

## The idea

The old setup baked one project into the image: the repo was cloned at bake
time, the venv was built at bake time, and the launch template's user-data
named `Lora_inductionhead` in four places. Working on a second project meant
another AMI, and changing a dependency meant *rebuilding* the AMI.

This inverts that. **The AMI holds only things that never change** — OS, git,
gh, awscli, zstd, Claude Code. Everything else arrives at boot:

```
AMI (stable) ──> user-data (15 generic lines, project name substituted)
                  └─ clone research-vm-infra          (git — fixes ship by push)
                     └─ bootstrap.sh <owner/repo> <role>
                        ├─ git auth via the account PAT (works for every repo)
                        ├─ clone/reset the project repo
                        ├─ restore the venv from S3, keyed by dependency hash
                        ├─ pull shared data caches (HF checkpoints, datasets)
                        ├─ hard cap (idle alarm still emitted; being retired — ROADMAP)
                        └─ wrapper.sh (orchestrator) | worker.sh (sweep cell)
```

Three consequences worth being explicit about:

- **A new project is a launch argument**, not an image: `rvm launch owner/repo`.
- **A dependency change costs one slow boot, ever.** The first instance to see
  a new `pyproject.toml` builds the venv and publishes it to S3 under a hash of
  the files that defined it; every later instance restores it. No AMI involved.
- **A bug in the boot path is a `git push`**, because the boot path lives here
  rather than inside the image.

You still rebuild the AMI for OS upgrades or to shave cold-start time. That is
now a convenience, not a requirement.

## Adding a project

```bash
rvm new ZachData/MetastableStateAnalysis   # scaffolds infra/rvm.env + infra/prompt.md
$EDITOR ~/MetastableStateAnalysis/infra/rvm.env
git -C ~/MetastableStateAnalysis add infra && git -C ~/... commit -m 'add rvm config' && git -C ~/... push
rvm launch ZachData/MetastableStateAnalysis
```

`infra/rvm.env` is the whole contract — install command, prompt file, worker
command, instance type, caps, caches. It lives in the project repo, so a
project can change how it runs without touching this repo. See
`templates/rvm.env`.

## Commands

| | |
|---|---|
| `rvm launch <owner/repo> [--role worker] [--branch B] [--type T] [--autorun]` | start an instance on a project |
| `rvm new <owner/repo>` | scaffold a project's `infra/` config |
| `rvm env status \| build \| publish` | inspect / build / publish the venv cache |
| `rvm cache pull\|push <name> <path>` | shared data caches (model checkpoints) |
| `rvm backup` | transcripts + boot logs to S3 before a terminate destroys them |
| `rvm restore-transcripts <project>` | fetch them back |
| `rvm ps` | what the fleet is running |
| `rvm doctor` | pre-flight; run it before trusting a long run |

## S3 layout

```
s3://research-vm-shared-176048535722/
  envs/<arch>/py<ver>/<project>/<dephash>.tar.zst   venv cache
  caches/<name>/                                     shared data (HF, datasets)
  memory/<project>/                                  agent memory, restored at boot
  runs/<project>/<ts>-<instance>/                    transcripts, boot logs
  <project>/...                                      whatever a project writes
```

The instance roles have `s3:PutObject` but **not** `s3:DeleteObject`, so
nothing here is ever cleaned up automatically. Old env tarballs accumulate at
~2 GB each; add a lifecycle rule on `envs/` (expire after 60 days) from the
console, or prune manually with admin credentials.

## What is still project-specific outside this repo

- The two launch templates supply the AMI, IAM profile and security group.
  `rvm launch` overrides their user-data and instance type, so one pair of
  templates serves every project. They are only touched to change the AMI.
- `/research-vm/github-pat` in SSM, rescoped to all-repositories 2026-09-03. It
  must stay that way — if it is ever narrowed to selected repositories, a new
  project fails at clone with a 403. `/research-vm/github-deploy-key` is no
  longer used (deploy keys are per-repo, the constraint being removed here) but
  the SSM parameter still exists — retire it (`ROADMAP.md` §6).

## The image

One bake, then rarely again. `bake-prep.sh` is the whole procedure; run it as
root on an instance whose repo is pushed, then take the AMI.

**What the image contains** — only things that never expire: OS packages
(`at`, `zstd`, `pigz`, `jq`, `ripgrep`, `tmux`, `build-essential`,
`python3-venv`), awscli, gh, Claude Code and its login, `uv`, and a clone of
this repo at `/opt/rvm/infra` on `PATH`.

**What it must not contain**: a project repo, a venv, a git token, or an `at`
job. The first two arrive at boot from S3 and GitHub; the token comes from SSM;
a baked `at` job would fire on first boot of every instance made from the image
and stop it seconds after launch.

`bake-prep.sh` also clears per-instance identity — ssh host keys, machine-id,
and cloud-init state. That last one is not cosmetic: without `cloud-init clean`
an instance launched from the image can skip user-data entirely and come up
with nothing configured and nothing scheduled to stop it.

`uv` is what keeps the image general. A project pins its interpreter with
`RVM_PYTHON` and uv fetches that CPython at boot, so a project on 3.11 and a
project on 3.13 share one image. Pin it to whatever the project's CI runs —
a skew there produces tests that pass in CI and fail on the instance, which
costs a session before anyone suspects the interpreter.

`CreateImage` is deliberately absent from the instance roles, so take the image
with admin credentials or from the console; `bake-prep.sh` prints the exact
commands, including the two launch-template updates that point at the new AMI.
