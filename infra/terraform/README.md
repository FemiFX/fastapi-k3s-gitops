# Terraform

Provisions the four VMs on the Proxmox host. See
[../../docs/infrastructure.md](../../docs/infrastructure.md) for what they are
and why.

## State lives in GitLab

State is the record of which real resources Terraform believes it created. Lose
it and Terraform no longer knows the VMs exist, so the next `apply` tries to
build them again.

It used to be a local file. That cannot work from a pipeline: a runner is
disposable, so every run would start blind. GitLab hosts a state backend for
every project, which also provides locking — a second `apply` waits rather than
racing the first.

`versions.tf` declares `backend "http" {}` with no values in it. Everything
comes from `TF_HTTP_*` environment variables, so the same configuration works
from CI and from a workstation.

## One-off: migrating the existing state

**Do this once.** There are four live VMs recorded in the local state file, and
they must be carried across, not rediscovered.

```sh
cd infra/terraform

# 1. Keep a copy. If anything goes wrong, this is the way back.
cp terraform.tfstate ~/terraform.tfstate.backup-$(date +%Y%m%d)

# 2. Point at GitLab. PROJECT_ID is on the project's home page.
export PROJECT_ID=<numeric project ID>
export STATE_NAME=production
export GITLAB_TOKEN=<personal access token with the api scope>

export TF_HTTP_ADDRESS="https://gitlab.com/api/v4/projects/${PROJECT_ID}/terraform/state/${STATE_NAME}"
export TF_HTTP_LOCK_ADDRESS="${TF_HTTP_ADDRESS}/lock"
export TF_HTTP_UNLOCK_ADDRESS="${TF_HTTP_ADDRESS}/lock"
export TF_HTTP_LOCK_METHOD="POST"
export TF_HTTP_UNLOCK_METHOD="DELETE"
export TF_HTTP_USERNAME="<your gitlab username>"
export TF_HTTP_PASSWORD="${GITLAB_TOKEN}"

# 3. Migrate. Terraform will ask whether to copy the existing state up: yes.
terraform init -migrate-state

# 4. Prove nothing changed. This is the whole point of the exercise.
terraform plan
```

**`terraform plan` must report no changes.** That is the proof the migration
worked: Terraform is reading state from GitLab and still recognises all four
VMs. If it proposes creating VMs, stop — the state did not come across, and the
local backup above is the way back.

Afterwards the local `terraform.tfstate` is dead weight. Keep the backup
somewhere safe rather than deleting it outright.

## Running it later, from a workstation

The `TF_HTTP_*` exports above are needed every session. Put them in a
gitignored `infra/terraform/.envrc` (or your shell profile) and source it:

```sh
set -a; . ./.envrc; set +a
terraform plan
```

## Running it from CI

The pipeline sets the same variables, with two differences:

- `TF_HTTP_USERNAME=gitlab-ci-token` and `TF_HTTP_PASSWORD=$CI_JOB_TOKEN`.
  GitLab's state backend accepts the job token, so **no long-lived credential
  is needed for state**.
- Provider inputs arrive as `TF_VAR_*` environment variables from protected
  CI/CD variables, so there is no `terraform.tfvars` in the pipeline.

## Authorised keys live in a directory

Every `*.pub` file in `infra/ssh-keys/` is authorised on every VM. There is no
`ssh_public_key` variable any more.

Terraform reads the directory for cloud-init, so a new VM trusts all of them at
first boot. The `common` Ansible role reads the same directory, so machines
that already exist get them too. **One source, two readers**, and nothing to
keep in step.

Adding a person is dropping in a file. Removing one is deleting a file: the
next Ansible run removes the key from every machine, which a one-off
`ssh-copy-id` could never do.

The pipeline has its own key, `ci-ansible.pub`, separate from yours so either
can be revoked without disturbing the other and the `authorized_keys` file says
which logins came from CI.

**Public keys are public.** There is nothing secret in that directory; the
private halves never leave your machine and GitLab's protected variables.

## Gotchas

- **The `insecure` provider setting is on**, because the Proxmox host serves its
  own certificate. That is stated rather than hidden; a proper certificate on
  the host would let it be turned off.
- **`terraform apply` is destructive in a way `helm upgrade` is not.** A changed
  disk size or VM id can mean "destroy and recreate", taking the database volume
  with it. That is why the pipeline gates `apply` behind a manual button and
  always shows a plan first.
- **State contains sensitive values**, including the API token. GitLab encrypts
  it at rest and it is never written to the repository, but treat the state
  endpoint as a credential in its own right.
