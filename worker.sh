#!/usr/bin/env bash
# Runs one sweep cell, pushes, and shuts down. Exec'd by bootstrap.sh when
# the role is `worker`, as root; the cell itself runs as the target user.
#   worker.sh <owner/repo> <worker_id>
#
# Success: push -> cancel the hard cap -> shutdown -h now, which the launch
# template turns into a terminate. Failure: stop, not terminate, so the
# volume survives for inspection.
set -euo pipefail

RVM_INFRA_DIR="${RVM_INFRA_DIR:-/opt/rvm/infra}"
# shellcheck source=lib/common.sh
. "${RVM_INFRA_DIR}/lib/common.sh"

PROJECT_ARG="${1:?}"; WORKER_ID="${2:?}"
rvm_load_project "${PROJECT_ARG}"
INSTANCE_ID="$(rvm_instance_id || echo unknown)"
BRANCH="$(su - "${RVM_TARGET_USER}" -c "cd '${RVM_REPO_DIR}' && git rev-parse --abbrev-ref HEAD")"

[ -n "${RVM_WORKER_CMD}" ] || rvm_die "RVM_WORKER_CMD unset in ${RVM_REPO_DIR}/infra/rvm.env"
CMD="${RVM_WORKER_CMD//\{worker_id\}/${WORKER_ID}}"

set +e
su - "${RVM_TARGET_USER}" -c "cd '${RVM_REPO_DIR}' \
  && . '${RVM_VENV}/bin/activate' \
  && export RVM_S3_BUCKET='${RVM_BUCKET}' RVM_PROJECT='${RVM_PROJECT}' RVM_WORKER_ID='${WORKER_ID}' \
  && ${CMD}"
CELL_RC=$?
set -e
rvm_log "cell exited ${CELL_RC}"

# Push whatever the cell produced even on failure — a partial result plus a
# nonzero exit is far more useful than a silently dead instance.
PUSHED=false
for _ in $(seq 1 5); do
  su - "${RVM_TARGET_USER}" -c "cd '${RVM_REPO_DIR}' && git add -A \
    && (git diff --cached --quiet || git commit -m 'worker ${WORKER_ID}: ${RVM_PROJECT} cell result')"
  if su - "${RVM_TARGET_USER}" -c "cd '${RVM_REPO_DIR}' \
      && git pull --rebase origin '${BRANCH}' && git push origin 'HEAD:${BRANCH}'"; then
    PUSHED=true; break
  fi
  sleep $((RANDOM % 10 + 5))   # jittered: several workers collide on the same branch
done

"${RVM_INFRA_DIR}/bin/rvm" backup || true

if [ "${PUSHED}" = true ] && [ "${CELL_RC}" -eq 0 ]; then
  atrm "$(cat /run/rvm-hardcap-job 2>/dev/null || echo x)" 2>/dev/null || true
  shutdown -h now
else
  rvm_log "cell rc=${CELL_RC} pushed=${PUSHED} — stopping for inspection, not terminating"
  aws ec2 stop-instances --region "${RVM_REGION}" --instance-ids "${INSTANCE_ID}"
fi
