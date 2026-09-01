# CLAUDE.md

Operational rules. `PROJECT.md` is the source of truth for what the fleet *is* — claims, criteria, status board, decisions log, open questions. Read it before doing anything non-trivial. This file only covers how to work.

## What this repo is

The boot path and control plane for a fleet of ephemeral EC2 research instances. It is deliberately the only project-agnostic thing in the account: one image, one pair of launch templates, one CLI. A project joins the fleet by committing an `infra/rvm.env` to its own repo.

Everything here runs on a machine nobody is watching, usually as root, usually once. That single fact sets every rule below.

## Layout

```
bin/rvm                  the CLI: launch, new, env, cache, backup, ps, doctor
boot/user-data.sh.tmpl   generic EC2 user-data; project name is the only variable
bootstrap.sh             runs at boot as root: auth, repo, env, caches, caps, handoff
wrapper.sh               one orchestrator work cycle: agent, clean-tree, CI gate, terminate
worker.sh                one sweep cell: run, push, shut down
bake-prep.sh             the one-time procedure that turns an instance into the image
lib/common.sh            config loading, auth, IMDS, memory sync
lib/envcache.sh          the venv cache: hash, restore, build, publish
projects/<name>.env      optional fleet-side defaults; the project's own file wins
templates/               what `rvm new` scaffolds into a new project
```

## The rules that matter

**1. An unattended instance must always be able to stop itself.** The hard cap is set before anything that can fail, because this script runs under `set -e` and a cap set at the end is a cap a failed boot never sets. Any new early-exit path must keep that ordering. This is C5 in `PROJECT.md` §5 and its failure mode is a bill, not an error message.

**2. An unattended instance must always leave evidence.** Every exit path writes a boot receipt. If you add a branch that can terminate or exit, it either writes a receipt or it is a bug. There is no other channel: the volume is usually gone by the time anyone looks.

**3. Nothing project-specific enters the image, and no secret ever does.** Credentials are read from SSM at boot and written with `umask 077`. A token must never end up in a git remote URL, a shell history, or a baked file — an image is copyable.

**4. The env-cache hash must cover everything that changes the environment.** If you add an input that affects `site-packages` and do not add it to `rvm_env_hash`, the cache will serve a stale environment that looks completely fine. That is the worst failure this repo can produce, because it is silent and it contaminates results in *other* repos. Changing the hash inputs means bumping the `v` prefix.

**5. `bash -n` is not evidence.** Syntax checking proves nothing about a boot. A change to `bootstrap.sh`, `worker.sh`, or `user-data.sh.tmpl` is unproven until a real launch has produced an `ok` receipt. Say "unproven" in the status board rather than marking a row done.

## Testing, such as it is

There is no pytest here and it would be theatre if there were. The checks that actually catch things, in the order they cost time:

| Check | Command | Catches |
|---|---|---|
| Parse | `bash -n` on every script | typos |
| Lint | `shellcheck` | quoting, unset vars, subshell scope |
| Render | substitute the template, grep for leftover `__` | a placeholder that never got replaced |
| Pre-flight | `rvm doctor` | creds, bucket, PAT scope, push access, disk |
| Dry run | `aws ec2 run-instances --dry-run` | permissions, template names |
| Real boot | launch, then read the receipt | everything else |

Only the last one is evidence. Budget for it: a boot is minutes and cents, and it is the only thing that distinguishes working code from plausible code.

**Idempotence is a requirement, not a nicety.** `bootstrap.sh` may run on a machine with a stale repo from another project, a venv from another hash, or a `.bashrc` it already edited. Reset rather than pull; check the hash rather than assume; guard every append with a marker. A boot script that only works on a clean machine will fail exactly when a machine is not clean, which is the case you cannot reproduce by hand.

## Working on a status-board row

1. Read the row and the `PROJECT.md` section it references.
2. Make the change here; instances fetch it at boot, so it ships by push.
3. Prove it with a real launch. Read the receipt.
4. Update the status board. Decisions to §9, new uncertainties to §10.
5. Commit with a message that says what failed and why the change is the fix, not what the diff contains.

**A gate that fails stops the phase.** Record it in §9 with the decision taken. Do not route around it, and do not mark a row done on the strength of a local test.

## Do not

- Do not widen an IAM policy to make something work without recording it in §9. `ec2:CreateImage` and `s3:DeleteObject` are absent from the instance roles deliberately.
- Do not delete objects from the bucket by hand. Use a lifecycle rule.
- Do not add a second source of truth for the boot path. It lives in git, is fetched at boot, and that is the whole design.
- Do not bake a repo, a venv, an `at` job, or a credential into the image. The first two are stale the moment they exist; the third stops every future instance seconds after boot; the fourth is a leak.
- Do not touch AWS resources outside `Project=research-vm`, and do not create or modify IAM roles or policies.
- Do not reintroduce the per-repo deploy key. It is what made the fleet single-project.

## When finishing

Update the status board. Append decisions to §9, uncertainties to §10. Leave the tree clean and pushed — an instance boots from `origin/main`, so an unpushed fix does not exist.
