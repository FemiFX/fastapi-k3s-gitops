#!/usr/bin/env bash
#
# One command from nothing to a running environment.
#
#   ./scripts/bootstrap.sh staging
#
# Mints the two credentials that used to be created by hand, provisions the VM,
# configures it, installs the GitLab Agent and Argo CD, seeds the Secrets that
# are deliberately not in git, and does not exit 0 until the application
# answers.
#
# ---------------------------------------------------------------------------
# Read this before running it
# ---------------------------------------------------------------------------
#
# This script creates credentials, which means it has to hold a larger one.
# GITLAB_PAT (api scope, Maintainer) can create agent tokens for every cluster
# in the project; root on the hypervisor can create Proxmox tokens with any
# privileges at all.
#
# That is a real trade and it should be made deliberately. The gain is that a
# rebuild has no manual step left to forget -- and the first rebuild drill was
# derailed for three rounds by exactly one forgotten manual step, the agent
# token. The cost is a credential that can mint every other credential.
#
# So: run it from a trusted machine, keep GITLAB_PAT short-lived, revoke it
# when the rebuild is done, and do not put it in CI. CI deliberately uses
# CI_JOB_TOKEN for state and cannot create tokens at all.
#
# ---------------------------------------------------------------------------
# What it needs
# ---------------------------------------------------------------------------
#
# Required:
#   GITLAB_PAT                  personal access token, api scope, Maintainer.
#                               Used for the agent token AND Terraform state.
#   GITLAB_USERNAME             your GitLab username, for the state backend
#   ARGOCD_REPO_USERNAME        deploy token with read_repository
#   ARGOCD_REPO_PASSWORD
#   GITLAB_PROJECT_ID           numeric ID, on the project's home page
#   PROXMOX_SSH_HOST            the Proxmox host's address
#   PROXMOX_SSH_USER            an account on it that can run qm
#
# Optional. Each one left unset leaves something for a pipeline to finish:
#   POSTGRES_USER / POSTGRES_PASSWORD / POSTGRES_DB
#   STAGING_MATTERMOST_WEBHOOK_URL
#
# With defaults:
#   TF_STATE_NAME       production    PROXMOX_TOKEN_USER terraform@pve
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Environments
# ---------------------------------------------------------------------------
# Everything that differs between the two, in one place, so every step below
# reads the same for both.
case "${1:-}" in
  staging)
    ENVIRONMENT=staging
    TF_TARGETS=('proxmox_virtual_environment_vm.vm["staging"]')
    ANSIBLE_LIMIT=staging
    AGENT_NAME=staging
    NAMESPACE=staging
    RELEASE=staging
    ;;
  production)
    # Production is two machines, and bootstrapping it unattended is a much
    # bigger claim than bootstrapping staging. Gated on typing it out, same as
    # the destroy job.
    if [ "${CONFIRM_PRODUCTION:-}" != "bootstrap production" ]; then
      echo "Refusing to bootstrap production unless CONFIRM_PRODUCTION is set to" >&2
      echo "exactly: bootstrap production" >&2
      exit 1
    fi
    ENVIRONMENT=production
    TF_TARGETS=(
      'proxmox_virtual_environment_vm.vm["prod-server"]'
      'proxmox_virtual_environment_vm.vm["prod-agent"]'
    )
    ANSIBLE_LIMIT='prod-server,prod-agent'
    AGENT_NAME=production
    NAMESPACE=production
    RELEASE=prod
    ;;
  *)
    echo "usage: $0 {staging|production}" >&2
    exit 1
    ;;
esac

GITLAB_PROJECT_ID="${GITLAB_PROJECT_ID:?set GITLAB_PROJECT_ID}"
GITLAB_HOST="${GITLAB_HOST:-gitlab.com}"
PROXMOX_SSH_HOST="${PROXMOX_SSH_HOST:?set PROXMOX_SSH_HOST}"
PROXMOX_SSH_USER="${PROXMOX_SSH_USER:?set PROXMOX_SSH_USER}"
PROXMOX_TOKEN_USER="${PROXMOX_TOKEN_USER:-terraform@pve}"
PROXMOX_TOKEN_NAME="${PROXMOX_TOKEN_NAME:-bootstrap}"
TF_STATE_NAME="${TF_STATE_NAME:-production}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---------------------------------------------------------------------------
# Plumbing
# ---------------------------------------------------------------------------
STEP=0
step() { STEP=$((STEP + 1)); printf '\n\033[1m[%d] %s\033[0m\n' "$STEP" "$1"; }
die()  { printf '\n\033[31mFAILED: %s\033[0m\n' "$1" >&2; exit 1; }

# Named one at a time rather than looped, so the message says which is missing.
need() {
  if [ -z "${!1:-}" ]; then
    die "$1 is not set. See the header of this script for what it is for."
  fi
}

# Secrets are written to files with mode 600 and passed by filename, never on a
# command line. Two reasons, and the second is the one that has actually bitten
# this project: a command line is readable by every user on the machine via
# `ps`, and every layer between here and the tool -- the shell, Ansible's
# argument splitter -- gets a turn at rewriting it. A file has no layers.
SCRATCH="$(mktemp -d)"
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT

ssh_pve() {
  ssh -o StrictHostKeyChecking=accept-new \
      "${PROXMOX_SSH_USER}@${PROXMOX_SSH_HOST}" "$@"
}

# GitLab API. The token goes in a header from a variable, not an argument.
api() {
  local method="$1" path="$2" body="${3:-}"
  local url="https://${GITLAB_HOST}/api/v4${path}"
  if [ -n "$body" ]; then
    curl -sS $CURL_FAIL -X "$method" "$url" \
      -H "PRIVATE-TOKEN: ${GITLAB_PAT}" \
      -H "Content-Type: application/json" --data "$body"
  else
    curl -sS $CURL_FAIL -X "$method" "$url" -H "PRIVATE-TOKEN: ${GITLAB_PAT}"
  fi
}

# python3 rather than jq: Ansible already needs python3 here, and one fewer
# dependency is one fewer thing a rebuilt machine can be missing.
json() { python3 -c "import json,sys; print(json.load(sys.stdin)$1)"; }

# ---------------------------------------------------------------------------
step "Preflight"
# ---------------------------------------------------------------------------
for tool in terraform ansible ansible-playbook ssh curl python3; do
  command -v "$tool" >/dev/null || die "$tool is not on PATH."
done

# --fail-with-body shows the API's explanation of a 4xx; older curl has only
# --fail, which throws the body away. Detect rather than assume.
if curl --help all 2>/dev/null | grep -q -- --fail-with-body; then
  CURL_FAIL="--fail-with-body"
else
  CURL_FAIL="--fail"
fi

need GITLAB_PAT
need GITLAB_USERNAME
need ARGOCD_REPO_USERNAME
need ARGOCD_REPO_PASSWORD

# Fail on a bad token here, in one second, rather than three minutes later
# inside Terraform with a message about state locking.
api GET "/projects/${GITLAB_PROJECT_ID}" >/dev/null \
  || die "GITLAB_PAT cannot read project ${GITLAB_PROJECT_ID}. Wrong token, wrong scope, or too low a role -- state needs Maintainer, not Developer."

ssh_pve true >/dev/null 2>&1 \
  || die "Cannot SSH to ${PROXMOX_SSH_USER}@${PROXMOX_SSH_HOST}."

echo "ok: tools, GitLab API, hypervisor"

# ---------------------------------------------------------------------------
step "Mint a Proxmox API token"
# ---------------------------------------------------------------------------
# A Proxmox token's secret is shown once, at creation, and can never be read
# back, so there is no "reuse the existing one" path. A fixed name is removed
# and recreated instead. That keeps the account tidy and makes the consequence
# explicit rather than accumulating tokens nobody can identify later.
#
# --privsep 0 means the token inherits the user's permissions rather than
# carrying an ACL of its own; the user is already scoped to what Terraform needs.
ssh_pve "pveum user token remove ${PROXMOX_TOKEN_USER} ${PROXMOX_TOKEN_NAME}" \
  >/dev/null 2>&1 || true

PVE_JSON="$(ssh_pve "pveum user token add ${PROXMOX_TOKEN_USER} ${PROXMOX_TOKEN_NAME} --privsep 0 --output-format json")" \
  || die "pveum could not create a token for ${PROXMOX_TOKEN_USER}. Does that user exist?"

PVE_TOKEN_ID="$(printf '%s' "$PVE_JSON" | json "['full-tokenid']")"
PVE_TOKEN_SECRET="$(printf '%s' "$PVE_JSON" | json "['value']")"
[ -n "$PVE_TOKEN_SECRET" ] || die "pveum returned no token value."

# The bpg provider wants the halves joined: USER@REALM!NAME=UUID
export TF_VAR_proxmox_api_token="${PVE_TOKEN_ID}=${PVE_TOKEN_SECRET}"
unset PVE_JSON PVE_TOKEN_SECRET
echo "ok: ${PVE_TOKEN_ID}"

# ---------------------------------------------------------------------------
step "Create a GitLab Agent token"
# ---------------------------------------------------------------------------
# The registration lives in GitLab and survives a destroy. The token lived in
# the cluster and did not. That asymmetry is what makes this the step everyone
# forgets: afterwards `kubectl config get-contexts` still lists the agent,
# because listing an agent does not contact it.
AGENT_ID="$(api GET "/projects/${GITLAB_PROJECT_ID}/cluster_agents" | python3 -c "
import json, sys
name = '${AGENT_NAME}'
print(next((a['id'] for a in json.load(sys.stdin) if a['name'] == name), ''))
")"

if [ -z "$AGENT_ID" ]; then
  echo "No agent named ${AGENT_NAME}; registering one."
  AGENT_ID="$(api POST "/projects/${GITLAB_PROJECT_ID}/cluster_agents" \
    "{\"name\":\"${AGENT_NAME}\"}" | json "['id']")"
fi

# An agent may hold at most two active tokens, so a third rebuild would fail
# with a message about limits rather than about anything real. Revoke the ones
# this script created; leave anything a person made alone.
api GET "/projects/${GITLAB_PROJECT_ID}/cluster_agents/${AGENT_ID}/tokens" | python3 -c "
import json, sys
for t in json.load(sys.stdin):
    if t.get('status') == 'active' and str(t.get('name', '')).startswith('bootstrap-'):
        print(t['id'])
" | while read -r tid; do
  [ -n "$tid" ] || continue
  echo "Revoking previous bootstrap token ${tid}."
  api DELETE "/projects/${GITLAB_PROJECT_ID}/cluster_agents/${AGENT_ID}/tokens/${tid}" >/dev/null
done

AGENT_TOKEN="$(api POST "/projects/${GITLAB_PROJECT_ID}/cluster_agents/${AGENT_ID}/tokens" \
  "{\"name\":\"bootstrap-$(date +%Y%m%d-%H%M%S)\",\"description\":\"Created by scripts/bootstrap.sh\"}" \
  | json "['token']")"
[ -n "$AGENT_TOKEN" ] || die "GitLab returned no agent token."
echo "ok: agent ${AGENT_NAME} (id ${AGENT_ID})"

# ---------------------------------------------------------------------------
step "Terraform: point at the shared state"
# ---------------------------------------------------------------------------
# backend "http" {} is empty in versions.tf on purpose. Everything comes from
# these variables, so one configuration works from CI and from here.
TF_ADDRESS="https://${GITLAB_HOST}/api/v4/projects/${GITLAB_PROJECT_ID}/terraform/state/${TF_STATE_NAME}"
export TF_HTTP_ADDRESS="$TF_ADDRESS"
export TF_HTTP_LOCK_ADDRESS="${TF_ADDRESS}/lock"
export TF_HTTP_UNLOCK_ADDRESS="${TF_ADDRESS}/lock"
export TF_HTTP_LOCK_METHOD=POST
export TF_HTTP_UNLOCK_METHOD=DELETE
export TF_HTTP_USERNAME="$GITLAB_USERNAME"
export TF_HTTP_PASSWORD="$GITLAB_PAT"

cd "${REPO_ROOT}/infra/terraform"
terraform init -input=false -reconfigure >/dev/null || die "terraform init failed."
echo "ok: state ${TF_STATE_NAME}"

# ---------------------------------------------------------------------------
step "Terraform: build the machine"
# ---------------------------------------------------------------------------
# Targeted, so bootstrapping one environment can never touch the other. Same
# reasoning as the destroy job, and the same reason: a blast radius should be
# chosen, not inherited.
TARGET_ARGS=()
for t in "${TF_TARGETS[@]}"; do TARGET_ARGS+=(-target="$t"); done

terraform plan -input=false "${TARGET_ARGS[@]}" -out=bootstrap.tfplan \
  || die "terraform plan failed."
terraform apply -input=false bootstrap.tfplan || die "terraform apply failed."
rm -f bootstrap.tfplan
echo "ok"

# ---------------------------------------------------------------------------
step "Wait for the machine to accept logins"
# ---------------------------------------------------------------------------
# A VM that answers ping is not a VM that accepts logins, and cloud-init is
# still installing packages for the first minute or two.
cd "${REPO_ROOT}/infra/ansible"
for i in $(seq 1 60); do
  if ansible "$ANSIBLE_LIMIT" -m ping >/dev/null 2>&1; then
    echo "ok: reachable after $((i * 10))s"
    break
  fi
  [ "$i" -lt 60 ] || die "No SSH after 10 minutes. Look at the VM console in Proxmox."
  sleep 10
done

# ---------------------------------------------------------------------------
step "Ansible: base configuration and k3s"
# ---------------------------------------------------------------------------
ansible-playbook site.yml --tags common,k3s --limit "$ANSIBLE_LIMIT" \
  || die "Base configuration failed."

# ---------------------------------------------------------------------------
step "Ansible: GitLab Agent and Argo CD"
# ---------------------------------------------------------------------------
# Credentials go in a vars file, not on the command line.
#
# `-e key=value` is split on whitespace by Ansible before the value reaches
# anything, which once delivered 11 characters of a 90-character SSH key and
# looked like a corrupt key rather than a parsing bug. `-e @file` has no such
# step. It is also not visible in `ps`.
VARS="${SCRATCH}/bootstrap-vars.yml"
umask 077
cat > "$VARS" <<EOF
gitlab_agent_token: "${AGENT_TOKEN}"
argocd_repo_username: "${ARGOCD_REPO_USERNAME}"
argocd_repo_password: "${ARGOCD_REPO_PASSWORD}"
EOF

ansible-playbook site.yml --tags agent --limit "$ANSIBLE_LIMIT" -e "@${VARS}" \
  || die "Agent installation failed."

ansible-playbook site.yml --tags argocd --limit "$ANSIBLE_LIMIT" -e "@${VARS}" \
  || die "Argo CD installation failed."

# ---------------------------------------------------------------------------
step "Seed the Secrets Argo CD does not own"
# ---------------------------------------------------------------------------
# Argo CD reconciles everything in gitops/. Secrets deliberately are not in
# there, so on a freshly built cluster it creates workloads that cannot start
# until something else puts them in place -- CreateContainerConfigError on
# every pod, which is precisely how the first rebuild drill went. Normally that
# something is a pipeline. Doing it here means the bootstrap does not end with
# a cluster that still needs one.
#
# Written by a small script sent over stdin, so no value appears in a command
# line. The kubeconfig k3s writes is mode 644, so no sudo is needed to read it.
# Ansible's ad-hoc shell module cannot take stdin, so this goes over ssh -J,
# using the same jump host the inventory uses.
NODE_IP="$(ansible-inventory --host "${ANSIBLE_LIMIT%%,*}" | json "['ansible_host']")"

remote_sh() {
  ssh -o StrictHostKeyChecking=accept-new \
      -o ProxyJump="${PROXMOX_SSH_USER}@${PROXMOX_SSH_HOST}" \
      "femi@${NODE_IP}" "sh -s"
}

if [ -n "${POSTGRES_PASSWORD:-}" ]; then
  remote_sh <<EOF
set -eu
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
k3s kubectl create namespace ${NAMESPACE} --dry-run=client -o yaml | k3s kubectl apply -f - >/dev/null
k3s kubectl -n ${NAMESPACE} create secret generic app-secrets \
  --from-literal=POSTGRES_USER='${POSTGRES_USER:-app}' \
  --from-literal=POSTGRES_PASSWORD='${POSTGRES_PASSWORD}' \
  --from-literal=POSTGRES_DB='${POSTGRES_DB:-app}' \
  --dry-run=client -o yaml | k3s kubectl apply --server-side --force-conflicts -f - >/dev/null
EOF
  echo "ok: app-secrets in ${NAMESPACE}"
else
  echo "POSTGRES_PASSWORD not set, so app-secrets is left for a pipeline."
  echo "Until one runs, every application pod will sit in CreateContainerConfigError."
fi

if [ "$ENVIRONMENT" = staging ] && [ -n "${STAGING_MATTERMOST_WEBHOOK_URL:-}" ]; then
  remote_sh <<EOF
set -eu
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
k3s kubectl create namespace monitoring --dry-run=client -o yaml | k3s kubectl apply -f - >/dev/null
k3s kubectl -n monitoring create secret generic alertmanager-mattermost \
  --from-literal=url='${STAGING_MATTERMOST_WEBHOOK_URL}' \
  --dry-run=client -o yaml | k3s kubectl apply --server-side --force-conflicts -f - >/dev/null
EOF
  echo "ok: alertmanager-mattermost"
fi

# ---------------------------------------------------------------------------
step "Wait for Argo CD to fill the cluster"
# ---------------------------------------------------------------------------
# Nothing else is installed by hand from here. What the cluster contains is
# described in gitops/, and Argo CD makes it true.
for i in $(seq 1 90); do
  out="$(ansible "$ANSIBLE_LIMIT" --become -m shell \
    -a "cmd='k3s kubectl -n argocd get applications --no-headers'" 2>/dev/null || true)"
  # Every Application Synced and Healthy, and at least one of them present.
  if printf '%s\n' "$out" | grep -q 'Synced *Healthy' \
     && ! printf '%s\n' "$out" | grep -qE 'OutOfSync|Degraded|Missing|Progressing'; then
    printf '%s\n' "$out"
    echo "ok: Argo CD settled after $((i * 10))s"
    break
  fi
  [ "$i" -lt 90 ] || die "Argo CD did not settle in 15 minutes. Look at: k3s kubectl -n argocd get applications"
  sleep 10
done

# ---------------------------------------------------------------------------
step "Prove the application answers"
# ---------------------------------------------------------------------------
# Not "the pods are running". A rollout that completes and a service that
# answers are different claims, and only the second one is what anybody cares
# about. This is the same reason the pipeline runs a smoke test after Argo CD
# reports it is done.
ansible "$ANSIBLE_LIMIT" --become -m shell -a "cmd='
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  k3s kubectl -n ${NAMESPACE} rollout status deployment/${RELEASE}-fastapi-app --timeout=300s
  k3s kubectl -n ${NAMESPACE} run bootstrap-smoke --rm -i --restart=Never --quiet --image=curlimages/curl:8.10.1 -- -sf --max-time 10 http://${RELEASE}-fastapi-app/health
'" || die "The application never answered /health."

printf '\n\033[32m%s is up.\033[0m\n' "$ENVIRONMENT"
cat <<EOF

Still a person's job:

  - Revoke GITLAB_PAT if it was created for this run. It can mint agent tokens
    for every cluster in the project, so it should not outlive the rebuild.
  - The Proxmox token "${PROXMOX_TOKEN_NAME}" was removed and recreated, so any
    previous holder of that name stopped working. CI has its own token and is
    unaffected.
  - Restoring data. This cluster has an empty database. Whether to restore, and
    from which snapshot, is a judgement rather than a step -- see
    docs/rebuild-staging.md.
EOF
