#!/usr/bin/env bash
# Build the cloud-init VM template that Terraform clones from.
#
# This is the bootstrap step Terraform cannot do for itself: it clones a
# template, so something has to create one first. Packer would be the "more
# time" answer; a documented, version-controlled script is the honest one.
#
# Run once, as root, on the Proxmox host. Idempotent: it refuses to clobber an
# existing template unless FORCE=1.

set -euo pipefail

VMID="${VMID:-9000}"
NAME="${NAME:-ubuntu-2204-cloud}"
STORAGE="${STORAGE:-vmdata}"
BRIDGE="${BRIDGE:-vmbr1}"
IMAGE_URL="${IMAGE_URL:-https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img}"
IMAGE="/var/lib/vz/template/iso/$(basename "$IMAGE_URL")"
DISK_GB="${DISK_GB:-40}"

if qm status "$VMID" &>/dev/null; then
    if [[ "${FORCE:-0}" == "1" ]]; then
        echo "Destroying existing VM/template $VMID (FORCE=1)"
        qm destroy "$VMID" --purge
    else
        echo "VMID $VMID already exists. Set FORCE=1 to rebuild. Nothing to do."
        exit 0
    fi
fi

echo "==> Downloading cloud image (skipped if present)"
mkdir -p "$(dirname "$IMAGE")"
[[ -f "$IMAGE" ]] || wget -q --show-progress -O "$IMAGE" "$IMAGE_URL"

echo "==> Installing libguestfs-tools to inject the guest agent"
command -v virt-customize >/dev/null || (apt-get update -qq && apt-get install -y -qq libguestfs-tools)

# The QEMU guest agent lets Proxmox read the VM's real IPs and shut it down
# cleanly. Installing it into the image avoids needing it in cloud-init.
echo "==> Injecting qemu-guest-agent into the image"
virt-customize -a "$IMAGE" --install qemu-guest-agent >/dev/null

echo "==> Creating VM $VMID ($NAME)"
qm create "$VMID" \
    --name "$NAME" \
    --memory 2048 \
    --cores 2 \
    --cpu host \
    --net0 "virtio,bridge=${BRIDGE}" \
    --ostype l26 \
    --agent enabled=1 \
    --serial0 socket \
    --vga serial0

echo "==> Importing the disk into $STORAGE"
qm importdisk "$VMID" "$IMAGE" "$STORAGE"

echo "==> Attaching disk, cloud-init drive and boot order"
qm set "$VMID" --scsihw virtio-scsi-pci --scsi0 "${STORAGE}:vm-${VMID}-disk-0"
qm set "$VMID" --ide2 "${STORAGE}:cloudinit"
qm set "$VMID" --boot c --bootdisk scsi0

echo "==> Growing the disk to ${DISK_GB}G"
qm resize "$VMID" scsi0 "${DISK_GB}G"

echo "==> Converting to a template"
qm template "$VMID"

echo
echo "Template $VMID ($NAME) is ready. Terraform clones it via template_vm_id."
