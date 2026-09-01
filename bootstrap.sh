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

# --- 6. runtime caps ---
apt-get install -y at >/dev/null 2>&1 || true
systemctl enable --now atd >/dev/null 2>&1 || true

if [ "${ROLE}" = "worker" ]; then
  HOURS="${RVM_WORKER_HOURS}"
else
  HOURS="${RVM_HARD_CAP_HOURS}"
fi
# Stop, never terminate, on the cap: a capped instance is one you want to
# look at. Job id is handed to the worker so a clean finish can cancel it.
CAP_JOB="$(echo "aws ec2 stop-instances --region ${RVM_REGION} --instance-ids ${INSTANCE_ID}" \
  | at now + "${HOURS}" hours 2>&1 | grep -o 'job [0-9]*' | awk '{print $2}' || true)"
echo "${CAP_JOB}" > /run/rvm-hardcap-job

if [ "${ROLE}" != "worker" ]; then
  aws cloudwatch put-metric-alarm --region "${RVM_REGION}" \
    --alarm-name "research-vm-idle-${INSTANCE_ID}" \
    --alarm-description "Stop ${INSTANCE_ID} if CPU stays low for 30 min" \
    --namespace AWS/EC2 --metric-name CPUUtilization \
    --dimensions "Name=InstanceId,Value=${INSTANCE_ID}" \
    --statistic Average --period 300 --evaluation-periods 6 \
    --threshold 5 --comparison-operator LessThanThreshold \
    --alarm-actions "arn:aws:automate:${RVM_REGION}:ec2:stop" \
    --treat-missing-data notBreaching || rvm_log "idle alarm not set (permissions?)"
fi

rvm_log "bootstrap complete: ${RVM_PROJECT} @ ${RVM_REPO_DIR} (${ROLE})"

# --- 7. hand off ---
if [ "${ROLE}" = "worker" ]; then
  exec "${HERE}/worker.sh" "${PROJECT_ARG}" "${WORKER_ID}"
fi
if [ "${RVM_AUTORUN:-0}" = "1" ]; then
  su - "${RVM_TARGET_USER}" -c "RVM_INFRA_DIR='${RVM_INFRA_DIR}' '${HERE}/wrapper.sh' '${PROJECT_ARG}'"
fi
