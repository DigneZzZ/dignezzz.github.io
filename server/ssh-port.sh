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
# Маркер формата drop-in override. Если в файле его нет — значит override писала
# старая версия скрипта (голый "ListenStream=<порт>", IPv6-only) и его надо мигрировать.
readonly OVERRIDE_MARKER="# ssh-port-changer-format: dual-stack-v2"

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
    local port=""

    # 1) sshd, который слушает сам (классическая схема, RHEL-based).
    if command -v ss >/dev/null 2>&1; then
        port=$(ss -tlnp 2>/dev/null \
            | awk '/"sshd"/ {n=split($4,a,":"); print a[n]; exit}')
    fi

    # 2) Socket-активация: слушающий сокет держит systemd (PID 1), а не sshd,
    #    поэтому ss по имени процесса ничего не находит — спрашиваем сам юнит.
    #    Свойство называется Listen (вида "0.0.0.0:2222 (Stream) [::]:2222 (Stream)"),
    #    а не ListenStream, которое systemctl show не экспонирует.
    if [[ -z "$port" ]]; then
        port=$(systemctl show ssh.socket --property=Listen --value 2>/dev/null \
            | tr ' ' '\n' \
            | awk 'match($0, /:[0-9]+$/) { print substr($0, RSTART + 1); exit }')
    fi

    # 3) Последний рубеж: читаем эффективный конфиг юнита (основной + все drop-in).
    if [[ -z "$port" ]]; then
        # Пустой "ListenStream=" сбрасывает накопленный список — воспроизводим
        # эту семантику, иначе прочитаем порт из базового юнита вместо drop-in.
        port=$(systemctl cat ssh.socket 2>/dev/null \
            | awk -F= '
                /^[[:space:]]*ListenStream=[[:space:]]*$/ { found = ""; next }
                /^[[:space:]]*ListenStream=/ {
                    if (found == "") {
                        n = split($2, a, ":"); gsub(/[[:space:]]/, "", a[n]);
                        if (a[n] ~ /^[0-9]+$/) found = a[n]
                    }
                }
                END { print found }')
    fi

    echo "$port"
}

# Доступен ли в системе стек IPv6. Если ядро загружено с ipv6.disable=1,
# /proc/net/if_inet6 отсутствует, и ListenStream=[::]:port развалит ssh.socket.
ipv6_available() {
    [[ -e /proc/net/if_inet6 ]]
}

# Список listen-адресов на указанном порту (по одному в строке), напр. "0.0.0.0:2222".
listeners_on_port() {
    local port="$1"
    command -v ss >/dev/null 2>&1 || return 0
    ss -tln 2>/dev/null | awk -v p=":$port" '$1 == "LISTEN" && $4 ~ (p "$") { print $4 }'
}

# Есть ли среди слушателей явный IPv4 (0.0.0.0:port или конкретный a.b.c.d:port).
ipv4_listener_present() {
    local port="$1" line
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        [[ "$line" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]+$ ]] && return 0
    done < <(listeners_on_port "$port")
    return 1
}

# Реальная проверка доступности по TCP: единственный надёжный способ отличить
# IPv6-only сокет от dual-stack, потому что ss в обоих случаях печатает "[::]:port".
tcp_probe() {
    local host="$1" port="$2"
    timeout 3 bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null
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
    [[ -f "$SOCKET_FILE" ]] \
        || [[ -f /usr/lib/systemd/system/ssh.socket ]] \
        || systemctl list-unit-files ssh.socket 2>/dev/null | grep -q '^ssh\.socket'
}

# Реально ли ssh.socket участвует в загрузке (активен или включён в автозапуск).
# Если сокета нет/он выключен — трогать его при рестарте не надо, иначе мы
# добавим socket-активацию туда, где sshd слушает сам.
socket_activation_enabled() {
    has_ssh_socket || return 1
    systemctl is-active  --quiet ssh.socket 2>/dev/null && return 0
    systemctl is-enabled --quiet ssh.socket 2>/dev/null && return 0
    return 1
}

# Нужна ли миграция уже существующего override, написанного старой версией скрипта.
# Симптом: строка "ListenStream=<порт>" без адреса. Базовый юнит Ubuntu/Debian
# содержит BindIPv6Only=ipv6-only, поэтому такой сокет поднимается ТОЛЬКО на [::],
# и sshd перестаёт принимать соединения по IPv4 (0.0.0.0), внешне выглядя рабочим.
socket_override_is_legacy() {
    [[ -f "$SOCKET_OVERRIDE_FILE" ]] || return 1
    grep -qF "$OVERRIDE_MARKER" "$SOCKET_OVERRIDE_FILE" || return 0
    grep -qE '^[[:space:]]*ListenStream=[0-9]+[[:space:]]*$' "$SOCKET_OVERRIDE_FILE" && return 0
    grep -qE '^[[:space:]]*ListenStream=0\.0\.0\.0:[0-9]+[[:space:]]*$' "$SOCKET_OVERRIDE_FILE" || return 0
    return 1
}

# Нужно ли перезаписать override и передёрнуть сокет, даже если порт уже "тот самый".
needs_socket_migration() {
    local port="$1"
    has_ssh_socket || return 1
    socket_override_is_legacy && return 0
    [[ -n "$port" ]] && ! ipv4_listener_present "$port" && return 0
    return 1
}

# Создаём drop-in override для ssh.socket вместо правки /lib/systemd/...
# Пустой "ListenStream=" сбрасывает все ListenStream из основного юнита, дальше
# задаём АДРЕСА ЯВНО. Голый "ListenStream=<порт>" использовать нельзя: базовый юнит
# ssh.socket в Ubuntu/Debian содержит BindIPv6Only=ipv6-only, и сокет без адреса
# создаётся только в AF_INET6 — IPv4 (0.0.0.0) не слушается вообще.
configure_ssh_socket_override() {
    local port="$1"
    local ipv4_only="${2:-0}"

    log_info "Configuring ssh.socket drop-in override for port $port..."

    if socket_override_is_legacy; then
        log_warning "Existing $SOCKET_OVERRIDE_FILE uses the legacy IPv6-only format:"
        sed -n 's/^/    /p' "$SOCKET_OVERRIDE_FILE" | while IFS= read -r line; do
            log_warning "$line"
        done
        log_warning "Rewriting it with explicit IPv4 + IPv6 ListenStream entries."
    fi

    mkdir -p "$SOCKET_OVERRIDE_DIR"
    {
        echo "# Managed by $SCRIPT_NAME — do not edit manually"
        echo "$OVERRIDE_MARKER"
        echo "[Socket]"
        echo "# Пустое значение сбрасывает ListenStream из основного юнита."
        echo "ListenStream="
        echo "ListenStream=0.0.0.0:$port"
        if [[ "$ipv4_only" -eq 0 ]] && ipv6_available; then
            echo "ListenStream=[::]:$port"
            # Дублируем ipv6-only явно: в базовом юните Ubuntu/Debian он есть, но на
            # других дистрибутивах [::] стал бы dual-stack и конфликтовал бы
            # с 0.0.0.0 по EADDRINUSE — сокет не поднялся бы вовсе.
            echo "BindIPv6Only=ipv6-only"
        fi
    } > "$SOCKET_OVERRIDE_FILE"
    chmod 0644 "$SOCKET_OVERRIDE_FILE"

    log_success "Created socket override: $SOCKET_OVERRIDE_FILE"
    sed -n 's/^/    /p' "$SOCKET_OVERRIDE_FILE" | while IFS= read -r line; do
        log_info "$line"
    done

    # Предупреждаем, если /lib/systemd/system/ssh.socket повреждён предыдущей
    # (багованной) версией скрипта (например, "ListenStream=5322.0.0.0:22").
    if [[ -f "$SOCKET_FILE" ]] && grep -qE '^ListenStream=[0-9]{4,}\.' "$SOCKET_FILE"; then
        log_warning "$SOCKET_FILE looks corrupted (likely from an older buggy run)."
        log_warning "Override will take precedence, but consider running:"
        log_warning "  apt install --reinstall openssh-server"
    fi
}

reload_ssh_services() {
    local port="$1"

    log_info "Reloading systemd configuration..."
    systemctl daemon-reload

    local ssh_service
    ssh_service=$(get_ssh_service_name) || die "Cannot determine SSH service name"

    # На socket-активированных системах одного `systemctl restart ssh.socket` мало:
    # запущенный ssh.service держит копию слушающего fd, полученного от СТАРОГО
    # сокета, и продолжает обслуживать старый bind. Поэтому гасим сервис первым,
    # затем пересоздаём сокет с новым биндингом, затем поднимаем сервис заново
    # (systemd передаст ему fd уже нового сокета).
    # Существующие SSH-сессии переживают stop: у ssh.service KillMode=process.
    if socket_activation_enabled; then
        log_info "Socket activation detected — restarting ssh.socket + $ssh_service..."
        systemctl stop "$ssh_service" 2>/dev/null || true
        systemctl stop ssh.socket 2>/dev/null || true

        if ! systemctl start ssh.socket; then
            log_error "ssh.socket failed to start with dual-stack ListenStream."
            log_warning "Retrying with an IPv4-only override to keep SSH reachable..."
            configure_ssh_socket_override "$port" 1
            systemctl daemon-reload
            if ! systemctl start ssh.socket; then
                log_error "ssh.socket still fails to start"
                show_service_logs "ssh.socket"
                return 1
            fi
            log_warning "ssh.socket started in IPv4-only mode. IPv6 access is unavailable."
        fi
    fi

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

# Self-check после смены порта: убеждаемся, что слушатели поднялись И на IPv4,
# И на IPv6, а не только на [::]. Именно IPv4 отваливался в старой версии,
# из-за чего доступ через VPN/mesh (IPv6/оверлей) работал, а прямой — нет.
verify_ssh_listeners() {
    local port="$1"
    local has_v4=0 has_v6=0 line attempt

    log_info "Self-check: verifying listeners on port $port..."

    # Сокету нужно время подняться после restart — даём несколько попыток.
    for attempt in 1 2 3 4 5; do
        has_v4=0
        has_v6=0
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            if [[ "$line" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]+$ ]]; then
                has_v4=1
            elif [[ "$line" == \[* ]]; then
                has_v6=1
            fi
        done < <(listeners_on_port "$port")
        [[ "$has_v4" -eq 1 ]] && break
        sleep 1
    done

    log_info "  ss -tln listeners on :$port"
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        log_info "    $line"
    done < <(listeners_on_port "$port")

    # Живая TCP-проверка — единственный способ отличить IPv6-only сокет от dual-stack.
    local v4_ok=0 v6_ok=0
    tcp_probe 127.0.0.1 "$port" && v4_ok=1
    if ipv6_available; then
        tcp_probe ::1 "$port" && v6_ok=1
    fi

    if [[ "$v4_ok" -eq 1 ]]; then
        log_success "IPv4: connect to 127.0.0.1:$port OK"
    else
        log_error "IPv4: connect to 127.0.0.1:$port FAILED (connection refused)"
    fi

    if ipv6_available; then
        if [[ "$v6_ok" -eq 1 ]]; then
            log_success "IPv6: connect to [::1]:$port OK"
        else
            log_warning "IPv6: connect to [::1]:$port failed"
        fi
    fi

    if [[ "$has_v4" -eq 0 ]] || [[ "$v4_ok" -eq 0 ]]; then
        log_error "SSH is NOT listening on IPv4 (0.0.0.0:$port)."
        if [[ "$has_v6" -eq 1 ]]; then
            log_error "Only an IPv6 listener is present — this is exactly the IPv6-only"
            log_error "socket-activation bug: access over VPN/mesh works, direct IPv4"
            log_error "connections get 'Connection refused'."
        fi
        log_error "Check for a ListenAddress directive in $SSHD_CONFIG restricting"
        log_error "sshd to IPv6, and inspect: systemctl cat ssh.socket"
        return 1
    fi

    if [[ "$has_v6" -eq 0 ]] && ipv6_available; then
        log_warning "No IPv6 listener on [::]:$port — IPv6 clients will not connect."
    fi

    log_success "Self-check passed: SSH listens on both IPv4 and IPv6 (port $port)."
    return 0
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

    # Миграция серверов, где уже лежит старый (багованный) override с голым портом.
    # Без этой проверки скрипт уходил в ранний выход "no changes needed" — порт-то
    # совпадает — и никогда не чинил IPv6-only биндинг.
    local migrate=0
    if needs_socket_migration "$NEW_PORT"; then
        migrate=1
        log_warning "Detected an ssh.socket override without an explicit IPv4 bind."
        log_warning "SSH is likely listening on IPv6 only. Re-applying the fixed override."
    fi

    # "Ничего не делать" только если оба порта (конфиг и реальный) уже совпадают
    # с целевым И override не требует миграции.
    if [[ "$NEW_PORT" == "$current_port" ]] \
       && { [[ -z "$active_port" ]] || [[ "$NEW_PORT" == "$active_port" ]]; } \
       && [[ "$migrate" -eq 0 ]]; then
        log_warning "Port $NEW_PORT is already configured and active. No changes needed."
        exit 0
    fi

    if [[ "$NEW_PORT" == "$current_port" ]] && [[ -n "$active_port" ]] && [[ "$NEW_PORT" != "$active_port" ]]; then
        log_warning "sshd_config already has Port $NEW_PORT, but service listens on $active_port."
        log_warning "Will fix socket override and restart SSH to align."
    fi

    # Порт может быть "занят" нашим же sshd — это не повод падать.
    # При миграции целевой порт заведомо занят текущим (IPv6-only) слушателем.
    if [[ "$NEW_PORT" != "$active_port" ]] && [[ "$migrate" -eq 0 ]]; then
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

    if ! reload_ssh_services "$NEW_PORT"; then
        log_error "Failed to restart SSH service."
        exit 1
    fi
    
    # Настройка файрвола
    configure_firewall "$NEW_PORT"
    log_success "SSH service restarted successfully."

    # Self-check ДО удаления старого порта из файрвола: если новый порт слушается
    # некорректно, старый обязан остаться открытым, чтобы не потерять доступ.
    if ! verify_ssh_listeners "$NEW_PORT"; then
        log_error "Self-check FAILED — keep your current SSH session open!"
        log_error "Old port $current_port was left untouched in the firewall."
        show_service_logs "ssh.socket"
        exit 1
    fi

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
}

# Запуск
main "$@"
