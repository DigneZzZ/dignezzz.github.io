#!/bin/bash
# VM Host Tuning Script for High-Performance Dedicated Servers
# Optimized for: Ryzen 9950X (16C/32T), 250GB RAM, Multiple VMs
# Author: DigneZzZ
# Repository: https://github.com/DigneZzZ/dignezzz.github.io

VERSION="2.0"
GITHUB_REPO="DigneZzZ/dignezzz.github.io"
GITHUB_RAW="https://raw.githubusercontent.com/${GITHUB_REPO}/main/server"
SCRIPT_NAME="dedic"
INSTALL_PATH="/usr/local/bin/${SCRIPT_NAME}"

set -euo pipefail

CONF="/etc/sysctl.d/99-vm-host-tuning.conf"

# Calculate optimal values based on system resources
TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_GB=$((TOTAL_RAM_KB / 1024 / 1024))
CPU_CORES=$(nproc)
CPU_THREADS=$(nproc --all)

# Network parameters
declare -A WANT=(
  # Connection Tracking - 16M для большого количества VM
  ["net.netfilter.nf_conntrack_max"]="16777216"
  ["net.netfilter.nf_conntrack_buckets"]="4194304"
  ["net.netfilter.nf_conntrack_tcp_timeout_established"]="7200"
  ["net.netfilter.nf_conntrack_tcp_timeout_time_wait"]="30"
  
  # TCP optimization - агрессивные значения для множества соединений
  ["net.ipv4.tcp_fin_timeout"]="10"
  ["net.ipv4.tcp_tw_reuse"]="1"
  ["net.ipv4.tcp_orphan_retries"]="2"
  ["net.ipv4.tcp_max_orphans"]="262144"
  ["net.ipv4.tcp_max_tw_buckets"]="2097152"
  
  # TCP buffer sizes - увеличены для 250GB RAM
  ["net.core.rmem_max"]="134217728"
  ["net.core.wmem_max"]="134217728"
  ["net.core.rmem_default"]="16777216"
  ["net.core.wmem_default"]="16777216"
  ["net.ipv4.tcp_rmem"]="4096 87380 134217728"
  ["net.ipv4.tcp_wmem"]="4096 65536 134217728"
  ["net.ipv4.tcp_mem"]="786432 1048576 26777216"
  
  # Queue sizes - для 32 потоков
  ["net.core.netdev_max_backlog"]="250000"
  ["net.core.netdev_budget"]="600"
  ["net.core.netdev_budget_usecs"]="8000"
  ["net.core.somaxconn"]="65535"
  ["net.ipv4.tcp_max_syn_backlog"]="65536"
  
  # Congestion control
  ["net.ipv4.tcp_congestion_control"]="bbr"
  ["net.core.default_qdisc"]="fq"
  
  # Fast socket operations
  ["net.ipv4.tcp_fastopen"]="3"
  ["net.ipv4.tcp_slow_start_after_idle"]="0"
  ["net.ipv4.tcp_no_metrics_save"]="1"
  ["net.ipv4.tcp_moderate_rcvbuf"]="1"
  
  # SYN cookies protection
  ["net.ipv4.tcp_syncookies"]="1"
  ["net.ipv4.tcp_synack_retries"]="2"
  ["net.ipv4.tcp_syn_retries"]="2"
  
  # IP forwarding для VM
  ["net.ipv4.ip_forward"]="1"
  ["net.ipv6.conf.all.forwarding"]="1"
  
  # Local port range
  ["net.ipv4.ip_local_port_range"]="10000 65535"
  
  # Memory Management - оптимизация для 250GB RAM
  ["vm.swappiness"]="1"
  ["vm.dirty_ratio"]="10"
  ["vm.dirty_background_ratio"]="5"
  ["vm.dirty_expire_centisecs"]="1000"
  ["vm.dirty_writeback_centisecs"]="500"
  ["vm.vfs_cache_pressure"]="50"
  ["vm.min_free_kbytes"]="1048576"
  ["vm.overcommit_memory"]="1"
  ["vm.overcommit_ratio"]="80"
  
  # Kernel parameters
  ["kernel.pid_max"]="4194304"
  ["kernel.threads-max"]="4194304"
  ["fs.file-max"]="26234859"
  ["fs.inotify.max_user_instances"]="8192"
  ["fs.inotify.max_user_watches"]="524288"
  
  # ARP cache для множества VM
  ["net.ipv4.neigh.default.gc_thresh1"]="8192"
  ["net.ipv4.neigh.default.gc_thresh2"]="32768"
  ["net.ipv4.neigh.default.gc_thresh3"]="65536"
  ["net.ipv6.neigh.default.gc_thresh1"]="8192"
  ["net.ipv6.neigh.default.gc_thresh2"]="32768"
  ["net.ipv6.neigh.default.gc_thresh3"]="65536"
)

# All tunable parameters for validation
TARGET_KEYS=(
  "net.netfilter.nf_conntrack_max"
  "net.netfilter.nf_conntrack_buckets"
  "net.netfilter.nf_conntrack_tcp_timeout_established"
  "net.netfilter.nf_conntrack_tcp_timeout_time_wait"
  "net.ipv4.tcp_fin_timeout"
  "net.ipv4.tcp_tw_reuse"
  "net.ipv4.tcp_orphan_retries"
  "net.ipv4.tcp_max_orphans"
  "net.ipv4.tcp_max_tw_buckets"
  "net.core.rmem_max"
  "net.core.wmem_max"
  "net.core.rmem_default"
  "net.core.wmem_default"
  "net.ipv4.tcp_rmem"
  "net.ipv4.tcp_wmem"
  "net.ipv4.tcp_mem"
  "net.core.netdev_max_backlog"
  "net.core.netdev_budget"
  "net.core.netdev_budget_usecs"
  "net.core.somaxconn"
  "net.ipv4.tcp_max_syn_backlog"
  "net.ipv4.tcp_congestion_control"
  "net.core.default_qdisc"
  "net.ipv4.tcp_fastopen"
  "net.ipv4.tcp_slow_start_after_idle"
  "net.ipv4.tcp_no_metrics_save"
  "net.ipv4.tcp_moderate_rcvbuf"
  "net.ipv4.tcp_syncookies"
  "net.ipv4.tcp_synack_retries"
  "net.ipv4.tcp_syn_retries"
  "net.ipv4.ip_forward"
  "net.ipv6.conf.all.forwarding"
  "net.ipv4.ip_local_port_range"
  "vm.swappiness"
  "vm.dirty_ratio"
  "vm.dirty_background_ratio"
  "vm.dirty_expire_centisecs"
  "vm.dirty_writeback_centisecs"
  "vm.vfs_cache_pressure"
  "vm.min_free_kbytes"
  "vm.overcommit_memory"
  "vm.overcommit_ratio"
  "kernel.pid_max"
  "kernel.threads-max"
  "fs.file-max"
  "fs.inotify.max_user_instances"
  "fs.inotify.max_user_watches"
  "net.ipv4.neigh.default.gc_thresh1"
  "net.ipv4.neigh.default.gc_thresh2"
  "net.ipv4.neigh.default.gc_thresh3"
  "net.ipv6.neigh.default.gc_thresh1"
  "net.ipv6.neigh.default.gc_thresh2"
  "net.ipv6.neigh.default.gc_thresh3"
)

AUTO_FIX="${AUTO_FIX:-0}"
ENABLE_HUGEPAGES="${ENABLE_HUGEPAGES:-1}"
ENABLE_RPS="${ENABLE_RPS:-1}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

hr(){ echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; }
title(){ echo; echo -e "${BLUE}▶ $1${NC}"; }
kv(){ printf "  %-50s %s\n" "$1" "$2"; }
ok(){ echo -e "${GREEN}✓${NC} $1"; }
warn(){ echo -e "${YELLOW}⚠${NC} $1"; }
fail(){ echo -e "${RED}✗${NC} $1"; }
info(){ echo -e "${BLUE}ℹ${NC} $1"; }

is_num(){ [[ "${1:-}" =~ ^[0-9]+$ ]]; }

# ═══════════════════════════════════════════════════════════════════
# PRODUCTION SAFETY CHECK
# ═══════════════════════════════════════════════════════════════════

check_production_environment() {
  title "Production Environment Check"
  hr
  
  local has_vms=0
  
  # Check for running VMs (KVM/QEMU)
  if command -v virsh &>/dev/null; then
    local vm_count=$(virsh list --state-running 2>/dev/null | grep -c running || echo 0)
    if [[ $vm_count -gt 0 ]]; then
      info "Detected $vm_count running VM(s) via libvirt/KVM"
      has_vms=1
    fi
  fi
  
  # Check for Docker containers
  if command -v docker &>/dev/null; then
    local container_count=$(docker ps -q 2>/dev/null | wc -l | tr -d ' ')
    if [[ $container_count -gt 0 ]]; then
      info "Detected $container_count running Docker container(s)"
      has_vms=1
    fi
  fi
  
  # Check for LXC containers
  if command -v lxc-ls &>/dev/null; then
    local lxc_count=$(lxc-ls --running 2>/dev/null | wc -w | tr -d ' ')
    if [[ $lxc_count -gt 0 ]]; then
      info "Detected $lxc_count running LXC container(s)"
      has_vms=1
    fi
  fi
  
  if [[ $has_vms -eq 1 ]]; then
    echo
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║    Обнаружена production среда с VM/контейнерами     ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════╝${NC}\n"
    
    echo -e "${GREEN}Что скрипт НЕ делает (безопасно):${NC}"
    echo "  ✓ НЕ останавливает VM/контейнеры"
    echo "  ✓ НЕ трогает конфигурации VM"
    echo "  ✓ НЕ перезапускает сервисы"
    echo "  ✓ НЕ требует reboot (но рекомендуется)"
    echo
    echo -e "${BLUE}Что скрипт делает:${NC}"
    echo "  • Изменяет kernel параметры (sysctl)"
    echo "  • Оптимизирует сеть, память, I/O"
    echo "  • Применяется «на лету» без перезагрузки"
    echo
    echo -e "${GREEN}Защита:${NC}"
    echo "  ✓ Полный backup создается автоматически"
    echo "  ✓ Легкий откат через: dedic rollback"
    echo "  ✓ Изменения применяются постепенно"
    echo
  else
    ok "Нет активных VM/контейнеров"
  fi
  
  hr
}

# ═══════════════════════════════════════════════════════════════════
# INSTALLATION & MENU FUNCTIONS
# ═══════════════════════════════════════════════════════════════════

check_root() {
  if [[ $EUID -ne 0 ]]; then
    fail "This script must be run as root"
    echo "Usage: sudo $0 [command]"
    exit 1
  fi
}

is_installed() {
  [[ -f "$INSTALL_PATH" ]] && [[ -x "$INSTALL_PATH" ]]
}

install_self() {
  check_root
  
  echo -e "\n${CYAN}╔═══════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║         Installing dedic tool to system              ║${NC}"
  echo -e "${CYAN}╚═══════════════════════════════════════════════════════╝${NC}\n"
  
  if is_installed; then
    warn "dedic is already installed at $INSTALL_PATH"
    read -p "Reinstall? [y/N] " -n 1 -r
    echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 0
  fi
  
  # Copy self to install location
  info "Installing to $INSTALL_PATH..."
  cp "$0" "$INSTALL_PATH"
  chmod +x "$INSTALL_PATH"
  ok "Installed successfully"
  
  # Create config directory
  mkdir -p /etc/dedic
  echo "$VERSION" > /etc/dedic/version
  echo "$(date +%Y%m%d)" > /etc/dedic/install_date
  ok "Created config directory"
  
  echo -e "\n${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║           Installation completed!                     ║${NC}"
  echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}\n"
  
  echo "Available commands:"
  echo -e "  ${CYAN}dedic${NC}          - Interactive menu"
  echo -e "  ${CYAN}dedic apply${NC}    - Apply tuning"
  echo -e "  ${CYAN}dedic status${NC}   - Check system status"
  echo -e "  ${CYAN}dedic test${NC}     - Run performance test"
  echo -e "  ${CYAN}dedic rollback${NC} - Restore original settings"
  echo -e "  ${CYAN}dedic update${NC}   - Check for updates"
  echo -e "  ${CYAN}dedic remove${NC}   - Uninstall"
  echo
  
  exit 0
}

uninstall_self() {
  check_root
  
  echo -e "\n${YELLOW}╔═══════════════════════════════════════════════════════╗${NC}"
  echo -e "${YELLOW}║              Uninstalling dedic tool                  ║${NC}"
  echo -e "${YELLOW}╚═══════════════════════════════════════════════════════╝${NC}\n"
  
  warn "This will remove dedic tool from your system"
  echo "Applied tuning will NOT be removed."
  echo "To rollback tuning: dedic rollback"
  echo
  
  read -p "Continue? [y/N] " -n 1 -r
  echo
  [[ ! $REPLY =~ ^[Yy]$ ]] && exit 0
  
  rm -f "$INSTALL_PATH"
  rm -rf /etc/dedic
  ok "dedic tool removed"
  
  echo -e "\n${GREEN}Configs remain in:${NC}"
  echo "  • /etc/sysctl.d/99-vm-host-tuning.conf"
  echo "  • /var/backups/dedic-tuning/"
  echo
  
  exit 0
}

check_for_updates() {
  info "Checking for updates..."
  
  if ! command -v curl &>/dev/null; then
    warn "curl not installed, cannot check updates"
    return 1
  fi
  
  local remote_version
  remote_version=$(curl -fsSL "${GITHUB_RAW}/dedic.sh" | grep '^VERSION=' | head -1 | cut -d'"' -f2 2>/dev/null || echo "")
  
  if [[ -z "$remote_version" ]]; then
    warn "Cannot fetch remote version"
    return 1
  fi
  
  if [[ "$remote_version" == "$VERSION" ]]; then
    ok "You have the latest version (v${VERSION})"
    return 0
  else
    warn "Update available: v${VERSION} → v${remote_version}"
    echo
    read -p "Download and install update? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      info "Downloading update..."
      if curl -fsSL "${GITHUB_RAW}/dedic.sh" -o /tmp/dedic_new.sh; then
        if bash -n /tmp/dedic_new.sh 2>/dev/null; then
          check_root
          cp /tmp/dedic_new.sh "$INSTALL_PATH"
          chmod +x "$INSTALL_PATH"
          rm -f /tmp/dedic_new.sh
          ok "Updated to v${remote_version}"
          echo "$remote_version" > /etc/dedic/version
          exit 0
        else
          fail "Downloaded script has errors"
          rm -f /tmp/dedic_new.sh
          return 1
        fi
      else
        fail "Download failed"
        return 1
      fi
    fi
  fi
}

show_status() {
  echo -e "\n${CYAN}╔═══════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║              dedic - System Status                    ║${NC}"
  echo -e "${CYAN}╚═══════════════════════════════════════════════════════╝${NC}\n"
  
  kv "Version" "$VERSION"
  if [[ -f /etc/dedic/install_date ]]; then
    kv "Installed" "$(cat /etc/dedic/install_date)"
  fi
  
  echo
  kv "Hostname" "$(hostname)"
  kv "Kernel" "$(uname -r)"
  kv "CPU" "$(nproc) cores / $(nproc --all) threads"
  kv "RAM" "$(free -h | awk '/^Mem:/ {print $2}')"
  
  echo
  if [[ -f "$CONF" ]]; then
    ok "Tuning applied: $CONF"
    kv "Config date" "$(date -r $CONF '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo 'N/A')"
  else
    warn "Tuning not applied"
  fi
  
  echo
  kv "Conntrack" "$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 'N/A') / $(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo 'N/A')"
  kv "File descriptors" "$(cat /proc/sys/fs/file-nr 2>/dev/null | awk '{print $1}') / $(cat /proc/sys/fs/file-max 2>/dev/null)"
  
  local cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "N/A")
  kv "TCP congestion" "$cc"
  
  echo
  local backups=$(ls -1 /var/backups/dedic-tuning/rollback_*.sh 2>/dev/null | wc -l)
  kv "Backups available" "$backups"
  
  echo
}

do_rollback() {
  check_root
  
  local latest_backup=$(ls -t /var/backups/dedic-tuning/rollback_*.sh 2>/dev/null | head -1)
  
  if [[ -z "$latest_backup" ]]; then
    fail "No backup found"
    echo "Run 'dedic apply' first to create a backup"
    exit 1
  fi
  
  echo -e "\n${YELLOW}╔═══════════════════════════════════════════════════════╗${NC}"
  echo -e "${YELLOW}║              Rolling back tuning                      ║${NC}"
  echo -e "${YELLOW}╚═══════════════════════════════════════════════════════╝${NC}\n"
  
  kv "Backup date" "$(basename "$latest_backup" | sed 's/rollback_//; s/.sh//' | sed 's/_/ /')"
  kv "Backup file" "$latest_backup"
  
  echo
  warn "This will restore original system settings"
  read -p "Continue? [y/N] " -n 1 -r
  echo
  [[ ! $REPLY =~ ^[Yy]$ ]] && exit 0
  
  if bash "$latest_backup"; then
    ok "Rollback completed"
    echo
    info "Reboot recommended: sudo reboot"
  else
    fail "Rollback failed"
    exit 1
  fi
  
  exit 0
}

show_menu() {
  clear
  echo -e "\n${CYAN}╔═══════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║         dedic - VM Host Tuning Tool v${VERSION}           ║${NC}"
  echo -e "${CYAN}║         Optimized for Ryzen 9950X + 250GB RAM        ║${NC}"
  echo -e "${CYAN}╚═══════════════════════════════════════════════════════╝${NC}\n"
  
  echo -e "${MAGENTA}What would you like to do?${NC}\n"
  
  echo -e "  ${GREEN}1)${NC} Apply tuning       - Optimize system for VMs"
  echo -e "  ${GREEN}2)${NC} Show status        - Check current state"
  echo -e "  ${GREEN}3)${NC} Run test           - Performance benchmark"
  echo -e "  ${GREEN}4)${NC} Rollback           - Restore original settings"
  echo -e "  ${GREEN}5)${NC} Check updates      - Update from GitHub"
  echo
  echo -e "  ${YELLOW}6)${NC} View backup list   - Show available backups"
  echo -e "  ${YELLOW}7)${NC} Documentation      - Show help"
  echo
  if ! is_installed; then
    echo -e "  ${BLUE}i)${NC} Install to system  - Install as 'dedic' command"
  else
    echo -e "  ${RED}u)${NC} Uninstall          - Remove from system"
  fi
  echo -e "  ${RED}q)${NC} Quit"
  echo
  
  read -p "Enter choice: " choice
  echo
  
  case $choice in
    1) run_tuning_main ;;
    2) show_status; pause ;;
    3) run_performance_test ;;
    4) do_rollback ;;
    5) check_for_updates; pause ;;
    6) show_backup_list ;;
    7) show_help ;;
    i|I) install_self ;;
    u|U) uninstall_self ;;
    q|Q) exit 0 ;;
    *) warn "Invalid choice"; pause ;;
  esac
}

pause() {
  echo
  read -p "Press Enter to continue..." -r
  show_menu
}

show_backup_list() {
  echo -e "\n${CYAN}Available Backups:${NC}\n"
  
  if [[ -d /var/backups/dedic-tuning ]]; then
    local backups=$(ls -t /var/backups/dedic-tuning/rollback_*.sh 2>/dev/null)
    if [[ -n "$backups" ]]; then
      local count=1
      while IFS= read -r backup; do
        local date=$(basename "$backup" | sed 's/rollback_//; s/.sh//' | sed 's/_/ /')
        local size=$(du -h "$backup" | cut -f1)
        echo -e "  ${GREEN}${count})${NC} $date (${size})"
        echo -e "     ${BLUE}→${NC} $backup"
        echo
        count=$((count + 1))
      done <<< "$backups"
    else
      warn "No backups found"
    fi
  else
    warn "Backup directory not found"
  fi
  
  pause
}

show_help() {
  echo -e "\n${CYAN}╔═══════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║              dedic - Quick Help                       ║${NC}"
  echo -e "${CYAN}╚═══════════════════════════════════════════════════════╝${NC}\n"
  
  echo -e "${YELLOW}Commands:${NC}"
  echo -e "  ${CYAN}dedic${NC}               Interactive menu"
  echo -e "  ${CYAN}dedic apply${NC}         Apply tuning directly"
  echo -e "  ${CYAN}dedic status${NC}        Show system status"
  echo -e "  ${CYAN}dedic test${NC}          Run performance test"
  echo -e "  ${CYAN}dedic rollback${NC}      Restore original settings"
  echo -e "  ${CYAN}dedic update${NC}        Check for updates"
  
  echo -e "\n${YELLOW}Environment Variables:${NC}"
  echo -e "  ${CYAN}AUTO_FIX=1${NC}          Auto-fix conflicts"
  echo -e "  ${CYAN}ENABLE_HUGEPAGES=0${NC}  Disable huge pages"
  echo -e "  ${CYAN}ENABLE_RPS=0${NC}        Disable RPS/RFS"
  
  echo -e "\n${YELLOW}Examples:${NC}"
  echo -e "  sudo AUTO_FIX=1 dedic apply"
  echo -e "  sudo ENABLE_HUGEPAGES=0 dedic apply"
  
  echo -e "\n${YELLOW}Files:${NC}"
  echo -e "  Config: /etc/sysctl.d/99-vm-host-tuning.conf"
  echo -e "  Backup: /var/backups/dedic-tuning/"
  
  echo -e "\n${YELLOW}Documentation:${NC}"
  echo -e "  GitHub: https://github.com/${GITHUB_REPO}"
  
  pause
}

run_performance_test() {
  if command -v dedic-test &>/dev/null; then
    dedic-test
  else
    warn "Test script not found"
    info "Install: curl -fsSL ${GITHUB_RAW}/dedic-test.sh | bash"
  fi
  pause
}

# ═══════════════════════════════════════════════════════════════════
# MAIN TUNING FUNCTIONS (original code below)
# ═══════════════════════════════════════════════════════════════════

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
# Backup Current State
# -------------------------------------------------------------------

backup_current_state() {
  title "Creating backup of current system state"
  hr
  
  local timestamp=$(date +%Y%m%d_%H%M%S)
  local backup_dir="/var/backups/dedic-tuning"
  local backup_file="$backup_dir/sysctl_backup_${timestamp}.conf"
  local rollback_script="$backup_dir/rollback_${timestamp}.sh"
  
  # Create backup directory
  mkdir -p "$backup_dir"
  
  # Backup all current sysctl values
  {
    echo "# System state backup - $(date)"
    echo "# Hostname: $(hostname)"
    echo "# Kernel: $(uname -r)"
    echo "# Created by dedic.sh v2.0"
    echo "#"
    echo "# To restore: bash $rollback_script"
    echo ""
  } > "$backup_file"
  
  # Save current values of all parameters we're going to change
  for key in "${TARGET_KEYS[@]}"; do
    local current_value=$(sysctl -n "$key" 2>/dev/null || echo "N/A")
    if [[ "$current_value" != "N/A" ]]; then
      echo "$key = $current_value" >> "$backup_file"
    fi
  done
  
  ok "Backup created: $backup_file"
  
  # Create rollback script
  cat > "$rollback_script" <<'EOF_ROLLBACK_HEADER'
#!/bin/bash
# Auto-generated rollback script
# This script will restore system to state before dedic.sh tuning

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root"
  exit 1
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Rolling back dedic.sh tuning"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo

EOF_ROLLBACK_HEADER

  # Add restoration commands
  echo "echo 'Restoring original sysctl values...'" >> "$rollback_script"
  echo "" >> "$rollback_script"
  
  for key in "${TARGET_KEYS[@]}"; do
    local current_value=$(sysctl -n "$key" 2>/dev/null || echo "")
    if [[ -n "$current_value" ]]; then
      # Escape special characters for shell
      local safe_value=$(printf '%s' "$current_value" | sed 's/"/\\"/g')
      echo "sysctl -w '${key}=${safe_value}' 2>/dev/null || true" >> "$rollback_script"
    fi
  done
  
  cat >> "$rollback_script" <<'EOF_ROLLBACK_FOOTER'

echo
echo "Removing tuning configuration files..."
rm -f /etc/sysctl.d/99-vm-host-tuning.conf
rm -f /etc/security/limits.d/99-vm-host.conf

echo
echo "Reloading sysctl..."
sysctl --system >/dev/null 2>&1

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✓ Rollback completed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo
echo "Recommendations:"
echo "  • Reboot recommended for full restoration: sudo reboot"
echo "  • Original backup: $(dirname "$0")/$(basename "$backup_file")"
echo

EOF_ROLLBACK_FOOTER
  
  chmod +x "$rollback_script"
  ok "Rollback script created: $rollback_script"
  
  # Backup existing config files
  if [[ -f /etc/sysctl.d/99-vm-host-tuning.conf ]]; then
    cp -a /etc/sysctl.d/99-vm-host-tuning.conf "$backup_dir/99-vm-host-tuning.conf.${timestamp}.bak"
    info "Previous tuning config backed up"
  fi
  
  if [[ -f /etc/security/limits.d/99-vm-host.conf ]]; then
    cp -a /etc/security/limits.d/99-vm-host.conf "$backup_dir/99-vm-host.conf.${timestamp}.bak"
    info "Previous limits config backed up"
  fi
  
  # Create backup index
  cat > "$backup_dir/README.txt" <<EOF_INDEX
Backup Directory for dedic.sh Tuning
=====================================

This directory contains backups of system state before applying dedic.sh tuning.

Latest backup: ${timestamp}
  - Configuration: sysctl_backup_${timestamp}.conf
  - Rollback script: rollback_${timestamp}.sh

To restore original state:
  sudo bash rollback_${timestamp}.sh
  sudo reboot

To list all backups:
  ls -lh $backup_dir/

To manually restore a parameter:
  sysctl -w parameter.name=value
  # or edit /etc/sysctl.conf and run: sysctl --system

Created: $(date)
EOF_INDEX
  
  hr
  
  echo -e "\n${GREEN}Backup Summary:${NC}"
  kv "Backup directory" "$backup_dir"
  kv "Backup file" "$(basename "$backup_file")"
  kv "Rollback script" "$(basename "$rollback_script")"
  kv "Backup size" "$(du -h "$backup_file" | cut -f1)"
  echo
  info "To restore original state: sudo bash $rollback_script"
  hr
}

# -------------------------------------------------------------------
# System Information
# -------------------------------------------------------------------

show_system_info() {
  title "System Information"
  hr
  kv "Hostname" "$(hostname)"
  kv "Kernel" "$(uname -r)"
  kv "CPU Model" "$(lscpu | grep 'Model name' | cut -d':' -f2 | xargs)"
  kv "CPU Cores" "$CPU_CORES"
  kv "CPU Threads" "$CPU_THREADS"
  kv "Total RAM" "${TOTAL_RAM_GB}GB"
  kv "Free RAM" "$(free -h | awk '/^Mem:/ {print $7}')"
  
  if [[ -f /sys/devices/system/node/node0/numastat ]]; then
    local numa_nodes=$(ls -d /sys/devices/system/node/node[0-9]* 2>/dev/null | wc -l)
    kv "NUMA Nodes" "$numa_nodes"
  fi
  
  hr
}

# -------------------------------------------------------------------
# Pre-flight checks
# -------------------------------------------------------------------

check_modules() {
  title "Checking required kernel modules"
  hr
  
  local modules=("tcp_bbr" "nf_conntrack")
  for mod in "${modules[@]}"; do
    if lsmod | grep -q "^${mod}"; then
      ok "$mod module loaded"
    else
      warn "$mod module not loaded, attempting to load..."
      if modprobe "$mod" 2>/dev/null; then
        ok "$mod module loaded successfully"
      else
        fail "Failed to load $mod module"
      fi
    fi
  done
  hr
}

# -------------------------------------------------------------------
# Huge Pages Configuration
# -------------------------------------------------------------------

configure_hugepages() {
  if [[ "$ENABLE_HUGEPAGES" != "1" ]]; then
    info "Huge pages disabled (ENABLE_HUGEPAGES=0)"
    return
  fi
  
  title "Configuring Transparent Huge Pages"
  hr
  
  # Allocate 20% of RAM for huge pages (for KVM/QEMU)
  local hugepage_size_kb=$(grep Hugepagesize /proc/meminfo | awk '{print $2}')
  local nr_hugepages=$((TOTAL_RAM_KB * 20 / 100 / hugepage_size_kb))
  
  kv "Huge page size" "${hugepage_size_kb}KB"
  kv "Huge pages to allocate" "$nr_hugepages"
  
  if echo "$nr_hugepages" > /proc/sys/vm/nr_hugepages 2>/dev/null; then
    ok "Huge pages configured: $nr_hugepages pages"
  else
    warn "Failed to configure huge pages (may require reboot)"
  fi
  
  # Enable THP for better memory management
  if [[ -f /sys/kernel/mm/transparent_hugepage/enabled ]]; then
    echo "madvise" > /sys/kernel/mm/transparent_hugepage/enabled
    echo "defer+madvise" > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true
    ok "Transparent Huge Pages: madvise mode"
  fi
  
  hr
}

# -------------------------------------------------------------------
# RPS/RFS Configuration (Receive Packet Steering)
# -------------------------------------------------------------------

configure_rps_rfs() {
  if [[ "$ENABLE_RPS" != "1" ]]; then
    info "RPS/RFS disabled (ENABLE_RPS=0)"
    return
  fi
  
  title "Configuring RPS/RFS (Multi-queue packet processing)"
  hr
  
  local rps_mask=$(printf '%x' $((2**CPU_THREADS - 1)))
  
  for iface in /sys/class/net/*/queues/rx-*/rps_cpus; do
    if [[ -f "$iface" ]]; then
      echo "$rps_mask" > "$iface" 2>/dev/null || true
    fi
  done
  
  ok "RPS configured for all network interfaces"
  
  # Configure RFS
  echo 32768 > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || true
  for iface in /sys/class/net/*/queues/rx-*/rps_flow_cnt; do
    if [[ -f "$iface" ]]; then
      echo 2048 > "$iface" 2>/dev/null || true
    fi
  done
  
  ok "RFS configured for flow distribution"
  hr
}

# -------------------------------------------------------------------
# IRQ Affinity Optimization
# -------------------------------------------------------------------

optimize_irq_affinity() {
  title "Optimizing IRQ Affinity"
  hr
  
  # Distribute network IRQs across all CPUs
  local net_irqs=$(grep -E 'eth|ens|enp' /proc/interrupts | awk -F: '{print $1}' | tr -d ' ')
  
  if [[ -n "$net_irqs" ]]; then
    local cpu_num=0
    for irq in $net_irqs; do
      if [[ -f "/proc/irq/$irq/smp_affinity_list" ]]; then
        echo "$cpu_num" > "/proc/irq/$irq/smp_affinity_list" 2>/dev/null || true
        cpu_num=$(( (cpu_num + 1) % CPU_THREADS ))
      fi
    done
    ok "IRQ affinity distributed across $CPU_THREADS threads"
  else
    info "No network IRQs found for optimization"
  fi
  
  hr
}

# -------------------------------------------------------------------
# I/O Scheduler Optimization
# -------------------------------------------------------------------

optimize_io_scheduler() {
  title "Optimizing I/O Schedulers"
  hr
  
  for disk in /sys/block/sd* /sys/block/nvme*; do
    [[ -d "$disk" ]] || continue
    local disk_name=$(basename "$disk")
    
    # Use none/noop for NVMe, mq-deadline for SSD, bfq for HDD
    local scheduler="mq-deadline"
    if [[ "$disk_name" == nvme* ]]; then
      scheduler="none"
    fi
    
    if [[ -f "$disk/queue/scheduler" ]]; then
      echo "$scheduler" > "$disk/queue/scheduler" 2>/dev/null || true
      kv "$disk_name scheduler" "$scheduler"
    fi
    
    # Increase queue depth
    if [[ -f "$disk/queue/nr_requests" ]]; then
      echo "4096" > "$disk/queue/nr_requests" 2>/dev/null || true
    fi
    
    # Readahead optimization
    if [[ -f "$disk/queue/read_ahead_kb" ]]; then
      echo "4096" > "$disk/queue/read_ahead_kb" 2>/dev/null || true
    fi
  done
  
  ok "I/O schedulers optimized"
  hr
}

# -------------------------------------------------------------------
# -------------------------------------------------------------------
# Current State Display
# -------------------------------------------------------------------

show_current_state() {
  title "Current system state (before tuning)"
  hr
  kv "Conntrack in use" "$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 'N/A')"
  kv "Conntrack limit" "$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo 'N/A')"
  kv "Open file descriptors" "$(cat /proc/sys/fs/file-nr | awk '{print $1}')"
  kv "File descriptor limit" "$(cat /proc/sys/fs/file-max)"
  kv "Active threads" "$(ps -eLf | wc -l)"
  kv "Thread limit" "$(cat /proc/sys/kernel/threads-max)"
  hr
}

# -------------------------------------------------------------------
# Conflict Detection
# -------------------------------------------------------------------

detect_conflicts() {
  title "Detecting conflicting sysctl definitions"
  hr
  conflicts=0

  for key in "${TARGET_KEYS[@]}"; do
    want="${WANT[$key]:-}"
    [[ -z "$want" ]] && continue
    
    hits="$(find_key_hits "$key" || true)"
    if [[ -z "${hits:-}" ]]; then
      continue
    fi

    last_file=""
    last_val=""
    while IFS= read -r h; do
      [[ -z "$h" ]] && continue
      f="${h%%:*}"
      rest="${h#*:}"
      lineno="${rest%%:*}"
      val="$(extract_value_from_line "$h")"
      last_file="$f"
      last_val="$val"
    done <<< "$hits"

    if echo "$hits" | grep -qE '^/etc/sysctl\.conf:'; then
      while IFS= read -r h; do
        val="$(extract_value_from_line "$h")"
        if [[ "$val" != "$want" ]]; then
          warn "Conflict: $key in /etc/sysctl.conf = $val (want: $want)"
          conflicts=$((conflicts+1))
          if [[ "$AUTO_FIX" == "1" ]]; then
            comment_out_key_in_file "/etc/sysctl.conf" "$key"
            ok "Auto-fixed: commented out $key in /etc/sysctl.conf"
          fi
        fi
      done < <(echo "$hits" | awk -F: '$1=="/etc/sysctl.conf"{print}')
    fi
  done

  if [[ "$conflicts" -gt 0 ]]; then
    warn "Detected $conflicts conflict(s)"
    [[ "$AUTO_FIX" != "1" ]] && info "Tip: run with AUTO_FIX=1 to auto-fix"
  else
    ok "No conflicts detected"
  fi
  hr
}

# -------------------------------------------------------------------
# Write Configuration
# -------------------------------------------------------------------

write_sysctl_config() {
  title "Writing sysctl configuration"
  hr
  
  cat <<'EOF_HEADER' > "$CONF"
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# VM Host Tuning Configuration
# Optimized for high-performance dedicated servers with multiple VMs
# Generated by dedic.sh v2.0
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

EOF_HEADER

  cat <<EOF >> "$CONF"
# Connection Tracking (16M connections for multiple VMs)
net.netfilter.nf_conntrack_max = ${WANT[net.netfilter.nf_conntrack_max]}
net.netfilter.nf_conntrack_buckets = ${WANT[net.netfilter.nf_conntrack_buckets]}
net.netfilter.nf_conntrack_tcp_timeout_established = ${WANT[net.netfilter.nf_conntrack_tcp_timeout_established]}
net.netfilter.nf_conntrack_tcp_timeout_time_wait = ${WANT[net.netfilter.nf_conntrack_tcp_timeout_time_wait]}

# TCP Optimization
net.ipv4.tcp_fin_timeout = ${WANT[net.ipv4.tcp_fin_timeout]}
net.ipv4.tcp_tw_reuse = ${WANT[net.ipv4.tcp_tw_reuse]}
net.ipv4.tcp_orphan_retries = ${WANT[net.ipv4.tcp_orphan_retries]}
net.ipv4.tcp_max_orphans = ${WANT[net.ipv4.tcp_max_orphans]}
net.ipv4.tcp_max_tw_buckets = ${WANT[net.ipv4.tcp_max_tw_buckets]}

# TCP Buffer Sizes (optimized for 250GB RAM)
net.core.rmem_max = ${WANT[net.core.rmem_max]}
net.core.wmem_max = ${WANT[net.core.wmem_max]}
net.core.rmem_default = ${WANT[net.core.rmem_default]}
net.core.wmem_default = ${WANT[net.core.wmem_default]}
net.ipv4.tcp_rmem = ${WANT[net.ipv4.tcp_rmem]}
net.ipv4.tcp_wmem = ${WANT[net.ipv4.tcp_wmem]}
net.ipv4.tcp_mem = ${WANT[net.ipv4.tcp_mem]}

# Queue Sizes (for 32 CPU threads)
net.core.netdev_max_backlog = ${WANT[net.core.netdev_max_backlog]}
net.core.netdev_budget = ${WANT[net.core.netdev_budget]}
net.core.netdev_budget_usecs = ${WANT[net.core.netdev_budget_usecs]}
net.core.somaxconn = ${WANT[net.core.somaxconn]}
net.ipv4.tcp_max_syn_backlog = ${WANT[net.ipv4.tcp_max_syn_backlog]}

# Congestion Control (BBR for better throughput)
net.ipv4.tcp_congestion_control = ${WANT[net.ipv4.tcp_congestion_control]}
net.core.default_qdisc = ${WANT[net.core.default_qdisc]}

# Fast Operations
net.ipv4.tcp_fastopen = ${WANT[net.ipv4.tcp_fastopen]}
net.ipv4.tcp_slow_start_after_idle = ${WANT[net.ipv4.tcp_slow_start_after_idle]}
net.ipv4.tcp_no_metrics_save = ${WANT[net.ipv4.tcp_no_metrics_save]}
net.ipv4.tcp_moderate_rcvbuf = ${WANT[net.ipv4.tcp_moderate_rcvbuf]}

# Security
net.ipv4.tcp_syncookies = ${WANT[net.ipv4.tcp_syncookies]}
net.ipv4.tcp_synack_retries = ${WANT[net.ipv4.tcp_synack_retries]}
net.ipv4.tcp_syn_retries = ${WANT[net.ipv4.tcp_syn_retries]}

# IP Forwarding for VMs
net.ipv4.ip_forward = ${WANT[net.ipv4.ip_forward]}
net.ipv6.conf.all.forwarding = ${WANT[net.ipv6.conf.all.forwarding]}

# Port Range
net.ipv4.ip_local_port_range = ${WANT[net.ipv4.ip_local_port_range]}

# Memory Management (250GB RAM optimization)
vm.swappiness = ${WANT[vm.swappiness]}
vm.dirty_ratio = ${WANT[vm.dirty_ratio]}
vm.dirty_background_ratio = ${WANT[vm.dirty_background_ratio]}
vm.dirty_expire_centisecs = ${WANT[vm.dirty_expire_centisecs]}
vm.dirty_writeback_centisecs = ${WANT[vm.dirty_writeback_centisecs]}
vm.vfs_cache_pressure = ${WANT[vm.vfs_cache_pressure]}
vm.min_free_kbytes = ${WANT[vm.min_free_kbytes]}
vm.overcommit_memory = ${WANT[vm.overcommit_memory]}
vm.overcommit_ratio = ${WANT[vm.overcommit_ratio]}

# Kernel Limits
kernel.pid_max = ${WANT[kernel.pid_max]}
kernel.threads-max = ${WANT[kernel.threads-max]}
fs.file-max = ${WANT[fs.file-max]}
fs.inotify.max_user_instances = ${WANT[fs.inotify.max_user_instances]}
fs.inotify.max_user_watches = ${WANT[fs.inotify.max_user_watches]}

# ARP Cache (for multiple VMs)
net.ipv4.neigh.default.gc_thresh1 = ${WANT[net.ipv4.neigh.default.gc_thresh1]}
net.ipv4.neigh.default.gc_thresh2 = ${WANT[net.ipv4.neigh.default.gc_thresh2]}
net.ipv4.neigh.default.gc_thresh3 = ${WANT[net.ipv4.neigh.default.gc_thresh3]}
net.ipv6.neigh.default.gc_thresh1 = ${WANT[net.ipv6.neigh.default.gc_thresh1]}
net.ipv6.neigh.default.gc_thresh2 = ${WANT[net.ipv6.neigh.default.gc_thresh2]}
net.ipv6.neigh.default.gc_thresh3 = ${WANT[net.ipv6.neigh.default.gc_thresh3]}
EOF

  ok "Configuration written to $CONF"
  hr
}

# -------------------------------------------------------------------
# Apply and Verify
# -------------------------------------------------------------------

apply_sysctl() {
  title "Applying sysctl settings"
  hr
  
  if sysctl --system >/dev/null 2>&1; then
    ok "sysctl reloaded successfully"
  else
    fail "sysctl reload failed"
    return 1
  fi
  
  # Apply conntrack buckets separately (not via sysctl)
  if [[ -f /sys/module/nf_conntrack/parameters/hashsize ]]; then
    echo "${WANT[net.netfilter.nf_conntrack_buckets]}" > /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null || true
    ok "Conntrack buckets set to ${WANT[net.netfilter.nf_conntrack_buckets]}"
  fi
  
  hr
}

verify_settings() {
  title "Verifying applied values"
  hr
  
  local failed=0
  for key in "${TARGET_KEYS[@]}"; do
    want="${WANT[$key]:-}"
    [[ -z "$want" ]] && continue
    
    actual="$(sysctl -n "$key" 2>/dev/null || true)"
    if [[ -z "$actual" ]]; then
      continue
    fi
    
    if [[ "$actual" == "$want" ]]; then
      ok "$key = $actual"
    else
      warn "$key = $actual (expected: $want)"
      failed=$((failed+1))
    fi
  done
  
  if [[ "$failed" -eq 0 ]]; then
    ok "All settings verified successfully"
  else
    warn "$failed setting(s) don't match expected values"
  fi
  
  hr
}

# -------------------------------------------------------------------
# System Limits Configuration
# -------------------------------------------------------------------

configure_system_limits() {
  title "Configuring system limits"
  hr
  
  local limits_file="/etc/security/limits.d/99-vm-host.conf"
  
  cat <<'EOF' > "$limits_file"
# VM Host System Limits
# Optimized for high-performance servers

* soft nofile 1048576
* hard nofile 1048576
* soft nproc 1048576
* hard nproc 1048576
* soft memlock unlimited
* hard memlock unlimited

root soft nofile 1048576
root hard nofile 1048576
root soft nproc 1048576
root hard nproc 1048576
EOF

  ok "System limits configured: $limits_file"
  
  # Apply limits to current session
  ulimit -n 1048576 2>/dev/null || true
  ulimit -u 1048576 2>/dev/null || true
  
  hr
}

# -------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------

show_summary() {
  title "Configuration Summary"
  hr
  
  echo -e "\n${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${GREEN}     System tuning completed successfully!${NC}"
  echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
  
  kv "CPU Threads" "$CPU_THREADS"
  kv "Total RAM" "${TOTAL_RAM_GB}GB"
  kv "Conntrack limit" "${WANT[net.netfilter.nf_conntrack_max]}"
  kv "Max file descriptors" "${WANT[fs.file-max]}"
  kv "TCP congestion control" "${WANT[net.ipv4.tcp_congestion_control]}"
  kv "Huge pages" "$([[ $ENABLE_HUGEPAGES -eq 1 ]] && echo 'enabled' || echo 'disabled')"
  kv "RPS/RFS" "$([[ $ENABLE_RPS -eq 1 ]] && echo 'enabled' || echo 'disabled')"
  
  echo
  kv "Conntrack usage" "$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 'N/A')"
  kv "Open files" "$(cat /proc/sys/fs/file-nr | awk '{print $1}')"
  
  hr
  
  echo -e "\n${BLUE}📦 Backup Information:${NC}"
  local latest_backup=$(ls -t /var/backups/dedic-tuning/rollback_*.sh 2>/dev/null | head -1)
  if [[ -n "$latest_backup" ]]; then
    kv "Backup location" "/var/backups/dedic-tuning/"
    kv "Rollback script" "$(basename "$latest_backup")"
    echo -e "\n  ${GREEN}✓${NC} Full system state backup created"
    echo -e "  ${BLUE}ℹ${NC} To restore original settings: sudo bash $latest_backup"
  fi
  
  echo -e "\n${BLUE}📋 Recommendations:${NC}"
  echo "  • Reboot recommended for optimal performance"
  echo "  • Test VM performance before production use"
  echo "  • Monitor: htop, iotop, iftop, ss -s"
  echo "  • Check logs: journalctl -xe"
  echo "  • Re-run script after kernel updates"
  
  if [[ "$AUTO_FIX" != "1" ]] && [[ -f /etc/sysctl.conf ]]; then
    echo -e "\n${YELLOW}⚠${NC} Run with AUTO_FIX=1 to automatically resolve conflicts"
  fi
  
  echo -e "\n${BLUE}🔄 Rollback:${NC}"
  if [[ -n "$latest_backup" ]]; then
    echo "  sudo bash $latest_backup"
    echo "  sudo reboot"
  else
    echo "  No backup found in this session"
  fi
  
  echo
}

# -------------------------------------------------------------------
# Main Tuning Execution
# -------------------------------------------------------------------

run_tuning_main() {
  check_root
  
  echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BLUE}     VM Host Tuning Script v${VERSION}${NC}"
  echo -e "${BLUE}     Optimized for Ryzen 9950X + 250GB RAM${NC}"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
  
  show_system_info
  check_production_environment  # ← Проверка production среды
  check_modules
  show_current_state
  backup_current_state
  detect_conflicts
  write_sysctl_config
  apply_sysctl
  configure_hugepages
  configure_rps_rfs
  optimize_irq_affinity
  optimize_io_scheduler
  configure_system_limits
  verify_settings
  show_summary
  
  # Return to menu if running interactively
  if [[ "${1:-}" == "menu" ]]; then
    pause
  fi
}

# -------------------------------------------------------------------
# Command Line Interface
# -------------------------------------------------------------------

main() {
  # Parse command line arguments
  case "${1:-}" in
    install)
      install_self
      ;;
    remove|uninstall)
      uninstall_self
      ;;
    apply|tune|run)
      check_root
      run_tuning_main
      ;;
    status)
      show_status
      exit 0
      ;;
    test|bench|benchmark)
      run_performance_test
      ;;
    rollback|restore)
      do_rollback
      ;;
    update|upgrade)
      check_for_updates
      exit 0
      ;;
    help|-h|--help)
      show_help
      exit 0
      ;;
    version|-v|--version)
      echo "dedic v${VERSION}"
      exit 0
      ;;
    menu|"")
      # Interactive menu mode
      if [[ -t 0 ]]; then
        # Running in terminal with no args or 'menu' - show interactive menu
        show_menu
      else
        # Running non-interactively (e.g., piped) - show help
        show_help
        exit 0
      fi
      ;;
    *)
      echo -e "${RED}Unknown command: $1${NC}"
      echo
      echo "Usage: $0 [command]"
      echo
      echo "Commands:"
      echo "  apply       Apply tuning (default if run as root)"
      echo "  status      Show system status"
      echo "  test        Run performance test"
      echo "  rollback    Restore original settings"
      echo "  update      Check for updates"
      echo "  install     Install to /usr/local/bin/dedic"
      echo "  remove      Uninstall from system"
      echo "  help        Show help"
      echo "  menu        Interactive menu (default)"
      echo
      exit 1
      ;;
  esac
}

# Entry point
main "$@"

