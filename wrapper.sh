#!/usr/bin/env bash
# One work cycle for any project. Same contract as the old per-project
# wrapper: Claude Code takes the next row, the tree must end clean and
# pushed, CI must be green, then the instance terminates. What changed is
# that nothing here names a project — the prompt, the sweep command and
# the CI policy all come from the project's own infra/rvm.env.
#   wrapper.sh [owner/repo]        (defaults to ~/.rvm-current)
set -euo pipefail

RVM_INFRA_DIR="${RVM_INFRA_DIR:-/opt/rvm/infra}"
# shellcheck source=lib/common.sh
. "${RVM_INFRA_DIR}/lib/common.sh"
# shellcheck source=lib/envcache.sh
. "${RVM_INFRA_DIR}/lib/envcache.sh"

if [ $# -ge 1 ]; then
  PROJECT_ARG="$1"
else
  [ -f "${HOME}/.rvm-current" ] || rvm_die "no project given and no ~/.rvm-current"
  # shellcheck disable=SC1091
  . "${HOME}/.rvm-current"
  PROJECT_ARG="${RVM_SLUG}"
fi
rvm_load_project "${PROJECT_ARG}"

INSTANCE_ID="$(rvm_instance_id || echo unknown)"
cd "${RVM_REPO_DIR}"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
# shellcheck disable=SC1091
[ -f "${RVM_VENV}/bin/activate" ] && . "${RVM_VENV}/bin/activate"

# The venv came from a cache keyed on this commit's dependency files, so
# it is already correct — but a `git pull` since boot can move them.
rvm_env_ensure "${RVM_REPO_DIR}"

# --- 1. run the agent on the next row ---
PROMPT_PATH="${RVM_REPO_DIR}/${RVM_PROMPT_FILE}"
[ -f "${PROMPT_PATH}" ] || PROMPT_PATH="${RVM_INFRA_DIR}/templates/prompt.md"
claude "$(cat "${PROMPT_PATH}")"

# --- 2. refuse to proceed on an unclean tree: terminate destroys the volume ---
if [ -n "$(git status --porcelain)" ]; then
  rvm_log "uncommitted changes present, not proceeding"; git status --short; exit 1
fi
UNPUSHED="$(git log '@{u}..' --oneline 2>/dev/null || echo no-upstream)"
if [ -n "${UNPUSHED}" ] && [ "${UNPUSHED}" != "no-upstream" ]; then
  rvm_log "unpushed commits present, not proceeding"; exit 1
fi

# --- 3. sweep fan-out, if the agent asked for one ---
if [ -f NEEDS_WORKERS ]; then
  [ -n "${RVM_WORKER_CMD}" ] || rvm_die "sweep requested but RVM_WORKER_CMD is unset in infra/rvm.env"
  WORKER_IDS="$(python3 -c "import json;print(' '.join(str(w['worker_id']) for w in json.load(open('sweep_manifest.json'))['workers']))")"
  INSTANCE_IDS=()
  for WID in ${WORKER_IDS}; do
    "${RVM_INFRA_DIR}/bin/rvm" launch "${RVM_SLUG}" --role worker --worker-id "${WID}" \
      --branch "${BRANCH}" --quiet-id > /tmp/rvm-worker-${WID}.id
    WIID="$(cat /tmp/rvm-worker-${WID}.id)"
    rvm_log "launched worker ${WID}: ${WIID}"
    INSTANCE_IDS+=("${WIID}")
  done

  rvm_log "waiting on ${#INSTANCE_IDS[@]} workers"
  while true; do
    STATES="$(aws ec2 describe-instances --region "${RVM_REGION}" \
      --instance-ids "${INSTANCE_IDS[@]}" \
      --query 'Reservations[].Instances[].State.Name' --output text)"
    if ! echo "${STATES}" | grep -qv terminated; then rvm_log "all workers terminated"; break; fi
    if echo "${STATES}" | grep -q stopped; then
      rvm_log "a worker stopped instead of terminating — failure or hard cap. Inspect:"
      aws ec2 describe-instances --region "${RVM_REGION}" --instance-ids "${INSTANCE_IDS[@]}" \
        --query 'Reservations[].Instances[].[InstanceId,State.Name]' --output table
      exit 1
    fi
    sleep 30
  done

  git pull --ff-only
  rm -f NEEDS_WORKERS
  claude "The workers for the sweep on the current row have all finished and \
pushed their results. Read the results, mark the row per the pre-registered \
criteria, record anything surprising, commit, and push."
  if [ -n "$(git status --porcelain)" ] || [ -n "$(git log '@{u}..' --oneline 2>/dev/null)" ]; then
    rvm_log "tree dirty or unpushed after closing out the sweep, not terminating"; exit 1
  fi
fi

# --- 4. CI gate ---
if [ "${RVM_CI_GATE}" = "1" ] && [ -d .github/workflows ]; then
  SHA="$(git rev-parse HEAD)"
  rvm_log "waiting on CI for ${SHA}"
  STATUS=""
  for _ in $(seq 1 60); do
    STATUS="$(gh run list --commit "${SHA}" --limit 1 --json status,conclusion \
              --jq '.[0].conclusion // .[0].status' 2>/dev/null || true)"
    [[ "${STATUS}" == success || "${STATUS}" == failure ]] && break
    sleep 10
  done
  if [ "${STATUS}" != success ]; then
    rvm_log "CI did not pass (status: ${STATUS:-none}). Not terminating."; exit 1
  fi
fi

# --- 5. back up anything the terminate would destroy ---
"${RVM_INFRA_DIR}/bin/rvm" backup || rvm_log "backup failed (non-fatal)"

# --- 6. drop this instance's own idle alarm before the instance is gone ---
aws cloudwatch delete-alarms --region "${RVM_REGION}" \
  --alarm-names "research-vm-idle-${INSTANCE_ID}" 2>/dev/null || true

rvm_log "CI green. Terminating ${INSTANCE_ID}."
aws ec2 terminate-instances --region "${RVM_REGION}" --instance-ids "${INSTANCE_ID}"
