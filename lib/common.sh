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
RVM_VENV="${RVM_VENV:-${RVM_TARGET_HOME}/venv}"
RVM_DEFAULT_OWNER="${RVM_DEFAULT_OWNER:-ZachData}"

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
  RVM_ENV_INSTALL="pip install -e '.[dev]'"
  RVM_ENV_FILES="pyproject.toml requirements.txt uv.lock poetry.lock setup.py"
  RVM_HARD_CAP_HOURS=4
  RVM_WORKER_HOURS=3
  RVM_TEST_CMD=""
  RVM_WORKER_CMD=""
  RVM_PROMPT_FILE="infra/prompt.md"
  RVM_CACHE_PATHS=""
  RVM_CI_GATE=1

  [ -f "${RVM_INFRA_DIR}/projects/${name}.env" ] && . "${RVM_INFRA_DIR}/projects/${name}.env"
  [ -f "${repo_dir}/infra/rvm.env" ] && . "${repo_dir}/infra/rvm.env"
  return 0
}
