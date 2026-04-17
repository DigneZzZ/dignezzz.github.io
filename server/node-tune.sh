#!/bin/bash
# node-tune.sh — Network & System Tuning for VPN/Proxy Nodes
# Profiles: reality (Xray/VLESS/Trojan TCP), wireguard (UDP), mixed
# Target:   Ubuntu 20.04+ / Debian 11+ on Ryzen 7/9 dedicated
# Author:   DigneZzZ  (https://github.com/DigneZzZ/dignezzz.github.io)

set -euo pipefail

VERSION="1.0.0"
GITHUB_REPO="DigneZzZ/dignezzz.github.io"
GITHUB_RAW="https://raw.githubusercontent.com/${GITHUB_REPO}/main/server"
SCRIPT_NAME="node-tune"
INSTALL_PATH="/usr/local/bin/${SCRIPT_NAME}"

# ─── Config paths ─────────────────────────────────────────────────────
CONF_SYSCTL="/etc/sysctl.d/99-node-tune.conf"
CONF_LIMITS="/etc/security/limits.d/99-node-tune.conf"
CONF_SYSTEMD_SYS="/etc/systemd/system.conf.d/99-node-tune.conf"
CONF_SYSTEMD_USER="/etc/systemd/user.conf.d/99-node-tune.conf"
CONF_MODPROBE="/etc/modprobe.d/99-node-tune.conf"
CONF_UDEV="/etc/udev/rules.d/99-node-tune.rules"
STATE_DIR="/etc/node-tune"
BACKUP_DIR="/var/backups/node-tune"

# ─── Env flags ────────────────────────────────────────────────────────
PROFILE="${PROFILE:-}"                 # reality | wireguard | mixed
AUTO_FIX="${AUTO_FIX:-0}"              # 1 = comment conflicting sysctls
DISABLE_THP_OVERRIDE="${DISABLE_THP_OVERRIDE:-}"   # never | madvise | always
NONINTERACTIVE="${NONINTERACTIVE:-0}"  # 1 = no prompts (CI)

# ─── Colors ───────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
  BOLD='\033[1m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; MAGENTA=''; BOLD=''; NC=''
fi

hr(){ printf '%s\n' "────────────────────────────────────────────────────────────"; }
title(){ printf '\n%b▶ %s%b\n' "$BLUE" "$1" "$NC"; }
kv(){ printf '  %-42s %s\n' "$1" "$2"; }
ok(){ printf '%b✓%b %s\n' "$GREEN" "$NC" "$1"; }
warn(){ printf '%b⚠%b %s\n' "$YELLOW" "$NC" "$1"; }
fail(){ printf '%b✗%b %s\n' "$RED" "$NC" "$1" >&2; }
info(){ printf '%bℹ%b %s\n' "$BLUE" "$NC" "$1"; }

# ─── Detected environment (populated by detect_environment) ───────────
OS_ID=""; OS_VER=""; KERNEL=""; KERNEL_MAJOR=0; KERNEL_MINOR=0
IS_XANMOD=0; IS_AMD=0
BEST_CC="cubic"; BEST_QDISC="fq_codel"
HAS_IPV6=0; TOTAL_RAM_KB=0; TOTAL_RAM_MB=0; CPU_THREADS=1
HAS_ETHTOOL=0; HAS_TC=0; HAS_CPUPOWER=0

require_root(){
  if [[ $EUID -ne 0 ]]; then
    fail "Требуются root-привилегии. Запустите: sudo $0 $*"
    exit 1
  fi
}

confirm(){
  local prompt="${1:-Continue?}"
  [[ "$NONINTERACTIVE" == "1" ]] && return 0
  read -rp "$prompt [y/N] " reply
  [[ "$reply" =~ ^[YyДд]$ ]]
}

# ═════════════════════════════════════════════════════════════════════
# ENVIRONMENT DETECTION
# ═════════════════════════════════════════════════════════════════════

detect_environment(){
  # OS
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VER="${VERSION_ID:-}"
  fi
  case "$OS_ID" in
    ubuntu|debian) : ;;
    *) warn "ОС '$OS_ID' не в списке поддерживаемых (ubuntu/debian). Продолжаем на свой страх и риск." ;;
  esac

  # Kernel
  KERNEL="$(uname -r)"
  local kv_clean="${KERNEL%%-*}"
  KERNEL_MAJOR="${kv_clean%%.*}"
  local rest="${kv_clean#*.}"
  KERNEL_MINOR="${rest%%.*}"
  [[ "$KERNEL_MAJOR" =~ ^[0-9]+$ ]] || KERNEL_MAJOR=0
  [[ "$KERNEL_MINOR" =~ ^[0-9]+$ ]] || KERNEL_MINOR=0

  # XanMod
  if grep -qi xanmod /proc/version 2>/dev/null || [[ "$KERNEL" == *xanmod* ]]; then
    IS_XANMOD=1
  fi

  # CPU vendor
  if grep -q "AuthenticAMD" /proc/cpuinfo 2>/dev/null; then
    IS_AMD=1
  fi

  # Congestion control — приоритет bbr3 > bbr2 > bbr > cubic
  local avail
  avail="$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || echo cubic)"
  if [[ " $avail " == *" bbr3 "* ]]; then BEST_CC="bbr3"
  elif [[ " $avail " == *" bbr2 "* ]]; then BEST_CC="bbr2"
  elif [[ " $avail " == *" bbr "*  ]]; then BEST_CC="bbr"
  else
    # Попытка загрузить модуль bbr
    if modprobe tcp_bbr 2>/dev/null; then
      avail="$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || echo cubic)"
      [[ " $avail " == *" bbr "* ]] && BEST_CC="bbr"
    fi
  fi

  # Qdisc — пробуем cake, иначе fq
  BEST_QDISC="fq"
  if command -v tc >/dev/null 2>&1; then
    HAS_TC=1
    if modprobe sch_cake 2>/dev/null && tc qdisc add dev lo root cake 2>/dev/null; then
      tc qdisc del dev lo root 2>/dev/null || true
      BEST_QDISC="cake"
    fi
  fi

  # IPv6
  [[ -f /proc/net/if_inet6 ]] && HAS_IPV6=1

  # Hardware
  TOTAL_RAM_KB="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
  TOTAL_RAM_MB=$((TOTAL_RAM_KB / 1024))
  CPU_THREADS="$(nproc)"

  command -v ethtool  >/dev/null 2>&1 && HAS_ETHTOOL=1
  command -v cpupower >/dev/null 2>&1 && HAS_CPUPOWER=1
}

# ═════════════════════════════════════════════════════════════════════
# PROFILE SELECTION
# ═════════════════════════════════════════════════════════════════════

select_profile_interactive(){
  echo
  printf '%bВыберите профиль оптимизации:%b\n\n' "$BOLD" "$NC"
  echo "  1) reality     — Xray/Reality/VLESS/Trojan (TCP-heavy, короткие TLS)"
  echo "  2) wireguard   — WireGuard/AmneziaWG (UDP forwarding)"
  echo "  3) mixed       — 3x-ui / Marzban (Xray + WG + Shadowsocks)"
  echo
  local choice
  read -rp "Profile [1-3]: " choice
  case "$choice" in
    1) PROFILE="reality" ;;
    2) PROFILE="wireguard" ;;
    3) PROFILE="mixed" ;;
    *) fail "Invalid choice"; exit 1 ;;
  esac
}

ensure_profile(){
  if [[ -z "$PROFILE" ]]; then
    if [[ -f "$STATE_DIR/profile" ]]; then
      PROFILE="$(cat "$STATE_DIR/profile")"
      info "Активный профиль из $STATE_DIR/profile: $PROFILE"
    elif [[ "$NONINTERACTIVE" == "1" ]]; then
      fail "PROFILE не указан (NONINTERACTIVE=1). Установите PROFILE=reality|wireguard|mixed"
      exit 1
    else
      select_profile_interactive
    fi
  fi
  case "$PROFILE" in
    reality|wireguard|mixed) : ;;
    *) fail "Неизвестный профиль: $PROFILE"; exit 1 ;;
  esac
}

# ═════════════════════════════════════════════════════════════════════
# CALCULATIONS (scale by RAM)
# ═════════════════════════════════════════════════════════════════════

# clamp val min max
clamp(){ local v=$1 mn=$2 mx=$3; (( v < mn )) && v=$mn; (( v > mx )) && v=$mx; echo "$v"; }

compute_values(){
  # conntrack_max: RAM_MB * 256, clamp(131072, 1048576)
  local ct=$(( TOTAL_RAM_MB * 256 ))
  CT_MAX=$(clamp "$ct" 131072 1048576)
  # hashsize = ct_max / 4
  CT_HASH=$(( CT_MAX / 4 ))

  # min_free_kbytes: RAM_KB / 100, clamp(65536, 1048576)
  local mfk=$(( TOTAL_RAM_KB / 100 ))
  MIN_FREE=$(clamp "$mfk" 65536 1048576)

  # tcp_mem pages (4 KB): low=RAM_KB/64, pressure=RAM_KB/32, max=RAM_KB/16
  TCP_MEM_LOW=$(( TOTAL_RAM_KB / 64 ))
  TCP_MEM_PRESSURE=$(( TOTAL_RAM_KB / 32 ))
  TCP_MEM_MAX=$(( TOTAL_RAM_KB / 16 ))

  # udp_mem базовый = tcp_mem, для wireguard x4
  if [[ "$PROFILE" == "wireguard" || "$PROFILE" == "mixed" ]]; then
    UDP_MEM_LOW=$(( TCP_MEM_LOW * 4 ))
    UDP_MEM_PRESSURE=$(( TCP_MEM_PRESSURE * 4 ))
    UDP_MEM_MAX=$(( TCP_MEM_MAX * 4 ))
  else
    UDP_MEM_LOW="$TCP_MEM_LOW"
    UDP_MEM_PRESSURE="$TCP_MEM_PRESSURE"
    UDP_MEM_MAX="$TCP_MEM_MAX"
  fi

  # netdev_max_backlog — для wireguard/mixed бёрсты UDP
  case "$PROFILE" in
    wireguard|mixed) NETDEV_BACKLOG=250000 ;;
    *)               NETDEV_BACKLOG=65536 ;;
  esac
}

# ═════════════════════════════════════════════════════════════════════
# BACKUP / ROLLBACK
# ═════════════════════════════════════════════════════════════════════

# Все ключи, которые трогаем — для снапшота
BACKUP_KEYS=(
  net.ipv4.tcp_congestion_control
  net.core.default_qdisc
  net.ipv4.tcp_fastopen
  net.ipv4.tcp_mtu_probing
  net.ipv4.tcp_ecn
  net.ipv4.tcp_slow_start_after_idle
  net.ipv4.tcp_no_metrics_save
  net.ipv4.tcp_moderate_rcvbuf
  net.ipv4.tcp_notsent_lowat
  net.ipv4.tcp_window_scaling
  net.ipv4.tcp_sack
  net.ipv4.tcp_dsack
  net.ipv4.tcp_timestamps
  net.ipv4.tcp_syncookies
  net.ipv4.tcp_syn_retries
  net.ipv4.tcp_synack_retries
  net.ipv4.tcp_max_syn_backlog
  net.core.somaxconn
  net.core.netdev_max_backlog
  net.core.netdev_budget
  net.core.netdev_budget_usecs
  net.core.rmem_max
  net.core.wmem_max
  net.core.rmem_default
  net.core.wmem_default
  net.ipv4.tcp_rmem
  net.ipv4.tcp_wmem
  net.ipv4.tcp_mem
  net.ipv4.udp_mem
  net.ipv4.udp_rmem_min
  net.ipv4.udp_wmem_min
  net.ipv4.ip_local_port_range
  net.ipv4.tcp_fin_timeout
  net.ipv4.tcp_tw_reuse
  net.ipv4.tcp_max_tw_buckets
  net.ipv4.tcp_keepalive_time
  net.ipv4.tcp_keepalive_intvl
  net.ipv4.tcp_keepalive_probes
  net.ipv4.tcp_max_orphans
  net.ipv4.tcp_orphan_retries
  net.ipv4.ip_forward
  net.ipv6.conf.all.forwarding
  net.ipv4.conf.all.rp_filter
  net.ipv4.conf.default.rp_filter
  net.netfilter.nf_conntrack_max
  net.netfilter.nf_conntrack_tcp_timeout_established
  net.netfilter.nf_conntrack_tcp_timeout_time_wait
  net.netfilter.nf_conntrack_tcp_timeout_close_wait
  net.netfilter.nf_conntrack_tcp_timeout_fin_wait
  net.ipv4.neigh.default.gc_thresh1
  net.ipv4.neigh.default.gc_thresh2
  net.ipv4.neigh.default.gc_thresh3
  vm.swappiness
  vm.dirty_ratio
  vm.dirty_background_ratio
  vm.vfs_cache_pressure
  vm.min_free_kbytes
  vm.overcommit_memory
  fs.file-max
  fs.nr_open
  kernel.pid_max
  kernel.threads-max
  net.core.rps_sock_flow_entries
)

backup_state(){
  title "Создание бэкапа текущего состояния"
  hr
  mkdir -p "$BACKUP_DIR"
  local ts; ts="$(date +%Y%m%d_%H%M%S)"
  local snap="$BACKUP_DIR/snapshot_${ts}.conf"
  local rb="$BACKUP_DIR/rollback_${ts}.sh"

  {
    echo "# node-tune snapshot — $(date)"
    echo "# host: $(hostname)  kernel: $KERNEL  profile(old): ${OLD_PROFILE:-none}"
  } > "$snap"

  for k in "${BACKUP_KEYS[@]}"; do
    local v
    v="$(sysctl -n "$k" 2>/dev/null || true)"
    [[ -n "$v" ]] && printf '%s = %s\n' "$k" "$v" >> "$snap"
  done

  # Rollback script
  cat > "$rb" <<EOF_RB_HEAD
#!/bin/bash
# Auto-generated rollback for node-tune (snapshot $ts)
set -u
if [[ \$EUID -ne 0 ]]; then echo "Run as root"; exit 1; fi
echo "Restoring sysctl values from $snap ..."
EOF_RB_HEAD

  for k in "${BACKUP_KEYS[@]}"; do
    local v
    v="$(sysctl -n "$k" 2>/dev/null || true)"
    if [[ -n "$v" ]]; then
      # экранируем одинарные кавычки
      local vs="${v//\'/\'\\\'\'}"
      printf "sysctl -w '%s=%s' >/dev/null 2>&1 || true\n" "$k" "$vs" >> "$rb"
    fi
  done

  cat >> "$rb" <<EOF_RB_TAIL

echo "Removing node-tune config files..."
rm -f "$CONF_SYSCTL" "$CONF_LIMITS" "$CONF_SYSTEMD_SYS" "$CONF_SYSTEMD_USER" "$CONF_MODPROBE" "$CONF_UDEV"
sysctl --system >/dev/null 2>&1 || true
udevadm control --reload >/dev/null 2>&1 || true
udevadm trigger --subsystem-match=net --subsystem-match=block >/dev/null 2>&1 || true
echo "Rollback done. Reboot recommended for full restoration."
EOF_RB_TAIL
  chmod +x "$rb"

  # Backup existing configs
  for f in "$CONF_SYSCTL" "$CONF_LIMITS" "$CONF_SYSTEMD_SYS" "$CONF_SYSTEMD_USER" "$CONF_MODPROBE" "$CONF_UDEV"; do
    [[ -f "$f" ]] && cp -a "$f" "$BACKUP_DIR/$(basename "$f").${ts}.bak"
  done

  ok "Snapshot: $snap"
  ok "Rollback: $rb"
  hr
}

do_rollback(){
  require_root
  local latest
  latest="$(ls -t "$BACKUP_DIR"/rollback_*.sh 2>/dev/null | head -1 || true)"
  if [[ -z "$latest" ]]; then
    fail "Бэкапы не найдены в $BACKUP_DIR"
    exit 1
  fi
  title "Откат к: $(basename "$latest")"
  confirm "Применить rollback?" || { info "Отменено"; exit 0; }
  bash "$latest"
  rm -f "$STATE_DIR/profile"
  ok "Rollback выполнен. Рекомендуется reboot для полной очистки."
}

# ═════════════════════════════════════════════════════════════════════
# CONFLICT DETECTION
# ═════════════════════════════════════════════════════════════════════

conflict_files(){
  local files=()
  while IFS= read -r -d '' f; do files+=("$f"); done < <(
    find /usr/lib/sysctl.d /run/sysctl.d /etc/sysctl.d -maxdepth 1 -type f -name '*.conf' \
      ! -name "99-node-tune.conf" -print0 2>/dev/null || true
  )
  [[ -f /etc/sysctl.conf ]] && files+=("/etc/sysctl.conf")
  printf '%s\n' "${files[@]}"
}

detect_conflicts(){
  title "Проверка конфликтующих sysctl-настроек"
  hr
  local conflicts=0
  local -a keys=(
    net.ipv4.tcp_congestion_control
    net.core.default_qdisc
    net.ipv4.ip_forward
    vm.swappiness
  )
  for k in "${keys[@]}"; do
    while IFS= read -r f; do
      [[ -z "$f" || ! -f "$f" ]] && continue
      if grep -Eq "^[[:space:]]*${k//./\\.}[[:space:]]*=" "$f" 2>/dev/null; then
        warn "Конфликт: $k определён в $f"
        conflicts=$((conflicts+1))
        if [[ "$AUTO_FIX" == "1" ]]; then
          cp -a "$f" "${f}.node-tune.bak.$(date +%s)"
          sed -i -E "s|^([[:space:]]*${k//./\\.}[[:space:]]*=.*)$|# DISABLED by node-tune: \1|" "$f"
          ok "Закомментировано в $f"
        fi
      fi
    done < <(conflict_files)
  done
  if (( conflicts == 0 )); then
    ok "Конфликтов не обнаружено"
  elif [[ "$AUTO_FIX" != "1" ]]; then
    info "Подсказка: запустите с AUTO_FIX=1 для авто-исправления"
  fi
  hr
}

# ═════════════════════════════════════════════════════════════════════
# WRITE CONFIGS
# ═════════════════════════════════════════════════════════════════════

write_sysctl(){
  title "Запись $CONF_SYSCTL (profile: $PROFILE)"
  hr

  # Профильные переменные
  local fin_timeout=15 tw_buckets=1048576 ct_est=7200 ct_tw=30 ct_cw=30 ct_fw=30
  local rp_filter=1
  case "$PROFILE" in
    reality)
      fin_timeout=10
      tw_buckets=2000000
      ct_tw=15
      ;;
    wireguard)
      rp_filter=2
      ct_est=3600
      ct_tw=15
      ;;
    mixed)
      fin_timeout=12
      tw_buckets=2000000
      ct_tw=15
      rp_filter=1
      ;;
  esac

  # forward — всегда для VPN/proxy-ноды
  local v6fwd=0
  [[ $HAS_IPV6 -eq 1 ]] && v6fwd=1

  cat > "$CONF_SYSCTL" <<EOF
# ──────────────────────────────────────────────────────────────────
# node-tune.sh v${VERSION}  —  profile: ${PROFILE}
# Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
# Kernel:    ${KERNEL}$([[ $IS_XANMOD -eq 1 ]] && echo " (XanMod)")
# RAM:       ${TOTAL_RAM_MB} MB   CPU threads: ${CPU_THREADS}
# ──────────────────────────────────────────────────────────────────

# ── Congestion control & qdisc ───────────────────────────────────
net.ipv4.tcp_congestion_control = ${BEST_CC}
net.core.default_qdisc = ${BEST_QDISC}

# ── TCP core ─────────────────────────────────────────────────────
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_timestamps = 1

# ── SYN protection / backlog ─────────────────────────────────────
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 3
net.ipv4.tcp_max_syn_backlog = 32768
net.core.somaxconn = 65535
net.core.netdev_max_backlog = ${NETDEV_BACKLOG}
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 8000

# ── Socket buffers (max 64 MB, не 128 — экономия памяти) ─────────
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_rmem = 4096 262144 67108864
net.ipv4.tcp_wmem = 4096 262144 67108864
net.ipv4.tcp_mem = ${TCP_MEM_LOW} ${TCP_MEM_PRESSURE} ${TCP_MEM_MAX}

# ── UDP (критично для WireGuard) ─────────────────────────────────
net.ipv4.udp_mem = ${UDP_MEM_LOW} ${UDP_MEM_PRESSURE} ${UDP_MEM_MAX}
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

# ── Connection management ────────────────────────────────────────
net.ipv4.ip_local_port_range = 10000 65535
net.ipv4.tcp_fin_timeout = ${fin_timeout}
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_tw_buckets = ${tw_buckets}
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 6
net.ipv4.tcp_max_orphans = 262144
net.ipv4.tcp_orphan_retries = 2

# ── IP forwarding (VPN/proxy node) ───────────────────────────────
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = ${v6fwd}

# ── Reverse Path Filter ──────────────────────────────────────────
# 1 = strict (рекомендуется для reality/mixed)
# 2 = loose  (нужен для WireGuard с policy routing)
net.ipv4.conf.all.rp_filter = ${rp_filter}
net.ipv4.conf.default.rp_filter = ${rp_filter}

# ── Conntrack (размер масштабируется от RAM) ─────────────────────
net.netfilter.nf_conntrack_max = ${CT_MAX}
net.netfilter.nf_conntrack_tcp_timeout_established = ${ct_est}
net.netfilter.nf_conntrack_tcp_timeout_time_wait = ${ct_tw}
net.netfilter.nf_conntrack_tcp_timeout_close_wait = ${ct_cw}
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = ${ct_fw}

# ── ARP/ND cache ─────────────────────────────────────────────────
net.ipv4.neigh.default.gc_thresh1 = 4096
net.ipv4.neigh.default.gc_thresh2 = 16384
net.ipv4.neigh.default.gc_thresh3 = 32768

# ── Memory ───────────────────────────────────────────────────────
vm.swappiness = 10
vm.dirty_ratio = 10
vm.dirty_background_ratio = 3
vm.vfs_cache_pressure = 50
vm.min_free_kbytes = ${MIN_FREE}
vm.overcommit_memory = 1

# ── Kernel limits ────────────────────────────────────────────────
fs.file-max = 4194304
fs.nr_open = 4194304
kernel.pid_max = 4194304
kernel.threads-max = 1048576

# ── RFS (receive flow steering) ──────────────────────────────────
net.core.rps_sock_flow_entries = 32768
EOF
  ok "Написан: $CONF_SYSCTL"
  hr
}

write_limits(){
  title "Запись limits"
  hr
  cat > "$CONF_LIMITS" <<'EOF'
# node-tune PAM limits
*     soft  nofile   1048576
*     hard  nofile   1048576
*     soft  nproc    1048576
*     hard  nproc    1048576
*     soft  memlock  unlimited
*     hard  memlock  unlimited
root  soft  nofile   1048576
root  hard  nofile   1048576
root  soft  nproc    1048576
root  hard  nproc    1048576
root  soft  memlock  unlimited
root  hard  memlock  unlimited
EOF
  ok "Написан: $CONF_LIMITS"

  mkdir -p "$(dirname "$CONF_SYSTEMD_SYS")" "$(dirname "$CONF_SYSTEMD_USER")"
  cat > "$CONF_SYSTEMD_SYS" <<'EOF'
# node-tune systemd system defaults (влияет на systemd-сервисы вроде xray, wg-quick)
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=1048576
DefaultLimitMEMLOCK=infinity
DefaultTasksMax=infinity
EOF
  ok "Написан: $CONF_SYSTEMD_SYS"

  cat > "$CONF_SYSTEMD_USER" <<'EOF'
# node-tune systemd user defaults
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=1048576
DefaultLimitMEMLOCK=infinity
DefaultTasksMax=infinity
EOF
  ok "Написан: $CONF_SYSTEMD_USER"

  systemctl daemon-reexec 2>/dev/null || true
  info "systemd daemon-reexec выполнен (новые лимиты для сервисов — после restart каждого сервиса)"
  hr
}

write_modprobe(){
  title "Запись modprobe config (nf_conntrack hashsize)"
  hr
  cat > "$CONF_MODPROBE" <<EOF
# node-tune — hashsize=${CT_HASH} (max=${CT_MAX})
options nf_conntrack hashsize=${CT_HASH}
EOF
  ok "Написан: $CONF_MODPROBE"

  # Try to apply hashsize at runtime
  if [[ -f /sys/module/nf_conntrack/parameters/hashsize ]]; then
    echo "$CT_HASH" > /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null \
      && ok "hashsize применён онлайн: $CT_HASH" \
      || warn "Онлайн-применение hashsize не удалось (применится при перезагрузке модуля)"
  fi
  hr
}

write_udev(){
  title "Запись udev rules (I/O scheduler + txqueuelen)"
  hr
  cat > "$CONF_UDEV" <<'EOF'
# node-tune — persistent I/O schedulers + NIC txqueuelen

# NVMe → none (NVMe имеет свою mq)
ACTION=="add|change", KERNEL=="nvme[0-9]*n[0-9]*", ATTR{queue/scheduler}="none"

# SSD (rotational=0, не NVMe) → mq-deadline
ACTION=="add|change", KERNEL=="sd[a-z]*|vd[a-z]*", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"

# HDD (rotational=1) → bfq
ACTION=="add|change", KERNEL=="sd[a-z]*|vd[a-z]*", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"

# NIC txqueuelen 10000 для ethernet
ACTION=="add", SUBSYSTEM=="net", KERNEL=="e*|en*", ATTR{tx_queue_len}="10000"
EOF
  ok "Написан: $CONF_UDEV"
  udevadm control --reload 2>/dev/null || true
  udevadm trigger --subsystem-match=net --subsystem-match=block 2>/dev/null || true
  hr
}

# ═════════════════════════════════════════════════════════════════════
# APPLY RUNTIME TUNING
# ═════════════════════════════════════════════════════════════════════

apply_sysctl(){
  title "Применение sysctl"
  hr
  if sysctl --system >/dev/null 2>&1; then
    ok "sysctl --system: ok"
  else
    warn "sysctl --system вернул ошибку, смотрите вывод ниже:"
    sysctl --system || true
  fi
  hr
}

configure_thp(){
  title "Transparent Huge Pages"
  hr
  local mode
  if [[ -n "$DISABLE_THP_OVERRIDE" ]]; then
    mode="$DISABLE_THP_OVERRIDE"
  else
    case "$PROFILE" in
      reality)  mode="madvise" ;;   # Xray TLS выигрывает от THP
      wireguard|mixed) mode="never" ;; # low-latency критичнее
    esac
  fi
  if [[ -f /sys/kernel/mm/transparent_hugepage/enabled ]]; then
    echo "$mode" > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null && ok "THP enabled = $mode" || warn "Не удалось установить THP"
    echo "$mode" > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true
  fi

  # Persist via systemd service
  cat > /etc/systemd/system/node-tune-thp.service <<EOF
[Unit]
Description=node-tune THP mode ($mode)
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=basic.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo $mode > /sys/kernel/mm/transparent_hugepage/enabled; echo $mode > /sys/kernel/mm/transparent_hugepage/defrag'

[Install]
WantedBy=basic.target
EOF
  systemctl daemon-reload 2>/dev/null || true
  systemctl enable node-tune-thp.service >/dev/null 2>&1 && ok "node-tune-thp.service enabled"
  hr
}

disable_ksm(){
  title "Kernel Samepage Merging (KSM)"
  hr
  if [[ -f /sys/kernel/mm/ksm/run ]]; then
    local cur; cur="$(cat /sys/kernel/mm/ksm/run 2>/dev/null || echo 0)"
    if [[ "$cur" != "0" ]]; then
      echo 0 > /sys/kernel/mm/ksm/run 2>/dev/null || true
      ok "KSM отключён (экономия CPU на proxy-ноде)"
    else
      info "KSM уже отключён"
    fi
  else
    info "KSM недоступен"
  fi
  hr
}

configure_nic(){
  title "NIC tuning (offloads, RPS/RFS, IRQ affinity)"
  hr
  local ifaces
  ifaces="$(ip -br link show 2>/dev/null | awk '$1 !~ /^(lo|docker|veth|br-|virbr|wg|tun|tap)/ && $2 == "UP" {print $1}')"
  if [[ -z "$ifaces" ]]; then
    warn "Активных физических интерфейсов не найдено"
    hr
    return
  fi

  local rps_mask
  # маска всех CPU кроме CPU0 (hex)
  if (( CPU_THREADS > 1 )); then
    rps_mask=$(printf '%x' $(( (1 << CPU_THREADS) - 2 )))
  else
    rps_mask="1"
  fi

  for iface in $ifaces; do
    kv "Interface" "$iface"

    # Offloads
    if [[ $HAS_ETHTOOL -eq 1 ]]; then
      ethtool -K "$iface" gro on gso on tso on 2>/dev/null || true
      # UDP GRO list (kernel 6.2+, критично для WG)
      ethtool -K "$iface" rx-gro-list on 2>/dev/null || true
      # Ring buffers на максимум
      local rx_max tx_max
      rx_max="$(ethtool -g "$iface" 2>/dev/null | awk '/^RX:/ && !seen {print $2; seen=1}')"
      tx_max="$(ethtool -g "$iface" 2>/dev/null | awk '/^TX:/ && !seen {print $2; seen=1}')"
      if [[ -n "$rx_max" && "$rx_max" =~ ^[0-9]+$ ]]; then
        ethtool -G "$iface" rx "$rx_max" tx "${tx_max:-$rx_max}" 2>/dev/null \
          && ok "$iface: ring buffers → rx=$rx_max tx=${tx_max:-$rx_max}"
      fi
    fi

    # txqueuelen 10000
    ip link set "$iface" txqueuelen 10000 2>/dev/null && ok "$iface: txqueuelen=10000"

    # RPS — распределить по всем CPU кроме CPU0
    local rps_set=0
    for q in /sys/class/net/"$iface"/queues/rx-*/rps_cpus; do
      [[ -w "$q" ]] || continue
      echo "$rps_mask" > "$q" 2>/dev/null && rps_set=$((rps_set+1))
    done
    [[ $rps_set -gt 0 ]] && ok "$iface: RPS на $rps_set очередях (mask=0x$rps_mask)"

    # RFS flow count per queue
    for q in /sys/class/net/"$iface"/queues/rx-*/rps_flow_cnt; do
      [[ -w "$q" ]] && echo 4096 > "$q" 2>/dev/null || true
    done

    # IRQ affinity: раскидать IRQ интерфейса по CPU (начиная с 1, CPU0 оставляем)
    local irqs cpu_idx=1
    irqs="$(grep -E "\\b${iface}\\b|\\b${iface}-" /proc/interrupts | awk -F: '{gsub(/ /,""); print $1}')"
    if [[ -n "$irqs" ]]; then
      local ir_set=0
      for irq in $irqs; do
        [[ -w "/proc/irq/$irq/smp_affinity_list" ]] || continue
        echo "$cpu_idx" > "/proc/irq/$irq/smp_affinity_list" 2>/dev/null && ir_set=$((ir_set+1))
        cpu_idx=$(( cpu_idx + 1 ))
        (( cpu_idx >= CPU_THREADS )) && cpu_idx=1
      done
      [[ $ir_set -gt 0 ]] && ok "$iface: IRQ affinity распределён ($ir_set IRQ, CPU0 исключён)"
    fi
  done
  hr
}

configure_cpu_governor(){
  title "CPU governor"
  hr
  if [[ ! -d /sys/devices/system/cpu/cpu0/cpufreq ]]; then
    info "cpufreq недоступен (нет управления частотой)"
    hr; return
  fi

  local set=0
  for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [[ -w "$g" ]] || continue
    echo performance > "$g" 2>/dev/null && set=$((set+1))
  done
  if (( set > 0 )); then
    ok "governor=performance на $set CPU"
  else
    warn "Не удалось установить governor (возможно, нужны драйверы/cpupower)"
  fi

  # Persist via systemd
  cat > /etc/systemd/system/node-tune-governor.service <<'EOF'
[Unit]
Description=node-tune CPU governor=performance
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > "$g" 2>/dev/null || true; done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload 2>/dev/null || true
  systemctl enable node-tune-governor.service >/dev/null 2>&1 && ok "node-tune-governor.service enabled"

  # AMD pstate info
  if [[ $IS_AMD -eq 1 ]]; then
    local driver
    driver="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null || echo unknown)"
    kv "CPU driver" "$driver"
    if [[ "$driver" != "amd-pstate-epp" && "$driver" != "amd_pstate" && "$driver" != "amd-pstate" ]]; then
      info "Для Ryzen рекомендуется amd_pstate=active в GRUB (kernel ≥ 6.1):"
      echo "    GRUB_CMDLINE_LINUX=\"... amd_pstate=active\""
      info "После правки: update-grub && reboot"
    fi
  fi
  hr
}

configure_io_runtime(){
  title "I/O schedulers (runtime)"
  hr
  for disk in /sys/block/*; do
    local name; name="$(basename "$disk")"
    case "$name" in
      loop*|ram*|dm-*|sr*) continue ;;
    esac
    local sched_file="$disk/queue/scheduler"
    [[ -f "$sched_file" ]] || continue
    local target
    if [[ "$name" == nvme* ]]; then
      target="none"
    elif [[ "$(cat "$disk/queue/rotational" 2>/dev/null)" == "0" ]]; then
      target="mq-deadline"
    else
      target="bfq"
    fi
    echo "$target" > "$sched_file" 2>/dev/null && kv "$name" "$target" || true
  done
  hr
}

# ═════════════════════════════════════════════════════════════════════
# VERIFY & STATUS
# ═════════════════════════════════════════════════════════════════════

verify(){
  title "Проверка применённых значений"
  hr
  local checks=(
    "net.ipv4.tcp_congestion_control|$BEST_CC"
    "net.core.default_qdisc|$BEST_QDISC"
    "net.ipv4.ip_forward|1"
    "net.ipv4.tcp_fastopen|3"
    "vm.swappiness|10"
  )
  for pair in "${checks[@]}"; do
    local k="${pair%%|*}" want="${pair##*|}"
    local got; got="$(sysctl -n "$k" 2>/dev/null || echo N/A)"
    if [[ "$got" == "$want" ]]; then
      ok "$k = $got"
    else
      warn "$k = $got (ожидалось: $want)"
    fi
  done
  hr
}

show_status(){
  printf '\n%b╔═══ node-tune status ══════════════════════════════════╗%b\n' "$CYAN" "$NC"
  kv "Version" "$VERSION"
  kv "Installed" "$([[ -f "$STATE_DIR/install_date" ]] && cat "$STATE_DIR/install_date" || echo 'not installed')"
  kv "Active profile" "$([[ -f "$STATE_DIR/profile" ]] && cat "$STATE_DIR/profile" || echo 'none')"
  echo
  kv "Host" "$(hostname)"
  kv "Kernel" "$KERNEL$([[ $IS_XANMOD -eq 1 ]] && echo ' (XanMod)')"
  kv "OS" "${OS_ID} ${OS_VER}"
  kv "CPU threads" "$CPU_THREADS"
  kv "RAM" "$(free -h | awk '/^Mem:/ {print $2}')"
  echo
  kv "Tuning config" "$([[ -f "$CONF_SYSCTL" ]] && echo "$CONF_SYSCTL (applied)" || echo 'not applied')"
  kv "Congestion control" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo N/A)"
  kv "Qdisc default" "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo N/A)"
  kv "Conntrack" "$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo N/A) / $(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo N/A)"
  kv "File descriptors" "$(awk '{print $1}' /proc/sys/fs/file-nr 2>/dev/null) / $(sysctl -n fs.file-max 2>/dev/null)"
  kv "THP" "$(awk -F'[][]' '{print $2}' /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo N/A)"
  kv "Swappiness" "$(sysctl -n vm.swappiness 2>/dev/null)"
  local backups; backups="$(ls -1 "$BACKUP_DIR"/rollback_*.sh 2>/dev/null | wc -l)"
  kv "Backups" "$backups"
  echo
}

run_bench(){
  title "Quick network sanity check"
  hr
  kv "Established conns" "$(ss -s 2>/dev/null | awk '/TCP:/{print $2}')"
  kv "UDP sockets" "$(ss -u -a 2>/dev/null | wc -l)"
  if command -v iperf3 >/dev/null 2>&1; then
    info "iperf3 установлен — для бенчмарка запустите вручную:"
    echo "  iperf3 -s            # на ноде"
    echo "  iperf3 -c <node-ip>  # с клиента"
  else
    info "iperf3 не установлен — apt install iperf3 для полного теста"
  fi
  hr
}

# ═════════════════════════════════════════════════════════════════════
# INSTALL / UPDATE / REMOVE
# ═════════════════════════════════════════════════════════════════════

is_installed(){ [[ -f "$INSTALL_PATH" && -x "$INSTALL_PATH" ]]; }

install_self(){
  require_root
  info "Установка в $INSTALL_PATH"
  cp "$0" "$INSTALL_PATH"
  chmod +x "$INSTALL_PATH"
  mkdir -p "$STATE_DIR"
  echo "$VERSION" > "$STATE_DIR/version"
  date -u '+%Y-%m-%d' > "$STATE_DIR/install_date"
  ok "Установлено. Запустите: node-tune"
}

uninstall_self(){
  require_root
  warn "Удаление node-tune CLI. Применённые настройки останутся."
  info "Для отката настроек: node-tune rollback"
  confirm "Продолжить?" || exit 0
  rm -f "$INSTALL_PATH"
  ok "CLI удалён. Конфиги в /etc/sysctl.d/, /etc/security/limits.d/ остались."
}

check_for_updates(){
  command -v curl >/dev/null 2>&1 || { fail "curl не установлен"; return 1; }
  info "Проверка версии на GitHub..."
  local remote
  remote="$(curl -fsSL "${GITHUB_RAW}/node-tune.sh" 2>/dev/null | grep -m1 '^VERSION=' | cut -d'"' -f2)"
  if [[ -z "$remote" ]]; then
    warn "Не удалось получить версию"
    return 1
  fi
  if [[ "$remote" == "$VERSION" ]]; then
    ok "У вас актуальная версия v${VERSION}"
    return 0
  fi
  warn "Доступно обновление: v${VERSION} → v${remote}"
  confirm "Скачать и установить?" || return 0
  require_root
  curl -fsSL "${GITHUB_RAW}/node-tune.sh" -o /tmp/node-tune.new
  bash -n /tmp/node-tune.new || { fail "Скачанный скрипт содержит ошибки"; rm -f /tmp/node-tune.new; return 1; }
  cp /tmp/node-tune.new "$INSTALL_PATH"
  chmod +x "$INSTALL_PATH"
  rm -f /tmp/node-tune.new
  echo "$remote" > "$STATE_DIR/version"
  ok "Обновлено до v${remote}"
}

# ═════════════════════════════════════════════════════════════════════
# MENU
# ═════════════════════════════════════════════════════════════════════

show_menu(){
  clear
  printf '%b╔═══════════════════════════════════════════════════════╗%b\n' "$CYAN" "$NC"
  printf '%b║       node-tune v%s — VPN/Proxy Node Tuning      ║%b\n' "$CYAN" "$VERSION" "$NC"
  printf '%b╚═══════════════════════════════════════════════════════╝%b\n\n' "$CYAN" "$NC"

  kv "Kernel" "$KERNEL$([[ $IS_XANMOD -eq 1 ]] && echo ' (XanMod)')"
  kv "Best CC" "$BEST_CC"
  kv "Best qdisc" "$BEST_QDISC"
  kv "RAM / CPU" "${TOTAL_RAM_MB} MB / ${CPU_THREADS} threads"
  [[ -f "$STATE_DIR/profile" ]] && kv "Active profile" "$(cat "$STATE_DIR/profile")"
  echo
  printf '  %b1)%b Apply tuning      — выбрать профиль и применить\n' "$GREEN" "$NC"
  printf '  %b2)%b Status            — текущее состояние\n' "$GREEN" "$NC"
  printf '  %b3)%b Quick bench       — быстрая проверка сети\n' "$GREEN" "$NC"
  printf '  %b4)%b Rollback          — откат к бэкапу\n' "$GREEN" "$NC"
  printf '  %b5)%b Check updates     — обновление с GitHub\n' "$GREEN" "$NC"
  echo
  if is_installed; then
    printf '  %bu)%b Uninstall CLI\n' "$RED" "$NC"
  else
    printf '  %bi)%b Install CLI       — /usr/local/bin/node-tune\n' "$BLUE" "$NC"
  fi
  printf '  %bq)%b Quit\n\n' "$RED" "$NC"

  local ch
  read -rp "Выбор: " ch
  echo
  case "$ch" in
    1) run_apply "" ;;
    2) show_status; read -rp "Enter..."; show_menu ;;
    3) run_bench; read -rp "Enter..."; show_menu ;;
    4) do_rollback ;;
    5) check_for_updates; read -rp "Enter..."; show_menu ;;
    i|I) install_self ;;
    u|U) uninstall_self ;;
    q|Q) exit 0 ;;
    *) warn "Invalid"; sleep 1; show_menu ;;
  esac
}

# ═════════════════════════════════════════════════════════════════════
# MAIN APPLY FLOW
# ═════════════════════════════════════════════════════════════════════

run_apply(){
  local prof="${1:-}"
  [[ -n "$prof" ]] && PROFILE="$prof"
  require_root
  ensure_profile

  # save old profile for snapshot header
  OLD_PROFILE=""
  [[ -f "$STATE_DIR/profile" ]] && OLD_PROFILE="$(cat "$STATE_DIR/profile")"

  printf '\n%b━━━ node-tune apply ━━━%b\n' "$BOLD" "$NC"
  kv "Profile" "$PROFILE"
  kv "Kernel" "$KERNEL"
  kv "BBR" "$BEST_CC"
  kv "Qdisc" "$BEST_QDISC"
  kv "RAM" "${TOTAL_RAM_MB} MB"
  echo

  if [[ "$NONINTERACTIVE" != "1" ]]; then
    confirm "Применить настройки?" || { info "Отменено"; exit 0; }
  fi

  compute_values
  backup_state
  detect_conflicts
  write_sysctl
  write_limits
  write_modprobe
  write_udev
  apply_sysctl
  configure_thp
  disable_ksm
  configure_nic
  configure_cpu_governor
  configure_io_runtime
  verify

  mkdir -p "$STATE_DIR"
  echo "$PROFILE" > "$STATE_DIR/profile"

  printf '\n%b✓ Настройки применены. Профиль: %s%b\n' "$GREEN" "$PROFILE" "$NC"

  # WG-specific hint
  if [[ "$PROFILE" == "wireguard" ]]; then
    echo
    info "Опциональная подсказка для WireGuard (не применяется автоматом):"
    echo "    Исключить WG-трафик из conntrack для максимальной производительности:"
    echo "    nft add table inet raw"
    echo "    nft 'add chain inet raw prerouting { type filter hook prerouting priority -300; }'"
    echo "    nft 'add rule inet raw prerouting udp dport 51820 notrack'"
  fi

  echo
  info "Для применения systemd DefaultLimit* к уже запущенным сервисам:"
  echo "    systemctl restart xray    # или wg-quick@wg0, sing-box и т.д."
  echo
  info "Rollback: $(ls -t "$BACKUP_DIR"/rollback_*.sh 2>/dev/null | head -1)"
}

# ═════════════════════════════════════════════════════════════════════
# CLI
# ═════════════════════════════════════════════════════════════════════

show_help(){
  cat <<EOF
node-tune v${VERSION} — Network & System Tuning for VPN/Proxy Nodes

Usage:
  node-tune                       Interactive menu
  node-tune apply [profile]       Apply tuning (reality|wireguard|mixed)
  node-tune profile <name>        Switch active profile and reapply
  node-tune status                Show current state
  node-tune bench                 Quick network sanity check
  node-tune rollback              Restore previous state
  node-tune install               Install to /usr/local/bin/node-tune
  node-tune remove                Uninstall CLI
  node-tune update                Check for updates
  node-tune help | version

Profiles:
  reality     Xray/Reality/VLESS/Trojan (TCP-heavy)
  wireguard   WireGuard/AmneziaWG       (UDP-heavy, forwarding)
  mixed       3x-ui / Marzban           (Xray + WG + SS)

Environment variables:
  PROFILE=<name>          Set profile non-interactively
  AUTO_FIX=1              Comment out conflicting sysctls in /etc/sysctl.conf etc.
  DISABLE_THP_OVERRIDE=<never|madvise|always>   Override THP mode
  NONINTERACTIVE=1        Skip all prompts (for CI)

Files:
  $CONF_SYSCTL
  $CONF_LIMITS
  $CONF_SYSTEMD_SYS
  $CONF_SYSTEMD_USER
  $CONF_MODPROBE
  $CONF_UDEV
  $STATE_DIR/profile
  $BACKUP_DIR/

Repo: https://github.com/${GITHUB_REPO}
EOF
}

main(){
  local cmd="${1:-}"
  # Команды, не требующие Linux-окружения
  case "$cmd" in
    help|-h|--help)       show_help; exit 0 ;;
    version|-v|--version) echo "node-tune v${VERSION}"; exit 0 ;;
  esac

  detect_environment

  case "$cmd" in
    apply|tune|run)
      shift || true
      run_apply "${1:-}"
      ;;
    profile)
      shift || true
      [[ -z "${1:-}" ]] && { fail "Укажите имя профиля"; exit 1; }
      run_apply "$1"
      ;;
    status)           show_status ;;
    bench|benchmark)  run_bench ;;
    rollback|restore) do_rollback ;;
    install)          install_self ;;
    remove|uninstall) uninstall_self ;;
    update|upgrade)   check_for_updates ;;
    "")
      if [[ -t 0 && -t 1 ]]; then
        show_menu
      else
        show_help
      fi
      ;;
    *)
      fail "Unknown command: $cmd"
      show_help
      exit 1
      ;;
  esac
}

main "$@"
