#!/bin/bash

# ============================================================================
# GIG MOTD Dashboard - Installation & Management Script
# ============================================================================
# Description: Modern, configurable MOTD dashboard for Linux servers
# Author: DigneZzZ - https://gig.ovh
# Version: 2025.12.18.3
# License: MIT
# ============================================================================

set -euo pipefail  # Exit on error, undefined variable, pipe failure

# ============================================================================
# CONSTANTS
# ============================================================================
readonly SCRIPT_VERSION="2026.03.18.1"
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
    
    # Root mode - common paths for all OS
    CONFIG_GLOBAL="/etc/motdrc"
    MOTD_CONFIG_TOOL="/usr/local/bin/motd-config"
    MOTD_VIEWER="/usr/local/bin/motd"
    
    # Only DASHBOARD_FILE differs between OS
    case "$OS_TYPE" in
        debian)
            DASHBOARD_FILE="/etc/update-motd.d/99-dashboard"
            ;;
        rhel|*)
            DASHBOARD_FILE="/etc/profile.d/motd.sh"
            [ "$OS_TYPE" = "unknown" ] && warning "Using fallback paths for unknown OS"
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
    ✅ NetBird VPN: status, IP, peers, features (DNS, Rosenpass, Routes)
    ✅ Fully configurable via /etc/motdrc or ~/.motdrc
    ✅ Optimized for fast loading

$(_bold "CONFIGURABLE SECTIONS (26 total):")
    SHOW_UPTIME, SHOW_LOAD, SHOW_CPU, SHOW_RAM, SHOW_SWAP, SHOW_DISK
    SHOW_ADDITIONAL_DISKS, SHOW_INODES, SHOW_PROCESSES
    SHOW_IO_WAIT, SHOW_NET, SHOW_IP, SHOW_CONNECTIONS
    SHOW_LAST_LOGIN, SHOW_FAILED_LOGINS, SHOW_DOCKER
    SHOW_DOCKER_VOLUMES, SHOW_SERVICES, SHOW_SSL_CERTS, SHOW_SSH
    SHOW_SECURITY, SHOW_UPDATES, SHOW_AUTOUPDATES, SHOW_FAIL2BAN_STATS, SHOW_TEMP
    SHOW_NETBIRD

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
DASHBOARD_FILE_DEBIAN="/etc/update-motd.d/99-dashboard"
DASHBOARD_FILE_RHEL="/etc/profile.d/motd.sh"
DASHBOARD_FILE_USER="$HOME/.config/gig-motd/dashboard.sh"
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
    rm -f /tmp/motd-update-available /tmp/motd-remote-version 2>/dev/null
fi

if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    echo "Usage: motd [OPTIONS]"
    echo "  --update, -u      Update to latest version"
    echo "  --check-update    Force check for updates"
    echo "  --help, -h        Show this help"
    exit 0
fi

# Выбираем файл дашборда в порядке приоритета
DASHBOARD_FILE=""
if [ -f "$DASHBOARD_FILE_DEBIAN" ]; then
    DASHBOARD_FILE="$DASHBOARD_FILE_DEBIAN"
elif [ -f "$DASHBOARD_FILE_RHEL" ]; then
    DASHBOARD_FILE="$DASHBOARD_FILE_RHEL"
elif [ -f "$DASHBOARD_FILE_USER" ]; then
    DASHBOARD_FILE="$DASHBOARD_FILE_USER"
fi

if [ -n "$DASHBOARD_FILE" ]; then
    bash "$DASHBOARD_FILE"
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
  SHOW_NETBIRD
)

# Descriptions for each option
# Зависимости для опций (пакет => команда для проверки)
declare -A DEPENDENCIES=(
  ["SHOW_NET"]="vnstat"
  ["SHOW_DOCKER"]="docker"
  ["SHOW_DOCKER_VOLUMES"]="docker"
  ["SHOW_FAIL2BAN_STATS"]="fail2ban-client"
  ["SHOW_NETBIRD"]="netbird"
)

# Пакеты для установки
declare -A PACKAGES=(
  ["vnstat"]="vnstat"
  ["docker"]="docker.io"
  ["fail2ban-client"]="fail2ban"
)

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
  ["SHOW_NET"]="Network traffic RX/TX (требует vnstat)"
  ["SHOW_IP"]="Public and local IP addresses"
  ["SHOW_CONNECTIONS"]="Active network connections (slow)"
  ["SHOW_LAST_LOGIN"]="Last login info (user, IP, time)"
  ["SHOW_FAILED_LOGINS"]="Failed SSH login attempts"
  ["SHOW_DOCKER"]="Docker containers status (требует docker)"
  ["SHOW_DOCKER_VOLUMES"]="Docker volumes disk usage (требует docker)"
  ["SHOW_SERVICES"]="Services status (nginx, mysql, etc.)"
  ["SHOW_SSL_CERTS"]="SSL certificates expiry (warns <30 days)"
  ["SHOW_SSH"]="SSH port and configuration"
  ["SHOW_SECURITY"]="Security settings (root login, etc.)"
  ["SHOW_UPDATES"]="Available system updates"
  ["SHOW_AUTOUPDATES"]="Auto-updates status"
  ["SHOW_FAIL2BAN_STATS"]="Fail2ban banned IPs count (требует fail2ban)"
  ["SHOW_TEMP"]="CPU temperature (if available)"
  ["SHOW_NETBIRD"]="NetBird VPN status, IP and peers (требует netbird)"
)

# Функция проверки зависимости
check_dependency() {
  local option="$1"
  local dep="${DEPENDENCIES[$option]:-}"
  [ -z "$dep" ] && return 0  # Нет зависимости
  command -v "$dep" &>/dev/null
}

# Функция установки зависимости
install_dependency() {
  local cmd="$1"
  local pkg="${PACKAGES[$cmd]:-$cmd}"
  
  echo ""
  if [ "$EUID" -eq 0 ]; then
    echo "📦 Устанавливаю $pkg..."
    if command -v apt-get &>/dev/null; then
      apt-get update -qq && apt-get install -y "$pkg" >/dev/null 2>&1
    elif command -v dnf &>/dev/null; then
      dnf install -y "$pkg" >/dev/null 2>&1
    elif command -v yum &>/dev/null; then
      yum install -y "$pkg" >/dev/null 2>&1
    fi
    
    if command -v "$cmd" &>/dev/null; then
      echo "✅ $pkg успешно установлен"
      # Для vnstat нужно запустить сервис
      if [ "$cmd" = "vnstat" ]; then
        systemctl enable vnstat >/dev/null 2>&1 || true
        systemctl start vnstat >/dev/null 2>&1 || true
        echo "ℹ️  Статистика трафика начнёт собираться через несколько минут"
      fi
      sleep 1
      return 0
    else
      echo "❌ Не удалось установить $pkg"
      sleep 2
      return 1
    fi
  else
    echo "⚠️  Для $pkg требуются права root"
    echo "   Установи вручную: sudo apt install $pkg -y"
    sleep 2
    return 1
  fi
}

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
      local dep_status=""
      
      if [ "$status" = "true" ]; then
        symbol="[✓]"
      else
        symbol="[ ]"
      fi
      
      # Проверяем статус зависимости
      local dep="${DEPENDENCIES[$VAR]:-}"
      if [ -n "$dep" ]; then
        if command -v "$dep" &>/dev/null; then
          dep_status=" ✅"
        else
          dep_status=" ⚠️ нет $dep"
        fi
      fi
      
      # Format option name for display
      local display_name="${VAR#SHOW_}"
      display_name="${display_name//_/ }"
      
      # Get description
      local desc="${DESCRIPTIONS[$VAR]}"
      
      printf "%2d) %s %-20s - %s%s\n" "$idx" "$symbol" "$display_name" "$desc" "$dep_status"
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
            # Проверяем зависимость перед включением
            local dep="${DEPENDENCIES[$var_name]:-}"
            if [ -n "$dep" ] && ! command -v "$dep" &>/dev/null; then
              echo ""
              echo "⚠️  Для опции $var_name требуется: $dep"
              read -p "   Установить сейчас? (y/N): " install_confirm
              if [[ "$install_confirm" =~ ^[Yy]$ ]]; then
                if install_dependency "$dep"; then
                  settings[$var_name]="true"
                fi
              else
                echo "ℹ️  Опция будет включена, но может не работать без $dep"
                sleep 1
                settings[$var_name]="true"
              fi
            else
              settings[$var_name]="true"
            fi
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
EOF

    chmod +x "$MOTD_CONFIG_TOOL"
    echo "✅ Установлена CLI утилита: $MOTD_CONFIG_TOOL"
}

# === Функция: Миграция конфига (добавление новых опций) ===
migrate_motd_config() {
    local config_file="$1"
    [ ! -f "$config_file" ] && return
    
    echo "🔄 Проверка конфига $config_file на новые опции..."
    
    # Список новых опций с дефолтными значениями
    declare -A NEW_OPTIONS=(
        ["MOTD_FAST_MODE"]="true"
        ["SSL_WARN_DAYS"]="30"
        ["MONITORED_SERVICES"]="nginx,mysql,postgresql,redis,docker,fail2ban"
        ["SSL_CERT_PATHS"]="/etc/letsencrypt/live"
        ["SHOW_NETBIRD"]="true"
    )
    
    local updated=false
    
    for option in "${!NEW_OPTIONS[@]}"; do
        if ! grep -q "^${option}=" "$config_file" 2>/dev/null; then
            echo "  ➕ Добавляю: ${option}=${NEW_OPTIONS[$option]}"
            echo "" >> "$config_file"
            echo "# Added in v2025.12.14.1" >> "$config_file"
            echo "${option}=${NEW_OPTIONS[$option]}" >> "$config_file"
            updated=true
        fi
    done
    
    # Принудительно включаем FAST_MODE если был false (для ускорения)
    if grep -q "^MOTD_FAST_MODE=false" "$config_file" 2>/dev/null; then
        echo "  ⚡ Включаю MOTD_FAST_MODE=true для ускорения"
        sed -i 's/^MOTD_FAST_MODE=false/MOTD_FAST_MODE=true/' "$config_file" 2>/dev/null || \
        sed -i '' 's/^MOTD_FAST_MODE=false/MOTD_FAST_MODE=true/' "$config_file" 2>/dev/null
        updated=true
    fi
    
    if [ "$updated" = true ]; then
        echo "✅ Конфиг обновлён: $config_file"
    else
        echo "✅ Конфиг актуален: $config_file"
    fi
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

# === VPN ===
SHOW_NETBIRD=true

# === Updates ===
SHOW_UPDATES=true
SHOW_AUTOUPDATES=true

# === Performance ===
# MOTD_FAST_MODE=true - мгновенное отображение (по умолчанию)
# Пропускает медленные проверки: public IP, docker sizes, crowdsec
MOTD_FAST_MODE=true

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
        # Конфиг существует - мигрируем
        migrate_motd_config "$CONFIG_GLOBAL"
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

# === Установка/проверка зависимостей ===
install_dependencies() {
    local MISSING=()
    local REQUIRED_CMDS="curl hostname awk grep cut uname df free top ip uptime"
    local OPTIONAL_CMDS="vnstat"
    
    # Проверяем обязательные утилиты
    for CMD in $REQUIRED_CMDS; do
        if ! command -v "$CMD" &>/dev/null; then
            MISSING+=("$CMD")
        fi
    done
    
    if (( ${#MISSING[@]} )); then
        echo "❌ Не хватает обязательных утилит: ${MISSING[*]}"
        if [ "$EUID" -eq 0 ]; then
            echo "🛠 Попытка автоматической установки..."
            case "$PACKAGE_MANAGER" in
                apt)
                    apt-get update -qq && apt-get install -y curl coreutils net-tools procps iproute2 >/dev/null 2>&1
                    ;;
                dnf)
                    dnf install -y curl coreutils net-tools procps iproute >/dev/null 2>&1
                    ;;
                yum)
                    yum install -y curl coreutils net-tools procps iproute >/dev/null 2>&1
                    ;;
            esac
        else
            echo "🛠 Пожалуйста, установи их командой (под root):"
            echo "    sudo apt install curl coreutils net-tools procps iproute2 -y"
            echo "🔁 После этого снова запусти установку."
            exit 1
        fi
    fi
    
    # Проверяем vnstat (опционально, но нужен для Network Traffic)
    if ! command -v vnstat &>/dev/null; then
        if [ "$EUID" -eq 0 ]; then
            info "Устанавливаю vnstat для мониторинга сетевого трафика..."
            case "$PACKAGE_MANAGER" in
                apt)
                    apt-get install -y vnstat >/dev/null 2>&1
                    ;;
                dnf)
                    dnf install -y vnstat >/dev/null 2>&1
                    ;;
                yum)
                    yum install -y vnstat >/dev/null 2>&1
                    ;;
            esac
            
            # Включаем и запускаем службу vnstat
            if command -v vnstat &>/dev/null; then
                systemctl enable vnstat >/dev/null 2>&1 || true
                systemctl start vnstat >/dev/null 2>&1 || true
                success "vnstat установлен и запущен"
                info "Статистика трафика начнёт собираться через несколько минут"
            else
                warning "Не удалось установить vnstat. Network Traffic будет недоступен."
            fi
        else
            warning "vnstat не установлен. Network Traffic будет недоступен."
            echo "    Для установки выполни: sudo apt install vnstat -y"
        fi
    fi

    # Проверяем last (нужен для Last Login, перенесён в util-linux-extra на Ubuntu 24.04+)
    if ! command -v last &>/dev/null; then
        if [ "$EUID" -eq 0 ]; then
            info "Устанавливаю util-linux-extra для команды last..."
            case "$PACKAGE_MANAGER" in
                apt)
                    apt-get install -y util-linux-extra >/dev/null 2>&1 || apt-get install -y util-linux >/dev/null 2>&1
                    ;;
                dnf|yum)
                    $PACKAGE_MANAGER install -y util-linux >/dev/null 2>&1
                    ;;
            esac
            if command -v last &>/dev/null; then
                success "last установлен (util-linux-extra)"
            else
                warning "Не удалось установить last. Last Login будет использовать fallback."
            fi
        else
            warning "Команда last не найдена. Last Login может быть неполным."
        fi
    fi
}

if [ "$EUID" -ne 0 ]; then
    # Для не-root просто проверяем наличие утилит
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
else
    # Для root устанавливаем зависимости автоматически
    install_dependencies
fi

# === Создание dashboard-файла ===
if [ "$INSTALL_USER_MODE" = false ]; then
    mkdir -p /etc/update-motd.d
fi
cat > "$TMP_FILE" << 'EOF'
#!/bin/bash

CURRENT_VERSION="2025.03.18.1"
REMOTE_URL="https://dignezzz.github.io/server/dashboard.sh"
CONFIG_GLOBAL="/etc/motdrc"

# === БЫСТРЫЙ РЕЖИМ (по умолчанию ВКЛЮЧЁН) ===
# Отключает тяжёлые проверки для мгновенного отображения
# Установи MOTD_FAST_MODE=false в /etc/motdrc для полной информации
: "${MOTD_FAST_MODE:=true}"

ok="✅"
fail="❌"
warn="⚠️"
separator="─~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

# === Функция кэширования с проверкой возраста ===
cache_valid() {
    local cache_file="$1"
    local max_age="$2"
    [ -f "$cache_file" ] || return 1
    local mtime
    mtime=$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null || echo 0)
    [ $(($(date +%s) - mtime)) -lt "$max_age" ]
}

# === Проверка обновлений в ФОНЕ (не блокирует вход) ===
check_updates_bg() {
    local cache_file="/tmp/motd-update-available"
    local version_cache="/tmp/motd-remote-version"
    
    # Проверяем кэш (раз в 24 часа)
    if cache_valid "$version_cache" 86400; then
        [ -f "$cache_file" ] && cat "$cache_file"
        return
    fi
    
    # Запускаем проверку в фоне
    (
        REMOTE_VERSION=$(timeout 2 curl -s "$REMOTE_URL" 2>/dev/null | grep '^CURRENT_VERSION=' | head -n1 | cut -d= -f2 | tr -d '"')
        echo "$REMOTE_VERSION" > "$version_cache" 2>/dev/null
        if [ -n "$REMOTE_VERSION" ] && [ "$REMOTE_VERSION" != "$CURRENT_VERSION" ]; then
            echo "${warn} Новая версия: $REMOTE_VERSION (текущая: $CURRENT_VERSION)" > "$cache_file"
            echo "💡 Обновление: motd --update" >> "$cache_file"
        else
            rm -f "$cache_file" 2>/dev/null
        fi
    ) &>/dev/null &
    
    # Показываем предыдущий результат если есть
    [ -f "$cache_file" ] && { cat "$cache_file"; echo ""; }
}

check_updates_bg
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
: "${SHOW_NETBIRD:=true}"

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

# Определяем OS для корректной работы условий
if [ -f /etc/os-release ]; then
    . /etc/os-release
    case "$ID" in
        ubuntu|debian|linuxmint)
            OS_TYPE="debian"
            ;;
        centos|rhel|almalinux|rocky|fedora)
            OS_TYPE="rhel"
            ;;
        *)
            OS_TYPE="unknown"
            ;;
    esac
else
    OS_TYPE="unknown"
fi

uptime_str=$(uptime -p 2>/dev/null || echo "up")
loadavg=$(cut -d ' ' -f1-3 /proc/loadavg)
cpu_cores=$(nproc)

# === БЫСТРЫЙ CPU через /proc/stat (экономия ~1 секунды vs top) ===
get_cpu_usage() {
    local cpu1=($(grep '^cpu ' /proc/stat))
    sleep 0.1
    local cpu2=($(grep '^cpu ' /proc/stat))
    
    local idle1=${cpu1[4]}
    local total1=$((${cpu1[1]} + ${cpu1[2]} + ${cpu1[3]} + ${cpu1[4]} + ${cpu1[5]} + ${cpu1[6]} + ${cpu1[7]}))
    local idle2=${cpu2[4]}
    local total2=$((${cpu2[1]} + ${cpu2[2]} + ${cpu2[3]} + ${cpu2[4]} + ${cpu2[5]} + ${cpu2[6]} + ${cpu2[7]}))
    
    local diff_idle=$((idle2 - idle1))
    local diff_total=$((total2 - total1))
    
    if [ "$diff_total" -gt 0 ]; then
        echo $((100 * (diff_total - diff_idle) / diff_total))
    else
        echo 0
    fi
}

# I/O Wait из /proc/stat (без top)
get_io_wait() {
    local cpu=($(grep '^cpu ' /proc/stat))
    local total=$((${cpu[1]} + ${cpu[2]} + ${cpu[3]} + ${cpu[4]} + ${cpu[5]} + ${cpu[6]} + ${cpu[7]}))
    local iowait=${cpu[5]}
    if [ "$total" -gt 0 ]; then
        echo $((100 * iowait / total))
    else
        echo 0
    fi
}

# CPU (только если включено)
if [ "$SHOW_CPU" = true ]; then
    cpu_percent=$(get_cpu_usage)
    cpu_temp=""
    if [ "$SHOW_TEMP" = true ] && [ -f /sys/class/thermal/thermal_zone0/temp ]; then
        temp_raw=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
        [ -n "$temp_raw" ] && cpu_temp=" | $((temp_raw / 1000))°C"
    fi
fi

# === ОПТИМИЗАЦИЯ: один вызов free для RAM и SWAP ===
if [ "$SHOW_RAM" = true ] || [ "$SHOW_SWAP" = true ]; then
    _free_output=$(free -m)
fi

# RAM (только если включено)
if [ "$SHOW_RAM" = true ]; then
    mem_total=$(echo "$_free_output" | awk '/Mem:/ {print $2}')
    mem_used=$(echo "$_free_output" | awk '/Mem:/ {print $3}')
    mem_percent=$((mem_used * 100 / mem_total))
    mem_data="${mem_used}MB / ${mem_total}MB"
fi

# SWAP (только если включено)
if [ "$SHOW_SWAP" = true ]; then
    swap_total=$(echo "$_free_output" | awk '/Swap:/ {print $2}')
    swap_used=$(echo "$_free_output" | awk '/Swap:/ {print $3}')
    swap_percent=0
    swap_data="not configured"
    if [ "$swap_total" -gt 0 ]; then
        swap_percent=$((swap_used * 100 / swap_total))
        swap_data="${swap_used}MB / ${swap_total}MB"
    fi
fi

# Disk (только если включено) - один вызов df
if [ "$SHOW_DISK" = true ]; then
    _df_root=$(df -h / | awk 'NR==2 {print $2, $3, $5}')
    disk_total=$(echo "$_df_root" | awk '{print $1}')
    disk_used_space=$(echo "$_df_root" | awk '{print $2}')
    disk_percent=$(echo "$_df_root" | awk '{print $3}' | tr -d '%')
    disk_data="${disk_used_space} / ${disk_total}"
fi

# Network (только если включено)
# vnstat --oneline поля: 1=version, 2=iface, 3=today_date, 4=rx_today, 5=tx_today, 6=total_today, 7=rate_today
#                        8=month_date, 9=rx_month, 10=tx_month, 11=total_month, 12=rate_month
#                        13=rx_all, 14=tx_all, 15=total_all
# Цвета: Cyan=36 для дня, Yellow=33 для месяца
if [ "$SHOW_NET" = true ]; then
    traffic=$(vnstat --oneline 2>/dev/null | awk -F\; '{
        cyan="\033[0;36m"; yellow="\033[0;33m"; nc="\033[0m";
        print cyan "Day: " $4 " / " $5 nc " │ " yellow "Month: " $9 " / " $10 nc
    }')
fi

# IP адреса (только если включено) - с кэшированием Public IP на 1 час
if [ "$SHOW_IP" = true ]; then
    # Кэшируем Public IP на 1 ЧАС (принудительно IPv4)
    cache_file="/tmp/motd-public-ip"
    if cache_valid "$cache_file" 3600; then
        ip_public=$(cat "$cache_file" 2>/dev/null)
    else
        # Запрашиваем Public IP
        ip_public=$(timeout 2 curl -4 -s --connect-timeout 2 ifconfig.me 2>/dev/null)
        # Если ifconfig.me не ответил — пробуем альтернативы
        [ -z "$ip_public" ] && ip_public=$(timeout 2 curl -4 -s --connect-timeout 2 icanhazip.com 2>/dev/null)
        [ -z "$ip_public" ] && ip_public=$(timeout 2 curl -4 -s --connect-timeout 2 api.ipify.org 2>/dev/null)
        # Если все сервисы недоступны — берём IP с основного интерфейса
        if [ -z "$ip_public" ]; then
            ip_public=$(ip -4 addr show 2>/dev/null | grep -v -E 'docker|br-|veth|lo:' | grep 'inet ' | grep -v '127.0.0.1' | head -1 | awk '{print $2}' | cut -d/ -f1)
        fi
        [ -z "$ip_public" ] && ip_public="n/a"
        # Сохраняем в кэш
        [ "$ip_public" != "n/a" ] && echo "$ip_public" > "$cache_file" 2>/dev/null
    fi
    
    # IPv6 global (первый глобальный, не link-local)
    ip6=$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/{print $2; exit}' | cut -d/ -f1)
    [ -z "$ip6" ] && ip6=""
fi

# Top процессы (только если включено)
if [ "$SHOW_TOP_PROCESSES" = true ]; then
    top_cpu=$(ps aux --sort=-%cpu | awk 'NR>1 {print $11}' | head -n 3 | paste -sd ', ')
    top_mem=$(ps aux --sort=-%mem | awk 'NR>1 {print $11}' | head -n 3 | paste -sd ', ')
fi

# Fail2ban статистика - ОПТИМИЗИРОВАНО (один вызов с кэшем)
fail2ban_banned=0
fail2ban_installed=false
if [ "$SHOW_FAIL2BAN_STATS" = true ]; then
    if command -v fail2ban-client &>/dev/null; then
        fail2ban_installed=true
        f2b_cache="/tmp/motd-f2b-banned"
        if cache_valid "$f2b_cache" 60; then
            fail2ban_banned=$(cat "$f2b_cache" 2>/dev/null || echo 0)
        else
            # Быстрый подсчёт через один вызов
            fail2ban_banned=$(fail2ban-client status 2>/dev/null | awk -F: '/Jail list/{gsub(/[, ]/,"\n",$2); print $2}' | while read jail; do
                [ -n "$jail" ] && fail2ban-client status "$jail" 2>/dev/null | awk '/Currently banned/{print $NF}'
            done | awk '{s+=$1} END{print s+0}')
            echo "$fail2ban_banned" > "$f2b_cache" 2>/dev/null
        fi
    fi
    
    # CrowdSec статистика - с кэшем
    crowdsec_banned=0
    crowdsec_installed=false
    if command -v cscli &>/dev/null; then
        crowdsec_installed=true
        cs_cache="/tmp/motd-cs-banned"
        if cache_valid "$cs_cache" 60; then
            crowdsec_banned=$(cat "$cs_cache" 2>/dev/null || echo 0)
        else
            crowdsec_banned=$(cscli decisions list -o raw 2>/dev/null | tail -n +2 | wc -l)
            echo "$crowdsec_banned" > "$cs_cache" 2>/dev/null
        fi
    fi
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
    if command -v last &>/dev/null && [ -f /var/log/wtmp ]; then
        last_login=$(last -n 1 -w 2>/dev/null | head -n 1 | awk '{printf "%s from %s at %s %s %s", $1, $3, $5, $6, $7}')
    elif command -v lastlog &>/dev/null; then
        last_login=$(lastlog -u "$(whoami)" 2>/dev/null | tail -1 | awk '{printf "%s %s %s from %s", $4, $5, $6, $3}')
    else
        last_login="n/a (install util-linux-extra)"
    fi
    [ -z "$last_login" ] && last_login="n/a"
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

# Статус сервисов (только если включено) - ПОКАЗЫВАЕМ ТОЛЬКО УСТАНОВЛЕННЫЕ
if [ "$SHOW_SERVICES" = true ]; then
    services_status=""
    services_down=""
    IFS=',' read -ra SERVICES <<< "$MONITORED_SERVICES"
    
    for service in "${SERVICES[@]}"; do
        service=$(echo "$service" | xargs)  # trim whitespace
        # Проверяем существует ли юнит сервиса
        if systemctl list-unit-files "${service}.service" 2>/dev/null | grep -q "${service}.service"; then
            status=$(systemctl is-active "${service}.service" 2>/dev/null)
            if [ "$status" = "active" ]; then
                services_status="${services_status}$ok ${service} "
            else
                services_status="${services_status}$fail ${service} "
                services_down="${services_down}${service}, "
            fi
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

# SSL сертификаты (только если включено) - КЭШИРОВАНИЕ на 6 часов
if [ "$SHOW_SSL_CERTS" = true ]; then
    ssl_cache="/tmp/motd-ssl-certs"
    if cache_valid "$ssl_cache" 21600; then
        ssl_expiring=$(cat "$ssl_cache" 2>/dev/null)
    else
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
        echo "$ssl_expiring" > "$ssl_cache" 2>/dev/null
    fi
fi

# I/O Wait (только если включено) - через /proc/stat (без bc)
if [ "$SHOW_IO_WAIT" = true ]; then
    io_wait=$(get_io_wait)
    io_wait_status="$ok low"
    [ "$io_wait" -gt 20 ] && io_wait_status="$fail high"
    [ "$io_wait" -gt 10 ] && [ "$io_wait" -le 20 ] && io_wait_status="$warn moderate"
fi

# Docker volumes (только если включено) - с кэшированием
if [ "$SHOW_DOCKER_VOLUMES" = true ]; then
    docker_volumes_usage=""
    if command -v docker &>/dev/null; then
        dv_cache="/tmp/motd-docker-volumes"
        if cache_valid "$dv_cache" 300; then
            docker_volumes_usage=$(cat "$dv_cache" 2>/dev/null)
        else
            docker_volumes_count=$(docker volume ls -q 2>/dev/null | wc -l)
            if [ "$docker_volumes_count" -gt 0 ]; then
                if [ "$MOTD_FAST_MODE" = true ]; then
                    docker_volumes_usage="$docker_volumes_count volumes"
                else
                    docker_volumes_size=$(timeout 2 docker system df 2>/dev/null | awk '/Local Volumes/{print $3}')
                    [ -n "$docker_volumes_size" ] && [ "$docker_volumes_size" != "0B" ] && \
                        docker_volumes_usage="$docker_volumes_count volumes ($docker_volumes_size)" || \
                        docker_volumes_usage="$docker_volumes_count volumes"
                fi
                echo "$docker_volumes_usage" > "$dv_cache" 2>/dev/null
            fi
        fi
    fi
fi

# Docker containers (только если включено) - с кэшированием
if [ "$SHOW_DOCKER" = true ]; then
    docker_msg="$warn not installed"
    docker_msg_extra=""
    if command -v docker &>/dev/null; then
        dc_cache="/tmp/motd-docker-containers"
        if cache_valid "$dc_cache" 30; then
            docker_msg=$(head -1 "$dc_cache" 2>/dev/null)
            docker_msg_extra=$(tail -n +2 "$dc_cache" 2>/dev/null)
        else
            docker_total=$(docker ps -a -q 2>/dev/null | wc -l)
            docker_running=$(docker ps -q 2>/dev/null | wc -l)
            docker_stopped=$((docker_total - docker_running))
            docker_msg="$ok ${docker_running} running / ${docker_stopped} stopped"
            # Проблемные контейнеры только в не-fast режиме
            if [ "$MOTD_FAST_MODE" != true ] && [ "$docker_stopped" -gt 0 ]; then
                bad_containers=$(docker ps -a --filter "status=exited" --filter "status=restarting" --format '⛔ {{.Names}} ({{.Status}})' 2>/dev/null | head -3)
                if [ -n "$bad_containers" ]; then
                    docker_msg="$warn ${docker_running} running / ${docker_stopped} stopped"
                    docker_msg_extra=$(echo "$bad_containers" | sed 's/^/                    /')
                fi
            fi
            { echo "$docker_msg"; echo "$docker_msg_extra"; } > "$dc_cache" 2>/dev/null
        fi
    fi
fi

# NetBird VPN (только если включено) - с кэшированием
if [ "$SHOW_NETBIRD" = true ]; then
    netbird_msg="$warn not installed"
    netbird_extra=""
    if command -v netbird &>/dev/null; then
        nb_cache="/tmp/motd-netbird"
        if cache_valid "$nb_cache" 60; then
            netbird_msg=$(head -1 "$nb_cache" 2>/dev/null)
            netbird_extra=$(tail -n +2 "$nb_cache" 2>/dev/null)
        else
            nb_status_output=$(netbird status 2>/dev/null)
            if [ -n "$nb_status_output" ]; then
                # Management connection status
                nb_mgmt=$(echo "$nb_status_output" | grep -i 'Management:' | awk '{print $NF}')
                # Signal connection status
                nb_signal=$(echo "$nb_status_output" | grep -i 'Signal:' | awk '{print $NF}')
                # NetBird IP
                nb_ip=$(echo "$nb_status_output" | grep -i 'NetBird IP:' | awk '{print $NF}')
                # FQDN
                nb_fqdn=$(echo "$nb_status_output" | grep -i 'FQDN:' | awk '{print $NF}')
                # Connected peers
                nb_peers=$(echo "$nb_status_output" | grep -i 'Peers count:' | awk '{print $NF}')
                # Interface
                nb_iface=$(echo "$nb_status_output" | grep -i 'Interface type:' | awk -F: '{gsub(/^[ \t]+/,"",\$2); print \$2}')

                # Build status message
                if [ "$nb_mgmt" = "Connected" ]; then
                    netbird_msg="$ok Connected"
                    [ -n "$nb_ip" ] && netbird_msg="$netbird_msg | IP: $nb_ip"
                else
                    netbird_msg="$fail Disconnected"
                fi

                # Build extra info
                nb_extra_lines=""
                [ -n "$nb_fqdn" ] && [ "$nb_fqdn" != "n/a" ] && nb_extra_lines="FQDN: $nb_fqdn"
                [ -n "$nb_peers" ] && nb_extra_lines="${nb_extra_lines:+$nb_extra_lines | }Peers: $nb_peers"
                [ -n "$nb_iface" ] && nb_extra_lines="${nb_extra_lines:+$nb_extra_lines | }Interface: $nb_iface"

                # Check enabled features
                nb_features=""
                echo "$nb_status_output" | grep -qi 'DNS:.*true\|DNS:.*enabled' && nb_features="DNS"
                echo "$nb_status_output" | grep -qi 'Rosenpass:.*true\|Rosenpass:.*enabled' && nb_features="${nb_features:+$nb_features, }Rosenpass"
                echo "$nb_status_output" | grep -qi 'Routes:' && {
                    nb_routes=$(echo "$nb_status_output" | grep -i 'Routes:' | awk -F: '{gsub(/^[ \t]+/,"",\$2); print \$2}')
                    [ -n "$nb_routes" ] && [ "$nb_routes" != "-" ] && nb_features="${nb_features:+$nb_features, }Routes"
                }
                [ -n "$nb_features" ] && nb_extra_lines="${nb_extra_lines:+$nb_extra_lines | }Features: $nb_features"

                netbird_extra="$nb_extra_lines"
            else
                netbird_msg="$fail daemon not running"
            fi
            { echo "$netbird_msg"; [ -n "$netbird_extra" ] && echo "$netbird_extra"; } > "$nb_cache" 2>/dev/null
        fi
    fi
fi

# SSH info (только если включено)
if [ "$SHOW_SSH" = true ] || [ "$SHOW_SECURITY" = true ]; then
    ssh_users=$(who | wc -l)
    # Извлекаем IP из скобок, игнорируя время и локальные tty
    ssh_ips=$(who 2>/dev/null | grep -oE '\([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\)' | tr -d '()' | sort -u | paste -sd ', ' -)
    [ -z "$ssh_ips" ] && ssh_ips="local"
fi

# Fail2ban и CrowdSec статус (только если включено)
if [ "$SHOW_FAIL2BAN_STATS" = true ]; then
    # Формируем единую строку статуса
    ban_systems_status=""
    
    # Fail2ban
    if [ "$fail2ban_installed" = true ]; then
        if systemctl is-active fail2ban &>/dev/null; then
            ban_systems_status="$ok Fail2ban"
        else
            ban_systems_status="$warn Fail2ban (inactive)"
        fi
    else
        ban_systems_status="$fail Fail2ban"
    fi
    
    # CrowdSec
    if [ "$crowdsec_installed" = true ]; then
        if systemctl is-active crowdsec &>/dev/null; then
            ban_systems_status="${ban_systems_status} | $ok CrowdSec"
        else
            ban_systems_status="${ban_systems_status} | $warn CrowdSec (inactive)"
        fi
    else
        ban_systems_status="${ban_systems_status} | $fail CrowdSec"
    fi
fi

# Firewall (только если включено для Security блока) - с кэшированием (экономия ~100ms)
if [ "$SHOW_SECURITY" = true ]; then
    cache_file="/tmp/motd-firewall-status"
    if cache_valid "$cache_file" 30; then
        ufw_status=$(cat "$cache_file")
    else
        if [ "$OS_TYPE" = "debian" ]; then
            # Debian/Ubuntu: UFW
            if command -v ufw &>/dev/null; then
                ufw_status_raw=$(ufw status | grep -i "Status" | awk '{print $2}')
                if [[ "$ufw_status_raw" == "active" ]]; then
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
        echo "$ufw_status" > "$cache_file" 2>/dev/null
    fi
fi

# Security блок - SSH, Root login, Password auth (только если включено)
if [ "$SHOW_SECURITY" = true ]; then
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

# Обновления (только если включено) - с кэшированием (экономия ~545ms)
if [ "$SHOW_UPDATES" = true ]; then
    cache_file="/tmp/motd-updates-count"
    if cache_valid "$cache_file" 3600; then
        updates=$(cat "$cache_file" 2>/dev/null || echo "0")
    else
        if [ "$OS_TYPE" = "debian" ]; then
            updates=$(apt list --upgradable 2>/dev/null | grep -v "Listing" | wc -l)
        elif [ "$OS_TYPE" = "rhel" ]; then
            if command -v dnf &>/dev/null; then
                updates=$(dnf check-update -q 2>/dev/null | grep -v "^$" | grep -v "^Last metadata" | wc -l)
            else
                updates=$(yum check-update -q 2>/dev/null | grep -v "^$" | grep -v "^Loaded plugins" | wc -l)
            fi
        else
            updates="0"
        fi
        echo "$updates" > "$cache_file" 2>/dev/null
    fi
    update_msg="${updates} package(s) can be updated"
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
    ip)
      # Формируем строку IP: показываем IPv4 и IPv6 (если есть)
      local ip_str="$ip_public"
      [ -n "$ip6" ] && [ "$ip6" != "n/a" ] && ip_str="$ip_str / $ip6"
      print_row "IP Address" "$ip_str"
      ;;
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
      print_row "Ban Systems" "$ban_systems_status"
      
      # Показываем статистику блокировок если есть
      if [ "$SHOW_FAIL2BAN_STATS" = true ]; then
        local ban_stats=""
        if [ "$fail2ban_banned" -gt 0 ]; then
          ban_stats="F2B: $fail2ban_banned"
        fi
        if [ "$crowdsec_banned" -gt 0 ]; then
          [ -n "$ban_stats" ] && ban_stats="$ban_stats | "
          ban_stats="${ban_stats}CrowdSec: $crowdsec_banned"
        fi
        [ -n "$ban_stats" ] && print_row "  Banned IPs" "$ban_stats"
      fi
      
      print_row "Firewall" "$ufw_status"
      print_row "SSH Port" "$ssh_port_status"
      print_row "Root Login" "$root_login_status"
      print_row "Password Auth" "$password_auth_status"
      print_row "SSH Sessions" "$ssh_users"
      print_row "SSH IPs" "$ssh_ips"
      echo " ~~~~~~ ↑↑↑ Security Block ↑↑↑ ~~~~~~"
      ;;
    netbird)
      print_row "NetBird VPN" "$netbird_msg"
      if [ -n "$netbird_extra" ]; then
        printf " %-20s   %s\n" "" "$netbird_extra"
      fi
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
[ "$SHOW_NETBIRD" = true ] && print_section netbird
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

# === Функция: Финализация установки (избегаем дублирования кода) ===
finalize_installation() {
    mv "$TMP_FILE" "$DASHBOARD_FILE"
    
    # Очистка кэша версий после обновления
    rm -f /tmp/motd-update-available /tmp/motd-remote-version 2>/dev/null
    
    if [ "$INSTALL_USER_MODE" = false ]; then
        chmod +x "$DASHBOARD_FILE"
        
        # Отключение стандартного MOTD только для Debian/Ubuntu
        if [ "$OS_TYPE" = "debian" ]; then
            info "Отключение стандартных скриптов Ubuntu/Debian MOTD..."
            for script in 00-header 10-help-text 50-landscape-sysinfo 50-motd-news \
                         80-livepatch 90-updates-available 91-release-upgrade 95-hwe-eol; do
                chmod -x "/etc/update-motd.d/$script" 2>/dev/null || true
            done
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
}

if [ "$FORCE_MODE" = true ]; then
    echo "⚙️ Автоматическая установка без подтверждения (--force)"
    finalize_installation
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
        finalize_installation
    else
        echo "❌ Установка отменена."
        rm -f "$TMP_FILE"
    fi
fi
