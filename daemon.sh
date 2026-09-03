#!/usr/bin/env bash
# The maintenance loop. One long-lived orchestrator per project: pick up the
# next unit of work, run one bounded Claude Code cycle via wrapper.sh, sleep,
# repeat. The box outlives every cycle — only the agent's context is recycled,
# by starting each cycle with a fresh `claude` conversation.
#
# Started by systemd (rvm-daemon.service, Restart=always), which bootstrap.sh
# enables when the boot role is `daemon`.
#
# Lifecycle safety, in layers — C5 ("no instance left running without a cap")
# still has teeth even though nothing terminates on green:
#   ceiling : bootstrap.sh set an `at` job at RVM_MAX_LIFETIME_HOURS that is
#             never renewed. A daemon wedged forever still dies on it.
#   lease   : this loop reschedules an `at` job RVM_LEASE_MINUTES out on every
#             iteration. If one iteration hangs past that window the lease
#             fires and stops the box. Renewed only while the loop is moving.
#   control : /research-vm/daemon-control in SSM, polled each iteration —
#             `run` (default, or param missing) | `pause` (heartbeat only).
set -euo pipefail

RVM_INFRA_DIR="${RVM_INFRA_DIR:-/opt/rvm/infra}"
# shellcheck source=lib/common.sh
. "${RVM_INFRA_DIR}/lib/common.sh"

# The project is whatever bootstrap.sh recorded for this box.
[ -f "${RVM_TARGET_HOME}/.rvm-current" ] || rvm_die "no ${RVM_TARGET_HOME}/.rvm-current; bootstrap did not run"
# shellcheck disable=SC1091
. "${RVM_TARGET_HOME}/.rvm-current"
PROJECT_ARG="${RVM_SLUG:?no RVM_SLUG in .rvm-current}"
rvm_load_project "${PROJECT_ARG}"

INSTANCE_ID="$(rvm_instance_id || echo unknown)"
mkdir -p "${RVM_STATE_DIR}"
LEASE_JOB_FILE="${RVM_STATE_DIR}/lease-job"
ITER=0

renew_lease() {
  local prev job
  prev="$(cat "${LEASE_JOB_FILE}" 2>/dev/null || true)"
  [ -n "${prev}" ] && atrm "${prev}" 2>/dev/null || true
  job="$(echo "aws ec2 stop-instances --region ${RVM_REGION} --instance-ids ${INSTANCE_ID}" \
    | at now + "${RVM_LEASE_MINUTES}" minutes 2>&1 | grep -o 'job [0-9]*' | awk '{print $2}' || true)"
  echo "${job}" > "${LEASE_JOB_FILE}"
}

heartbeat() {
  local status="$1" ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'ts=%s\nproject=%s\ninstance=%s\nstatus=%s\niteration=%s\n' \
    "${ts}" "${RVM_PROJECT}" "${INSTANCE_ID}" "${status}" "${ITER}" > "${RVM_HEARTBEAT}"
  # S3 is the channel anyone off-box can read; CloudWatch feeds a stalled-loop
  # alarm if the role is allowed to put metrics. Both best-effort.
  aws s3 cp "${RVM_HEARTBEAT}" "s3://${RVM_BUCKET}/heartbeat/${RVM_PROJECT}/latest" \
    --region "${RVM_REGION}" --only-show-errors || true
  aws cloudwatch put-metric-data --region "${RVM_REGION}" \
    --namespace rvm --metric-name heartbeat_age_seconds --value 0 \
    --dimensions "project=${RVM_PROJECT}" >/dev/null 2>&1 || true
}

control() {
  aws ssm get-parameter --name "${RVM_CONTROL_PARAM}" --region "${RVM_REGION}" \
    --query Parameter.Value --output text 2>/dev/null || echo run
}

rvm_log "daemon start: project=${RVM_PROJECT} instance=${INSTANCE_ID} poll=${RVM_DAEMON_POLL_SECONDS}s lease=${RVM_LEASE_MINUTES}m"

while true; do
  ITER=$((ITER + 1))
  renew_lease

  case "$(control)" in
    pause|paused)
      rvm_log "iteration ${ITER}: control=pause, no work"
      heartbeat paused
      ;;
    *)
      heartbeat working
      rvm_log "iteration ${ITER}: work cycle"
      if RVM_NO_TERMINATE=1 RVM_INFRA_DIR="${RVM_INFRA_DIR}" \
         "${RVM_INFRA_DIR}/wrapper.sh" "${PROJECT_ARG}"; then
        rvm_log "iteration ${ITER}: cycle ok"
        heartbeat idle
      else
        rvm_log "iteration ${ITER}: wrapper exited nonzero — continuing to next cycle"
        heartbeat error
      fi
      ;;
  esac

  sleep "${RVM_DAEMON_POLL_SECONDS}"
done
