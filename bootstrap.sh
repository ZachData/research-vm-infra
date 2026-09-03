#!/usr/bin/env bash
# Runs as root at boot, from user-data, once the infra repo is on disk.
#   bootstrap.sh <owner/repo> <orchestrator|worker> [worker_id]
# Everything project-specific it needs comes from the project's own
# infra/rvm.env; everything expensive it needs comes from S3. Nothing
# here depends on what happens to be baked into the AMI.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${HERE}/lib/common.sh"
# shellcheck source=lib/envcache.sh
. "${HERE}/lib/envcache.sh"

PROJECT_ARG="${1:?usage: bootstrap.sh <owner/repo> <role> [worker_id]}"
ROLE="${2:-orchestrator}"
WORKER_ID="${3:-}"
INSTANCE_ID="$(rvm_instance_id || echo unknown)"

rvm_log "bootstrap: project=${PROJECT_ARG} role=${ROLE} instance=${INSTANCE_ID}"

# --- 0. runtime cap, FIRST ---
# Before anything that can fail. This script runs under `set -e`, so a bad
# clone or a failed env build aborts it; if the cap were set at the end,
# that abort would leave an instance running with nothing scheduled to
# stop it. The default hard-cap hours are used here because the project's
# own config has not been read yet — a cap that is slightly wrong beats a
# cap that never gets set.
apt-get install -y at >/dev/null 2>&1 || true
systemctl enable --now atd >/dev/null 2>&1 || true
# A one-time spot instance (every worker) cannot be stopped, only terminated,
# so its cap does an OS shutdown — the worker template's
# InstanceInitiatedShutdownBehavior=terminate turns that into a terminate, and
# it needs no EC2 permissions. The orchestrator is on-demand and stoppable.
if [ "${ROLE}" = "worker" ]; then
  CAP_CMD="shutdown -h now"
else
  CAP_CMD="aws ec2 stop-instances --region ${RVM_REGION} --instance-ids ${INSTANCE_ID}"
fi
CAP_JOB="$(echo "${CAP_CMD}" \
  | at now + "${RVM_BOOT_CAP_HOURS:-4}" hours 2>&1 | grep -o 'job [0-9]*' | awk '{print $2}' || true)"
echo "${CAP_JOB}" > /run/rvm-hardcap-job
rvm_log "hard cap set (job ${CAP_JOB}, ${RVM_BOOT_CAP_HOURS:-4}h, role=${ROLE})"

# --- 0b. boot receipt ---
# An unattended instance has no other way to say what happened. Every exit
# path, success or failure, leaves a receipt in S3 with the status and the
# tail of the boot log, so a fleet can be debugged without shell access to
# a machine that may already be gone.
RVM_T0="$(date +%s)"
rvm_receipt() {
  local status="$1"
  local key="boot-receipts/${RVM_PROJECT:-unknown}/$(date -u +%Y%m%dT%H%M%SZ)-${INSTANCE_ID}-${status}.json"
  local elapsed=$(( $(date +%s) - RVM_T0 ))
  python3 - "${status}" "${elapsed}" > /tmp/rvm-receipt.json <<'PYR' || return 0
import json, subprocess, sys, os
tail = ""
try:
    tail = subprocess.run(["tail","-c","4000","/var/log/rvm-boot.log"],
                          capture_output=True, text=True).stdout
except Exception:
    pass
json.dump({
    "status": sys.argv[1],
    "seconds": int(sys.argv[2]),
    "instance": os.environ.get("INSTANCE_ID",""),
    "project": os.environ.get("RVM_PROJECT",""),
    "role": os.environ.get("ROLE",""),
    "python": os.environ.get("RVM_PYTHON",""),
    "env_hash": os.environ.get("RVM_ENV_HASH",""),
    "log_tail": tail,
}, sys.stdout, indent=2)
PYR
  aws s3 cp /tmp/rvm-receipt.json "s3://${RVM_BUCKET}/${key}" \
    --region "${RVM_REGION}" --only-show-errors || true
}
export INSTANCE_ID ROLE
trap 'rvm_receipt failed' ERR

# --- 1. git auth (PAT, works for every repo the token can see) ---
rvm_setup_git_auth

# --- 2. project config + repo ---
rvm_load_project "${PROJECT_ARG}"
export RVM_PROJECT RVM_REPO_DIR RVM_SLUG

if [ -d "${RVM_REPO_DIR}/.git" ]; then
  # The dir may be a stale copy baked into an older AMI or left by a
  # previous project on a restarted instance. Reset rather than pull:
  # a pull into a diverged or dirty tree fails, and a bootstrap that
  # fails here leaves an instance running with nothing to stop it.
  su - "${RVM_TARGET_USER}" -c "cd '${RVM_REPO_DIR}' \
    && git remote set-url origin '${RVM_REPO_URL}' \
    && git fetch origin '${RVM_BRANCH}' \
    && git checkout -B '${RVM_BRANCH}' 'origin/${RVM_BRANCH}' \
    && git reset --hard 'origin/${RVM_BRANCH}' && git clean -fd"
else
  su - "${RVM_TARGET_USER}" -c \
    "git clone -b '${RVM_BRANCH}' '${RVM_REPO_URL}' '${RVM_REPO_DIR}'"
fi

# Re-read config: the clone may have brought a newer infra/rvm.env than
# the one the pre-clone read saw (or the first one, on a fresh clone).
rvm_load_project "${PROJECT_ARG}"

# --- 3. python env, from the S3 cache ---
rvm_env_ensure "${RVM_REPO_DIR}" "$(command -v python3.12 || command -v python3)"
chown -R "${RVM_TARGET_USER}:${RVM_TARGET_USER}" "${RVM_VENV}"

# --- 4. named data caches (model checkpoints, datasets) ---
for spec in ${RVM_CACHE_PATHS}; do
  name="${spec%%:*}"; dest="${spec#*:}"
  rvm_log "cache ${name} -> ${dest}"
  rvm_cache_pull "${name}" "${dest}"
  chown -R "${RVM_TARGET_USER}:${RVM_TARGET_USER}" "${dest}" || true
done

# --- 4b. agent memory from the last instance that worked this project ---
rvm_memory_pull "${RVM_REPO_DIR}"
chown -R "${RVM_TARGET_USER}:${RVM_TARGET_USER}" "${RVM_TARGET_HOME}/.claude" 2>/dev/null || true

# --- 5. record what this instance is, for interactive sessions ---
cat > "${RVM_TARGET_HOME}/.rvm-current" <<EOF
RVM_PROJECT=${RVM_PROJECT}
RVM_SLUG=${RVM_SLUG}
RVM_REPO_DIR=${RVM_REPO_DIR}
RVM_BRANCH=${RVM_BRANCH}
RVM_ROLE=${ROLE}
RVM_INFRA_DIR=${RVM_INFRA_DIR}
EOF
chown "${RVM_TARGET_USER}:${RVM_TARGET_USER}" "${RVM_TARGET_HOME}/.rvm-current"

# Interactive SSM sessions land in the right repo with the venv active and
# Claude Code already running. Guarded so re-running bootstrap cannot
# append the block twice.
if ! grep -q RVM_AUTOSTART_MARKER "${RVM_TARGET_HOME}/.bashrc" 2>/dev/null; then
cat >> "${RVM_TARGET_HOME}/.bashrc" <<'BASHRC'
# RVM_AUTOSTART_MARKER — managed by research-vm-infra, do not duplicate
if [ -f "$HOME/.rvm-current" ]; then
  set -a; . "$HOME/.rvm-current"; set +a
  export PATH="$RVM_INFRA_DIR/bin:$PATH"
  [ -d "$RVM_REPO_DIR" ] && cd "$RVM_REPO_DIR"
  [ -f "$HOME/venv/bin/activate" ] && . "$HOME/venv/bin/activate"
fi
if [[ $- == *i* ]] && [ -z "${CLAUDE_AUTOSTARTED:-}" ]; then
  export CLAUDE_AUTOSTARTED=1
  claude
fi
BASHRC
chown "${RVM_TARGET_USER}:${RVM_TARGET_USER}" "${RVM_TARGET_HOME}/.bashrc"
fi

# The boot cap in step 0 used the built-in default, since no project config
# had been read yet. Now that one has, replace it with the project's value.
# Worker default is 2h (RVM_WORKER_HOURS); a project raises it in infra/rvm.env
# for a cell that genuinely needs longer. Same shutdown-vs-stop split as step 0.
case "${ROLE}" in
  worker) HOURS="${RVM_WORKER_HOURS}" ;;
  daemon) HOURS="${RVM_MAX_LIFETIME_HOURS}" ;;   # ceiling: never renewed, the wedged-loop backstop
  *)      HOURS="${RVM_HARD_CAP_HOURS}" ;;
esac
if [ "${HOURS}" != "${RVM_BOOT_CAP_HOURS:-4}" ]; then
  atrm "$(cat /run/rvm-hardcap-job)" 2>/dev/null || true
  CAP_JOB="$(echo "${CAP_CMD}" \
    | at now + "${HOURS}" hours 2>&1 | grep -o 'job [0-9]*' | awk '{print $2}' || true)"
  echo "${CAP_JOB}" > /run/rvm-hardcap-job
  rvm_log "hard cap reset to ${HOURS}h (job ${CAP_JOB}, role=${ROLE})"
fi

# No idle-CPU stop alarm. It repeatedly stopped instances that were mid-work,
# and under the daemon model an idle box between units of work is expected.
# Cost safety is the never-renewed lifetime ceiling above plus alert-only
# Budgets; the box is stopped deliberately with `rvm stop <project>`.

RVM_ENV_HASH="$(cat "${RVM_VENV}/.rvm-env-hash" 2>/dev/null || echo unknown)"
export RVM_ENV_HASH RVM_PROJECT RVM_PYTHON
rvm_receipt ok
trap - ERR
rvm_log "bootstrap complete in $(( $(date +%s) - RVM_T0 ))s: ${RVM_PROJECT} @ ${RVM_REPO_DIR} (${ROLE})"

# --- 7. hand off ---
if [ "${ROLE}" = "worker" ]; then
  exec "${HERE}/worker.sh" "${PROJECT_ARG}" "${WORKER_ID}"
fi
if [ "${ROLE}" = "daemon" ]; then
  # The maintenance loop runs under systemd so a crash restarts it and a
  # reboot resumes it — the box now outlives every work cycle.
  install -m 0644 "${HERE}/systemd/rvm-daemon.service" /etc/systemd/system/rvm-daemon.service
  systemctl daemon-reload
  systemctl enable --now rvm-daemon.service
  rvm_log "rvm-daemon.service enabled and started"
  exit 0
fi
if [ "${RVM_AUTORUN:-0}" = "1" ]; then
  su - "${RVM_TARGET_USER}" -c "RVM_INFRA_DIR='${RVM_INFRA_DIR}' '${HERE}/wrapper.sh' '${PROJECT_ARG}'"
fi
