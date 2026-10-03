# Ansible

Configuration as Code for the four VMs that Terraform created. Terraform builds
the machines; Ansible decides what runs on them.

## Collections

The roles use modules from two collections. A workstation with the full
`ansible` package already has them; a pipeline running `ansible-core` does not,
and the failure reads as "couldn't resolve module" rather than "collection
missing".

```sh
ansible-galaxy collection install -r requirements.yml
```

## What each role does

| Role | Runs on | What it does |
| --- | --- | --- |
| `common` | all four | Base packages, hostname, clock sync, automatic security updates, SSH hardening |
| `k3s_server` | `staging`, `prod-server` | Installs a k3s control plane and saves a kubeconfig back to your machine |
| `k3s_agent` | `prod-agent` | Joins the production cluster as a worker |
| `gitlab_runner` | `ci-runner` | Docker, kubectl, helm, and the self-hosted GitLab Runner |
| `gitlab_agent` | `staging`, `prod-server` | GitLab Agent for Kubernetes, with permissions scoped to one namespace |

## Connecting

The VMs have private addresses and are not reachable from the internet. Every
connection goes through the Proxmox host first. That is handled by
`ansible_ssh_common_args` in `inventory.ini`, so no extra setup is needed beyond
having your SSH key on the Proxmox host.

## Running from WSL on Windows

Ansible has no Windows version, so it runs inside WSL. Two things need doing
once, or Ansible fails in ways that look like network problems.

**1. Accept the Proxmox host key.** Every connection hops through the Proxmox
host. If that host is not yet in `known_hosts`, SSH cannot verify it, and
because Ansible runs without a terminal it cannot ask you to confirm. It just
closes the connection and reports every VM as unreachable. Connect once by hand
first:

```sh
ssh <proxmox-ssh-user>@203.0.113.10 hostname
```

**2. Let Ansible read its own config file.** Ansible ignores `ansible.cfg` if
the folder looks world-writable, and Windows drives mounted in WSL always do.
Fix the mount permissions once:

```sh
sudo tee /etc/wsl.conf >/dev/null <<'EOF'
[automount]
options = "metadata,umask=022,fmask=011"
EOF
```

Then run `wsl --shutdown` in PowerShell and reopen Ubuntu. Until that is done,
pass the inventory by hand instead: `ansible all -i inventory.ini -m ping`.

## Running it

```sh
cd infra/ansible

ansible all -m ping          # check every VM answers
ansible-playbook site.yml    # base config + k3s
```

Everything is idempotent, so re-running is safe and is the normal way to apply a
change.

Run one part only:

```sh
ansible-playbook site.yml --tags common
ansible-playbook site.yml --tags k3s
```

The runner needs a GitLab registration token, so it is tagged `never` and only
runs when asked for by name:

```sh
export GITLAB_REGISTRATION_TOKEN=<a GitLab runner registration token>
ansible-playbook site.yml --tags runner \
  -e gitlab_registration_token=$GITLAB_REGISTRATION_TOKEN
```

The token is used to register the runner with GitLab. It is not stored in the
repository or written to disk by the role.

## Using the clusters

`k3s_server` writes `kubeconfig-staging.yaml` and `kubeconfig-prod-server.yaml`
into this directory. They hold cluster admin credentials and are gitignored.

```sh
export KUBECONFIG=$PWD/kubeconfig-prod-server.yaml
kubectl get nodes
```

This works from a machine that can reach `10.10.10.x`. From outside, tunnel
through the Proxmox host first:

```sh
ssh -L 6443:10.10.10.30:6443 <proxmox-ssh-user>@203.0.113.10
```

## Versions

Pinned in `group_vars/all.yml` and `roles/gitlab_runner/defaults/main.yml` so
rebuilds are reproducible:

- k3s `v1.36.3+k3s1`
- kubectl `v1.36.3`
- helm `v3.16.3`
