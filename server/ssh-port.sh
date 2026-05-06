#!/bin/bash

# ============================================================================
# SSH Port Changer Script
# Safely changes SSH port with firewall and SELinux configuration
# ============================================================================

set -euo pipefail

# Цвета для вывода
readonly RED='\e[31m'
readonly GREEN='\e[32m'
readonly YELLOW='\e[33m'
readonly BLUE='\e[34m'
readonly NC='\e[0m'  # No Color

# Конфигурация
readonly SSHD_CONFIG="/etc/ssh/sshd_config"
readonly SOCKET_FILE="/lib/systemd/system/ssh.socket"
readonly SOCKET_OVERRIDE_DIR="/etc/systemd/system/ssh.socket.d"
readonly SOCKET_OVERRIDE_FILE="/etc/systemd/system/ssh.socket.d/override.conf"
readonly SCRIPT_NAME="ssh-port-changer"

# Глобальные переменные
os_name=""
os_version=""

# ============================================================================
# Вспомогательные функции
# ============================================================================

log() {
    local message="$1"
    echo -e "$message"
    logger -t "$SCRIPT_NAME" "$(echo -e "$message" | sed 's/\x1B\[[0-9;]*[JKmsu]//g')"
}

log_info()    { log "${BLUE}$1${NC}"; }
log_success() { log "${GREEN}$1${NC}"; }
log_warning() { log "${YELLOW}$1${NC}"; }
log_error()   { log "${RED}$1${NC}"; }

die() {
    log_error "$1"
    exit 1
}

backup_file() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    
    local backup="${file}.backup_$(date +%Y%m%d_%H%M%S)"
    cp "$file" "$backup"
    log_success "Backup created: $backup"
}

check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        log_error "Please run the script as root (sudo)."
        echo ""
        echo -e "${BLUE}Example / Пример:${NC}"
        echo -e "  wget -qO- https://dignezzz.github.io/server/ssh-port.sh | sudo bash -s -- --port 5322"
        exit 1
    fi
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        os_name="$ID"
        os_version="${VERSION_ID:-unknown}"
    else
        os_name=$(lsb_release -is 2>/dev/null || echo "unknown")
        os_version=$(lsb_release -rs 2>/dev/null || echo "unknown")
    fi
    log_info "Detected system: $os_name $os_version"
}

# ============================================================================
# Функции работы с портами
# ============================================================================

get_current_port() {
    local config_file="$1"
    local port
    port=$(grep -E '^[[:space:]]*Port[[:space:]]+[0-9]+' "$config_file" 2>/dev/null | awk '{print $2}')
    echo "${port:-22}"  # Порт по умолчанию
}

# Реальный порт, на котором сейчас слушает sshd (по данным ss).
# На Ubuntu 24.04 с socket-активацией значение из sshd_config может расходиться
# с фактическим listen-портом, поэтому ориентируемся на ss.
get_active_ssh_port() {
    command -v ss >/dev/null 2>&1 || return 0
    ss -tlnpH 2>/dev/null \
        | awk '/"sshd"/ {n=split($4,a,":"); print a[n]; exit}'
}

ensure_port_directive_exists() {
    local file="$1"
    grep -qE '^\s*#?\s*Port\s+[0-9]+' "$file" || echo "Port 22" >> "$file"
}

change_port_in_config() {
    local config_file="$1"
    local port="$2"
    sed -i -E "s/^#?Port[[:space:]]+[0-9]+/Port $port/" "$config_file"
    log_success "Port changed to $port in: $config_file"
}

is_port_in_use() {
    local port="$1"
    ss -tuln | grep -q ":${port} "
}

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 ))
}

# ============================================================================
# Функции управления SSH сервисом
# ============================================================================

get_ssh_service_name() {
    if systemctl list-units --type=service --all 2>/dev/null | grep -q 'sshd.service'; then
        echo "sshd.service"
    elif systemctl list-units --type=service --all 2>/dev/null | grep -q 'ssh.service'; then
        echo "ssh.service"
    elif [[ -f /etc/systemd/system/sshd.service ]] || [[ -f /usr/lib/systemd/system/sshd.service ]]; then
        echo "sshd.service"
    elif [[ -f /etc/systemd/system/ssh.service ]] || [[ -f /usr/lib/systemd/system/ssh.service ]]; then
        echo "ssh.service"
    else
        return 1
    fi
}

show_service_logs() {
    local service="$1"
    log_error "Service status:"
    systemctl status "$service" --no-pager --lines=5 2>&1 | while IFS= read -r line; do
        log_error "  $line"
    done
    log_error "Journal logs:"
    journalctl -xeu "$service" --no-pager --lines=10 2>&1 | while IFS= read -r line; do
        log_error "  $line"
    done
}

has_ssh_socket() {
    [[ -f "$SOCKET_FILE" ]] || systemctl list-unit-files ssh.socket 2>/dev/null | grep -q '^ssh\.socket'
}

# Создаём drop-in override для ssh.socket вместо правки /lib/systemd/...
# Формат "ListenStream=" сначала сбрасывает все ListenStream из основного юнита,
# затем задаём нужный порт. Это устойчиво к любому исходному формату строки.
configure_ssh_socket_override() {
    local port="$1"
    log_info "Configuring ssh.socket drop-in override for port $port..."
    mkdir -p "$SOCKET_OVERRIDE_DIR"
    cat > "$SOCKET_OVERRIDE_FILE" <<EOF
# Managed by $SCRIPT_NAME — do not edit manually
[Socket]
ListenStream=
ListenStream=$port
EOF
    log_success "Created socket override: $SOCKET_OVERRIDE_FILE"

    # Предупреждаем, если /lib/systemd/system/ssh.socket повреждён предыдущей
    # (багованной) версией скрипта (например, "ListenStream=5322.0.0.0:22").
    if [[ -f "$SOCKET_FILE" ]] && grep -qE '^ListenStream=[0-9]{4,}\.' "$SOCKET_FILE"; then
        log_warning "$SOCKET_FILE looks corrupted (likely from an older buggy run)."
        log_warning "Override will take precedence, but consider running:"
        log_warning "  apt install --reinstall openssh-server"
    fi
}

reload_ssh_services() {
    log_info "Reloading systemd configuration..."
    systemctl daemon-reload

    # На socket-активированных системах перезапуск ssh.socket обязателен:
    # именно он держит listening port. ssh.service после этого тоже рестартим,
    # чтобы подхватился sshd_config.
    if has_ssh_socket; then
        log_info "Restarting ssh.socket..."
        if ! systemctl restart ssh.socket 2>/dev/null; then
            log_warning "Failed to restart ssh.socket (may be inactive — continuing)"
        fi
    fi

    local ssh_service
    ssh_service=$(get_ssh_service_name) || die "Cannot determine SSH service name"

    log_info "Restarting SSH service: $ssh_service"

    if ! systemctl restart "$ssh_service"; then
        log_error "Failed to restart SSH service $ssh_service"
        show_service_logs "$ssh_service"
        return 1
    fi

    sleep 2

    if ! systemctl is-active --quiet "$ssh_service"; then
        log_error "SSH service $ssh_service failed to start after restart"
        show_service_logs "$ssh_service"
        return 1
    fi

    log_success "SSH service $ssh_service restarted successfully"
    return 0
}

test_ssh_config() {
    log_info "Testing SSH configuration..."
    
    if ! command -v sshd >/dev/null 2>&1; then
        log_warning "Warning: sshd command not found, skipping config test"
        return 0
    fi
    
    if sshd -t -f "$SSHD_CONFIG" 2>/dev/null; then
        log_success "SSH configuration is valid"
        return 0
    fi
    
    log_error "SSH configuration has errors:"
    sshd -t -f "$SSHD_CONFIG" 2>&1 | while IFS= read -r line; do
        log_error "  $line"
    done
    return 1
}

test_port_reachable() {
    local port="$1"
    log_info "Testing SSH on port $port..."
    
    if timeout 3 bash -c "</dev/tcp/127.0.0.1/$port" &>/dev/null; then
        log_success "Port $port is reachable locally."
    else
        log_warning "Warning: Port $port is not reachable locally. Check firewall or SSH config."
    fi
}

# ============================================================================
# Функции SELinux
# ============================================================================

is_rhel_based() {
    [[ "$os_name" =~ ^(almalinux|rocky|rhel|centos|fedora)$ ]]
}

configure_selinux() {
    local port="$1"
    
    # SELinux актуален только для RHEL-based систем
    if ! command -v getenforce >/dev/null 2>&1; then
        is_rhel_based && install_selinux_tools "$port"
        return
    fi
    
    local selinux_status
    selinux_status=$(getenforce 2>/dev/null || echo "Disabled")
    log_info "SELinux status: $selinux_status"
    
    [[ "$selinux_status" =~ ^(Enforcing|Permissive)$ ]] || return 0
    
    if ! command -v semanage >/dev/null 2>&1; then
        install_selinux_tools "$port"
        return
    fi
    
    add_selinux_port "$port"
}

install_selinux_tools() {
    local port="$1"
    log_warning "SELinux tools not found. Installing policycoreutils-python-utils..."
    
    local pkg_manager=""
    command -v dnf >/dev/null 2>&1 && pkg_manager="dnf"
    command -v yum >/dev/null 2>&1 && [[ -z "$pkg_manager" ]] && pkg_manager="yum"
    
    if [[ -n "$pkg_manager" ]] && $pkg_manager install -y policycoreutils-python-utils 2>/dev/null; then
        log_success "SELinux tools installed successfully"
        add_selinux_port "$port"
    else
        log_warning "Failed to install SELinux tools. Please install manually: dnf install policycoreutils-python-utils"
    fi
}

add_selinux_port() {
    local port="$1"
    log_info "Configuring SELinux for SSH port $port..."
    
    if semanage port -l 2>/dev/null | grep ssh_port_t | grep -q "\b${port}\b"; then
        log_warning "SELinux: SSH port $port already configured"
        return 0
    fi
    
    if semanage port -a -t ssh_port_t -p tcp "$port" 2>/dev/null; then
        log_success "SELinux: SSH port $port added successfully"
    else
        log_warning "Warning: Failed to add SSH port $port to SELinux. This may cause issues."
    fi
}

remove_old_port_from_selinux() {
    local port="$1"
    
    # Не удаляем стандартный порт 22
    [[ "$port" == "22" ]] && {
        log_warning "Skipping removal of standard SSH port 22 from SELinux"
        return 0
    }
    
    command -v semanage >/dev/null 2>&1 || return 0
    
    local selinux_status
    selinux_status=$(getenforce 2>/dev/null || echo "Disabled")
    [[ "$selinux_status" =~ ^(Enforcing|Permissive)$ ]] || return 0
    
    log_info "Removing old SSH port $port from SELinux..."
    
    if ! semanage port -l 2>/dev/null | grep ssh_port_t | grep -q "\b${port}\b"; then
        log_warning "SELinux: SSH port $port was not in rules"
        return 0
    fi
    
    if semanage port -d -t ssh_port_t -p tcp "$port" 2>/dev/null; then
        log_success "SELinux: SSH port $port removed successfully"
    else
        log_warning "Warning: Failed to remove SSH port $port from SELinux"
    fi
}

# ============================================================================
# Функции управления файрволом
# ============================================================================

configure_firewall() {
    local port="$1"
    
    if command -v firewall-cmd >/dev/null 2>&1; then
        configure_firewalld "$port"
    elif command -v ufw >/dev/null 2>&1; then
        configure_ufw "$port"
    elif command -v iptables >/dev/null 2>&1; then
        configure_iptables "$port"
    else
        log_warning "No supported firewall found (firewalld/ufw/iptables). Please configure manually."
    fi
}

configure_firewalld() {
    local port="$1"
    log_info "Configuring firewalld for port $port..."
    
    if firewall-cmd --list-ports 2>/dev/null | grep -q "${port}/tcp"; then
        log_warning "Port $port already allowed in firewalld."
        return 0
    fi
    
    firewall-cmd --permanent --add-port="${port}/tcp"
    
    if systemctl is-active --quiet firewalld; then
        firewall-cmd --reload
        log_success "Port $port added to firewalld rules."
    else
        log_success "Port $port rule added (firewalld not active)."
    fi
}

configure_ufw() {
    local port="$1"
    log_info "Configuring UFW for port $port..."
    
    if ufw status 2>/dev/null | grep -q "$port"; then
        log_warning "Port $port already allowed in UFW."
        return 0
    fi
    
    ufw allow "${port}/tcp"
    log_success "Port $port added to UFW rules."
}

configure_iptables() {
    local port="$1"
    log_info "Using iptables for port $port..."
    
    if iptables -L INPUT -n 2>/dev/null | grep -q ":${port} "; then
        log_warning "Port $port already allowed in iptables."
        return 0
    fi
    
    iptables -A INPUT -p tcp --dport "$port" -j ACCEPT
    log_success "Port $port added to iptables rules."
    log_warning "Note: iptables rules may not persist after reboot."
}

remove_old_port_from_firewall() {
    local port="$1"
    
    if command -v firewall-cmd >/dev/null 2>&1; then
        remove_port_firewalld "$port"
    elif command -v ufw >/dev/null 2>&1; then
        remove_port_ufw "$port"
    else
        log_warning "No supported firewall found. Please remove port $port manually."
    fi
}

remove_port_firewalld() {
    local port="$1"
    
    if ! systemctl is-active --quiet firewalld; then
        log_warning "Firewalld is not active. Cannot remove port $port."
        return 0
    fi
    
    if ! firewall-cmd --list-ports 2>/dev/null | grep -q "${port}/tcp"; then
        log_warning "Old port $port was not in firewalld rules."
        return 0
    fi
    
    firewall-cmd --permanent --remove-port="${port}/tcp"
    firewall-cmd --reload
    log_success "Old port $port removed from firewalld."
}

remove_port_ufw() {
    local port="$1"
    
    if ! ufw status 2>/dev/null | grep -q 'Status: active'; then
        log_warning "UFW is installed but not active. Cannot remove port $port."
        return 0
    fi
    
    if ! ufw status 2>/dev/null | grep -q "$port"; then
        log_warning "Old port $port was not in UFW rules."
        return 0
    fi
    
    ufw delete allow "${port}/tcp"
    log_success "Old port $port removed from UFW."
}

# ============================================================================
# Функция восстановления из бэкапа
# ============================================================================

restore_from_backup() {
    log_error "SSH configuration is invalid. Restoring backup..."
    local backup_file
    backup_file=$(ls -t "${SSHD_CONFIG}.backup_"* 2>/dev/null | head -1)
    
    if [[ -n "$backup_file" ]] && [[ -f "$backup_file" ]]; then
        cp "$backup_file" "$SSHD_CONFIG"
        log_success "Backup restored from: $backup_file"
    else
        log_error "No backup file found!"
    fi
}

# ============================================================================
# Вывод справки
# ============================================================================

show_help() {
    cat << EOF
Usage: $0 [OPTIONS]

Options:
    --port PORT         Set new SSH port (1-65535)
    --yes               Non-interactive mode (skip confirmations)
    --remove-old-port   Remove old port from firewall after change
    --help, -h          Show this help message

Examples:
    $0 --port 2222
    $0 --port 2222 --yes --remove-old-port

EOF
    exit 0
}

# ============================================================================
# Парсинг аргументов
# ============================================================================

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes)
                AUTO_YES=1
                shift
                ;;
            --port)
                [[ -n "${2:-}" ]] || die "Option --port requires an argument"
                NEW_PORT="$2"
                shift 2
                ;;
            --remove-old-port)
                REMOVE_OLD_PORT=1
                shift
                ;;
            --help|-h)
                show_help
                ;;
            *)
                die "Unknown option: $1. Use --help for usage."
                ;;
        esac
    done
}

# ============================================================================
# Основная логика
# ============================================================================

main() {
    check_root
    detect_os
    
    # Параметры по умолчанию
    local AUTO_YES=0
    local REMOVE_OLD_PORT=0
    local NEW_PORT=""
    
    parse_arguments "$@"
    
    local current_port active_port
    current_port=$(get_current_port "$SSHD_CONFIG")
    active_port=$(get_active_ssh_port)
    log_info "Current SSH port (sshd_config): $current_port"
    [[ -n "$active_port" ]] && log_info "Active listening port:    $active_port"

    # Интерактивный ввод порта
    if [[ -z "$NEW_PORT" ]] && [[ "$AUTO_YES" -eq 0 ]]; then
        while true; do
            read -rp "Enter a new port for SSH (1-65535): " NEW_PORT </dev/tty
            validate_port "$NEW_PORT" && break
            log_error "Invalid port number. Must be between 1 and 65535."
        done
    fi

    # Валидация
    validate_port "$NEW_PORT" || die "Invalid or missing port. Use --port <1-65535>."

    # "Ничего не делать" только если оба порта (конфиг и реальный) уже совпадают с целевым.
    # Если sshd_config = NEW_PORT, но реально слушает другой — продолжаем, чтобы починить.
    if [[ "$NEW_PORT" == "$current_port" ]] \
       && { [[ -z "$active_port" ]] || [[ "$NEW_PORT" == "$active_port" ]]; }; then
        log_warning "Port $NEW_PORT is already configured and active. No changes needed."
        exit 0
    fi

    if [[ "$NEW_PORT" == "$current_port" ]] && [[ -n "$active_port" ]] && [[ "$NEW_PORT" != "$active_port" ]]; then
        log_warning "sshd_config already has Port $NEW_PORT, but service listens on $active_port."
        log_warning "Will fix socket override and restart SSH to align."
    fi

    # Порт может быть "занят" нашим же sshd — это не повод падать.
    if [[ "$NEW_PORT" != "$active_port" ]]; then
        is_port_in_use "$NEW_PORT" && die "Port $NEW_PORT is already in use."
    fi

    # Изменение конфигурации
    backup_file "$SSHD_CONFIG"
    ensure_port_directive_exists "$SSHD_CONFIG"
    change_port_in_config "$SSHD_CONFIG" "$NEW_PORT"

    # На системах с ssh.socket (Ubuntu 22.10+/24.04+) задаём порт через drop-in override —
    # это надёжнее, чем sed по /lib/systemd/system/ssh.socket.
    if has_ssh_socket; then
        configure_ssh_socket_override "$NEW_PORT"
    fi

    # Проверка конфигурации
    if ! test_ssh_config; then
        restore_from_backup
        exit 1
    fi

    # Настройка SELinux и перезапуск сервиса
    configure_selinux "$NEW_PORT"

    if ! reload_ssh_services; then
        log_error "Failed to restart SSH service."
        exit 1
    fi
    
    # Настройка файрвола
    configure_firewall "$NEW_PORT"
    log_success "SSH service restarted successfully."
    
    # Удаление старого порта
    if [[ "$AUTO_YES" -eq 0 ]]; then
        read -rp "Remove old SSH port $current_port from firewall? [y/N]: " answer </dev/tty
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            remove_old_port_from_firewall "$current_port"
            remove_old_port_from_selinux "$current_port"
        fi
    elif [[ "$REMOVE_OLD_PORT" -eq 1 ]]; then
        remove_old_port_from_firewall "$current_port"
        remove_old_port_from_selinux "$current_port"
    fi
    
    test_port_reachable "$NEW_PORT"
}

# Запуск
main "$@"
