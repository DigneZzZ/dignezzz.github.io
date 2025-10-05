#!/bin/bash

# ============================================================================
# GIG MOTD Dashboard - Installation & Management Script
# ============================================================================
# Description: Modern, configurable MOTD dashboard for Linux servers
# Author: DigneZzZ - https://gig.ovh
# Version: 2025.10.05
# License: MIT
# ============================================================================

set -euo pipefail  # Exit on error, undefined variable, pipe failure

# ============================================================================
# CONSTANTS
# ============================================================================
readonly SCRIPT_VERSION="2025.10.05"
readonly SCRIPT_NAME="GIG MOTD Dashboard"
readonly REMOTE_URL="https://dignezzz.github.io/server/dashboard.sh"

# Default paths (can be overridden by --not-root)
DASHBOARD_FILE="/etc/update-motd.d/99-dashboard"
CONFIG_GLOBAL="/etc/motdrc"
MOTD_CONFIG_TOOL="/usr/local/bin/motd-config"
MOTD_VIEWER="/usr/local/bin/motd"

# ============================================================================
# GLOBAL VARIABLES
# ============================================================================
FORCE_MODE=false
INSTALL_USER_MODE=false
QUIET_MODE=false

# ============================================================================
# COLOR FUNCTIONS
# ============================================================================
_color() { 
    [ "$QUIET_MODE" = true ] && return
    printf "\033[%sm%s\033[0m" "$1" "$2"
}

_red() { _color "0;31" "$1"; }
_green() { _color "0;32" "$1"; }
_yellow() { _color "0;33" "$1"; }
_blue() { _color "0;36" "$1"; }
_bold() { _color "1" "$1"; }

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

_exists() {
    command -v "$1" >/dev/null 2>&1
}

print_header() {
    echo ""
    _bold "=========================================="
    _bold "$1"
    _bold "=========================================="
    echo ""
}

info() {
    [ "$QUIET_MODE" = false ] && echo "$(_blue "ℹ️")  $*"
}

success() {
    [ "$QUIET_MODE" = false ] && echo "$(_green "✅") $*"
}

warning() {
    [ "$QUIET_MODE" = false ] && echo "$(_yellow "⚠️")  $*"
}

error_exit() {
    echo "$(_red "❌") $*" >&2
    exit 1
}

# ============================================================================
# HELP AND VERSION
# ============================================================================

show_help() {
    cat << EOF
$(_bold "$SCRIPT_NAME v$SCRIPT_VERSION")

$(_bold "USAGE:")
    $0 [OPTIONS]

$(_bold "OPTIONS:")
    --force         Skip confirmation prompts
    --not-root      Install in user's home directory
    --quiet         Minimal output
    --help          Show this help message
    --version       Show version information

$(_bold "EXAMPLES:")
    sudo bash dashboard.sh
    bash dashboard.sh --not-root
    bash <(wget -qO- $REMOTE_URL)

$(_bold "POST-INSTALLATION:")
    motd            - View MOTD dashboard anytime
    motd-config     - Configure dashboard settings
    motd --update   - Update to latest version

EOF
}

show_version() {
    echo "$SCRIPT_NAME v$SCRIPT_VERSION"
    echo "Author: DigneZzZ - https://gig.ovh"
}

# ============================================================================
# ARGUMENT PARSING
# ============================================================================

parse_arguments() {
    for arg in "$@"; do
        case $arg in
            --force) FORCE_MODE=true ;;
            --not-root) INSTALL_USER_MODE=true ;;
            --quiet) QUIET_MODE=true ;;
            --help|-h) show_help; exit 0 ;;
            --version|-v) show_version; exit 0 ;;
            *) warning "Unknown option: $arg (use --help for usage)" ;;
        esac
    done
}


if [ "$INSTALL_USER_MODE" = true ]; then
    DASHBOARD_FILE="$HOME/.config/gig-motd/99-dashboard"
    MOTD_CONFIG_TOOL="$HOME/.local/bin/motd-config"
    CONFIG_GLOBAL="$HOME/.motdrc"
    mkdir -p "$(dirname "$DASHBOARD_FILE")" "$(dirname "$MOTD_CONFIG_TOOL")"
fi


# === Функция: Установка CLI утилиты motd (viewer) ===
install_motd_viewer() {
    echo "📥 Установка команды motd в $MOTD_VIEWER"
    cat > "$MOTD_VIEWER" << 'EOF'
#!/bin/bash
# GIG MOTD Viewer - быстрый просмотр дашборда
DASHBOARD_FILE_GLOBAL="/etc/update-motd.d/99-dashboard"
DASHBOARD_FILE_USER="$HOME/.config/gig-motd/99-dashboard"

if [ -f "$DASHBOARD_FILE_GLOBAL" ]; then
    bash "$DASHBOARD_FILE_GLOBAL"
elif [ -f "$DASHBOARD_FILE_USER" ]; then
    bash "$DASHBOARD_FILE_USER"
else
    echo "❌ MOTD Dashboard не установлен"
    echo "💡 Установка: bash <(wget -qO- https://dignezzz.github.io/server/dashboard.sh)"
    exit 1
fi
EOF
    chmod +x "$MOTD_VIEWER"
    echo "✅ Установлена команда: $MOTD_VIEWER"
}

# === Функция: Установка CLI утилиты motd-config ===
install_motd_config() {
    echo "📥 Установка CLI утилиты motd-config в $MOTD_CONFIG_TOOL"
    cat > "$MOTD_CONFIG_TOOL" << 'EOF'
#!/bin/bash

CONFIG_GLOBAL="/etc/motdrc"
CONFIG_USER="$HOME/.motdrc"
TARGET_FILE="$CONFIG_GLOBAL"

[ ! -w "$CONFIG_GLOBAL" ] && TARGET_FILE="$CONFIG_USER"

DASHBOARD_FILE_GLOBAL="/etc/update-motd.d/99-dashboard"
DASHBOARD_FILE_USER="$HOME/.config/gig-motd/99-dashboard"
TOOL_PATH_GLOBAL="/usr/local/bin/motd-config"
TOOL_PATH_USER="$HOME/.local/bin/motd-config"

OPTIONS=(
  SHOW_UPTIME
  SHOW_LOAD
  SHOW_CPU
  SHOW_RAM
  SHOW_SWAP
  SHOW_DISK
  SHOW_TOP_PROCESSES
  SHOW_NET
  SHOW_IP
  SHOW_DOCKER
  SHOW_SSH
  SHOW_SECURITY
  SHOW_UPDATES
  SHOW_AUTOUPDATES
  SHOW_FAIL2BAN_STATS
  SHOW_TEMP
)

print_menu() {
  echo "🔧 Настройка GIG MOTD"
  echo "1) Настроить отображаемые блоки"
  echo "2) Удалить MOTD-дашборд"
  echo "0) Выход"
}

configure_blocks() {
  echo "Выбери блоки для отображения (y/n):"
  for VAR in "${OPTIONS[@]}"; do
    read -p "$VAR (y/n) [Y]: " val
    case "${val,,}" in
      y|"") echo "$VAR=true" ;;
      n)    echo "$VAR=false" ;;
      *)    echo "$VAR=true" ;;
    esac
  done > "$TARGET_FILE"
  echo "✅ Настройки сохранены в $TARGET_FILE"
}

uninstall_dashboard() {
  echo "⚠️ Это удалит MOTD-дашборд, CLI и все настройки."
  read -p "Ты уверен? (y/N): " confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    echo "🗑 Удаляем дашборд и конфиги..."

    sudo rm -f "$DASHBOARD_FILE_GLOBAL"
    rm -f "$DASHBOARD_FILE_USER"

    sudo rm -f "$TOOL_PATH_GLOBAL"
    rm -f "$TOOL_PATH_USER"

    sudo rm -f "$CONFIG_GLOBAL"
    rm -f "$CONFIG_USER"

    echo "✅ Всё удалено. MOTD вернётся к стандартному виду."
  else
    echo "❌ Отмена удаления."
  fi
}

while true; do
  print_menu
  read -p "Выбор: " choice
  case "$choice" in
    1) configure_blocks ;;
    2) uninstall_dashboard ;;
    0) exit ;;
    *) echo "❌ Неверный ввод" ;;
  esac
done 

echo "✅ Настройки сохранены в $TARGET_FILE"
EOF

    chmod +x "$MOTD_CONFIG_TOOL"
    echo "✅ Установлена CLI утилита: $MOTD_CONFIG_TOOL"
}

# === Функция: Создание глобального конфига ===
create_motd_global_config() {
    if [ ! -f "$CONFIG_GLOBAL" ]; then
        cat > "$CONFIG_GLOBAL" << EOF
SHOW_UPTIME=true
SHOW_LOAD=true
SHOW_CPU=true
SHOW_RAM=true
SHOW_SWAP=true
SHOW_DISK=true
SHOW_TOP_PROCESSES=true
SHOW_NET=true
SHOW_IP=true
SHOW_DOCKER=true
SHOW_SSH=true
SHOW_SECURITY=true
SHOW_UPDATES=true
SHOW_AUTOUPDATES=true
SHOW_FAIL2BAN_STATS=true
SHOW_TEMP=true
EOF
        echo "✅ Создан глобальный конфиг: $CONFIG_GLOBAL"
    else
        echo "ℹ️ Глобальный конфиг уже существует: $CONFIG_GLOBAL"
    fi
}

# === Проверка прав ===
if [ "$EUID" -ne 0 ] && [ "$INSTALL_USER_MODE" = false ]; then
    echo "❌ Пожалуйста, запусти от root или с флагом --not-root"
    exit 1
fi
TMP_FILE=$(mktemp)

# === Проверка зависимостей, если не root ===
if [ "$EUID" -ne 0 ]; then
    MISSING=()
    for CMD in curl hostname awk grep cut uname df free top ip uptime vnstat; do
        if ! command -v "$CMD" &>/dev/null; then
            MISSING+=("$CMD")
        fi
    done
    if (( ${#MISSING[@]} )); then
        echo "❌ Не хватает обязательных утилит: ${MISSING[*]}"
        echo "🛠 Пожалуйста, установи их командой (под root):"
        echo "    sudo apt install curl coreutils net-tools procps iproute2 vnstat -y"
        echo "🔁 После этого снова запусти установку."
        exit 1
    fi
fi

# === Создание dashboard-файла ===
if [ "$INSTALL_USER_MODE" = false ]; then
    mkdir -p /etc/update-motd.d
fi
cat > "$TMP_FILE" << 'EOF'
#!/bin/bash


CURRENT_VERSION="2025.05.09"
REMOTE_URL="https://dignezzz.github.io/server/dashboard.sh"
REMOTE_VERSION=$(curl -s "$REMOTE_URL" | grep '^CURRENT_VERSION=' | cut -d= -f2 | tr -d '"')

if [ -n "$REMOTE_VERSION" ] && [ "$REMOTE_VERSION" != "$CURRENT_VERSION" ]; then
    echo "${warn} Доступна новая версия MOTD-дашборда: $REMOTE_VERSION (текущая: $CURRENT_VERSION)"
    echo "💡 Обновление: bash <(wget -qO- $REMOTE_URL) --force"
    echo ""
fi


ok="✅"
fail="❌"
warn="⚠️"
separator="─~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

CONFIG_GLOBAL="$CONFIG_GLOBAL"
CONFIG_USER="$HOME/.motdrc"
[ -f "$CONFIG_GLOBAL" ] && source "$CONFIG_GLOBAL"
[ -f "$CONFIG_USER" ] && source "$CONFIG_USER"

: "${SHOW_UPTIME:=true}"
: "${SHOW_LOAD:=true}"
: "${SHOW_CPU:=true}"
: "${SHOW_RAM:=true}"
: "${SHOW_DISK:=true}"
: "${SHOW_NET:=true}"
: "${SHOW_IP:=true}"
: "${SHOW_DOCKER:=true}"
: "${SHOW_SSH:=true}"
: "${SHOW_SECURITY:=true}"
: "${SHOW_UPDATES:=true}"
: "${SHOW_AUTOUPDATES:=true}"
: "${SHOW_SWAP:=true}"
: "${SHOW_TOP_PROCESSES:=true}"
: "${SHOW_FAIL2BAN_STATS:=true}"
: "${SHOW_TEMP:=true}"

# === Функция: Прогресс-бар ===
draw_bar() {
    local percent=$1
    local width=30
    local filled=$((percent * width / 100))
    local empty=$((width - filled))
    
    local color=""
    if [ "$percent" -ge 90 ]; then
        color="\033[0;31m"  # Красный
    elif [ "$percent" -ge 70 ]; then
        color="\033[0;33m"  # Желтый
    else
        color="\033[0;32m"  # Зеленый
    fi
    
    printf "${color}["
    printf "%${filled}s" | tr ' ' '█'
    printf "%${empty}s" | tr ' ' '░'
    printf "]\033[0m %3d%%" "$percent"
}

# === Сбор данных ===
uptime_str=$(uptime -p)
loadavg=$(cut -d ' ' -f1-3 /proc/loadavg)
cpu_cores=$(nproc)

# CPU
cpu_percent=$(top -bn2 -d 0.5 | grep "Cpu(s)" | tail -n1 | awk '{print 100 - $8}' | cut -d. -f1)
cpu_usage="${cpu_percent}%"
cpu_temp=""
if [ -f /sys/class/thermal/thermal_zone0/temp ]; then
    temp_raw=$(cat /sys/class/thermal/thermal_zone0/temp)
    temp_c=$((temp_raw / 1000))
    cpu_temp=" | ${temp_c}°C"
fi

# RAM
mem_total=$(free -m | awk '/Mem:/ {print $2}')
mem_used=$(free -m | awk '/Mem:/ {print $3}')
mem_percent=$((mem_used * 100 / mem_total))
mem_data="${mem_used}MB / ${mem_total}MB"

# SWAP
swap_total=$(free -m | awk '/Swap:/ {print $2}')
swap_used=$(free -m | awk '/Swap:/ {print $3}')
swap_percent=0
swap_data="not configured"
if [ "$swap_total" -gt 0 ]; then
    swap_percent=$((swap_used * 100 / swap_total))
    swap_data="${swap_used}MB / ${swap_total}MB"
fi

# Disk
disk_used=$(df -h / | awk 'NR==2 {print $5}' | tr -d '%')
disk_percent=$disk_used
disk_total=$(df -h / | awk 'NR==2 {print $2}')
disk_used_space=$(df -h / | awk 'NR==2 {print $3}')
disk_data="${disk_used_space} / ${disk_total}"

# Network
traffic=$(vnstat --oneline 2>/dev/null | awk -F\; '{print $10 " ↓ / " $11 " ↑"}')
ip_local=$(hostname -I | awk '{print $1}')
ip_public=$(curl -s ifconfig.me || echo "n/a")
ip6=$(ip -6 addr show scope global | grep inet6 | awk '{print $2}' | cut -d/ -f1 | head -n1)
[ -z "$ip6" ] && ip6="n/a"

# Top процессы
top_cpu=$(ps aux --sort=-%cpu | awk 'NR>1 {print $11}' | head -n 3 | paste -sd ', ')
top_mem=$(ps aux --sort=-%mem | awk 'NR>1 {print $11}' | head -n 3 | paste -sd ', ')

# Fail2ban статистика
fail2ban_banned=0
if command -v fail2ban-client &>/dev/null; then
    fail2ban_banned=$(fail2ban-client status 2>/dev/null | grep "Jail list" | sed 's/.*://;s/,//g' | xargs -n1 fail2ban-client status 2>/dev/null | grep "Currently banned" | awk '{s+=$NF} END {print s+0}')
fi

if command -v docker &>/dev/null; then
    docker_total=$(docker ps -a -q | wc -l)
    docker_running=$(docker ps -q | wc -l)
    docker_stopped=$((docker_total - docker_running))
    docker_msg="$ok ${docker_running} running / ${docker_stopped} stopped"
    bad_containers=$(docker ps -a --filter "status=exited" --filter "status=restarting" --format '⛔ {{.Names}} ({{.Status}})')
    if [ -n "$bad_containers" ]; then
        docker_msg="$fail Issues: $docker_running running / $docker_stopped stopped"
        docker_msg_extra=$(echo "$bad_containers" | sed 's/^/                    /')
    fi
else
    docker_msg="$warn not installed"
fi

ssh_users=$(who | wc -l)
ssh_ips=$(who | awk '{print $5}' | tr -d '()' | sort | uniq | paste -sd ', ' -)

if command -v fail2ban-client &>/dev/null; then
    fail2ban_status="$ok active"
else
    fail2ban_status="$fail not installed"
fi

if command -v ufw &>/dev/null; then
    ufw_status=$(ufw status | grep -i "Status" | awk '{print $2}')
    if [[ "$ufw_status" == "active" ]]; then
        ufw_status="$ok enabled"
    else
        ufw_status="$fail disabled"
    fi
else
    ufw_status="$fail not installed"
fi

if systemctl is-active crowdsec &>/dev/null; then
    crowdsec_status="$ok active"
else
    crowdsec_status="$fail not running"
fi

ssh_port=$(grep -Ei '^Port ' /etc/ssh/sshd_config | awk '{print $2}' | head -n1)
[ -z "$ssh_port" ] && ssh_port=22
[ "$ssh_port" != "22" ] && ssh_port_status="$ok non-standard port ($ssh_port)" || ssh_port_status="$warn default port (22)"

permit_root=$(sshd -T 2>/dev/null | grep -i permitrootlogin | awk '{print $2}')
case "$permit_root" in
    yes) root_login_status="$fail enabled" ;;
    no) root_login_status="$ok disabled" ;;
    *) root_login_status="$warn limited ($permit_root)" ;;
esac

password_auth=$(grep -Ei '^PasswordAuthentication' /etc/ssh/sshd_config | awk '{print $2}')
[ "$password_auth" != "yes" ] && password_auth_status="$ok disabled" || password_auth_status="$fail enabled"

updates=$(apt list --upgradable 2>/dev/null | grep -v "Listing" | wc -l)
update_msg="${updates} package(s) can be updated"

auto_update_status=""
if dpkg -s unattended-upgrades &>/dev/null && command -v unattended-upgrade &>/dev/null; then
    if grep -q 'Unattended-Upgrade "1";' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null; then
        if systemctl is-enabled apt-daily.timer &>/dev/null && systemctl is-enabled apt-daily-upgrade.timer &>/dev/null; then
            if grep -q "Installing" /var/log/unattended-upgrades/unattended-upgrades.log 2>/dev/null; then
                auto_update_status="$ok working"
            else
                auto_update_status="$ok enabled"
            fi
        else
            auto_update_status="$warn config enabled, timers disabled"
        fi
    else
        auto_update_status="$warn installed, config disabled"
    fi
else
    auto_update_status="$fail not installed"
fi

print_row() {
    local label="$1"
    local value="$2"
    printf " %-20s : %s\n" "$label" "$value"
}

print_section() {
  case "$1" in
    uptime)       print_row "System Uptime" "$uptime_str" ;;
    load)         print_row "Load Average" "$loadavg (cores: $cpu_cores)" ;;
    cpu)          
      printf " %-20s : " "CPU Usage"
      draw_bar "$cpu_percent"
      echo " $cpu_usage$cpu_temp"
      ;;
    kernel)       print_row "Kernel" "$(uname -r)" ;;
    ram)          
      printf " %-20s : " "RAM Usage"
      draw_bar "$mem_percent"
      echo " $mem_data"
      ;;
    swap)
      if [ "$swap_total" -gt 0 ]; then
        printf " %-20s : " "SWAP Usage"
        draw_bar "$swap_percent"
        echo " $swap_data"
      fi
      ;;
    disk)         
      printf " %-20s : " "Disk Usage /"
      draw_bar "$disk_percent"
      echo " $disk_data"
      ;;
    net)          print_row "Net Traffic" "$traffic" ;;
    ip)           print_row "IPv4/IPv6" "Local: $ip_local / Public: $ip_public / IPv6: $ip6" ;;
    top_processes)
      print_row "Top CPU" "$top_cpu"
      print_row "Top RAM" "$top_mem"
      ;;
    docker)
      print_row "Docker" "$docker_msg"
      [ -n "$docker_msg_extra" ] && echo -e "$docker_msg_extra"
      ;;
    updates)      print_row "Apt Updates" "$update_msg" ;;
    autoupdates)
      print_row "Auto Updates" "$auto_update_status"
      case "$auto_update_status" in
        *"$fail"*)
          echo "📌 Auto-Upgrades not installed. To install and enable:"
          echo "   apt install unattended-upgrades -y"
          echo "   dpkg-reconfigure --priority=low unattended-upgrades"
          ;;
        *"timers disabled"*)
          echo "📌 Auto-Upgrades config enabled, but timers are off. To enable:"
          echo "   systemctl enable --now apt-daily.timer apt-daily-upgrade.timer"
          ;;
        *"config disabled"*)
          echo "📌 Auto-Upgrades installed, but config disabled. To fix:"
          echo "   echo 'APT::Periodic::Unattended-Upgrade \"1\";' >> /etc/apt/apt.conf.d/20auto-upgrades"
          echo "   systemctl restart apt-daily.timer apt-daily-upgrade.timer"
          ;;
      esac
      ;;
    ssh_block)
      echo " ~~~~~~ ↓↓↓ Security Block ↓↓↓ ~~~~~~"
      print_row "Fail2ban" "$fail2ban_status"
      [ "$SHOW_FAIL2BAN_STATS" = true ] && [ "$fail2ban_banned" -gt 0 ] && print_row "  Banned IPs" "$fail2ban_banned"
      print_row "CrowdSec" "$crowdsec_status"
      print_row "UFW Firewall" "$ufw_status"
      print_row "SSH Port" "$ssh_port_status"
      print_row "Root Login" "$root_login_status"
      print_row "Password Auth" "$password_auth_status"
      print_row "SSH Sessions" "$ssh_users"
      print_row "SSH IPs" "$ssh_ips"
      echo " ~~~~~~ ↑↑↑ Security Block ↑↑↑ ~~~~~~"
      ;;
  esac
}

echo "$separator"
echo " MOTD Dashboard — powered by https://gig.ovh"
echo "$separator"
[ "$SHOW_UPTIME" = true ] && print_section uptime
[ "$SHOW_LOAD" = true ] && print_section load
[ "$SHOW_CPU" = true ] && print_section cpu
print_section kernel
[ "$SHOW_RAM" = true ] && print_section ram
[ "$SHOW_SWAP" = true ] && print_section swap
[ "$SHOW_DISK" = true ] && print_section disk
[ "$SHOW_TOP_PROCESSES" = true ] && print_section top_processes
[ "$SHOW_NET" = true ] && print_section net
[ "$SHOW_IP" = true ] && print_section ip
[ "$SHOW_DOCKER" = true ] && print_section docker
[ "$SHOW_SECURITY" = true ] && print_section ssh_block
[ "$SHOW_UPDATES" = true ] && print_section updates
[ "$SHOW_AUTOUPDATES" = true ] && print_section autoupdates

echo ""
printf " %-20s : %s\n" "Dashboard Ver" "$CURRENT_VERSION"
echo "$separator"
printf " %-20s : %s\n" "Config tool" "motd-config"
EOF
clear
echo "===================================================="
echo "📋 Предпросмотр GIG MOTD (реальный вывод):"
echo "===================================================="
bash "$TMP_FILE"
echo "===================================================="

if [ "$FORCE_MODE" = true ]; then
    echo "⚙️ Автоматическая установка без подтверждения (--force)"
    mv "$TMP_FILE" "$DASHBOARD_FILE"
if [ "$INSTALL_USER_MODE" = false ]; then
    chmod +x "$DASHBOARD_FILE"
    # Отключение стандартного MOTD Ubuntu
    chmod -x /etc/update-motd.d/00-header 2>/dev/null || true
    chmod -x /etc/update-motd.d/10-help-text 2>/dev/null || true
    chmod -x /etc/update-motd.d/50-landscape-sysinfo 2>/dev/null || true
    chmod -x /etc/update-motd.d/50-motd-news 2>/dev/null || true
    chmod -x /etc/update-motd.d/80-livepatch 2>/dev/null || true
    chmod -x /etc/update-motd.d/90-updates-available 2>/dev/null || true
    chmod -x /etc/update-motd.d/91-release-upgrade 2>/dev/null || true
    chmod -x /etc/update-motd.d/95-hwe-eol 2>/dev/null || true
fi
    install_motd_viewer
    install_motd_config
    create_motd_global_config
    echo "✅ Установлен дашборд: $DASHBOARD_FILE"
    echo "✅ Установлена команда: $MOTD_VIEWER"
    echo "✅ Установлена CLI утилита: $MOTD_CONFIG_TOOL"
    echo "✅ Создан глобальный конфиг: $CONFIG_GLOBAL"
    echo ""
    echo "👉 Для просмотра дашборда — выполни: motd"
    echo "👉 Для настройки отображения блоков — выполни: motd-config"
    echo "👉 Обновлённый MOTD появится при следующем входе"

else
    echo "Будет выполнена установка следующего набора:"
    echo "👉 Будет установлен дашборд: $DASHBOARD_FILE"
    echo "👉 Будет установлена команда: $MOTD_VIEWER"
    echo "👉 Будет установлена CLI утилита: $MOTD_CONFIG_TOOL"
    echo "👉 Будет создан глобальный конфиг: $CONFIG_GLOBAL"
    echo "👉 Будут отключены все стандартные скрипты Ubuntu MOTD"
    read -p '❓ Установить этот MOTD-дэшборд? [y/N]: ' confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        mv "$TMP_FILE" "$DASHBOARD_FILE"
if [ "$INSTALL_USER_MODE" = false ]; then
    chmod +x "$DASHBOARD_FILE"
    # Отключение стандартного MOTD Ubuntu
    chmod -x /etc/update-motd.d/00-header 2>/dev/null || true
    chmod -x /etc/update-motd.d/10-help-text 2>/dev/null || true
    chmod -x /etc/update-motd.d/50-landscape-sysinfo 2>/dev/null || true
    chmod -x /etc/update-motd.d/50-motd-news 2>/dev/null || true
    chmod -x /etc/update-motd.d/80-livepatch 2>/dev/null || true
    chmod -x /etc/update-motd.d/90-updates-available 2>/dev/null || true
    chmod -x /etc/update-motd.d/91-release-upgrade 2>/dev/null || true
    chmod -x /etc/update-motd.d/95-hwe-eol 2>/dev/null || true
fi
    install_motd_viewer
    install_motd_config
    create_motd_global_config
    
    echo "✅ Установлен дашборд: $DASHBOARD_FILE"
    echo "✅ Установлена команда: $MOTD_VIEWER"
    echo "✅ Установлена CLI утилита: $MOTD_CONFIG_TOOL"
    echo "✅ Создан глобальный конфиг: $CONFIG_GLOBAL"
    echo ""
    echo "👉 Для просмотра дашборда — выполни: motd"
    echo "👉 Для настройки отображения блоков — выполни: motd-config"
    echo "👉 Обновлённый MOTD появится при следующем входе"
    else
        echo "❌ Установка отменена."
        rm -f "$TMP_FILE"
    fi
fi
