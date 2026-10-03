#!/usr/bin/env bash
# Create the private NAT bridge the VMs attach to.
#
# Why this is needed: vmbr0 is bridged to the physical NIC, but the hosting
# provider only leases an address to the server's registered MAC. VMs attached
# to vmbr0 would therefore get no address. Instead they live on a private
# network behind the host, which masquerades their outbound traffic and
# forwards selected inbound ports.
#
# Run once, as root, on the Proxmox host. Idempotent.

set -euo pipefail

BRIDGE="${BRIDGE:-vmbr1}"
SUBNET="${SUBNET:-10.10.10.0/24}"
GATEWAY="${GATEWAY:-10.10.10.1}"
UPLINK="${UPLINK:-vmbr0}"

if grep -q "iface ${BRIDGE}" /etc/network/interfaces; then
    echo "${BRIDGE} already configured; leaving it alone."
else
    echo "Adding ${BRIDGE} (${GATEWAY}) to /etc/network/interfaces"
    cp /etc/network/interfaces "/etc/network/interfaces.bak.$(date +%s)"

    cat >>/etc/network/interfaces <<EOF

auto ${BRIDGE}
iface ${BRIDGE} inet static
    address ${GATEWAY}/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    # Masquerade outbound traffic from the private network so VMs can reach
    # the internet (apt, GitHub, container registries).
    post-up   echo 1 > /proc/sys/net/ipv4/ip_forward
    post-up   iptables -t nat -A POSTROUTING -s ${SUBNET} -o ${UPLINK} -j MASQUERADE
    post-down iptables -t nat -D POSTROUTING -s ${SUBNET} -o ${UPLINK} -j MASQUERADE
EOF

    ifup "${BRIDGE}"
fi

echo
echo "Bridge status:"
ip -brief addr show "${BRIDGE}" || true
echo
echo "Next: forward the public ports to the production VM once it exists."
echo "  iptables -t nat -A PREROUTING -i ${UPLINK} -p tcp --dport 80  -j DNAT --to-destination 10.10.10.30:80"
echo "  iptables -t nat -A PREROUTING -i ${UPLINK} -p tcp --dport 443 -j DNAT --to-destination 10.10.10.30:443"
echo "Persist rules with iptables-persistent so they survive a reboot."
