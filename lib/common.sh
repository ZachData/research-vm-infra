#!/usr/bin/env bash
# Sourced by every rvm script. Pure helpers: no side effects at source time
# beyond setting defaults, so it is safe to source from the CLI, from
# cloud-init as root, and from `su - ubuntu` shells alike.

RVM_REGION="${RVM_REGION:-us-east-2}"
RVM_BUCKET="${RVM_BUCKET:-research-vm-shared-176048535722}"
RVM_INFRA_REPO="${RVM_INFRA_REPO:-ZachData/research-vm-infra}"
RVM_INFRA_DIR="${RVM_INFRA_DIR:-/opt/rvm/infra}"
RVM_PAT_PARAM="${RVM_PAT_PARAM:-/research-vm/github-pat}"
RVM_TARGET_USER="${RVM_TARGET_USER:-ubuntu}"
RVM_TARGET_HOME="${RVM_TARGET_HOME:-/home/${RVM_TARGET_USER}}"
# One venv per project, under a common root. The daemon serves several
# projects from one long-lived box, and a single shared venv path meant
# every project switch evicted the previous project's environment. A venv
# is not relocatable, so the path must be deterministic per project rather
# than merely unique: ${RVM_VENV_ROOT}/<project> is the same path on every
# machine, which keeps the S3 tarballs valid. ~1.5 GB each against 50 GB
# free is ~30 projects.
RVM_VENV_ROOT="${RVM_VENV_ROOT:-${RVM_TARGET_HOME}/venvs}"
RVM_VENV_OVERRIDE="${RVM_VENV:-}"
RVM_VENV="${RVM_VENV:-${RVM_VENV_ROOT}/default}"

# Daemon state. Kept on local disk, not in S3: the box outlives every
# individual run now, so S3 is the backup channel rather than the hot path.
RVM_STATE_DIR="${RVM_STATE_DIR:-/run/rvm}"
RVM_HEARTBEAT="${RVM_HEARTBEAT:-${RVM_STATE_DIR}/heartbeat}"
# Polled each loop so a daemon can be paused or stopped without SSH.
RVM_CONTROL_PARAM="${RVM_CONTROL_PARAM:-/research-vm/daemon-control}"
RVM_DEFAULT_OWNER="${RVM_DEFAULT_OWNER:-ZachData}"
# Default interpreter for a project that does not pin one. uv fetches
# whatever a project asks for at boot, so a project on 3.11 or 3.13 costs
# a download, not an AMI.
RVM_PYTHON_DEFAULT="${RVM_PYTHON_DEFAULT:-3.12}"

rvm_log() { printf '[rvm %s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
rvm_die() { rvm_log "FATAL: $*"; exit 1; }

rvm_imds() {
  local tok
  tok="$(curl -sfX PUT http://169.254.169.254/latest/api/token \
        -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600')" || return 1
  curl -sf -H "X-aws-ec2-metadata-token: ${tok}" \
    "http://169.254.169.254/latest/meta-data/$1"
}

rvm_instance_id() { rvm_imds instance-id; }

# arm64 / x86_64 — part of the env-cache key, since a venv with compiled
# wheels is not portable across architectures.
rvm_arch() { uname -m; }

# No GPU means torch's default PyPI wheel drags in ~3 GB of CUDA libraries
# that can never execute. Part of the env-cache key, so a GPU instance and
# a CPU instance never share an environment.
rvm_has_gpu() { [ -e /dev/nvidia0 ] || command -v nvidia-smi >/dev/null 2>&1; }

# "3.12" — also part of the key: a venv built for one minor version does
# not work under another.
rvm_pyver() { "${1:-python3}" -c 'import sys;print("%d.%d"%sys.version_info[:2])'; }

# owner/name -> name ; name -> name
rvm_repo_name() { echo "${1##*/}"; }
# name -> RVM_DEFAULT_OWNER/name ; owner/name -> unchanged
rvm_repo_slug() {
  case "$1" in
    */*) echo "$1" ;;
    *)   echo "${RVM_DEFAULT_OWNER}/$1" ;;
  esac
}

# Write the PAT into a git credential store so any repo the token can see
# clones over HTTPS without a per-repo deploy key. Deploy keys are scoped
# to a single repo, which is the thing that made the old setup
# single-project; this is the replacement.
rvm_setup_git_auth() {
  local home="${1:-${RVM_TARGET_HOME}}" user="${2:-${RVM_TARGET_USER}}" pat
  pat="$(aws ssm get-parameter --name "${RVM_PAT_PARAM}" --with-decryption \
        --region "${RVM_REGION}" --query Parameter.Value --output text)" \
    || rvm_die "could not read ${RVM_PAT_PARAM} from SSM"
  umask 077
  printf 'https://x-access-token:%s@github.com\n' "${pat}" > "${home}/.git-credentials"
  chmod 600 "${home}/.git-credentials"
  chown "${user}:${user}" "${home}/.git-credentials" 2>/dev/null || true
  su - "${user}" -c "git config --global credential.helper store && \
    git config --global user.name  'research-vm' && \
    git config --global user.email 'zachsvm@gmail.com'" >/dev/null
  # gh, for the CI gate in wrapper.sh
  su - "${user}" -c "gh auth status" >/dev/null 2>&1 || \
    su - "${user}" -c "printf '%s' '${pat}' | gh auth login --with-token" || true
}

# Claude Code keys per-project state by an encoded form of the repo path:
# /home/ubuntu/Lora_inductionhead -> -home-ubuntu-Lora-inductionhead
# (slashes and underscores both become dashes).
rvm_claude_dir() {
  local enc; enc="$(echo "${1}" | tr '/_' '--')"
  echo "${RVM_TARGET_HOME}/.claude/projects/${enc}"
}

# Agent memory is the one piece of instance state with no copy anywhere
# else: the repo is on GitHub and the venv is in the cache, but memory
# written during a run dies with the volume unless it is synced. An
# ephemeral fleet that forgets everything each terminate is worse than a
# long-lived box, so this makes memory outlive the instance.
rvm_memory_pull() {
  local dir; dir="$(rvm_claude_dir "$1")/memory"
  mkdir -p "${dir}"
  aws s3 sync "s3://${RVM_BUCKET}/memory/${RVM_PROJECT}/" "${dir}/" \
    --region "${RVM_REGION}" --only-show-errors || true
}
rvm_memory_push() {
  local dir; dir="$(rvm_claude_dir "$1")/memory"
  [ -d "${dir}" ] || return 0
  aws s3 sync "${dir}/" "s3://${RVM_BUCKET}/memory/${RVM_PROJECT}/" \
    --region "${RVM_REGION}" --only-show-errors || true
}

# Load a project's config. Precedence, lowest to highest:
#   built-in defaults  <  infra repo projects/<name>.env  <  repo infra/rvm.env
# The repo file wins so a project can change its own runtime without a
# commit to this repo.
rvm_load_project() {
  local slug name repo_dir
  slug="$(rvm_repo_slug "$1")"; name="$(rvm_repo_name "${slug}")"
  repo_dir="${2:-${RVM_TARGET_HOME}/${name}}"

  RVM_PROJECT="${name}"
  RVM_SLUG="${slug}"
  RVM_REPO_DIR="${repo_dir}"
  RVM_REPO_URL="https://github.com/${slug}.git"
  RVM_BRANCH="${RVM_BRANCH:-main}"
  RVM_INSTANCE_TYPE="t4g.small"
  RVM_ORCH_TEMPLATE="small_t4g_template"
  RVM_WORKER_TEMPLATE="research-vm-worker-template"
  RVM_PYTHON="${RVM_PYTHON_DEFAULT}"
  RVM_ENV_INSTALL="pip install -e '.[dev]'"
  RVM_ENV_FILES="pyproject.toml requirements.txt uv.lock poetry.lock setup.py"
  RVM_HARD_CAP_HOURS=4
  RVM_WORKER_HOURS=2
  # Daemon lifetime. The lease is short and renewed while the daemon is
  # provably alive; the ceiling is set once and never renewed, so even a
  # daemon spinning on a wedged loop dies on schedule. C5 keeps its teeth.
  RVM_LEASE_MINUTES=90
  RVM_MAX_LIFETIME_HOURS=168
  RVM_DAEMON_POLL_SECONDS=300
  RVM_TEST_CMD=""
  RVM_WORKER_CMD=""
  RVM_PROMPT_FILE="infra/prompt.md"
  RVM_CACHE_PATHS=""
  RVM_CI_GATE=1
  RVM_VENV="${RVM_VENV_OVERRIDE:-${RVM_VENV_ROOT}/${name}}"

  [ -f "${RVM_INFRA_DIR}/projects/${name}.env" ] && . "${RVM_INFRA_DIR}/projects/${name}.env"
  [ -f "${repo_dir}/infra/rvm.env" ] && . "${repo_dir}/infra/rvm.env"
  return 0
}
