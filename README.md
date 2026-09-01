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
                        ├─ hard cap + idle alarm
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
- `/research-vm/github-pat` in SSM. It must be able to see every project repo —
  if it is ever narrowed to selected repositories, a new project fails at clone
  with a 403. `/research-vm/github-deploy-key` is no longer used; deploy keys
  are per-repo, which is exactly the constraint being removed here.

## Rebuilding the AMI (rarely)

Bake only project-agnostic things: apt packages, awscli, gh, zstd, Claude Code,
and an empty `/opt/rvm`. Do **not** bake a repo or a venv — a baked venv is
just a stale cache entry that the hash check will ignore anyway. `CreateImage`
is not in the instance roles' permissions; do it from the console or with admin
credentials, then update `ImageId` on both launch templates.
