#!/bin/bash
set -e

CONF="/etc/sysctl.d/99-vpn-host-tuning.conf"

hr() {
  echo "------------------------------------------------------------"
}

title() {
  echo
  echo "==> $1"
}

kv() {
  printf "  %-45s %s\n" "$1" "$2"
}

status_ok() {
  printf "[  OK  ] %s\n" "$1"
}

status_fail() {
  printf "[ FAIL ] %s\n" "$1"
}

# ------------------------------------------------------------------

title "Current system state (before tuning)"
hr
kv "Kernel" "$(uname -r)"
kv "Conntrack in use" "$(cat /proc/sys/net/netfilter/nf_conntrack_count)"
kv "Conntrack limit" "$(cat /proc/sys/net/netfilter/nf_conntrack_max)"
hr

# ------------------------------------------------------------------

title "Writing sysctl configuration"
hr

cat <<'EOF' > "$CONF"
# VPN / VM host tuning
net.netfilter.nf_conntrack_max = 4194304
net.ipv4.tcp_orphan_retries = 3
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
EOF

status_ok "Config written to $CONF"

# ------------------------------------------------------------------

title "Applying sysctl settings"
hr
sysctl --system >/dev/null
status_ok "sysctl reloaded"

# ------------------------------------------------------------------

title "Verifying applied values"
hr

check() {
  local key="$1"
  local expected="$2"
  local actual
  actual=$(sysctl -n "$key")

  if [[ "$actual" == "$expected" ]]; then
    status_ok "$key = $actual"
  else
    status_fail "$key = $actual (expected $expected)"
  fi
}

check net.netfilter.nf_conntrack_max 4194304
check net.ipv4.tcp_orphan_retries 3
check net.ipv4.tcp_fin_timeout 15
check net.ipv4.tcp_tw_reuse 1

# ------------------------------------------------------------------

title "Current conntrack usage (after tuning)"
hr
kv "Conntrack in use" "$(cat /proc/sys/net/netfilter/nf_conntrack_count)"
kv "Conntrack limit" "$(cat /proc/sys/net/netfilter/nf_conntrack_max)"
hr

echo
echo "Tuning completed."
