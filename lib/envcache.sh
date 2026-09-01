#!/usr/bin/env bash
# The venv cache. This is what makes AMI rebuilds unnecessary:
# the expensive artifact (a ~5 GB torch venv) lives in S3 keyed by a hash
# of the files that define it, not baked into an image. Change a
# dependency and the next boot builds once and publishes; every boot after
# that restores in well under a minute. The AMI then holds nothing that
# ever needs to change.
#
# Key: envs/<arch>/py<ver>/<project>/<dephash>.tar.zst
# dephash covers: dependency file contents + python minor version + arch +
# the install command itself. Anything that would produce a different
# site-packages must be in the hash, or a stale env gets served silently.

# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

rvm_env_hash() {
  local repo_dir="$1" f
  {
    echo "v3"
    echo "venv=$(basename "${RVM_VENV}")"
    echo "arch=$(rvm_arch)"
    echo "py=${RVM_PYTHON}"
    echo "gpu=$(rvm_has_gpu && echo 1 || echo 0)"
    echo "install=${RVM_ENV_INSTALL}"
    for f in ${RVM_ENV_FILES}; do
      if [ -f "${repo_dir}/${f}" ]; then
        echo "--- ${f}"
        cat "${repo_dir}/${f}"
      fi
    done
  } | sha256sum | cut -c1-16
}

rvm_env_key() {
  printf 'envs/%s/py%s/%s/%s.tar.zst' \
    "$(rvm_arch)" "${RVM_PYTHON}" "${RVM_PROJECT}" "$1"
}

rvm_env_exists() {
  aws s3api head-object --bucket "${RVM_BUCKET}" --key "$1" \
    --region "${RVM_REGION}" >/dev/null 2>&1
}

# Restore or build, then leave a usable venv at ${RVM_VENV}. Idempotent:
# a venv already carrying the right hash is left completely alone.
rvm_env_ensure() {
  local repo_dir="$1" hash key stamp
  hash="$(rvm_env_hash "${repo_dir}")"
  key="$(rvm_env_key "${hash}")"
  stamp="${RVM_VENV}/.rvm-env-hash"

  if [ -f "${stamp}" ] && [ "$(cat "${stamp}")" = "${hash}" ]; then
    rvm_log "env ${hash} already present at ${RVM_VENV}"
    return 0
  fi

  if rvm_env_exists "${key}"; then
    rvm_log "env ${hash}: cache hit, restoring s3://${RVM_BUCKET}/${key}"
    rvm_env_restore "${key}" "${hash}" && return 0
    rvm_log "restore failed, falling back to a local build"
  else
    rvm_log "env ${hash}: cache miss"
  fi

  rvm_env_build "${repo_dir}" "${hash}"
  rvm_env_publish "${key}"
}

rvm_env_restore() {
  local key="$1" hash="$2" tmp
  tmp="$(mktemp -d)"
  # Extract to a scratch dir and swap, so an interrupted download never
  # leaves a half-populated venv that later looks valid.
  if ! aws s3 cp "s3://${RVM_BUCKET}/${key}" - --region "${RVM_REGION}" \
       | tar -I 'zstd -d' -x -C "${tmp}"; then
    rm -rf "${tmp}"; return 1
  fi
  local src
  # The archive's top-level entry is named for the venv it was built from,
  # which is per-project now. Take whatever came out rather than assuming.
  src="$(find "${tmp}" -mindepth 1 -maxdepth 1 -type d | head -1)"
  [ -n "${src}" ] || { rm -rf "${tmp}"; rvm_log "empty archive"; return 1; }
  mkdir -p "$(dirname "${RVM_VENV}")"
  rm -rf "${RVM_VENV}.old"
  [ -d "${RVM_VENV}" ] && mv "${RVM_VENV}" "${RVM_VENV}.old"
  mv "${src}" "${RVM_VENV}"
  rm -rf "${tmp}" "${RVM_VENV}.old"
  echo "${hash}" > "${RVM_VENV}/.rvm-env-hash"
  # A venv is not relocatable: its scripts carry absolute shebangs. The
  # tarball is only valid extracted to the path it was built at, so the
  # venv path is part of the cache key and derived deterministically from
  # the project name. This check is what catches a violation of that.
  "${RVM_VENV}/bin/python" -c 'import sys; sys.exit(0)' \
    || { rvm_log "restored venv is not executable"; return 1; }
  return 0
}

rvm_env_build() {
  local repo_dir="$1" hash="$2" f
  rvm_log "building venv at ${RVM_VENV} for python ${RVM_PYTHON} (slow path)"
  mkdir -p "$(dirname "${RVM_VENV}")"
  rm -rf "${RVM_VENV}"
  if command -v uv >/dev/null 2>&1; then
    # uv downloads the requested CPython if the box does not have it, which
    # is what lets one image serve projects pinned to different versions.
    # --seed puts pip in the venv, since RVM_ENV_INSTALL is written in pip.
    uv venv --python "${RVM_PYTHON}" --seed "${RVM_VENV}" \
      || rvm_die "uv could not provide python ${RVM_PYTHON}"
  else
    command -v "python${RVM_PYTHON}" >/dev/null \
      || rvm_die "python${RVM_PYTHON} not installed and uv unavailable"
    "python${RVM_PYTHON}" -m venv "${RVM_VENV}"
  fi
  # shellcheck disable=SC1091
  . "${RVM_VENV}/bin/activate"
  pip install --quiet --upgrade pip wheel

  # torch resolves to a CUDA build by default on both x86_64 and aarch64.
  # On a GPU-less instance that is ~3 GB of libraries that cannot run —
  # paid for on every cache miss and every restore. Pre-install the CPU
  # build so the project's own install finds torch already satisfied.
  if ! rvm_has_gpu; then
    for f in ${RVM_ENV_FILES}; do
      if [ -f "${repo_dir}/${f}" ] && grep -qi '^[^#]*torch' "${repo_dir}/${f}"; then
        rvm_log "no GPU: installing the CPU torch build"
        pip install --quiet torch --index-url https://download.pytorch.org/whl/cpu \
          || rvm_log "CPU torch index failed; falling back to the default resolution"
        break
      fi
    done
  fi

  ( cd "${repo_dir}" && eval "${RVM_ENV_INSTALL}" ) \
    || rvm_die "env install failed: ${RVM_ENV_INSTALL}"
  echo "${hash}" > "${RVM_VENV}/.rvm-env-hash"
}

rvm_env_publish() {
  local key="$1"
  command -v zstd >/dev/null || { rvm_log "no zstd; not publishing"; return 0; }
  rvm_log "publishing env to s3://${RVM_BUCKET}/${key}"
  # -T0 uses both cores; -3 is the knee of the ratio/time curve for a venv.
  # Stream straight to S3: a 5 GB venv should never need 2 GB of scratch.
  tar -C "$(dirname "${RVM_VENV}")" -c "$(basename "${RVM_VENV}")" \
    | zstd -3 -T0 -c \
    | aws s3 cp - "s3://${RVM_BUCKET}/${key}" --region "${RVM_REGION}" \
    || rvm_log "publish failed (non-fatal; next boot rebuilds)"
}

# Named data caches (HF checkpoints, datasets). Shared across projects on
# purpose: two projects probing the same pythia revisions should not each
# pay the download.
rvm_cache_pull() {
  local name="$1" dest="$2"
  mkdir -p "${dest}"
  aws s3 sync "s3://${RVM_BUCKET}/caches/${name}/" "${dest}/" \
    --region "${RVM_REGION}" --only-show-errors
}
rvm_cache_push() {
  local name="$1" src="$2"
  aws s3 sync "${src}/" "s3://${RVM_BUCKET}/caches/${name}/" \
    --region "${RVM_REGION}" --only-show-errors
}
