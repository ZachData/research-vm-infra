#!/usr/bin/env bash
# Turn the instance this runs on into the generic image. Run it once,
# immediately before taking the AMI, with everything committed and pushed.
#
#   sudo /opt/rvm/infra/bake-prep.sh --yes
#
# Two halves, and the second is the one that actually matters:
#
#   INSTALL  project-agnostic tooling only. Nothing here knows about a
#            project, so nothing here expires.
#   STRIP    remove every trace of a specific project, every credential,
#            and every piece of per-instance state that would be wrong on
#            a machine launched from this image. Several of these are not
#            hygiene: a baked `at` job fires on first boot of every future
#            instance, and uncleaned cloud-init state can skip user-data
#            entirely, which would leave an instance running with nothing
#            to configure or stop it.
#
# Destructive: it deletes the working repo, the venv, and the credentials
# on this box. The repo must be pushed first.
set -euo pipefail
[ "${1:-}" = "--yes" ] || { echo "refusing to run without --yes (this deletes the working tree and venv)"; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }

U=ubuntu
H=/home/${U}
INFRA_REPO="${RVM_INFRA_REPO:-ZachData/research-vm-infra}"
say() { printf '\n=== %s\n' "$*"; }

say "INSTALL: base packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
# python3.11 is not in noble's default repos; uv supplies interpreters
# instead, which is also what lets a project pin any version later.
apt-get install -y -qq \
  at zstd pigz jq ripgrep tmux curl unzip git build-essential \
  python3-venv python3-pip ca-certificates >/dev/null
systemctl enable atd >/dev/null 2>&1 || true

say "INSTALL: uv (system-wide)"
if ! command -v uv >/dev/null 2>&1; then
  curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh
fi
uv --version

say "INSTALL: infra repo at /opt/rvm/infra + PATH"
mkdir -p /opt/rvm
if [ ! -d /opt/rvm/infra/.git ]; then
  PAT="$(aws ssm get-parameter --name /research-vm/github-pat --with-decryption \
        --region us-east-2 --query Parameter.Value --output text)"
  git clone -q "https://x-access-token:${PAT}@github.com/${INFRA_REPO}.git" /opt/rvm/infra || \
    echo "WARNING: could not clone ${INFRA_REPO}; user-data will clone it at boot instead"
  [ -d /opt/rvm/infra/.git ] && git -C /opt/rvm/infra remote set-url origin "https://github.com/${INFRA_REPO}.git"
fi
cat > /etc/profile.d/rvm.sh <<'PROFILE'
export RVM_INFRA_DIR=/opt/rvm/infra
case ":$PATH:" in *":/opt/rvm/infra/bin:"*) ;; *) PATH="/opt/rvm/infra/bin:$PATH" ;; esac
export PATH
PROFILE
chmod 644 /etc/profile.d/rvm.sh

say "STRIP: scheduled jobs"
# A baked `at` job runs on first boot of every instance made from this
# image — its scheduled time is already in the past, so atd fires it
# immediately and the new instance stops itself seconds after booting.
for j in $(atq | awk '{print $1}'); do atrm "$j"; done
su - "${U}" -c 'for j in $(atq | awk "{print \$1}"); do atrm "$j"; done' 2>/dev/null || true
rm -f /run/rvm-hardcap-job
atq

say "STRIP: project working state"
rm -rf "${H}"/Lora_inductionhead "${H}"/venv "${H}"/venv.bak "${H}"/venv.old
rm -f  "${H}"/.rvm-current "${H}"/bootstrap.log "${H}"/.bash_history
rm -rf "${H}"/rvm-runs
# Claude Code: keep the login, drop this project's transcripts and history.
# .credentials.json, settings.json and plugins stay — an unattended run
# needs the login. Everything below is per-project or per-session state,
# and memory is safe to drop because bootstrap.sh restores it from S3.
rm -rf "${H}"/.claude/projects "${H}"/.claude/todos "${H}"/.claude/shell-snapshots \
       "${H}"/.claude/statsig "${H}"/.claude/history.jsonl "${H}"/.claude/sessions \
       "${H}"/.claude/session-env "${H}"/.claude/backups "${H}"/.claude/cache \
       "${H}"/.claude/downloads
python3 - <<'PYCLEAN' || true
import json, pathlib
p = pathlib.Path("/home/ubuntu/.claude.json")
if p.exists():
    d = json.loads(p.read_text())
    d["projects"] = {}                     # per-project state, not credentials
    for k in ("tipsHistory", "promptQueueUseCount"):
        d.pop(k, None)
    p.write_text(json.dumps(d, indent=2))
    print("scrubbed .claude.json projects")
PYCLEAN

say "STRIP: credentials"
# Every one of these is re-established at boot by bootstrap.sh from SSM.
# An AMI is copyable and shareable; it should not carry a git token.
rm -f "${H}"/.ssh/github_deploy_key "${H}"/.git-credentials "${H}"/.gh_pat
rm -rf "${H}"/.config/gh
rm -f  "${H}"/.ssh/authorized_keys
su - "${U}" -c 'git config --global --unset credential.helper' 2>/dev/null || true

say "STRIP: stale shell autostart blocks"
# bootstrap.sh writes a fresh RVM_AUTOSTART_MARKER block on every instance.
# Both the old CLAUDE_AUTOSTART_MARKER block and a previous RVM block must
# go, or the image accumulates duplicates that each launch Claude Code.
python3 - <<'PYRC' || true
import pathlib, re
p = pathlib.Path("/home/ubuntu/.bashrc")
s = p.read_text()
for marker in ("CLAUDE_AUTOSTART_MARKER", "RVM_AUTOSTART_MARKER"):
    i = s.find(f"# {marker}")
    if i == -1:
        continue
    s = s[:i].rstrip() + "\n"          # both blocks are appended at the end
    print("removed", marker)
p.write_text(s)
PYRC

say "STRIP: per-instance identity and logs"
rm -f /etc/ssh/ssh_host_*                    # regenerated on first boot
truncate -s 0 /etc/machine-id                # regenerated on first boot
rm -f /var/lib/dbus/machine-id
rm -rf /var/log/rvm-boot.log /var/log/cloud-init*.log
journalctl --rotate >/dev/null 2>&1 || true
journalctl --vacuum-time=1s >/dev/null 2>&1 || true
find /var/log -type f -name '*.gz' -delete 2>/dev/null || true
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
rm -rf "${H}"/.cache/pip /root/.cache/pip

say "STRIP: cloud-init state (LAST — user-data will not run without this)"
cloud-init clean --logs --seed

chown -R "${U}:${U}" "${H}"
say "READY TO BAKE"
df -h / | tail -1
cat <<'NEXT'

Take the image now, from an account with ec2:CreateImage (the instance
roles deliberately do not have it):

  aws ec2 create-image --region us-east-2 --instance-id <this-instance> \
    --name "research-vm-generic-$(date -u +%Y%m%d)" \
    --description "Project-agnostic research fleet image" --no-reboot

Then point both launch templates at the new AMI id:

  aws ec2 create-launch-template-version --region us-east-2 \
    --launch-template-name small_t4g_template --source-version '$Latest' \
    --launch-template-data '{"ImageId":"ami-NEW"}'
  aws ec2 modify-launch-template --region us-east-2 \
    --launch-template-name small_t4g_template --default-version '$Latest'
  # and the same two calls for research-vm-worker-template

Do not reboot or keep working on this instance afterwards: it now has no
ssh host keys, no machine-id and no credentials, and cloud-init will
reconfigure it as if it were new.
NEXT
