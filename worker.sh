#!/usr/bin/env bash
# Runs one sweep cell, pushes, and shuts down. Exec'd by bootstrap.sh when
# the role is `worker`, as root; the cell itself runs as the target user.
#   worker.sh <owner/repo> <worker_id>
#
# Either outcome ends in `shutdown -h now`, which the worker template
# (InstanceInitiatedShutdownBehavior=terminate) turns into a terminate. A
# one-time spot instance cannot be stopped, and a reclaim can take the volume
# mid-run regardless, so a failed cell is inspected from its pushed partial
# result plus `rvm backup`, never from a stopped box.
set -euo pipefail

RVM_INFRA_DIR="${RVM_INFRA_DIR:-/opt/rvm/infra}"
# shellcheck source=lib/common.sh
. "${RVM_INFRA_DIR}/lib/common.sh"

PROJECT_ARG="${1:?}"; WORKER_ID="${2:?}"
rvm_load_project "${PROJECT_ARG}"
INSTANCE_ID="$(rvm_instance_id || echo unknown)"
BRANCH="$(su - "${RVM_TARGET_USER}" -c "cd '${RVM_REPO_DIR}' && git rev-parse --abbrev-ref HEAD")"

# What this cell runs, in precedence order:
#   1. a per-worker "cmd" in sweep_manifest.json — lets the agent that wrote
#      the manifest pick the command, which differs from sweep to sweep
#   2. RVM_WORKER_CMD from infra/rvm.env, with {worker_id} and {n_workers}
#      substituted, for projects whose sweeps always take the same shape
MANIFEST="${RVM_REPO_DIR}/sweep_manifest.json"
CMD=""
N_WORKERS=1
if [ -f "${MANIFEST}" ]; then
  MANIFEST_LINE="$(python3 - "${MANIFEST}" "${WORKER_ID}" <<'JSONQ'
import json, sys
ws = json.load(open(sys.argv[1]))["workers"]
me = next((w for w in ws if str(w["worker_id"]) == sys.argv[2]), {})
print(len(ws), me.get("cmd", ""))
JSONQ
)"
  N_WORKERS="${MANIFEST_LINE%% *}"
  CMD="${MANIFEST_LINE#* }"
fi
if [ -z "${CMD}" ]; then
  [ -n "${RVM_WORKER_CMD}" ] || rvm_die "no cmd in sweep_manifest.json and RVM_WORKER_CMD unset in ${RVM_REPO_DIR}/infra/rvm.env"
  CMD="${RVM_WORKER_CMD}"
fi
CMD="${CMD//\{worker_id\}/${WORKER_ID}}"
CMD="${CMD//\{n_workers\}/${N_WORKERS}}"
rvm_log "cell command: ${CMD}"

# A spot reclaim gives ~2 minutes' notice via IMDS before it takes the
# volume, which is not enough time for the cell's own end-of-run push to
# run if it hasn't started yet. Poll for the notice for the lifetime of the
# cell and push whatever exists the moment it appears, in parallel with
# whatever the cell is doing.
watch_spot_interruption() {
  while true; do
    if rvm_imds spot/instance-action >/dev/null 2>&1; then
      rvm_log "spot interruption notice received — pushing whatever exists now"
      su - "${RVM_TARGET_USER}" -c "cd '${RVM_REPO_DIR}' && git add -A \
        && (git diff --cached --quiet || git commit -m 'worker ${WORKER_ID}: ${RVM_PROJECT} partial (spot reclaim)') \
        && git pull --rebase origin '${BRANCH}' && git push origin 'HEAD:${BRANCH}'" \
        >>/var/log/rvm-boot.log 2>&1 || true
      "${RVM_INFRA_DIR}/bin/rvm" backup >>/var/log/rvm-boot.log 2>&1 || true
      break
    fi
    sleep 5
  done
}
watch_spot_interruption &
SPOT_WATCHER_PID=$!

set +e
su - "${RVM_TARGET_USER}" -c "cd '${RVM_REPO_DIR}' \
  && . '${RVM_VENV}/bin/activate' \
  && export RVM_S3_BUCKET='${RVM_BUCKET}' RVM_PROJECT='${RVM_PROJECT}' RVM_WORKER_ID='${WORKER_ID}' \
  && ${CMD}"
CELL_RC=$?
set -e
rvm_log "cell exited ${CELL_RC}"
kill "${SPOT_WATCHER_PID}" 2>/dev/null || true

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

atrm "$(cat /run/rvm-hardcap-job 2>/dev/null || echo x)" 2>/dev/null || true
if [ "${PUSHED}" = true ] && [ "${CELL_RC}" -eq 0 ]; then
  rvm_log "cell ok and pushed — terminating"
else
  rvm_log "cell rc=${CELL_RC} pushed=${PUSHED} — terminating; inspect the pushed partial + rvm backup"
fi
shutdown -h now
