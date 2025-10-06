#!/bin/bash

# ============================================================================
# GIG MOTD Dashboard - Installation & Management Script
# ============================================================================
# Description: Modern, configurable MOTD dashboard for Linux servers
# Author: DigneZzZ - https://gig.ovh
# Version: 2025.10.06.5
# License: MIT
# ============================================================================

set -euo pipefail  # Exit on error, undefined variable, pipe failure

# ============================================================================
# CONSTANTS
# ============================================================================
readonly SCRIPT_VERSION="2025.10.06.5"
readonly SCRIPT_NAME="GIG MOTD Dashboard"
readonly REMOTE_URL="https://dignezzz.github.io/server/dashboard.sh"

# Default paths (can be overridden by --not-root and OS detection)
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

# OS Detection variables
OS_TYPE=""           # debian, rhel, or unknown
OS_NAME=""           # Ubuntu, Debian, CentOS, AlmaLinux, etc.
OS_VERSION=""        # 20.04, 22.04, 10, 11, 12, 7, 8, 9
PACKAGE_MANAGER=""   # apt, yum, or dnf

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
# OS DETECTION
# ============================================================================

detect_os() {
    # Detect OS type and version
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_NAME="$NAME"
        OS_VERSION="${VERSION_ID:-unknown}"
        
        case "$ID" in
            ubuntu|debian)
                OS_TYPE="debian"
                PACKAGE_MANAGER="apt"
                ;;
            centos|rhel|almalinux|rocky)
                OS_TYPE="rhel"
                # CentOS 7 uses yum, CentOS 8+ and AlmaLinux use dnf
                if _exists dnf; then
                    PACKAGE_MANAGER="dnf"
                else
                    PACKAGE_MANAGER="yum"
                fi
                ;;
            *)
                OS_TYPE="unknown"
                PACKAGE_MANAGER="unknown"
                warning "Unknown OS: $ID. Some features may not work correctly."
                ;;
        esac
    else
        OS_TYPE="unknown"
        OS_NAME="Unknown Linux"
        OS_VERSION="unknown"
        PACKAGE_MANAGER="unknown"
        warning "Cannot detect OS. /etc/os-release not found."
    fi
    
    info "Detected: $OS_NAME $OS_VERSION ($OS_TYPE)"
}

setup_paths_for_os() {
    # Adjust paths based on OS type
    if [ "$INSTALL_USER_MODE" = true ]; then
        # User mode - same for all OS
        DASHBOARD_FILE="$HOME/.config/gig-motd/dashboard.sh"
        CONFIG_GLOBAL="$HOME/.motdrc"
        MOTD_CONFIG_TOOL="$HOME/.local/bin/motd-config"
        MOTD_VIEWER="$HOME/.local/bin/motd"
        return
    fi
    
    case "$OS_TYPE" in
        debian)
            # Debian/Ubuntu use /etc/update-motd.d/
            DASHBOARD_FILE="/etc/update-motd.d/99-dashboard"
            CONFIG_GLOBAL="/etc/motdrc"
            MOTD_CONFIG_TOOL="/usr/local/bin/motd-config"
            MOTD_VIEWER="/usr/local/bin/motd"
            ;;
        rhel)
            # CentOS/AlmaLinux use /etc/profile.d/
            DASHBOARD_FILE="/etc/profile.d/motd.sh"
            CONFIG_GLOBAL="/etc/motdrc"
            MOTD_CONFIG_TOOL="/usr/local/bin/motd-config"
            MOTD_VIEWER="/usr/local/bin/motd"
            ;;
        *)
            # Unknown OS - try /etc/profile.d/ as fallback
            DASHBOARD_FILE="/etc/profile.d/motd.sh"
            CONFIG_GLOBAL="/etc/motdrc"
            MOTD_CONFIG_TOOL="/usr/local/bin/motd-config"
            MOTD_VIEWER="/usr/local/bin/motd"
            warning "Using fallback paths for unknown OS"
            ;;
    esac
}

# ============================================================================
# HELP AND VERSION
# ============================================================================

show_help() {
    cat << EOF
$(_bold "$SCRIPT_NAME v$SCRIPT_VERSION")

$(_bold "USAGE:")
    $0 [OPTIONS]

$(_bold "SUPPORTED OS:")
    ✅ Ubuntu 20.04, 22.04, 24.04
    ✅ Debian 10, 11, 12
    ✅ CentOS 7, 8
    ✅ AlmaLinux 8, 9
    ✅ Rocky Linux 8, 9

$(_bold "OPTIONS:")
    --force         Skip confirmation prompts
    --not-root      Install in user's home directory
    --quiet         Minimal output
    --help          Show this help message
    --version       Show version information

$(_bold "EXAMPLES:")
    sudo bash dashboard.sh
    bash dashboard.sh --not-root
    bash <(wget -qO- $REMOTE_URL) --force

$(_bold "POST-INSTALLATION:")
    motd                  - View MOTD dashboard anytime
    motd --update         - Update to latest version
    motd --check-update   - Force check for updates
    motd-config           - Interactive configuration menu

$(_bold "FEATURES:")
    ✅ Multi-distro support: Debian, Ubuntu, CentOS, AlmaLinux, Rocky
    ✅ Interactive configuration with toggle switches [✓] / [ ]
    ✅ Progress bars for CPU, RAM, SWAP, Disk with color indicators
    ✅ System metrics: processes, zombie detection, I/O wait
    ✅ Network: traffic stats, IP addresses
    ✅ Security: last login, failed logins, Fail2ban stats
    ✅ Services monitoring: configurable list (nginx, mysql, redis, etc.)
    ✅ Docker: containers, volumes usage
    ✅ SSL certificates: expiry warnings (< 30 days)
    ✅ Additional disks: /home, /var, /data with progress bars
    ✅ Inodes monitoring: alerts when > 80%
    ✅ CPU temperature monitoring (if available)
    ✅ Auto-update checking (on every login)
    ✅ Fully configurable via /etc/motdrc or ~/.motdrc
    ✅ Optimized for fast loading

$(_bold "CONFIGURABLE SECTIONS (25 total):")
    SHOW_UPTIME, SHOW_LOAD, SHOW_CPU, SHOW_RAM, SHOW_SWAP, SHOW_DISK
    SHOW_ADDITIONAL_DISKS, SHOW_INODES, SHOW_PROCESSES
    SHOW_IO_WAIT, SHOW_NET, SHOW_IP, SHOW_CONNECTIONS
    SHOW_LAST_LOGIN, SHOW_FAILED_LOGINS, SHOW_DOCKER
    SHOW_DOCKER_VOLUMES, SHOW_SERVICES, SHOW_SSL_CERTS, SHOW_SSH
    SHOW_SECURITY, SHOW_UPDATES, SHOW_AUTOUPDATES, SHOW_FAIL2BAN_STATS, SHOW_TEMP

$(_bold "VERSION FORMAT:")
    YYYY.MM.DD.MINOR - Example: 2025.10.05.2
    - YYYY.MM.DD: Release date
    - MINOR: Incremental updates within the same day (1, 2, 3...)

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

# ============================================================================
# INITIALIZATION
# ============================================================================

# Detect OS and setup paths
detect_os
setup_paths_for_os

# Create directories if needed
if [ "$INSTALL_USER_MODE" = true ]; then
    mkdir -p "$(dirname "$DASHBOARD_FILE")" "$(dirname "$MOTD_CONFIG_TOOL")"
else
    # For RHEL-based systems, ensure /etc/profile.d exists
    if [ "$OS_TYPE" = "rhel" ]; then
        mkdir -p /etc/profile.d
    fi
fi


# === Функция: Установка CLI утилиты motd (viewer) ===
install_motd_viewer() {
    echo "📥 Установка команды motd в $MOTD_VIEWER"
    cat > "$MOTD_VIEWER" << 'EOF'
#!/bin/bash
# GIG MOTD Viewer - быстрый просмотр дашборда
DASHBOARD_FILE_GLOBAL="/etc/update-motd.d/99-dashboard"
DASHBOARD_FILE_USER="$HOME/.config/gig-motd/99-dashboard"
REMOTE_URL="https://dignezzz.github.io/server/dashboard.sh"

# Проверка аргументов
if [ "$1" = "--update" ] || [ "$1" = "-u" ]; then
    echo "🔄 Обновление GIG MOTD Dashboard..."
    if [ "$EUID" -eq 0 ]; then
        bash <(wget -qO- "$REMOTE_URL") --force
    else
        bash <(wget -qO- "$REMOTE_URL") --force --not-root
    fi
    exit $?
fi

if [ "$1" = "--check-update" ] || [ "$1" = "-c" ]; then
    echo "🔍 Проверка обновлений..."
fi

if [ -f "$DASHBOARD_FILE_GLOBAL" ]; then
    bash "$DASHBOARD_FILE_GLOBAL"
elif [ -f "$DASHBOARD_FILE_USER" ]; then
    bash "$DASHBOARD_FILE_USER"
else
    echo "❌ MOTD Dashboard не установлен"
    echo "💡 Установка: bash <(wget -qO- $REMOTE_URL)"
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
  SHOW_ADDITIONAL_DISKS
  SHOW_INODES
  SHOW_PROCESSES
  SHOW_IO_WAIT
  SHOW_NET
  SHOW_IP
  SHOW_CONNECTIONS
  SHOW_LAST_LOGIN
  SHOW_FAILED_LOGINS
  SHOW_DOCKER
  SHOW_DOCKER_VOLUMES
  SHOW_SERVICES
  SHOW_SSL_CERTS
  SHOW_SSH
  SHOW_SECURITY
  SHOW_UPDATES
  SHOW_AUTOUPDATES
  SHOW_FAIL2BAN_STATS
  SHOW_TEMP
)

# Descriptions for each option
declare -A DESCRIPTIONS=(
  ["SHOW_UPTIME"]="System uptime (days, hours)"
  ["SHOW_LOAD"]="Load average (1m, 5m, 15m)"
  ["SHOW_CPU"]="CPU usage with progress bar"
  ["SHOW_RAM"]="RAM usage with progress bar"
  ["SHOW_SWAP"]="SWAP usage with progress bar"
  ["SHOW_DISK"]="Root disk (/) usage"
  ["SHOW_ADDITIONAL_DISKS"]="Additional disks (/home, /var, /data)"
  ["SHOW_INODES"]="Inodes usage (warns at >80%)"
  ["SHOW_PROCESSES"]="Running/zombie processes count"
  ["SHOW_IO_WAIT"]="Disk I/O wait percentage"
  ["SHOW_NET"]="Network traffic (RX/TX)"
  ["SHOW_IP"]="Public and local IP addresses"
  ["SHOW_CONNECTIONS"]="Active network connections (slow)"
  ["SHOW_LAST_LOGIN"]="Last login info (user, IP, time)"
  ["SHOW_FAILED_LOGINS"]="Failed SSH login attempts"
  ["SHOW_DOCKER"]="Docker containers status"
  ["SHOW_DOCKER_VOLUMES"]="Docker volumes disk usage"
  ["SHOW_SERVICES"]="Services status (nginx, mysql, etc.)"
  ["SHOW_SSL_CERTS"]="SSL certificates expiry (warns <30 days)"
  ["SHOW_SSH"]="SSH port and configuration"
  ["SHOW_SECURITY"]="Security settings (root login, etc.)"
  ["SHOW_UPDATES"]="Available system updates"
  ["SHOW_AUTOUPDATES"]="Auto-updates status"
  ["SHOW_FAIL2BAN_STATS"]="Fail2ban banned IPs count"
  ["SHOW_TEMP"]="CPU temperature (if available)"
)

print_menu() {
  echo "🔧 Настройка GIG MOTD"
  echo "1) Настроить отображаемые блоки"
  echo "2) Удалить MOTD-дашборд"
  echo "0) Выход"
}

configure_blocks() {
  # Load current settings
  declare -A settings
  
  # Set defaults
  for VAR in "${OPTIONS[@]}"; do
    settings[$VAR]="true"
  done
  
  # Load existing config if present
  if [ -f "$TARGET_FILE" ]; then
    while IFS='=' read -r key value; do
      key=$(echo "$key" | xargs)  # trim whitespace
      value=$(echo "$value" | xargs)
      if [[ -n "$key" && "$key" != \#* ]]; then
        settings[$key]="$value"
      fi
    done < "$TARGET_FILE"
  fi
  
  # Interactive menu loop
  while true; do
    clear
    echo "=============================================================="
    echo "🔧 Настройка GIG MOTD Dashboard"
    echo "=============================================================="
    echo ""
    echo "Выбери номер пункта для переключения (✓/✗):"
    echo ""
    
    local idx=1
    for VAR in "${OPTIONS[@]}"; do
      local status="${settings[$VAR]:-true}"
      local symbol
      
      if [ "$status" = "true" ]; then
        symbol="[✓]"
      else
        symbol="[ ]"
      fi
      
      # Format option name for display
      local display_name="${VAR#SHOW_}"
      display_name="${display_name//_/ }"
      
      # Get description
      local desc="${DESCRIPTIONS[$VAR]}"
      
      printf "%2d) %s %-20s - %s\n" "$idx" "$symbol" "$display_name" "$desc"
      ((idx++))
    done
    
    echo ""
    echo "=============================================================="
    echo " s) Сохранить и выйти"
    echo " 0) Выйти без сохранения"
    echo "=============================================================="
    echo ""
    read -p "Выбор: " choice
    
    case "$choice" in
      s|S)
        # Save settings
        {
          echo "# GIG MOTD Dashboard Configuration"
          echo "# Generated: $(date '+%Y-%m-%d %H:%M:%S')"
          echo ""
          for VAR in "${OPTIONS[@]}"; do
            echo "$VAR=${settings[$VAR]}"
          done
        } > "$TARGET_FILE"
        echo ""
        echo "✅ Настройки сохранены в $TARGET_FILE"
        sleep 1
        return 0
        ;;
      0)
        echo "❌ Выход без сохранения"
        sleep 1
        return 1
        ;;
      ''|*[!0-9]*)
        # Invalid input
        continue
        ;;
      *)
        # Toggle option
        if [ "$choice" -ge 1 ] && [ "$choice" -le "${#OPTIONS[@]}" ]; then
          local var_idx=$((choice - 1))
          local var_name="${OPTIONS[$var_idx]}"
          
          if [ "${settings[$var_name]}" = "true" ]; then
            settings[$var_name]="false"
          else
            settings[$var_name]="true"
          fi
        fi
        ;;
    esac
  done
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
# GIG MOTD Dashboard Configuration
# Set to 'true' or 'false' to enable/disable each section

# === System Information ===
SHOW_UPTIME=true
SHOW_LOAD=true
SHOW_CPU=true
SHOW_RAM=true
SHOW_SWAP=true
SHOW_DISK=true
SHOW_ADDITIONAL_DISKS=true
SHOW_INODES=false         # Отключено по умолчанию (специфичная метрика)
SHOW_PROCESSES=true
SHOW_IO_WAIT=true
SHOW_TEMP=true

# === Network Information ===
SHOW_NET=true
SHOW_IP=true
SHOW_CONNECTIONS=false    # Отключено по умолчанию (ss -tun может быть медленным)

# === Security & Access ===
SHOW_LAST_LOGIN=true
SHOW_FAILED_LOGINS=true
SHOW_SSH=true
SHOW_SECURITY=true
SHOW_FAIL2BAN_STATS=true

# === Services & Docker ===
SHOW_DOCKER=true
SHOW_DOCKER_VOLUMES=true
SHOW_SERVICES=true
SHOW_SSL_CERTS=true

# === Updates ===
SHOW_UPDATES=true
SHOW_AUTOUPDATES=true

# === Advanced Settings ===
# Comma-separated list of services to monitor
MONITORED_SERVICES=nginx,mysql,postgresql,redis,docker,fail2ban

# Path to SSL certificates directory
SSL_CERT_PATHS=/etc/letsencrypt/live

# SSL certificate expiry warning threshold (days)
SSL_WARN_DAYS=30
EOF
        echo "✅ Создан глобальный конфиг: $CONFIG_GLOBAL"
    else
        echo "ℹ️ Глобальный конфиг уже существует: $CONFIG_GLOBAL"
    fi
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

# Parse command line arguments
parse_arguments "$@"

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


CURRENT_VERSION="2025.10.06.5"
REMOTE_URL="https://dignezzz.github.io/server/dashboard.sh"

# Проверка обновлений (каждый раз при входе)
REMOTE_VERSION=$(timeout 3 curl -s "$REMOTE_URL" 2>/dev/null | grep '^CURRENT_VERSION=' | head -n1 | cut -d= -f2 | tr -d '"')

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
: "${SHOW_TOP_PROCESSES:=false}"
: "${SHOW_FAIL2BAN_STATS:=true}"
: "${SHOW_TEMP:=true}"
: "${SHOW_PROCESSES:=true}"
: "${SHOW_LAST_LOGIN:=true}"
: "${SHOW_CONNECTIONS:=false}"
: "${SHOW_NTP:=false}"
: "${SHOW_INODES:=false}"
: "${SHOW_SERVICES:=true}"
: "${SHOW_ADDITIONAL_DISKS:=true}"
: "${SHOW_SSL_CERTS:=true}"
: "${SHOW_IO_WAIT:=true}"
: "${SHOW_FAILED_LOGINS:=true}"
: "${SHOW_DOCKER_VOLUMES:=true}"

# Настройка сервисов для мониторинга (через запятую)
: "${MONITORED_SERVICES:=nginx,mysql,postgresql,redis,docker,fail2ban}"

# Путь к SSL сертификатам (через запятую)
: "${SSL_CERT_PATHS:=/etc/letsencrypt/live}"

# Порог для предупреждения о сертификатах (дни)
: "${SSL_WARN_DAYS:=30}"

# === Рандомный выбор стиля прогресс-бара ===
BAR_STYLE=$((RANDOM % 6))
case $BAR_STYLE in
    0) BAR_FILLED_CHAR="=" BAR_EMPTY_CHAR="-" ;;  # [=============-------------]
    1) BAR_FILLED_CHAR="#" BAR_EMPTY_CHAR="." ;;  # [#############.............]
    2) BAR_FILLED_CHAR="*" BAR_EMPTY_CHAR="." ;;  # [*************..............]
    3) BAR_FILLED_CHAR=">" BAR_EMPTY_CHAR="." ;;  # [>>>>>>>>>>>>>.............]
    4) BAR_FILLED_CHAR="o" BAR_EMPTY_CHAR="." ;;  # [ooooooooooooo.............]
    5) BAR_FILLED_CHAR="+" BAR_EMPTY_CHAR="-" ;;  # [+++++++++++++-------------]
esac

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
    printf "%${filled}s" | tr ' ' "$BAR_FILLED_CHAR"
    printf "%${empty}s" | tr ' ' "$BAR_EMPTY_CHAR"
    printf "]\033[0m %3d%%" "$percent"
}

# === Сбор данных ===
uptime_str=$(uptime -p)
loadavg=$(cut -d ' ' -f1-3 /proc/loadavg)
cpu_cores=$(nproc)

# CPU (только если включено)
if [ "$SHOW_CPU" = true ]; then
    cpu_percent=$(top -bn2 -d 0.5 | grep "Cpu(s)" | tail -n1 | awk '{print 100 - $8}' | cut -d. -f1)
    cpu_temp=""
    if [ -f /sys/class/thermal/thermal_zone0/temp ]; then
        temp_raw=$(cat /sys/class/thermal/thermal_zone0/temp)
        temp_c=$((temp_raw / 1000))
        cpu_temp=" | ${temp_c}°C"
    fi
fi

# RAM (только если включено)
if [ "$SHOW_RAM" = true ]; then
    mem_total=$(free -m | awk '/Mem:/ {print $2}')
    mem_used=$(free -m | awk '/Mem:/ {print $3}')
    mem_percent=$((mem_used * 100 / mem_total))
    mem_data="${mem_used}MB / ${mem_total}MB"
fi

# SWAP (только если включено)
if [ "$SHOW_SWAP" = true ]; then
    swap_total=$(free -m | awk '/Swap:/ {print $2}')
    swap_used=$(free -m | awk '/Swap:/ {print $3}')
    swap_percent=0
    swap_data="not configured"
    if [ "$swap_total" -gt 0 ]; then
        swap_percent=$((swap_used * 100 / swap_total))
        swap_data="${swap_used}MB / ${swap_total}MB"
    fi
fi

# Disk (только если включено)
if [ "$SHOW_DISK" = true ]; then
    disk_used=$(df -h / | awk 'NR==2 {print $5}' | tr -d '%')
    disk_percent=$disk_used
    disk_total=$(df -h / | awk 'NR==2 {print $2}')
    disk_used_space=$(df -h / | awk 'NR==2 {print $3}')
    disk_data="${disk_used_space} / ${disk_total}"
fi

# Network (только если включено)
if [ "$SHOW_NET" = true ]; then
    traffic=$(vnstat --oneline 2>/dev/null | awk -F\; '{print $10 " ↓ / " $11 " ↑"}')
fi

# IP адреса (только если включено)
if [ "$SHOW_IP" = true ]; then
    ip_local=$(hostname -I | awk '{print $1}')
    ip_public=$(curl -s ifconfig.me || echo "n/a")
    ip6=$(ip -6 addr show scope global | grep inet6 | awk '{print $2}' | cut -d/ -f1 | head -n1)
    [ -z "$ip6" ] && ip6="n/a"
fi

# Top процессы (только если включено)
if [ "$SHOW_TOP_PROCESSES" = true ]; then
    top_cpu=$(ps aux --sort=-%cpu | awk 'NR>1 {print $11}' | head -n 3 | paste -sd ', ')
    top_mem=$(ps aux --sort=-%mem | awk 'NR>1 {print $11}' | head -n 3 | paste -sd ', ')
fi

# Fail2ban статистика
fail2ban_banned=0
if command -v fail2ban-client &>/dev/null; then
    fail2ban_banned=$(fail2ban-client status 2>/dev/null | grep "Jail list" | sed 's/.*://;s/,//g' | xargs -n1 fail2ban-client status 2>/dev/null | grep "Currently banned" | awk '{s+=$NF} END {print s+0}')
fi

# === НОВЫЕ МЕТРИКИ ===

# Процессы (только если включено)
if [ "$SHOW_PROCESSES" = true ]; then
    processes_total=$(ps aux | wc -l)
    processes_zombie=$(ps aux | awk '$8=="Z"' | wc -l)
    processes_running=$(ps aux | awk '$8=="R"' | wc -l)
fi

# Последний логин (только если включено)
if [ "$SHOW_LAST_LOGIN" = true ]; then
    if [ -f /var/log/wtmp ]; then
        last_login=$(last -n 1 -w | head -n 1 | awk '{printf "%s from %s at %s %s %s", $1, $3, $5, $6, $7}')
    else
        last_login="n/a"
    fi
fi

# Неудачные попытки входа за 24ч (только если включено)
if [ "$SHOW_FAILED_LOGINS" = true ]; then
    failed_logins=0
    if [ -f /var/log/auth.log ]; then
        failed_logins=$(grep "Failed password" /var/log/auth.log 2>/dev/null | grep "$(date +%b) $(date +%d)" | wc -l)
    elif [ -f /var/log/secure ]; then
        failed_logins=$(grep "Failed password" /var/log/secure 2>/dev/null | grep "$(date +%b) $(date +%d)" | wc -l)
    fi
fi

# Активные соединения (только если включено)
if [ "$SHOW_CONNECTIONS" = true ]; then
    connections_total=$(ss -tun | wc -l)
    connections_established=$(ss -tun state established | wc -l)
fi

# NTP синхронизация (только если включено)
if [ "$SHOW_NTP" = true ]; then
    ntp_status="$fail not synchronized"
    ntp_server="n/a"
    if command -v timedatectl &>/dev/null; then
        if timedatectl status | grep -q "synchronized: yes"; then
            ntp_status="$ok synchronized"
            ntp_server=$(timedatectl status | grep "NTP service" | awk '{print $3}')
            [ -z "$ntp_server" ] && ntp_server="systemd-timesyncd"
        fi
    elif command -v ntpq &>/dev/null; then
        if ntpq -p &>/dev/null; then
            ntp_status="$ok synchronized"
            ntp_server=$(ntpq -p 2>/dev/null | grep '^*' | awk '{print $1}' | tr -d '*')
        fi
    fi
fi

# Inode usage (только если включено)
if [ "$SHOW_INODES" = true ]; then
    inodes_total=$(df -i / | awk 'NR==2 {print $2}')
    inodes_used=$(df -i / | awk 'NR==2 {print $3}')
    inodes_percent=$(df -i / | awk 'NR==2 {print $5}' | tr -d '%')
    inodes_data="${inodes_used} / ${inodes_total}"
fi

# Статус сервисов (только если включено)
if [ "$SHOW_SERVICES" = true ]; then
    services_status=""
    services_down=""
    IFS=',' read -ra SERVICES <<< "$MONITORED_SERVICES"
    for service in "${SERVICES[@]}"; do
        service=$(echo "$service" | xargs) # trim whitespace
        if systemctl is-active "$service" &>/dev/null; then
            services_status="${services_status}$ok ${service} "
        elif systemctl list-unit-files | grep -q "^${service}.service"; then
            services_status="${services_status}$fail ${service} "
            services_down="${services_down}${service}, "
        fi
    done
    services_down=$(echo "$services_down" | sed 's/, $//')
fi

# Дополнительные диски (только если включено)
if [ "$SHOW_ADDITIONAL_DISKS" = true ]; then
    additional_disks=""
    while IFS= read -r line; do
        mountpoint=$(echo "$line" | awk '{print $6}')
        if [[ "$mountpoint" != "/" && "$mountpoint" =~ ^/(home|var|data|mnt|opt|backup) ]]; then
            disk_use=$(echo "$line" | awk '{print $5}' | tr -d '%')
            disk_size=$(echo "$line" | awk '{print $2}')
            disk_used_sp=$(echo "$line" | awk '{print $3}')
            additional_disks="${additional_disks}${mountpoint}:${disk_use}:${disk_used_sp}:${disk_size}|"
        fi
    done < <(df -h | grep '^/')
fi

# SSL сертификаты (только если включено)
if [ "$SHOW_SSL_CERTS" = true ]; then
    ssl_expiring=""
    if [ -d "$SSL_CERT_PATHS" ]; then
        for cert_dir in "$SSL_CERT_PATHS"/*; do
            if [ -d "$cert_dir" ]; then
                cert_file="$cert_dir/cert.pem"
                if [ -f "$cert_file" ]; then
                    domain=$(basename "$cert_dir")
                    expiry_date=$(openssl x509 -in "$cert_file" -noout -enddate 2>/dev/null | cut -d= -f2)
                    if [ -n "$expiry_date" ]; then
                        expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null)
                        now_epoch=$(date +%s)
                        days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
                        if [ "$days_left" -lt "$SSL_WARN_DAYS" ]; then
                            if [ "$days_left" -lt 7 ]; then
                                ssl_expiring="${ssl_expiring}$fail ${domain} (${days_left}d) "
                            else
                                ssl_expiring="${ssl_expiring}$warn ${domain} (${days_left}d) "
                        fi
                    fi
                fi
            fi
        fi
    done
    fi
    [ -z "$ssl_expiring" ] && ssl_expiring="$ok all certificates valid"
fi

# I/O Wait (только если включено)
if [ "$SHOW_IO_WAIT" = true ]; then
    io_wait=$(top -bn1 | grep "Cpu(s)" | awk '{print $10}' | tr -d '%wa,')
    io_wait_status="$ok low"
    if (( $(echo "$io_wait > 20" | bc -l 2>/dev/null || echo 0) )); then
        io_wait_status="$fail high"
    elif (( $(echo "$io_wait > 10" | bc -l 2>/dev/null || echo 0) )); then
        io_wait_status="$warn moderate"
    fi
fi

# Docker volumes (только если включено)
if [ "$SHOW_DOCKER_VOLUMES" = true ]; then
    docker_volumes_usage=""
    if command -v docker &>/dev/null; then
        docker_volumes_count=$(docker volume ls -q 2>/dev/null | wc -l)
    if [ "$docker_volumes_count" -gt 0 ]; then
        # Метод 1: через docker system df
        docker_volumes_size=$(docker system df 2>/dev/null | grep "Local Volumes" | awk '{print $3}')
        
        # Метод 2: если не получилось, считаем через du
        if [ -z "$docker_volumes_size" ] || [ "$docker_volumes_size" = "0B" ] || [ "$docker_volumes_size" = "0" ]; then
            # Получаем путь к volumes
            volumes_path="/var/lib/docker/volumes"
            if [ -d "$volumes_path" ]; then
                # Считаем размер через du
                total_kb=$(du -sk "$volumes_path" 2>/dev/null | awk '{print $1}')
                if [ -n "$total_kb" ] && [ "$total_kb" -gt 0 ]; then
                    # Конвертируем в человекочитаемый формат
                    if [ "$total_kb" -gt 1048576 ]; then
                        docker_volumes_size="$((total_kb / 1048576))GB"
                    elif [ "$total_kb" -gt 1024 ]; then
                        docker_volumes_size="$((total_kb / 1024))MB"
                    else
                        docker_volumes_size="${total_kb}KB"
                    fi
                fi
            fi
        fi
        
        # Формируем вывод
        if [ -n "$docker_volumes_size" ] && [ "$docker_volumes_size" != "0B" ] && [ "$docker_volumes_size" != "0" ]; then
            docker_volumes_usage="$docker_volumes_count volumes ($docker_volumes_size)"
        else
            docker_volumes_usage="$docker_volumes_count volumes"
        fi
    fi
    fi
fi

# Docker containers (только если включено)
if [ "$SHOW_DOCKER" = true ]; then
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
fi

# SSH info (только если включено)
if [ "$SHOW_SSH" = true ] || [ "$SHOW_SECURITY" = true ]; then
    ssh_users=$(who | wc -l)
    ssh_ips=$(who | awk '{print $5}' | tr -d '()' | sort | uniq | paste -sd ', ' -)
fi

# Fail2ban (только если включено)
if [ "$SHOW_FAIL2BAN_STATS" = true ]; then
    if command -v fail2ban-client &>/dev/null; then
        fail2ban_status="$ok active"
    else
        fail2ban_status="$fail not installed"
    fi
fi

# Firewall (только если включено для Security блока) - адаптировано для разных ОС
if [ "$SHOW_SECURITY" = true ]; then
    if [ "$OS_TYPE" = "debian" ]; then
        # Debian/Ubuntu: UFW
        if command -v ufw &>/dev/null; then
            ufw_status=$(ufw status | grep -i "Status" | awk '{print $2}')
            if [[ "$ufw_status" == "active" ]]; then
                ufw_status="$ok UFW enabled"
            else
                ufw_status="$fail UFW disabled"
            fi
        else
            ufw_status="$fail UFW not installed"
        fi
    elif [ "$OS_TYPE" = "rhel" ]; then
        # RHEL/CentOS/AlmaLinux: firewalld
        if command -v firewall-cmd &>/dev/null; then
            if systemctl is-active firewalld &>/dev/null; then
                ufw_status="$ok firewalld enabled"
            else
                ufw_status="$fail firewalld disabled"
            fi
        else
            ufw_status="$fail firewalld not installed"
        fi
    else
        ufw_status="$warn unknown OS"
    fi
fi

# Security блок - CrowdSec, SSH, Root login, Password auth (только если включено)
if [ "$SHOW_SECURITY" = true ]; then
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
fi

# Обновления (только если включено) - адаптировано для разных ОС
if [ "$SHOW_UPDATES" = true ]; then
    if [ "$OS_TYPE" = "debian" ]; then
        updates=$(apt list --upgradable 2>/dev/null | grep -v "Listing" | wc -l)
        update_msg="${updates} package(s) can be updated"
    elif [ "$OS_TYPE" = "rhel" ]; then
        if command -v dnf &>/dev/null; then
            updates=$(dnf check-update -q 2>/dev/null | grep -v "^$" | grep -v "^Last metadata" | wc -l)
        else
            updates=$(yum check-update -q 2>/dev/null | grep -v "^$" | grep -v "^Loaded plugins" | wc -l)
        fi
        update_msg="${updates} package(s) can be updated"
    else
        update_msg="unknown OS"
    fi
fi

# Автообновления (только если включено) - адаптировано для разных ОС
if [ "$SHOW_AUTOUPDATES" = true ]; then
    auto_update_status=""
    
    if [ "$OS_TYPE" = "debian" ]; then
        # Debian/Ubuntu: unattended-upgrades
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
        
    elif [ "$OS_TYPE" = "rhel" ]; then
        # RHEL/CentOS/AlmaLinux: dnf-automatic или yum-cron
        if command -v dnf &>/dev/null; then
            # CentOS 8+, AlmaLinux, Rocky
            if rpm -q dnf-automatic &>/dev/null; then
                if systemctl is-enabled dnf-automatic.timer &>/dev/null; then
                    auto_update_status="$ok enabled"
                else
                    auto_update_status="$warn installed, timer disabled"
                fi
            else
                auto_update_status="$fail dnf-automatic not installed"
            fi
        else
            # CentOS 7
            if rpm -q yum-cron &>/dev/null; then
                if systemctl is-active yum-cron &>/dev/null; then
                    auto_update_status="$ok enabled"
                else
                    auto_update_status="$warn installed, service disabled"
                fi
            else
                auto_update_status="$fail yum-cron not installed"
            fi
        fi
    else
        auto_update_status="$warn unknown OS"
    fi
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
      echo "$cpu_temp"
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
    processes)
      local proc_msg="${processes_total} total, ${processes_running} running"
      [ "$processes_zombie" -gt 0 ] && proc_msg="$proc_msg, $fail ${processes_zombie} zombie" || proc_msg="$proc_msg, 0 zombie"
      print_row "Processes" "$proc_msg"
      ;;
    last_login)
      print_row "Last Login" "$last_login"
      ;;
    failed_logins)
      if [ "$failed_logins" -gt 0 ]; then
        print_row "Failed Logins (24h)" "$warn $failed_logins attempts"
      fi
      ;;
    connections)
      print_row "Connections" "$connections_total total, $connections_established ESTABLISHED"
      ;;
    ntp)
      print_row "Time Sync" "$ntp_status ($ntp_server)"
      ;;
    inodes)
      if [ "$inodes_percent" -ge 80 ]; then
        printf " %-20s : " "Inodes /"
        draw_bar "$inodes_percent"
        echo " $inodes_data"
      fi
      ;;
    services)
      if [ -n "$services_status" ]; then
        print_row "Services" "$services_status"
      fi
      ;;
    additional_disks)
      if [ -n "$additional_disks" ]; then
        IFS='|' read -ra DISKS <<< "$additional_disks"
        for disk_info in "${DISKS[@]}"; do
          if [ -n "$disk_info" ]; then
            IFS=':' read -r mountpoint disk_pct disk_used_sp disk_size <<< "$disk_info"
            printf " %-20s : " "Disk ${mountpoint}"
            draw_bar "$disk_pct"
            echo " ${disk_used_sp} / ${disk_size}"
          fi
        done
      fi
      ;;
    ssl_certs)
      if [[ "$ssl_expiring" != *"all certificates valid"* ]]; then
        print_row "SSL Certificates" "$ssl_expiring"
      fi
      ;;
    io_wait)
      print_row "I/O Wait" "${io_wait}% ($io_wait_status)"
      ;;
    docker_volumes)
      if [ -n "$docker_volumes_usage" ]; then
        print_row "Docker Volumes" "$docker_volumes_usage"
      fi
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
      print_row "Firewall" "$ufw_status"
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
[ "$SHOW_ADDITIONAL_DISKS" = true ] && print_section additional_disks
[ "$SHOW_INODES" = true ] && print_section inodes
[ "$SHOW_PROCESSES" = true ] && print_section processes
[ "$SHOW_TOP_PROCESSES" = true ] && print_section top_processes
[ "$SHOW_IO_WAIT" = true ] && print_section io_wait
[ "$SHOW_NET" = true ] && print_section net
[ "$SHOW_IP" = true ] && print_section ip
[ "$SHOW_CONNECTIONS" = true ] && print_section connections
[ "$SHOW_LAST_LOGIN" = true ] && print_section last_login
[ "$SHOW_FAILED_LOGINS" = true ] && print_section failed_logins
[ "$SHOW_NTP" = true ] && print_section ntp
[ "$SHOW_DOCKER" = true ] && print_section docker
[ "$SHOW_DOCKER_VOLUMES" = true ] && print_section docker_volumes
[ "$SHOW_SERVICES" = true ] && print_section services
[ "$SHOW_SSL_CERTS" = true ] && print_section ssl_certs
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
    
    # Отключение стандартного MOTD только для Debian/Ubuntu
    if [ "$OS_TYPE" = "debian" ]; then
        info "Отключение стандартных скриптов Ubuntu MOTD..."
        chmod -x /etc/update-motd.d/00-header 2>/dev/null || true
        chmod -x /etc/update-motd.d/10-help-text 2>/dev/null || true
        chmod -x /etc/update-motd.d/50-landscape-sysinfo 2>/dev/null || true
        chmod -x /etc/update-motd.d/50-motd-news 2>/dev/null || true
        chmod -x /etc/update-motd.d/80-livepatch 2>/dev/null || true
        chmod -x /etc/update-motd.d/90-updates-available 2>/dev/null || true
        chmod -x /etc/update-motd.d/91-release-upgrade 2>/dev/null || true
        chmod -x /etc/update-motd.d/95-hwe-eol 2>/dev/null || true
    fi
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
    if [ "$OS_TYPE" = "debian" ]; then
        echo "👉 Будут отключены все стандартные скрипты Ubuntu/Debian MOTD"
    fi
    read -p '❓ Установить этот MOTD-дэшборд? [y/N]: ' confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        mv "$TMP_FILE" "$DASHBOARD_FILE"
if [ "$INSTALL_USER_MODE" = false ]; then
    chmod +x "$DASHBOARD_FILE"
    
    # Отключение стандартного MOTD только для Debian/Ubuntu
    if [ "$OS_TYPE" = "debian" ]; then
        info "Отключение стандартных скриптов Ubuntu/Debian MOTD..."
        chmod -x /etc/update-motd.d/00-header 2>/dev/null || true
        chmod -x /etc/update-motd.d/10-help-text 2>/dev/null || true
        chmod -x /etc/update-motd.d/50-landscape-sysinfo 2>/dev/null || true
        chmod -x /etc/update-motd.d/50-motd-news 2>/dev/null || true
        chmod -x /etc/update-motd.d/80-livepatch 2>/dev/null || true
        chmod -x /etc/update-motd.d/90-updates-available 2>/dev/null || true
        chmod -x /etc/update-motd.d/91-release-upgrade 2>/dev/null || true
        chmod -x /etc/update-motd.d/95-hwe-eol 2>/dev/null || true
    fi
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
