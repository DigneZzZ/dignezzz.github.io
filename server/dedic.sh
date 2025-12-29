#!/bin/bash
set -euo pipefail

CONF="/etc/sysctl.d/99-vpn-host-tuning.conf"
TARGET_KEYS=(
  "net.netfilter.nf_conntrack_max"
  "net.ipv4.tcp_orphan_retries"
  "net.ipv4.tcp_fin_timeout"
  "net.ipv4.tcp_tw_reuse"
)

declare -A WANT=(
  ["net.netfilter.nf_conntrack_max"]="4194304"
  ["net.ipv4.tcp_orphan_retries"]="3"
  ["net.ipv4.tcp_fin_timeout"]="15"
  ["net.ipv4.tcp_tw_reuse"]="1"
)

AUTO_FIX="${AUTO_FIX:-0}"   # AUTO_FIX=1 to auto-comment conflicts

hr(){ echo "------------------------------------------------------------"; }
title(){ echo; echo "==> $1"; }
kv(){ printf "  %-40s %s\n" "$1" "$2"; }
ok(){ printf "[  OK  ] %s\n" "$1"; }
warn(){ printf "[ WARN ] %s\n" "$1"; }
fail(){ printf "[ FAIL ] %s\n" "$1"; }

is_num(){ [[ "${1:-}" =~ ^[0-9]+$ ]]; }

# Find occurrences of keys in sysctl configs with file+line and value.
find_key_hits() {
  local key="$1"
  # Search in typical sysctl locations (systemd/sysctl reads these)
  # Include /usr/lib, /run, /etc plus /etc/sysctl.conf
  local files=()
  while IFS= read -r -d '' f; do files+=("$f"); done < <(
    find /usr/lib/sysctl.d /run/sysctl.d /etc/sysctl.d -maxdepth 1 -type f -name '*.conf' -print0 2>/dev/null || true
  )
  files+=("/etc/sysctl.conf")

  local found=0
  for f in "${files[@]}"; do
    [[ -f "$f" ]] || continue
    # match: optional spaces, key, optional spaces, =, value; ignore comments
    while IFS= read -r line; do
      # Print as: file:lineno:key=value (raw)
      echo "$line"
      found=1
    done < <(
      awk -v k="$key" '
        BEGIN{IGNORECASE=0}
        /^[[:space:]]*#/ {next}
        match($0, "^[[:space:]]*" k "[[:space:]]*=") {
          # print file:line:content
          printf "%s:%d:%s\n", FILENAME, FNR, $0
        }
      ' "$f" 2>/dev/null || true
    )
  done

  return $found
}

extract_value_from_line() {
  # Input: "file:line:key = value"
  # Output: value (trim spaces), keep as string
  local s="$1"
  # take part after '='
  local rhs="${s#*=}"
  # trim spaces
  rhs="$(echo "$rhs" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  echo "$rhs"
}

comment_out_key_in_file() {
  local file="$1"
  local key="$2"
  # comment any non-comment line defining key
  # keep a backup
  cp -a "$file" "${file}.bak.$(date +%Y%m%d%H%M%S)"
  sed -i -E "s|^([[:space:]]*)(${key}[[:space:]]*=.*)$|\\1# DISABLED by vpn-host-tuning: \\2|g" "$file"
}

# -------------------------------------------------------------------

title "Current system state (before tuning)"
hr
kv "Kernel" "$(uname -r)"
kv "Conntrack in use" "$(cat /proc/sys/net/netfilter/nf_conntrack_count)"
kv "Conntrack limit" "$(cat /proc/sys/net/netfilter/nf_conntrack_max)"
hr

title "Detecting conflicting sysctl definitions"
hr
conflicts=0

for key in "${TARGET_KEYS[@]}"; do
  want="${WANT[$key]}"
  echo "Key: $key (want: $want)"
  hits="$(find_key_hits "$key" || true)"
  if [[ -z "${hits:-}" ]]; then
    ok "No definitions found in configs (runtime may still have a value)"
    echo
    continue
  fi

  # Print hits with value extraction
  last_file=""
  last_val=""
  while IFS= read -r h; do
    [[ -z "$h" ]] && continue
    f="${h%%:*}"
    rest="${h#*:}"
    lineno="${rest%%:*}"
    content="${h#*:*:}"
    val="$(extract_value_from_line "$h")"
    printf "  - %s:%s  %s  (value: %s)\n" "$f" "$lineno" "$(echo "$content" | sed -E 's/^[[:space:]]+//')" "$val"
    last_file="$f"
    last_val="$val"
  done <<< "$hits"

  # Decide conflict: if the LAST definition value != want, it will override our file (or already overrides)
  # Note: order of application: /usr/lib -> /run -> /etc/sysctl.d (lexical) -> /etc/sysctl.conf
  # We do a practical check: if ANY definition exists in /etc/sysctl.conf with != want, it's a known override.
  if echo "$hits" | grep -qE '^/etc/sysctl\.conf:'; then
    # Check any /etc/sysctl.conf value
    while IFS= read -r h; do
      val="$(extrac
