#!/bin/bash
set -e

CONF="/etc/sysctl.d/99-vpn-host-tuning.conf"

cat <<'EOF' > "$CONF"
# Conntrack
net.netfilter.nf_conntrack_max = 4194304

# TCP cleanup
net.ipv4.tcp_orphan_retries = 3
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
EOF

sysctl --system

echo "✔ sysctl applied:"
sysctl net.netfilter.nf_conntrack_max
sysctl net.ipv4.tcp_orphan_retries
sysctl net.ipv4.tcp_fin_timeout
sysctl net.ipv4.tcp_tw_reuse
