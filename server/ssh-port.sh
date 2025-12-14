#!/bin/bash

log() {
    echo -e "$1"
    logger -t ssh-port-changer "$(echo -e "$1" | sed 's/\x1B\[[0-9;]*[JKmsu]//g')"  # без цвета
}

backup_file() {
    local file=$1
    if [ -f "$file" ]; then
        local timestamp=$(date +%Y%m%d_%H%M%S)
        cp "$file" "${file}.backup_$timestamp"
        log "\e[32mBackup created: ${file}.backup_$timestamp\e[0m"
    fi
}

check_root() {
    if [ "$EUID" -ne 0 ]; then 
        log "\e[31mPlease run the script as root (sudo).\e[0m"
        exit 1
    fi
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        os_name=$ID
        os_version=$VERSION_ID
    else
        os_name=$(lsb_release -is 2>/dev/null || echo "unknown")
        os_version=$(lsb_release -rs 2>/dev/null || echo "unknown")
    fi
    log "\e[34mDetected system: $os_name $os_version\e[0m"
}

get_current_port() {
    local config_file="$1"
    local port=$(grep -E '^[[:space:]]*Port[[:space:]]+[0-9]+' "$config_file" | awk '{print $2}' 2>/dev/null)
    if [ -z "$port" ]; then
        # Если Port не найден в конфиге, значит используется порт по умолчанию
        port="22"
    fi
    echo "$port"
}

ensure_port_directive_exists() {
    local file=$1
    if ! grep -qE '^\s*#?\s*Port\s+[0-9]+' "$file"; then
        echo "Port 22" >> "$file"
    fi
}

change_port_in_config() {
    local config_file=$1
    local port=$2
    sed -i -E "s/^#?Port[[:space:]]+[0-9]+/Port $port/" "$config_file"
    log "\e[32mPort was changed in the file: $config_file\e[0m"
    log "\e[32mNew port: $port\e[0m"
}

is_port_in_use() {
    local port=$1
    ss -tuln | grep -q ":$port "
}

validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

reload_ssh_services() {
    local version=$1
    
    # Специальная логика для Ubuntu 24.04 с socket-активацией
    if [ "$version" = "24.04" ]; then
        log "\e[34mUsing socket-activated SSH on Ubuntu 24.04\e[0m"
        systemctl daemon-reexec
        systemctl daemon-reload
        systemctl restart ssh.socket
        systemctl restart ssh.service
        return $?
    fi
    
    # Определяем имя SSH сервиса
    local ssh_service=""
    
    # Для RHEL/CentOS/AlmaLinux/Rocky обычно используется sshd.service
    if systemctl list-units --type=service --all | grep -q 'sshd.service'; then
        ssh_service="sshd.service"
    # Для Debian/Ubuntu обычно ssh.service
    elif systemctl list-units --type=service --all | grep -q 'ssh.service'; then
        ssh_service="ssh.service"
    # Fallback проверки
    elif [ -f /etc/systemd/system/sshd.service ] || [ -f /usr/lib/systemd/system/sshd.service ]; then
        ssh_service="sshd.service"
    elif [ -f /etc/systemd/system/ssh.service ] || [ -f /usr/lib/systemd/system/ssh.service ]; then
        ssh_service="ssh.service"
    else
        log "\e[31mCannot determine SSH service name\e[0m"
        return 1
    fi
    
    log "\e[34mRestarting SSH service: $ssh_service\e[0m"
    
    # Перезапускаем сервис
    if systemctl restart "$ssh_service"; then
        # Проверяем, что сервис действительно запустился
        sleep 2
        if systemctl is-active --quiet "$ssh_service"; then
            log "\e[32mSSH service $ssh_service restarted successfully\e[0m"
            return 0
        else
            log "\e[31mSSH service $ssh_service failed to start after restart\e[0m"
            # Показываем детали ошибки
            log "\e[31mService status:\e[0m"
            systemctl status "$ssh_service" --no-pager --lines=5 2>&1 | while read -r line; do
                log "\e[31m  $line\e[0m"
            done
            log "\e[31mJournal logs:\e[0m"
            journalctl -xeu "$ssh_service" --no-pager --lines=10 2>&1 | while read -r line; do
                log "\e[31m  $line\e[0m"
            done
            return 1
        fi
    else
        log "\e[31mFailed to restart SSH service $ssh_service\e[0m"
        # Показываем детали ошибки
        log "\e[31mService status:\e[0m"
        systemctl status "$ssh_service" --no-pager --lines=5 2>&1 | while read -r line; do
            log "\e[31m  $line\e[0m"
        done
        return 1
    fi
}

test_ssh_config() {
    log "\e[34mTesting SSH configuration...\e[0m"
    if command -v sshd >/dev/null 2>&1; then
        if sshd -t -f "$SSHD_CONFIG" 2>/dev/null; then
            log "\e[32mSSH configuration is valid\e[0m"
            return 0
        else
            log "\e[31mSSH configuration has errors:\e[0m"
            sshd -t -f "$SSHD_CONFIG" 2>&1 | while read -r line; do
                log "\e[31m  $line\e[0m"
            done
            return 1
        fi
    else
        log "\e[33mWarning: sshd command not found, skipping config test\e[0m"
        return 0
    fi
}

test_port_reachable() {
    local port=$1
    log "\e[34mTesting SSH on port $port...\e[0m"
    if timeout 3 bash -c "</dev/tcp/127.0.0.1/$port" &>/dev/null; then
        log "\e[32mPort $port is reachable locally.\e[0m"
    else
        log "\e[33mWarning: Port $port is not reachable locally. Check firewall or SSH config.\e[0m"
    fi
}

configure_selinux() {
    local port=$1
    
    # Проверяем SELinux для RHEL-based систем
    if command -v semanage >/dev/null 2>&1 && [ -f /etc/selinux/config ]; then
        local selinux_status=$(getenforce 2>/dev/null || echo "unknown")
        log "\e[34mSELinux status: $selinux_status\e[0m"
        
        if [ "$selinux_status" = "Enforcing" ] || [ "$selinux_status" = "Permissive" ]; then
            log "\e[34mConfiguring SELinux for SSH port $port...\e[0m"
            
            # Проверяем, разрешен ли порт для SSH в SELinux
            if ! semanage port -l | grep ssh_port_t | grep -q "$port"; then
                if semanage port -a -t ssh_port_t -p tcp "$port" 2>/dev/null; then
                    log "\e[32mSELinux: SSH port $port added successfully\e[0m"
                else
                    log "\e[33mWarning: Failed to add SSH port $port to SELinux. This may cause issues.\e[0m"
                fi
            else
                log "\e[33mSELinux: SSH port $port already configured\e[0m"
            fi
        fi
    elif [ "$os_name" = "almalinux" ] || [ "$os_name" = "rocky" ] || [ "$os_name" = "rhel" ] || [ "$os_name" = "centos" ]; then
        log "\e[33mSELinux tools not found. Installing policycoreutils-python-utils...\e[0m"
        if command -v dnf >/dev/null 2>&1; then
            dnf install -y policycoreutils-python-utils 2>/dev/null && {
                log "\e[32mSELinux tools installed successfully\e[0m"
                # Повторяем попытку конфигурации SELinux
                configure_selinux "$port"
                return
            }
        elif command -v yum >/dev/null 2>&1; then
            yum install -y policycoreutils-python-utils 2>/dev/null && {
                log "\e[32mSELinux tools installed successfully\e[0m"
                # Повторяем попытку конфигурации SELinux
                configure_selinux "$port"
                return
            }
        fi
        log "\e[33mFailed to install SELinux tools. Please install manually: dnf install policycoreutils-python-utils\e[0m"
    fi
}

configure_firewall() {
    local port=$1
    
    # Проверяем firewalld (RHEL/CentOS/AlmaLinux/Rocky)
    if command -v firewall-cmd >/dev/null 2>&1; then
        log "\e[34mConfiguring firewalld for port $port...\e[0m"
        
        # Проверяем, запущен ли firewalld
        if systemctl is-active --quiet firewalld; then
            # Проверяем, не открыт ли порт уже
            if ! firewall-cmd --list-ports | grep -q "$port/tcp"; then
                firewall-cmd --permanent --add-port="$port/tcp"
                firewall-cmd --reload
                log "\e[32mPort $port added to firewalld rules.\e[0m"
            else
                log "\e[33mPort $port already allowed in firewalld.\e[0m"
            fi
        else
            log "\e[33mFirewalld is not active. Adding rule anyway...\e[0m"
            firewall-cmd --permanent --add-port="$port/tcp"
            log "\e[32mPort $port rule added (firewalld not active).\e[0m"
        fi
    
    # Проверяем UFW (Debian/Ubuntu)
    elif command -v ufw >/dev/null 2>&1; then
        log "\e[34mConfiguring UFW for port $port...\e[0m"
        if ! ufw status | grep -q "$port"; then
            ufw allow "$port"/tcp
            log "\e[32mPort $port added to UFW rules.\e[0m"
        else
            log "\e[33mPort $port already allowed in UFW.\e[0m"
        fi
    
    # Fallback к iptables
    elif command -v iptables >/dev/null 2>&1; then
        log "\e[34mUsing iptables for port $port...\e[0m"
        if ! iptables -L INPUT -n | grep -q ":$port "; then
            iptables -A INPUT -p tcp --dport "$port" -j ACCEPT
            log "\e[32mPort $port added to iptables rules.\e[0m"
            log "\e[33mNote: iptables rules may not persist after reboot.\e[0m"
        else
            log "\e[33mPort $port already allowed in iptables.\e[0m"
        fi
    
    else
        log "\e[33mNo supported firewall found (firewalld/ufw/iptables). Please configure manually.\e[0m"
    fi
}

remove_old_port_from_selinux() {
    local port=$1
    
    # Не удаляем стандартный порт 22
    if [ "$port" = "22" ]; then
        log "\e[33mSkipping removal of standard SSH port 22 from SELinux\e[0m"
        return 0
    fi
    
    # Проверяем SELinux для RHEL-based систем
    if command -v semanage >/dev/null 2>&1; then
        local selinux_status=$(getenforce 2>/dev/null || echo "unknown")
        
        if [ "$selinux_status" = "Enforcing" ] || [ "$selinux_status" = "Permissive" ]; then
            log "\e[34mRemoving old SSH port $port from SELinux...\e[0m"
            
            # Проверяем, есть ли порт в SELinux правилах
            if semanage port -l | grep ssh_port_t | grep -q "$port"; then
                if semanage port -d -t ssh_port_t -p tcp "$port" 2>/dev/null; then
                    log "\e[32mSELinux: SSH port $port removed successfully\e[0m"
                else
                    log "\e[33mWarning: Failed to remove SSH port $port from SELinux\e[0m"
                fi
            else
                log "\e[33mSELinux: SSH port $port was not in rules\e[0m"
            fi
        fi
    fi
}

remove_old_port_from_firewall() {
    local port=$1
    
    # Firewalld (RHEL/CentOS/AlmaLinux/Rocky)
    if command -v firewall-cmd >/dev/null 2>&1; then
        if systemctl is-active --quiet firewalld; then
            if firewall-cmd --list-ports | grep -q "$port/tcp"; then
                firewall-cmd --permanent --remove-port="$port/tcp"
                firewall-cmd --reload
                log "\e[32mOld port $port removed from firewalld.\e[0m"
            else
                log "\e[33mOld port $port was not in firewalld rules.\e[0m"
            fi
        else
            log "\e[33mFirewalld is not active. Cannot remove port $port.\e[0m"
        fi
    
    # UFW (Debian/Ubuntu)  
    elif command -v ufw >/dev/null 2>&1; then
        if ufw status | grep -q 'Status: active'; then
            if ufw status | grep -q "$port"; then
                ufw delete allow "$port"/tcp
                log "\e[32mOld port $port removed from UFW.\e[0m"
            else
                log "\e[33mOld port $port was not in UFW rules.\e[0m"
            fi
        else
            log "\e[33mUFW is installed but not active. Cannot remove port $port.\e[0m"
        fi
    
    else
        log "\e[33mNo supported firewall found. Please remove port $port manually.\e[0m"
    fi
}

# ---------------- MAIN ---------------- #

check_root
detect_os

SSHD_CONFIG="/etc/ssh/sshd_config"
SOCKET_FILE="/lib/systemd/system/ssh.socket"

AUTO_YES=0
REMOVE_OLD_PORT=0
NEW_PORT=""

# Флаги
while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes)
            AUTO_YES=1
            shift
            ;;
        --port)
            NEW_PORT="$2"
            shift 2
            ;;
        --remove-old-port)
            REMOVE_OLD_PORT=1
            shift
            ;;
        *)
            log "\e[31mUnknown option: $1\e[0m"
            exit 1
            ;;
    esac
done

current_port=$(get_current_port "$SSHD_CONFIG")
log "\e[34mCurrent SSH port: $current_port\e[0m"

if [ -z "$NEW_PORT" ] && [ "$AUTO_YES" -eq 0 ]; then
    while true; do
        read -p "Enter a new port for SSH (1-65535): " NEW_PORT
        if validate_port "$NEW_PORT"; then
            break
        else
            log "\e[31mInvalid port number. Must be between 1 and 65535.\e[0m"
        fi
    done
fi

# Проверки
if ! validate_port "$NEW_PORT"; then
    log "\e[31mInvalid or missing port. Use --port <1-65535>.\e[0m"
    exit 1
fi

if [ "$NEW_PORT" = "$current_port" ]; then
    log "\e[33mThe new port is the same as the current SSH port. No changes needed.\e[0m"
    exit 0
fi

if is_port_in_use "$NEW_PORT"; then
    log "\e[31mPort $NEW_PORT is already in use.\e[0m"
    exit 1
fi

backup_file "$SSHD_CONFIG"
ensure_port_directive_exists "$SSHD_CONFIG"
change_port_in_config "$SSHD_CONFIG" "$NEW_PORT"

if [ "$os_version" = "24.04" ] && [ -f "$SOCKET_FILE" ]; then
    backup_file "$SOCKET_FILE"
    sed -i -E "s/ListenStream=\s*[0-9]+/ListenStream=$NEW_PORT/" "$SOCKET_FILE"
    log "\e[32mUpdated ListenStream in: $SOCKET_FILE\e[0m"
fi

# Проверяем конфигурацию перед перезапуском
if ! test_ssh_config; then
    log "\e[31mSSH configuration is invalid. Restoring backup...\e[0m"
    # Ищем последний backup файл
    backup_file=$(ls -t "${SSHD_CONFIG}.backup_"* 2>/dev/null | head -1)
    if [ -n "$backup_file" ] && [ -f "$backup_file" ]; then
        cp "$backup_file" "$SSHD_CONFIG"
        log "\e[32mBackup restored from: $backup_file\e[0m"
    else
        log "\e[31mNo backup file found!\e[0m"
    fi
    exit 1
fi

configure_selinux "$NEW_PORT"

reload_ssh_services "$os_version"
status=$?

configure_firewall "$NEW_PORT"
if [ $status -eq 0 ]; then
    log "\e[32mSSH service restarted successfully.\e[0m"

    if [ "$AUTO_YES" -eq 0 ]; then
        read -p "Remove old SSH port $current_port from firewall? [y/N]: " answer
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            remove_old_port_from_firewall "$current_port"
            remove_old_port_from_selinux "$current_port"
        fi
    elif [ "$REMOVE_OLD_PORT" -eq 1 ]; then
        remove_old_port_from_firewall "$current_port"
        remove_old_port_from_selinux "$current_port"
    fi
else
    log "\e[31mFailed to restart SSH service.\e[0m"
    exit 1
fi

test_port_reachable "$NEW_PORT"
