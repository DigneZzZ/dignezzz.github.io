#!/bin/bash

# ============================================================================
# SSH Port Changer
# Safely changes the sshd listening port on systemd-based Linux.
#
# Features:
#   - systemd socket activation (ssh.socket / sshd.socket, Ubuntu 22.10+/24.04)
#     with explicit dual-stack binds (0.0.0.0 + [::]) — avoids the IPv6-only trap
#   - firewall support: firewalld / ufw / iptables+ip6tables (active backend
#     is detected, the NEW port is opened BEFORE sshd moves off the old one)
#   - SELinux (semanage port) on RHEL-based systems
#   - handles /etc/ssh/sshd_config.d drop-ins and multiple Port directives
#   - full automatic rollback (config, override, firewall, services) on any
#     failure, Ctrl-C included
#   - post-change self-check: both IPv4 and IPv6 listeners + live TCP probes
#
# Usage:
#   wget -qO- https://dignezzz.github.io/server/ssh-port.sh | sudo bash -s -- --port 5322
#
# Exit codes:
#   0 — success (or nothing to do)
#   1 — aborted; the system was left in (or rolled back to) its previous state
#   2 — usage / environment error; nothing was changed
#   3 — FAILED and automatic rollback was incomplete — inspect before logout!
# ============================================================================

set -Eeuo pipefail

# Единая локаль: мы парсим вывод ufw/iptables/systemctl, локализация его ломает
export LC_ALL=C

# ВАЖНО: не "VERSION" — /etc/os-release определяет VERSION=, и сорсинг его
# в detect_os() упал бы на попытке присвоить readonly-переменной.
readonly SCRIPT_VERSION="2.0.1"
readonly SCRIPT_NAME="ssh-port-changer"

# Цвета для вывода
readonly RED='\e[31m'
readonly GREEN='\e[32m'
readonly YELLOW='\e[33m'
readonly BLUE='\e[34m'
readonly NC='\e[0m'  # No Color

# Конфигурация
readonly SSHD_CONFIG="/etc/ssh/sshd_config"
readonly SSHD_CONFIG_DIR="/etc/ssh/sshd_config.d"
readonly BACKUP_KEEP=5
# Маркер формата drop-in override. Если в файле его нет — значит override писала
# старая версия скрипта (голый "ListenStream=<порт>", IPv6-only) и его надо мигрировать.
readonly OVERRIDE_MARKER="# ssh-port-changer-format: dual-stack-v2"

# ============================================================================
# Глобальное состояние (заполняется по ходу работы; нужно rollback-движку)
# ============================================================================

os_name=""
os_like=""
os_version=""

SSHD_BIN=""               # путь к бинарнику sshd
SSH_SERVICE=""            # ssh.service | sshd.service
SOCKET_UNIT=""            # ssh.socket | sshd.socket | "" (нет юнита)
SOCKET_OVERRIDE_DIR=""    # /etc/systemd/system/<unit>.d
SOCKET_OVERRIDE_FILE=""   # .../override.conf
USE_SOCKET=0              # socket activation реально используется

NEW_PORT=""
ORIG_CONFIG_PORT=""       # порт из конфига до изменений
ORIG_ACTIVE_PORT=""       # реально слушавшийся порт до изменений
AUTO_YES=0
REMOVE_OLD_PORT=0
OLD_REMOVED=0             # старые порты реально удалены из файрвола
ACTION="change"           # change | status

FW_BACKEND="none"         # firewalld | ufw | iptables | none
FW_CHANGED=0              # firewall_allow_port реально что-то добавил

# Состояние для rollback
MUTATED=0                 # менялись ли конфиги на диске
SERVICES_TOUCHED=0        # дошли ли до рестарта юнитов
FIREWALL_ADDED=0          # добавляли ли правило для нового порта
SELINUX_ADDED=0           # добавляли ли новый порт в SELinux
COMPLETED=0               # main дошёл до конца
FINALIZED=0               # завершение уже обработано (страховка от повторного входа)
BACKUP_CONFIG=""          # путь к бэкапу sshd_config
BACKUP_OVERRIDE=""        # путь к бэкапу override.conf; "ABSENT" = файла не было
declare -a INCLUDE_BACKUPS=()  # элементы "файл|бэкап" для drop-in'ов sshd_config.d

# ============================================================================
# Логирование и завершение
# ============================================================================

log() {
    local message="$1"
    echo -e "$message"
    logger -t "$SCRIPT_NAME" "$(echo -e "$message" | sed 's/\x1B\[[0-9;]*[JKmsu]//g')" 2>/dev/null || true
}

log_info()    { log "${BLUE}$1${NC}"; }
log_success() { log "${GREEN}$1${NC}"; }
log_warning() { log "${YELLOW}$1${NC}"; }
log_error()   { log "${RED}$1${NC}"; }

# Контролируемое завершение с откатом. fail <код> [сообщение]
fail() {
    local code="${1:-1}"
    shift || true
    [[ $# -gt 0 ]] && log_error "$*"
    finalize "$code"
}

usage_error() { fail 2 "$1"; }   # ошибка использования/окружения — ничего не менялось

# Единая точка выхода при ошибке: откатывает всё, что успели изменить.
finalize() {
    local code="$1"
    # В сабшелле (process substitution, $(...)) откат запускать нельзя:
    # выходим тихо, решение примет родительский процесс.
    if [[ "${BASHPID:-$$}" != "$$" ]]; then
        exit "$code"
    fi
    [[ "$FINALIZED" -eq 1 ]] && exit "$code"
    FINALIZED=1
    trap - ERR EXIT
    trap '' INT TERM HUP   # повторный Ctrl-C не должен убить откат на середине
    set +e

    if [[ "$COMPLETED" -eq 0 ]] && { [[ "$MUTATED" -eq 1 ]] || [[ "$FIREWALL_ADDED" -eq 1 ]] || [[ "$SELINUX_ADDED" -eq 1 ]]; }; then
        if rollback_all; then
            log_warning "System restored to its previous state."
        else
            code=3
            log_error "=================================================================="
            log_error "ROLLBACK INCOMPLETE — inspect the system BEFORE closing this session!"
            log_error "=================================================================="
            print_manual_recovery
        fi
    fi
    exit "$code"
}

# shellcheck disable=SC2329  # вызывается через trap
on_error() {
    local rc=$1 line=$2
    log_error "Unexpected failure (exit code $rc) at line $line."
    finalize 1
}

# shellcheck disable=SC2329  # вызывается через trap
on_signal() {
    echo ""
    log_error "Interrupted."
    finalize 130
}

# shellcheck disable=SC2329  # вызывается через trap
on_exit() {
    # Страховка: сюда попадаем только если выход миновал fail()/finalize()
    # (например, exit из необработанного места или ошибка bash под set -u).
    local rc=$?
    [[ "$FINALIZED" -eq 1 ]] && return 0
    [[ "$rc" -eq 0 && "$COMPLETED" -eq 1 ]] && return 0
    [[ "$rc" -eq 0 && "$MUTATED" -eq 0 && "$FIREWALL_ADDED" -eq 0 && "$SELINUX_ADDED" -eq 0 ]] && return 0
    finalize "$rc"
}

# ============================================================================
# Rollback
# ============================================================================

rollback_all() {
    local ok=0 entry f b
    log_warning "Rolling back changes..."

    # 1. Файлы конфигурации
    if [[ -n "$BACKUP_CONFIG" && -f "$BACKUP_CONFIG" ]]; then
        cp -p "$BACKUP_CONFIG" "$SSHD_CONFIG" || ok=1
    fi
    if [[ ${#INCLUDE_BACKUPS[@]} -gt 0 ]]; then
        for entry in "${INCLUDE_BACKUPS[@]}"; do
            f="${entry%%|*}"; b="${entry##*|}"
            [[ -f "$b" ]] && { cp -p "$b" "$f" || ok=1; }
        done
    fi
    case "$BACKUP_OVERRIDE" in
        "")     : ;;
        ABSENT) rm -f "$SOCKET_OVERRIDE_FILE" ;;
        *)      [[ -f "$BACKUP_OVERRIDE" ]] && { cp -p "$BACKUP_OVERRIDE" "$SOCKET_OVERRIDE_FILE" || ok=1; } ;;
    esac

    # 2. Сервисы: сначала возвращаем SSH на восстановленные конфиги,
    #    и только потом трогаем файрвол — если нас убьют между шагами,
    #    доступ по старому порту уже работает.
    if [[ "$SERVICES_TOUCHED" -eq 1 ]]; then
        local svc_ok=0
        systemctl daemon-reload 2>/dev/null || true
        if [[ "$USE_SOCKET" -eq 1 && -n "$SOCKET_UNIT" ]]; then
            systemctl stop "$SSH_SERVICE" 2>/dev/null
            systemctl stop "$SOCKET_UNIT" 2>/dev/null
            systemctl start "$SOCKET_UNIT" 2>/dev/null || svc_ok=1
        fi
        systemctl restart "$SSH_SERVICE" 2>/dev/null || svc_ok=1
        sleep 1
        # Истина — фактические слушатели, а не коды выхода юнитов:
        # если старый порт снова слушается, откат сервисов удался.
        if [[ -n "$ORIG_ACTIVE_PORT" ]]; then
            if [[ -z "$(listeners_on_port "$ORIG_ACTIVE_PORT")" ]]; then
                log_error "After rollback nothing listens on the original port $ORIG_ACTIVE_PORT!"
                ok=1
            fi
        else
            [[ "$svc_ok" -eq 1 ]] && ok=1
        fi
    fi

    # 3. Файрвол: убираем правило, добавленное этим запуском для нового порта
    if [[ "$FIREWALL_ADDED" -eq 1 && -n "$NEW_PORT" ]]; then
        firewall_remove_port "$FW_BACKEND" "$NEW_PORT" >/dev/null 2>&1 || true
    fi

    # 4. SELinux: убираем добавленный порт
    if [[ "$SELINUX_ADDED" -eq 1 && -n "$NEW_PORT" && "$NEW_PORT" != "22" ]]; then
        semanage port -d -t ssh_port_t -p tcp "$NEW_PORT" 2>/dev/null || true
    fi

    return "$ok"
}

print_manual_recovery() {
    local L="${1:-log_error}" entry f b
    "$L" "Manual recovery:"
    [[ -n "$BACKUP_CONFIG" ]]   && "$L" "  cp -p '$BACKUP_CONFIG' '$SSHD_CONFIG'"
    if [[ ${#INCLUDE_BACKUPS[@]} -gt 0 ]]; then
        for entry in "${INCLUDE_BACKUPS[@]}"; do
            f="${entry%%|*}"; b="${entry##*|}"
            "$L" "  cp -p '$b' '$f'"
        done
    fi
    if [[ "$BACKUP_OVERRIDE" == "ABSENT" ]]; then
        "$L" "  rm -f '$SOCKET_OVERRIDE_FILE'"
    elif [[ -n "$BACKUP_OVERRIDE" ]]; then
        "$L" "  cp -p '$BACKUP_OVERRIDE' '$SOCKET_OVERRIDE_FILE'"
    fi
    "$L" "  systemctl daemon-reload"
    if [[ "$USE_SOCKET" -eq 1 && -n "$SOCKET_UNIT" ]]; then
        "$L" "  systemctl stop $SSH_SERVICE $SOCKET_UNIT && systemctl start $SOCKET_UNIT && systemctl restart $SSH_SERVICE"
    else
        "$L" "  systemctl restart ${SSH_SERVICE:-sshd}"
    fi
    "$L" "  ss -tlnp | grep sshd    # verify listeners"
}

# ============================================================================
# Вспомогательные функции
# ============================================================================

# Есть ли настоящий управляющий терминал (у "wget | bash" он есть, у cron — нет)
have_tty() {
    [[ -e /dev/tty ]] && (exec 3<>/dev/tty) 2>/dev/null
}

confirm() {
    local prompt="$1" ans=""
    [[ "$AUTO_YES" -eq 1 ]] && return 0
    read -rp "$prompt [y/N]: " ans </dev/tty || return 1
    [[ "$ans" =~ ^[Yy]([Ee][Ss])?$ ]]
}

backup_file() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    local backup
    backup="${file}.backup_$(date +%Y%m%d_%H%M%S)"
    cp -p "$file" "$backup"
    log_success "Backup created: $backup"
    echo "$backup"
}

# Оставляем только BACKUP_KEEP последних бэкапов файла
prune_backups() {
    local file="$1" old
    while IFS= read -r old; do
        [[ -n "$old" ]] && rm -f "$old"
    done < <(find "$(dirname "$file")" -maxdepth 1 -name "$(basename "$file").backup_*" 2>/dev/null \
                 | sort -r | tail -n +"$((BACKUP_KEEP + 1))")
}

check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        log_error "Please run the script as root (sudo)."
        echo ""
        echo -e "${BLUE}Example / Пример:${NC}"
        echo -e "  wget -qO- https://dignezzz.github.io/server/ssh-port.sh | sudo bash -s -- --port 5322"
        FINALIZED=1
        exit 2
    fi
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        # Сорсим в сабшелле: os-release определяет десятки переменных (VERSION,
        # NAME, ID...) — не даём им засорять или конфликтовать с нашими.
        # shellcheck source=/dev/null
        os_name=$(. /etc/os-release 2>/dev/null && echo "${ID:-unknown}")
        # shellcheck source=/dev/null
        os_like=$(. /etc/os-release 2>/dev/null && echo "${ID_LIKE:-}")
        # shellcheck source=/dev/null
        os_version=$(. /etc/os-release 2>/dev/null && echo "${VERSION_ID:-unknown}")
    else
        os_name=$(lsb_release -is 2>/dev/null || echo "unknown")
        os_version=$(lsb_release -rs 2>/dev/null || echo "unknown")
    fi
    log_info "Detected system: $os_name $os_version"
}

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    port=$((10#$port))   # защита от восьмеричной интерпретации "022"
    (( port >= 1 && port <= 65535 ))
}

# Живая TCP-проверка: единственный надёжный способ отличить IPv6-only сокет
# от dual-stack, потому что ss в обоих случаях может печатать "[::]:port".
tcp_probe() {
    local host="$1" port="$2"
    timeout 3 bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null
}

# Доступен ли в системе стек IPv6. Если ядро загружено с ipv6.disable=1,
# /proc/net/if_inet6 отсутствует, и ListenStream=[::]:port развалит socket-юнит.
ipv6_available() {
    [[ -e /proc/net/if_inet6 ]]
}

# ============================================================================
# Инспекция портов и слушателей
# ============================================================================

# Список listen-адресов на порту (по одному в строке), напр. "0.0.0.0:2222".
# pipefail-безопасно: сначала захватываем вывод, потом обрабатываем.
listeners_on_port() {
    local port="$1" out
    out=$(ss -tln 2>/dev/null || true)
    awk -v p=":$port" '$1 == "LISTEN" && $4 ~ (p "$") { print $4 }' <<< "$out"
}

# Есть ли явный IPv4-листенер (a.b.c.d:port) или wildcard старых ss ("*:port")
ipv4_listener_present() {
    local port="$1" line
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        [[ "$line" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]+$ ]] && return 0
        [[ "$line" == "*:$port" ]] && return 0
    done < <(listeners_on_port "$port")
    return 1
}

# Занят ли порт кем-либо (только TCP LISTEN; точное совпадение порта)
is_port_in_use() {
    local port="$1" out
    out=$(ss -tln 2>/dev/null || true)
    awk -v p=":$port" '$1 == "LISTEN" && $4 ~ (p "$") { found = 1 } END { exit !found }' <<< "$out"
}

# Порт удерживается самим SSH (sshd напрямую или socket-юнитом systemd)?
port_held_by_ssh() {
    local port="$1" out
    out=$(ss -tlnp 2>/dev/null || true)
    if awk -v p=":$port" '$4 ~ (p "$")' <<< "$out" | grep -q '"sshd"'; then
        return 0
    fi
    [[ -n "$SOCKET_UNIT" ]] || return 1
    systemctl is-active --quiet "$SOCKET_UNIT" 2>/dev/null || return 1
    systemctl show "$SOCKET_UNIT" --property=Listen --value 2>/dev/null \
        | tr ' ,' '\n' | grep -qE ":${port}\$"
}

# Реальный активный порт SSH: сначала sshd в ss, затем активный socket-юнит.
get_active_ssh_port() {
    local port="" out
    out=$(ss -tlnp 2>/dev/null || true)
    port=$(awk '/"sshd"/ { n = split($4, a, ":"); print a[n]; exit }' <<< "$out")
    if [[ -z "$port" && -n "$SOCKET_UNIT" ]] && systemctl is-active --quiet "$SOCKET_UNIT" 2>/dev/null; then
        port=$(systemctl show "$SOCKET_UNIT" --property=Listen --value 2>/dev/null \
            | tr ' ,' '\n' \
            | awk 'match($0, /:[0-9]+$/) { print substr($0, RSTART + 1); exit }' || true)
    fi
    echo "$port"
}

# ============================================================================
# Работа с конфигом sshd (включая drop-in'ы)
# ============================================================================

# Эффективные порты из sshd -T (авторитетный источник: учитывает Include)
effective_ports() {
    local out
    out=$("$SSHD_BIN" -T 2>/dev/null || true)
    awk '$1 == "port" { print $2 }' <<< "$out"
}

get_current_port() {
    local port
    port=$(effective_ports | head -1)
    if [[ -z "$port" ]]; then
        port=$(grep -iE '^[[:space:]]*Port[[:space:]]+[0-9]+' "$SSHD_CONFIG" 2>/dev/null \
                   | awk '{print $2; exit}' || true)
    fi
    echo "${port:-22}"
}

# ListenAddress с внедрённым портом ("ListenAddress 1.2.3.4:2200") переопределяет
# Port — менять порт правкой Port бессмысленно. Обнаруживаем и честно отказываемся.
find_listenaddress_with_port() {
    local f
    for f in "$SSHD_CONFIG" "$SSHD_CONFIG_DIR"/*.conf; do
        [[ -f "$f" ]] || continue
        grep -liE '^[[:space:]]*ListenAddress[[:space:]]+(\[[0-9a-fA-F:]+\]|([0-9]{1,3}\.){3}[0-9]{1,3}):[0-9]+([[:space:]]|$)' "$f" 2>/dev/null || true
    done
}

# Непинованные (не-wildcard) ListenAddress — влияют на self-check
pinned_listen_addresses() {
    local out v addr
    out=$("$SSHD_BIN" -T 2>/dev/null || true)
    while IFS= read -r v; do
        [[ -n "$v" ]] || continue
        addr="${v%:*}"           # отрезаем порт
        addr="${addr#[}"; addr="${addr%]}"
        case "$addr" in
            0.0.0.0|::|"") ;;
            *) echo "$addr" ;;
        esac
    done < <(awk '$1 == "listenaddress" { print $2 }' <<< "$out")
}

# Меняем Port в главном конфиге: первую активную директиву правим, дубликаты
# комментируем (Port аддитивен: несколько строк = несколько слушаемых портов!).
# Если активной директивы нет — вставляем в НАЧАЛО файла (до возможных Match-блоков;
# дописывание в конец сломало бы конфиг с завершающим Match).
set_port_in_config() {
    local file="$1" port="$2"
    local lines ln first=1
    # -i: ключевые слова sshd_config регистронезависимы ("port 22" валиден)
    lines=$(grep -inE '^[[:space:]]*Port[[:space:]]+[0-9]+' "$file" 2>/dev/null | cut -d: -f1 || true)

    if [[ -z "$lines" ]]; then
        if [[ ! -s "$file" ]]; then
            # sed '1i' на пустом файле — тихий no-op
            printf '# Port set by %s\nPort %s\n' "$SCRIPT_NAME" "$port" > "$file"
        else
            sed -i "1i # Port set by $SCRIPT_NAME\nPort $port" "$file"
        fi
        log_success "Port $port inserted into: $file"
        return 0
    fi

    while IFS= read -r ln; do
        [[ -n "$ln" ]] || continue
        if [[ "$first" -eq 1 ]]; then
            sed -i "${ln}s/.*/Port $port/" "$file"
            first=0
        else
            sed -i "${ln}s/^/# duplicate disabled by $SCRIPT_NAME: /" "$file"
            log_warning "Duplicate Port directive at line $ln disabled (Port is additive in sshd_config)"
        fi
    done <<< "$lines"
    log_success "Port changed to $port in: $file"
}

# Порты могут прятаться в /etc/ssh/sshd_config.d/*.conf (cloud-init и т.п.).
# Гасим их там (с бэкапом каждого тронутого файла).
neutralize_dropin_ports() {
    local f b
    [[ -d "$SSHD_CONFIG_DIR" ]] || return 0
    for f in "$SSHD_CONFIG_DIR"/*.conf; do
        [[ -f "$f" ]] || continue
        grep -qiE '^[[:space:]]*Port[[:space:]]+[0-9]+' "$f" || continue
        b=$(backup_file "$f" | tail -1)
        INCLUDE_BACKUPS+=("${f}|${b}")
        prune_backups "$f"
        sed -i -E "s/^([[:space:]]*[Pp][Oo][Rr][Tt][[:space:]]+[0-9]+.*)/# disabled by $SCRIPT_NAME: \1/" "$f"
        log_warning "Port directive in drop-in $f disabled (it would override the main config)"
    done
}

# Полный проход: главный конфиг -> drop-in'ы -> сверка с sshd -T
apply_config_port() {
    local port="$1" ports extra
    set_port_in_config "$SSHD_CONFIG" "$port"

    ports=$(effective_ports)
    if [[ -n "$ports" ]]; then
        extra=$(grep -vx "$port" <<< "$ports" || true)
        if [[ -n "$extra" ]]; then
            neutralize_dropin_ports
            ports=$(effective_ports)
            extra=$(grep -vx "$port" <<< "$ports" || true)
            if [[ -n "$extra" ]]; then
                log_error "sshd still resolves extra ports after edit: $(tr '\n' ' ' <<< "$extra")"
                log_error "Check Include directives in $SSHD_CONFIG."
                return 1
            fi
        fi
    fi
    return 0
}

# ============================================================================
# systemd: сервис и socket activation
# ============================================================================

get_ssh_service_name() {
    local unit resolved
    for unit in sshd.service ssh.service; do
        if systemctl is-active --quiet "$unit" 2>/dev/null; then
            resolved=$(systemctl show "$unit" --property=Id --value 2>/dev/null || true)
            echo "${resolved:-$unit}"; return 0
        fi
    done
    for unit in sshd.service ssh.service; do
        if systemctl is-enabled --quiet "$unit" 2>/dev/null; then
            resolved=$(systemctl show "$unit" --property=Id --value 2>/dev/null || true)
            echo "${resolved:-$unit}"; return 0
        fi
    done
    for unit in sshd.service ssh.service; do
        if systemctl cat "$unit" >/dev/null 2>&1; then
            echo "$unit"; return 0
        fi
    done
    return 1
}

detect_socket_unit() {
    local u
    SOCKET_UNIT=""
    for u in ssh.socket sshd.socket; do
        if systemctl cat "$u" >/dev/null 2>&1; then
            SOCKET_UNIT="$u"
            break
        fi
    done
    if [[ -n "$SOCKET_UNIT" ]]; then
        SOCKET_OVERRIDE_DIR="/etc/systemd/system/${SOCKET_UNIT}.d"
        SOCKET_OVERRIDE_FILE="${SOCKET_OVERRIDE_DIR}/override.conf"
    fi
}

# Socket activation реально используется (юнит активен или включён)?
socket_activation_enabled() {
    [[ -n "$SOCKET_UNIT" ]] || return 1
    systemctl is-active  --quiet "$SOCKET_UNIT" 2>/dev/null && return 0
    systemctl is-enabled --quiet "$SOCKET_UNIT" 2>/dev/null && return 0
    return 1
}

show_service_logs() {
    local service="$1" line
    log_error "Service status ($service):"
    while IFS= read -r line; do
        log_error "  $line"
    done < <(systemctl status "$service" --no-pager --lines=5 2>&1 || true)
    log_error "Journal logs:"
    while IFS= read -r line; do
        log_error "  $line"
    done < <(journalctl -xeu "$service" --no-pager --lines=10 2>&1 || true)
}

# Устаревший (багованный) формат override: "ListenStream=<порт>" без адреса.
# Базовый ssh.socket Ubuntu/Debian содержит BindIPv6Only=ipv6-only, поэтому такой
# сокет поднимается ТОЛЬКО на [::] — sshd перестаёт отвечать по IPv4.
socket_override_is_legacy() {
    [[ -n "$SOCKET_OVERRIDE_FILE" && -f "$SOCKET_OVERRIDE_FILE" ]] || return 1
    # Решаем по СОДЕРЖИМОМУ, а не по маркеру: корректный рукописный override
    # (с явными адресами) переписывать не нужно.
    grep -qE '^[[:space:]]*ListenStream=[0-9]+[[:space:]]*$' "$SOCKET_OVERRIDE_FILE" && return 0
    grep -qE '^[[:space:]]*ListenStream=' "$SOCKET_OVERRIDE_FILE" || return 1
    grep -qE '^[[:space:]]*ListenStream=(0\.0\.0\.0|\*):' "$SOCKET_OVERRIDE_FILE" || return 0
    return 1
}

# Нужен ли принудительный прогон (даже при совпадающем порте) из-за битого override.
# Проверяем АКТИВНЫЙ порт (не целевой!) и только при реально используемом сокете.
needs_socket_migration() {
    socket_activation_enabled || return 1
    socket_override_is_legacy && return 0
    local ap ls
    ap=$(get_active_ssh_port)
    [[ -n "$ap" ]] || return 1
    ls=$(listeners_on_port "$ap")
    # слушатели есть, но IPv4 среди них нет — симптом IPv6-only биндинга
    [[ -n "$ls" ]] && ipv6_available && ! ipv4_listener_present "$ap" && return 0
    return 1
}

# Drop-in с ЯВНЫМИ адресами. Голый "ListenStream=<порт>" недопустим (см. выше).
configure_ssh_socket_override() {
    local port="$1"
    local ipv4_only="${2:-0}"

    log_info "Configuring $SOCKET_UNIT drop-in override for port $port..."

    if socket_override_is_legacy; then
        log_warning "Existing $SOCKET_OVERRIDE_FILE uses the legacy IPv6-only format — rewriting."
    fi

    mkdir -p "$SOCKET_OVERRIDE_DIR"
    if [[ -z "$BACKUP_OVERRIDE" ]]; then
        if [[ -f "$SOCKET_OVERRIDE_FILE" ]]; then
            BACKUP_OVERRIDE=$(backup_file "$SOCKET_OVERRIDE_FILE" | tail -1)
            prune_backups "$SOCKET_OVERRIDE_FILE"
        else
            BACKUP_OVERRIDE="ABSENT"
        fi
    fi

    {
        echo "# Managed by $SCRIPT_NAME v$SCRIPT_VERSION — do not edit manually"
        echo "$OVERRIDE_MARKER"
        echo "[Socket]"
        echo "# The empty value resets ListenStream inherited from the base unit."
        echo "ListenStream="
        echo "ListenStream=0.0.0.0:$port"
        if [[ "$ipv4_only" -eq 0 ]] && ipv6_available; then
            echo "ListenStream=[::]:$port"
            # Явный ipv6-only: без него на дистрибутиве с дефолтным BindIPv6Only
            # [::] стал бы dual-stack и конфликтовал бы с 0.0.0.0 (EADDRINUSE).
            echo "BindIPv6Only=ipv6-only"
        fi
    } > "$SOCKET_OVERRIDE_FILE"
    chmod 0644 "$SOCKET_OVERRIDE_FILE"
    MUTATED=1

    log_success "Created socket override: $SOCKET_OVERRIDE_FILE"
}

reload_ssh_services() {
    local port="$1"

    SERVICES_TOUCHED=1
    log_info "Reloading systemd configuration..."
    systemctl daemon-reload

    # На socket-активированных системах одного restart сокета мало: работающий
    # ssh.service держит копию слушающего fd, полученного от СТАРОГО сокета.
    # Порядок: стоп сервиса -> пересоздание сокета -> старт сервиса (получит
    # fd уже нового сокета). Живые SSH-сессии переживают stop (KillMode=process).
    if [[ "$USE_SOCKET" -eq 1 ]]; then
        log_info "Socket activation detected — restarting $SOCKET_UNIT + $SSH_SERVICE..."
        systemctl stop "$SSH_SERVICE" 2>/dev/null || true
        systemctl stop "$SOCKET_UNIT" 2>/dev/null || true

        if ! systemctl start "$SOCKET_UNIT"; then
            log_error "$SOCKET_UNIT failed to start with dual-stack ListenStream."
            log_warning "Retrying with an IPv4-only override..."
            configure_ssh_socket_override "$port" 1
            systemctl daemon-reload
            if ! systemctl start "$SOCKET_UNIT"; then
                log_error "$SOCKET_UNIT still fails to start."
                show_service_logs "$SOCKET_UNIT"
                return 1
            fi
            log_warning "$SOCKET_UNIT started in IPv4-only mode. IPv6 access is unavailable."
        fi
    fi

    log_info "Restarting SSH service: $SSH_SERVICE"
    if ! systemctl restart "$SSH_SERVICE"; then
        log_error "Failed to restart $SSH_SERVICE"
        show_service_logs "$SSH_SERVICE"
        return 1
    fi

    sleep 2

    if ! systemctl is-active --quiet "$SSH_SERVICE"; then
        log_error "$SSH_SERVICE failed to stay active after restart"
        show_service_logs "$SSH_SERVICE"
        return 1
    fi
    return 0
}

test_ssh_config() {
    log_info "Testing SSH configuration..."
    if "$SSHD_BIN" -t -f "$SSHD_CONFIG" 2>/dev/null; then
        log_success "SSH configuration is valid"
        return 0
    fi
    log_error "SSH configuration has errors:"
    local line
    while IFS= read -r line; do
        log_error "  $line"
    done < <("$SSHD_BIN" -t -f "$SSHD_CONFIG" 2>&1 || true)
    return 1
}

# ============================================================================
# Self-check: после смены порта должны подняться слушатели И на IPv4, И на IPv6
# ============================================================================

verify_ssh_listeners() {
    local port="$1"
    local has_v4=0 has_v6=0 line pinned probes_ok=0

    log_info "Self-check: verifying listeners on port $port..."

    # Сокету/сервису нужно время подняться — несколько попыток.
    local _try
    for _try in 1 2 3 4 5; do
        has_v4=0; has_v6=0
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            if [[ "$line" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]+$ ]]; then
                has_v4=1
            elif [[ "$line" == \[* ]]; then
                has_v6=1
            elif [[ "$line" == "*:$port" ]]; then
                has_v4=1; has_v6=1   # старые версии ss печатают wildcard как "*"
            fi
        done < <(listeners_on_port "$port")
        [[ "$has_v4" -eq 1 ]] && break
        sleep 1
    done

    log_info "  Listeners on :$port"
    while IFS= read -r line; do
        [[ -n "$line" ]] && log_info "    $line"
    done < <(listeners_on_port "$port")

    if [[ -z "$(listeners_on_port "$port")" ]]; then
        log_error "Nothing is listening on port $port at all."
        return 1
    fi

    # sshd_config может пиновать адреса ListenAddress — тогда wildcard-требования
    # не применимы: пробуем сами закреплённые адреса.
    pinned=$(pinned_listen_addresses)
    if [[ -n "$pinned" && "$USE_SOCKET" -eq 0 ]]; then
        local probes_attempted=0
        log_warning "ListenAddress pins sshd to specific addresses:"
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            log_warning "    $line"
            case "$line" in
                fe80:*) log_warning "    (link-local address — probe skipped)" ;;
                *)
                    probes_attempted=1
                    if tcp_probe "$line" "$port"; then
                        log_success "    connect to ${line}:${port} OK"
                        probes_ok=1
                    else
                        log_error   "    connect to ${line}:${port} FAILED"
                    fi
                    ;;
            esac
        done <<< "$pinned"
        if [[ "$probes_attempted" -eq 0 ]]; then
            # Все адреса link-local: проверить не можем — но это не провал,
            # рабочую конфигурацию откатывать нельзя.
            log_warning "All pinned addresses are link-local — probe skipped, assuming OK."
            return 0
        fi
        if [[ "$probes_ok" -eq 1 ]]; then
            log_success "Self-check passed (address-pinned configuration)."
            return 0
        fi
        log_error "None of the pinned addresses accept connections on port $port."
        return 1
    fi
    if [[ -n "$pinned" && "$USE_SOCKET" -eq 1 ]]; then
        log_warning "ListenAddress directives are IGNORED under socket activation — systemd owns the sockets."
    fi

    # AddressFamily может сознательно ограничивать sshd одним стеком —
    # требовать второй в этом случае нельзя (ложный провал + ложный откат).
    # При socket-активации sshd игнорирует AddressFamily (сокеты у systemd).
    local af="any"
    if [[ "$USE_SOCKET" -eq 0 ]]; then
        af=$("$SSHD_BIN" -T 2>/dev/null | awk '$1 == "addressfamily" { print $2; exit }' || true)
        af="${af:-any}"
    fi

    # Живые TCP-пробы — первичный критерий; вывод ss — вторичный.
    local v4_ok=0 v6_ok=0
    tcp_probe 127.0.0.1 "$port" && v4_ok=1
    if ipv6_available; then
        tcp_probe ::1 "$port" && v6_ok=1
    fi

    if [[ "$af" == "inet6" ]]; then
        # Сознательно IPv6-only конфигурация: критерий — IPv6-проба
        if [[ "$v6_ok" -eq 1 ]]; then
            log_success "IPv6: connect to [::1]:$port OK (AddressFamily inet6)"
            log_warning "sshd is deliberately IPv6-only — IPv4 clients cannot connect."
            return 0
        fi
        log_error "AddressFamily inet6, but connect to [::1]:$port FAILED"
        return 1
    fi

    if [[ "$v4_ok" -eq 1 ]]; then
        log_success "IPv4: connect to 127.0.0.1:$port OK"
    else
        log_error "IPv4: connect to 127.0.0.1:$port FAILED (connection refused)"
    fi
    if ipv6_available && [[ "$af" != "inet" ]]; then
        if [[ "$v6_ok" -eq 1 ]]; then
            log_success "IPv6: connect to [::1]:$port OK"
        else
            log_warning "IPv6: connect to [::1]:$port failed"
        fi
    fi

    if [[ "$v4_ok" -eq 0 ]]; then
        log_error "SSH does NOT accept IPv4 connections on port $port."
        if [[ "$has_v6" -eq 1 && "$has_v4" -eq 0 ]]; then
            log_error "Only an IPv6 listener is present — the IPv6-only socket-activation"
            log_error "trap: VPN/mesh access works while direct IPv4 gets 'Connection refused'."
        fi
        return 1
    fi
    if [[ "$has_v4" -eq 0 ]]; then
        log_warning "TCP probe works but ss shows no IPv4 listener — unusual ss output format; continuing."
    fi
    if [[ "$has_v6" -eq 0 ]] && ipv6_available && [[ "$af" != "inet" ]]; then
        log_warning "No IPv6 listener on [::]:$port — IPv6 clients will not connect."
    fi

    log_success "Self-check passed: SSH accepts connections on port $port."
    return 0
}

# ============================================================================
# SELinux
# ============================================================================

is_rhel_like() {
    [[ "$os_name" =~ ^(almalinux|rocky|rhel|centos|fedora|amzn|ol)$ ]] && return 0
    [[ "$os_like" == *rhel* || "$os_like" == *fedora* || "$os_like" == *centos* ]]
}

selinux_mode() {
    getenforce 2>/dev/null || echo "Disabled"
}

# return 0 — порт разрешён (или SELinux не мешает); 1 — точно будет bind denial
configure_selinux() {
    local port="$1" mode

    if ! command -v getenforce >/dev/null 2>&1; then
        is_rhel_like || return 0
        install_selinux_tools || true
        command -v getenforce >/dev/null 2>&1 || return 0
    fi

    mode=$(selinux_mode)
    log_info "SELinux status: $mode"
    [[ "$mode" =~ ^(Enforcing|Permissive)$ ]] || return 0

    if ! command -v semanage >/dev/null 2>&1; then
        if ! install_selinux_tools; then
            if [[ "$mode" == "Enforcing" ]]; then
                log_error "SELinux is Enforcing and semanage is unavailable — sshd would be denied binding port $port."
                return 1
            fi
            log_warning "semanage unavailable (SELinux Permissive) — continuing; AVC denials will be logged."
            return 0
        fi
    fi

    if semanage port -l 2>/dev/null | awk '$1 == "ssh_port_t"' | grep -qw "$port"; then
        log_warning "SELinux: SSH port $port already configured"
        return 0
    fi
    # Только -a: fallback на "-m" переписал бы привязку порта ЧУЖОГО типа
    # (например, порт tomcat'а) на ssh_port_t — тихая диверсия против соседнего сервиса.
    if semanage port -a -t ssh_port_t -p tcp "$port" 2>/dev/null; then
        SELINUX_ADDED=1
        log_success "SELinux: SSH port $port added"
        return 0
    fi
    if semanage port -l 2>/dev/null | awk '$1 != "ssh_port_t"' | grep -qw "$port"; then
        log_error "SELinux: port $port is already labeled for another service type."
        log_error "Pick a different port, or remap it manually if you know what you are doing."
    fi

    if [[ "$mode" == "Enforcing" ]]; then
        log_error "SELinux: failed to allow port $port (Enforcing) — sshd would fail to bind."
        return 1
    fi
    log_warning "SELinux: failed to add port $port (Permissive) — continuing."
    return 0
}

install_selinux_tools() {
    log_warning "Installing SELinux tools (policycoreutils-python-utils)..."
    local pkg_manager=""
    command -v dnf >/dev/null 2>&1 && pkg_manager="dnf"
    [[ -z "$pkg_manager" ]] && command -v yum >/dev/null 2>&1 && pkg_manager="yum"
    [[ -n "$pkg_manager" ]] || return 1
    "$pkg_manager" install -y policycoreutils-python-utils >/dev/null 2>&1 || return 1
    log_success "SELinux tools installed"
    return 0
}

remove_old_port_from_selinux() {
    local port="$1"
    [[ "$port" == "22" ]] && { log_warning "Keeping standard port 22 in SELinux rules"; return 0; }
    command -v semanage >/dev/null 2>&1 || return 0
    [[ "$(selinux_mode)" =~ ^(Enforcing|Permissive)$ ]] || return 0
    if ! semanage port -l 2>/dev/null | awk '$1 == "ssh_port_t"' | grep -qw "$port"; then
        return 0
    fi
    if semanage port -d -t ssh_port_t -p tcp "$port" 2>/dev/null; then
        log_success "SELinux: old SSH port $port removed"
    else
        log_warning "SELinux: failed to remove old port $port"
    fi
}

# ============================================================================
# Файрвол: определяем АКТИВНЫЙ бэкенд, а не первый найденный бинарник
# ============================================================================

detect_firewall_backend() {
    if command -v firewall-cmd >/dev/null 2>&1; then
        if firewall-cmd --state >/dev/null 2>&1; then
            echo "firewalld"; return 0
        fi
        log_warning "firewalld is installed but not running — checking other backends" >&2
    fi
    if command -v ufw >/dev/null 2>&1; then
        local st
        st=$(ufw status 2>/dev/null || true)
        if [[ "$st" == "Status: active"* ]]; then
            echo "ufw"; return 0
        fi
        log_warning "ufw is installed but inactive — checking other backends" >&2
    fi
    if command -v iptables >/dev/null 2>&1; then
        echo "iptables"; return 0
    fi
    echo "none"
}

# Открыть порт. return 1 = не удалось (вызывается ДО правки sshd, поэтому
# отказ здесь безопасен: ничего ещё не изменено).
firewall_allow_port() {
    local backend="$1" port="$2"
    FW_CHANGED=0   # выставляется, только если мы РЕАЛЬНО что-то добавили:
                   # rollback не должен удалять правило, существовавшее до нас
    case "$backend" in
        firewalld)
            if firewall-cmd --query-port="${port}/tcp" >/dev/null 2>&1 \
               && firewall-cmd --permanent --query-port="${port}/tcp" >/dev/null 2>&1; then
                log_warning "Port $port already allowed in firewalld"
                return 0
            fi
            firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 || return 1
            if ! firewall-cmd --add-port="${port}/tcp" >/dev/null 2>&1; then
                # не оставляем "хвост" в permanent при отказе runtime-части
                firewall-cmd --permanent --remove-port="${port}/tcp" >/dev/null 2>&1 || true
                return 1
            fi
            FW_CHANGED=1
            log_success "Port $port allowed in firewalld (runtime + permanent)"
            ;;
        ufw)
            local st
            st=$(ufw status 2>/dev/null || true)
            if grep -qE "^${port}(/tcp)?[[:space:]]" <<< "$st"; then
                log_warning "Port $port already allowed in ufw"
            else
                ufw allow "${port}/tcp" >/dev/null 2>&1 || return 1
                FW_CHANGED=1
                log_success "Port $port allowed in ufw"
            fi
            ;;
        iptables)
            # -I (в начало): -A в конец бесполезен после терминального REJECT/DROP
            if ! iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; then
                iptables -I INPUT 1 -p tcp --dport "$port" -j ACCEPT || return 1
                FW_CHANGED=1
            fi
            if ipv6_available && command -v ip6tables >/dev/null 2>&1; then
                if ! ip6tables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; then
                    if ip6tables -I INPUT 1 -p tcp --dport "$port" -j ACCEPT; then
                        FW_CHANGED=1
                    else
                        log_warning "ip6tables rule failed — IPv6 may stay blocked"
                    fi
                fi
            fi
            log_success "Port $port allowed in iptables"
            persist_iptables
            warn_if_native_nftables
            ;;
        none)
            log_warning "No firewalld/ufw/iptables detected — nothing to open here."
            log_warning "If this host is firewalled by other means (native nftables, a cloud"
            log_warning "security group), allow TCP $port there YOURSELF before proceeding!"
            warn_if_native_nftables
            ;;
    esac
    return 0
}

firewall_remove_port() {
    local backend="$1" port="$2"
    case "$backend" in
        firewalld)
            local removed=0
            if firewall-cmd --permanent --query-port="${port}/tcp" >/dev/null 2>&1; then
                firewall-cmd --permanent --remove-port="${port}/tcp" >/dev/null 2>&1 && removed=1
            fi
            if firewall-cmd --query-port="${port}/tcp" >/dev/null 2>&1; then
                firewall-cmd --remove-port="${port}/tcp" >/dev/null 2>&1 && removed=1
            fi
            if [[ "$removed" -eq 1 ]]; then
                log_success "Port $port removed from firewalld"
            else
                log_warning "Port $port was not present in firewalld rules"
            fi
            ;;
        ufw)
            local st
            st=$(ufw status 2>/dev/null || true)
            # Порт 22 на Ubuntu часто открыт как профиль "OpenSSH", а не как 22/tcp
            if [[ "$port" == "22" ]] && grep -qE '^OpenSSH[[:space:]]' <<< "$st"; then
                log_warning "ufw allows the 'OpenSSH' profile (port 22). Removing it too."
                ufw delete allow OpenSSH >/dev/null 2>&1 || true
                ufw delete limit OpenSSH >/dev/null 2>&1 || true
                st=$(ufw status 2>/dev/null || true)
                if grep -qE '^OpenSSH[[:space:]]' <<< "$st"; then
                    log_warning "The 'OpenSSH' profile rule is still present — remove it manually:"
                    log_warning "  ufw status numbered && ufw delete <N>"
                fi
            fi
            if grep -qE "^${port}(/tcp)?[[:space:]]" <<< "$st"; then
                ufw delete allow "${port}/tcp" >/dev/null 2>&1 || true
                ufw delete allow "${port}" >/dev/null 2>&1 || true
                st=$(ufw status 2>/dev/null || true)
                if grep -qE "^${port}(/tcp)?[[:space:]]" <<< "$st"; then
                    log_warning "Port $port rule still present in ufw — remove it manually (ufw status numbered)"
                else
                    log_success "Port $port removed from ufw"
                fi
            else
                log_warning "Port $port was not present in ufw rules"
            fi
            ;;
        iptables)
            if iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; then
                iptables -D INPUT -p tcp --dport "$port" -j ACCEPT || true
            fi
            if command -v ip6tables >/dev/null 2>&1 \
               && ip6tables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; then
                ip6tables -D INPUT -p tcp --dport "$port" -j ACCEPT || true
            fi
            log_success "Port $port rules removed from iptables"
            persist_iptables
            ;;
        none) ;;
    esac
}

persist_iptables() {
    if command -v netfilter-persistent >/dev/null 2>&1; then
        if netfilter-persistent save >/dev/null 2>&1; then
            log_success "iptables rules persisted (netfilter-persistent)"
            return 0
        fi
        log_warning "netfilter-persistent save failed — rules may not survive reboot"
        return 0
    fi
    # RHEL-семейство: iptables-services хранит правила в /etc/sysconfig/iptables
    if [[ -f /etc/sysconfig/iptables ]] && command -v service >/dev/null 2>&1; then
        if service iptables save >/dev/null 2>&1; then
            [[ -f /etc/sysconfig/ip6tables ]] && service ip6tables save >/dev/null 2>&1
            log_success "iptables rules persisted (service iptables save)"
            return 0
        fi
    fi
    if command -v iptables-save >/dev/null 2>&1 && [[ -d /etc/iptables ]]; then
        if iptables-save > /etc/iptables/rules.v4 2>/dev/null; then
            command -v ip6tables-save >/dev/null 2>&1 \
                && ip6tables-save > /etc/iptables/rules.v6 2>/dev/null
            log_success "iptables rules saved to /etc/iptables/"
            return 0
        fi
        log_warning "Failed to write /etc/iptables/rules.v4"
    fi
    log_warning "iptables rules are NOT persisted — they will NOT survive a reboot,"
    log_warning "and after reboot the firewall may block the new SSH port (lockout!)."
    log_warning "Persist them: 'apt install iptables-persistent' (Debian/Ubuntu)"
    log_warning "or 'dnf install iptables-services && service iptables save' (RHEL-family)."
    return 0
}

warn_if_native_nftables() {
    command -v nft >/dev/null 2>&1 || return 0
    local rules
    rules=$(nft list ruleset 2>/dev/null || true)
    grep -q 'hook input' <<< "$rules" || return 0
    # Каждая nft base-цепочка с hook input оценивается НЕЗАВИСИМО: ACCEPT из
    # iptables (даже iptables-nft, живущего в "table ip/ip6 filter") не спасает
    # от drop в чужой нативной цепочке (обычно "table inet ..."). Предупреждаем,
    # если видим нативные таблицы или legacy-iptables рядом с nft-правилами.
    if grep -qE '^table (inet|bridge|netdev) ' <<< "$rules" \
       || iptables -V 2>/dev/null | grep -q legacy; then
        log_warning "Native nftables rules with an input hook detected."
        log_warning "An iptables ACCEPT may NOT override them — verify: nft list ruleset"
    fi
}

# Удаление старых портов (после успешного self-check!)
remove_old_ports() {
    local -a candidates=()
    local p seen

    for p in "$ORIG_ACTIVE_PORT" "$ORIG_CONFIG_PORT"; do
        [[ -n "$p" && "$p" != "$NEW_PORT" ]] || continue
        seen=0
        local c
        for c in ${candidates[@]+"${candidates[@]}"}; do [[ "$c" == "$p" ]] && seen=1; done
        [[ "$seen" -eq 0 ]] && candidates+=("$p")
    done
    [[ ${#candidates[@]} -gt 0 ]] || return 0

    OLD_REMOVED=1
    for p in "${candidates[@]}"; do
        log_info "Removing old port $p from firewall..."
        firewall_remove_port "$FW_BACKEND" "$p"
        remove_old_port_from_selinux "$p"
        # На RHEL-семействе порт 22 чаще открыт как сервис "ssh", а не как порт
        if [[ "$FW_BACKEND" == "firewalld" && "$p" == "22" ]]; then
            if firewall-cmd --query-service=ssh >/dev/null 2>&1; then
                log_warning "firewalld also allows the 'ssh' SERVICE (port 22). Removing it too."
                firewall-cmd --permanent --remove-service=ssh >/dev/null 2>&1 || true
                firewall-cmd --remove-service=ssh >/dev/null 2>&1 || true
            fi
        fi
    done
}

# ============================================================================
# Статус, план, итог
# ============================================================================

show_status() {
    local ports line pinned
    echo ""
    log_info "=== $SCRIPT_NAME v$SCRIPT_VERSION — status ==="
    ports=$(effective_ports | tr '\n' ' ')
    log_info "Configured port(s) (sshd -T):  ${ports:-unknown}"
    log_info "Active listening port:         $(get_active_ssh_port)"
    log_info "SSH service:                   ${SSH_SERVICE:-not found}"
    if [[ -n "$SOCKET_UNIT" ]]; then
        local act="inactive" en="disabled"
        systemctl is-active  --quiet "$SOCKET_UNIT" 2>/dev/null && act="active"
        systemctl is-enabled --quiet "$SOCKET_UNIT" 2>/dev/null && en="enabled"
        log_info "Socket unit:                   $SOCKET_UNIT ($act, $en)"
        if [[ -f "$SOCKET_OVERRIDE_FILE" ]]; then
            log_info "Socket override:               $SOCKET_OVERRIDE_FILE"
            if socket_override_is_legacy; then
                log_warning "  LEGACY FORMAT (IPv6-only trap) — re-run with --port <current port> to fix"
            fi
            while IFS= read -r line; do log_info "    $line"; done < "$SOCKET_OVERRIDE_FILE"
        fi
    else
        log_info "Socket unit:                   none"
    fi
    pinned=$(pinned_listen_addresses | tr '\n' ' ')
    [[ -n "$pinned" ]] && log_warning "Pinned ListenAddress:          $pinned"
    log_info "Firewall backend:              $FW_BACKEND"
    log_info "Listeners:"
    local out
    out=$(ss -tlnp 2>/dev/null | grep -E 'sshd|ssh' || true)
    while IFS= read -r line; do [[ -n "$line" ]] && log_info "    $line"; done <<< "$out"
    if command -v getenforce >/dev/null 2>&1; then
        log_info "SELinux:                       $(selinux_mode)"
        command -v semanage >/dev/null 2>&1 \
            && log_info "SELinux ssh ports:             $(semanage port -l 2>/dev/null | awk '$1 == "ssh_port_t" {sub(/^[^ ]+ +[^ ]+ +/, ""); print; exit}')"
    fi
    echo ""
}

print_plan() {
    echo ""
    log_info "=== Plan ==="
    log_info "  SSH port:        ${ORIG_ACTIVE_PORT:-$ORIG_CONFIG_PORT} -> $NEW_PORT"
    log_info "  Config:          $SSHD_CONFIG (Port directive)"
    if [[ -n "$SOCKET_UNIT" ]]; then
        log_info "  Socket override: $SOCKET_OVERRIDE_FILE (0.0.0.0:$NEW_PORT + [::]:$NEW_PORT)"
    fi
    log_info "  Firewall:        $FW_BACKEND — allow ${NEW_PORT}/tcp BEFORE restarting sshd"
    if [[ "$USE_SOCKET" -eq 1 ]]; then
        log_info "  Restart:         $SOCKET_UNIT + $SSH_SERVICE"
    else
        log_info "  Restart:         $SSH_SERVICE"
    fi
    log_info "  On any failure:  automatic rollback to the current state"
    echo ""
}

print_summary() {
    echo ""
    log_success "=================================================================="
    log_success " SSH port changed: ${ORIG_ACTIVE_PORT:-$ORIG_CONFIG_PORT} -> $NEW_PORT"
    log_success "=================================================================="
    [[ -n "$BACKUP_CONFIG" ]] && log_info "Config backup:   $BACKUP_CONFIG"
    [[ -n "$BACKUP_OVERRIDE" && "$BACKUP_OVERRIDE" != "ABSENT" ]] \
        && log_info "Override backup: $BACKUP_OVERRIDE"
    echo ""
    log_warning "IMPORTANT — do NOT close this session yet!"
    log_warning "Open a NEW terminal and verify you can connect:"
    log_warning "    ssh -p $NEW_PORT <user>@<server-ip>"
    echo ""
    log_warning "If your server is behind a cloud firewall / security group"
    log_warning "(AWS, GCP, Azure, Oracle, Hetzner...), allow TCP $NEW_PORT there as well."
    if [[ "$OLD_REMOVED" -eq 0 && -n "$ORIG_ACTIVE_PORT" && "$ORIG_ACTIVE_PORT" != "$NEW_PORT" ]]; then
        echo ""
        log_info "The old port $ORIG_ACTIVE_PORT was kept open in the firewall."
        log_info "Once the new port is verified, remove it:"
        case "$FW_BACKEND" in
            ufw)       log_info "    ufw delete allow ${ORIG_ACTIVE_PORT}/tcp" ;;
            firewalld) log_info "    firewall-cmd --permanent --remove-port=${ORIG_ACTIVE_PORT}/tcp && firewall-cmd --remove-port=${ORIG_ACTIVE_PORT}/tcp" ;;
            iptables)  log_info "    iptables -D INPUT -p tcp --dport ${ORIG_ACTIVE_PORT} -j ACCEPT" ;;
            none)      log_info "    (no local firewall backend — check your cloud firewall)" ;;
        esac
    fi
    echo ""
    log_info "Rollback recipe (if anything goes wrong):"
    print_manual_recovery log_info 2>/dev/null || true
    echo ""
}

# ============================================================================
# Preflight: всё, что должно остановить нас ДО каких-либо изменений
# ============================================================================

preflight() {
    command -v systemctl >/dev/null 2>&1 \
        || usage_error "systemd (systemctl) is required. Non-systemd systems (Alpine/OpenRC, SysV) are not supported."
    [[ -d /run/systemd/system ]] \
        || usage_error "systemd is not running as PID 1 (container without systemd?). Aborting before any changes."
    command -v ss >/dev/null 2>&1 \
        || usage_error "'ss' (iproute2) is required."
    command -v timeout >/dev/null 2>&1 \
        || usage_error "'timeout' (coreutils) is required."

    if command -v sshd >/dev/null 2>&1; then
        SSHD_BIN=$(command -v sshd)
    elif [[ -x /usr/sbin/sshd ]]; then
        SSHD_BIN=/usr/sbin/sshd
    else
        usage_error "sshd binary not found — is openssh-server installed?"
    fi
    [[ -f "$SSHD_CONFIG" ]] || usage_error "$SSHD_CONFIG not found."

    SSH_SERVICE=$(get_ssh_service_name) \
        || usage_error "Cannot determine the SSH service (ssh.service/sshd.service)."

    detect_socket_unit
    if [[ -n "$SOCKET_UNIT" ]] && socket_activation_enabled; then
        USE_SOCKET=1
    fi

    # Дальше — проверки, блокирующие только СМЕНУ порта; --status они не мешают.
    [[ "$ACTION" == "change" ]] || return 0

    # Accept=yes (EL7-стиль, инстанс на соединение) устроен иначе — не трогаем.
    if [[ "$USE_SOCKET" -eq 1 ]] \
       && [[ "$(systemctl show "$SOCKET_UNIT" --property=Accept --value 2>/dev/null)" == "yes" ]]; then
        usage_error "$SOCKET_UNIT uses Accept=yes (per-connection instances) — unsupported. Disable it or change the port manually."
    fi

    # Базовая валидность конфига: не наследуем чужие проблемы
    if ! "$SSHD_BIN" -t -f "$SSHD_CONFIG" >/dev/null 2>&1; then
        log_error "Existing sshd configuration is INVALID:"
        local line
        while IFS= read -r line; do log_error "  $line"; done < <("$SSHD_BIN" -t -f "$SSHD_CONFIG" 2>&1 || true)
        usage_error "Fix the existing configuration first — aborting before any changes."
    fi

    # ListenAddress с внедрённым портом переопределяет Port — правка была бы ложью
    local la_files
    la_files=$(find_listenaddress_with_port)
    if [[ -n "$la_files" ]]; then
        log_error "ListenAddress with an embedded port overrides the Port directive:"
        local f
        while IFS= read -r f; do [[ -n "$f" ]] && log_error "  $f"; done <<< "$la_files"
        usage_error "Remove the port from ListenAddress (or change it manually) — aborting before any changes."
    fi
}

# ============================================================================
# Аргументы и справка
# ============================================================================

show_help() {
    cat << EOF
$SCRIPT_NAME v$SCRIPT_VERSION — safely change the sshd listening port

Usage:
    ssh-port.sh [OPTIONS]
    wget -qO- https://dignezzz.github.io/server/ssh-port.sh | sudo bash -s -- --port 5322

Options:
    --port PORT, --port=PORT   New SSH port (1-65535)
    --yes, -y                  Non-interactive mode (no confirmations; requires --port)
    --remove-old-port          Remove the old port from firewall/SELinux after
                               a successful change (works with or without --yes)
    --status                   Show current SSH port/socket/firewall state and exit
    --version, -V              Print version and exit
    --help, -h                 Show this help

Exit codes:
    0  success (or nothing to do)
    1  aborted; system left in (or rolled back to) its previous state
    2  usage / environment error; nothing was changed
    3  failed AND automatic rollback was incomplete — inspect manually
  130  interrupted (Ctrl-C); rollback attempted, escalates to 3 if incomplete

Examples:
    ssh-port.sh --port 2222
    ssh-port.sh --port 2222 --yes --remove-old-port
    ssh-port.sh --status
EOF
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes|-y)          AUTO_YES=1; shift ;;
            --port)
                [[ -n "${2:-}" ]] || usage_error "Option --port requires an argument"
                NEW_PORT="$2"; shift 2 ;;
            --port=*)
                NEW_PORT="${1#--port=}"
                [[ -n "$NEW_PORT" ]] || usage_error "Option --port= requires a value"
                shift ;;
            --remove-old-port) REMOVE_OLD_PORT=1; shift ;;
            --status)          ACTION="status"; shift ;;
            --version|-V)      echo "$SCRIPT_NAME v$SCRIPT_VERSION"; FINALIZED=1; exit 0 ;;
            --help|-h)         show_help; FINALIZED=1; exit 0 ;;
            *)                 usage_error "Unknown option: $1. Use --help for usage." ;;
        esac
    done
}

# ============================================================================
# Основная логика
# ============================================================================

main() {
    parse_arguments "$@"   # --help/--version отрабатывают до проверки root
    check_root
    detect_os
    preflight

    FW_BACKEND=$(detect_firewall_backend)

    if [[ "$ACTION" == "status" ]]; then
        show_status
        FINALIZED=1
        exit 0
    fi

    ORIG_CONFIG_PORT=$(get_current_port)
    ORIG_ACTIVE_PORT=$(get_active_ssh_port)
    log_info "Current SSH port (config): $ORIG_CONFIG_PORT"
    [[ -n "$ORIG_ACTIVE_PORT" ]] && log_info "Active listening port:     $ORIG_ACTIVE_PORT"

    # Интерактив нужен, если не задан порт или не задан --yes
    if [[ -z "$NEW_PORT" || "$AUTO_YES" -eq 0 ]] && ! have_tty; then
        usage_error "No terminal available for prompts. Use: --port <N> --yes"
    fi

    if [[ -z "$NEW_PORT" ]]; then
        while true; do
            read -rp "Enter a new port for SSH (1-65535): " NEW_PORT </dev/tty \
                || usage_error "Failed to read from terminal."
            validate_port "$NEW_PORT" && break
            log_error "Invalid port number. Must be between 1 and 65535."
        done
    fi
    validate_port "$NEW_PORT" || usage_error "Invalid port '${NEW_PORT}'. Use --port <1-65535>."
    NEW_PORT=$((10#$NEW_PORT))

    # Миграция: старый (багованный) IPv6-only override чинится даже при том же порте
    local migrate=0
    if needs_socket_migration; then
        migrate=1
        log_warning "Socket override without an explicit IPv4 bind detected (IPv6-only listener)."
        log_warning "It will be rewritten with explicit 0.0.0.0 + [::] entries."
    elif [[ -n "$SOCKET_UNIT" ]] && socket_override_is_legacy; then
        # Сокет не используется, но на диске лежит legacy-файл — чиним только файл,
        # чтобы включение сокета в будущем не вернуло IPv6-only ловушку.
        log_warning "Legacy socket override found on disk (socket not active) — rewriting it."
        configure_ssh_socket_override "$ORIG_CONFIG_PORT"
        systemctl daemon-reload
        MUTATED=0   # безопасное изменение, откатывать нечего
    fi

    # "Ничего не делать" — только если порт совпадает, слушатели живы и миграция не нужна
    if [[ "$NEW_PORT" == "$ORIG_CONFIG_PORT" && "$migrate" -eq 0 ]] \
       && { [[ -z "$ORIG_ACTIVE_PORT" ]] || [[ "$NEW_PORT" == "$ORIG_ACTIVE_PORT" ]]; } \
       && [[ -n "$(listeners_on_port "$NEW_PORT")" ]]; then
        log_warning "Port $NEW_PORT is already configured and active. No changes needed."
        COMPLETED=1; FINALIZED=1
        exit 0
    fi

    if [[ "$NEW_PORT" == "$ORIG_CONFIG_PORT" && -n "$ORIG_ACTIVE_PORT" && "$NEW_PORT" != "$ORIG_ACTIVE_PORT" ]]; then
        log_warning "sshd_config already has Port $NEW_PORT, but SSH listens on $ORIG_ACTIVE_PORT."
        log_warning "Will re-apply configuration to align."
    fi

    # Порт занят чужим процессом — стоп. Занят самим SSH — продолжаем (чиним).
    if is_port_in_use "$NEW_PORT" && ! port_held_by_ssh "$NEW_PORT"; then
        usage_error "Port $NEW_PORT is already in use by another process."
    fi

    print_plan
    if ! confirm "Proceed with changing the SSH port to $NEW_PORT?"; then
        log_warning "Cancelled by user. Nothing was changed."
        FINALIZED=1
        exit 0
    fi

    # --- 1. Файрвол: открываем НОВЫЙ порт до любых изменений sshd -------------
    if ! firewall_allow_port "$FW_BACKEND" "$NEW_PORT"; then
        usage_error "Failed to open port $NEW_PORT in $FW_BACKEND — aborting before touching sshd."
    fi
    FIREWALL_ADDED="$FW_CHANGED"   # rollback удалит правило, только если добавили МЫ

    # --- 2. SELinux: тоже до правки конфига ----------------------------------
    if ! configure_selinux "$NEW_PORT"; then
        fail 1 "SELinux would block sshd on port $NEW_PORT — aborting."
    fi

    # --- 3. Бэкапы и правка конфига ------------------------------------------
    BACKUP_CONFIG=$(backup_file "$SSHD_CONFIG" | tail -1)
    prune_backups "$SSHD_CONFIG"
    MUTATED=1

    if ! apply_config_port "$NEW_PORT"; then
        fail 1 "Failed to set Port $NEW_PORT consistently."
    fi

    # --- 4. Socket override (пишем всегда, если юнит существует: даже отключённый
    #        сокет может быть включён позже и должен получить правильный порт) ---
    if [[ -n "$SOCKET_UNIT" ]]; then
        configure_ssh_socket_override "$NEW_PORT"
    fi

    # --- 5. Валидация конфига -------------------------------------------------
    if ! test_ssh_config; then
        fail 1 "New configuration is invalid."
    fi

    # --- 6. Перезапуск ---------------------------------------------------------
    if ! reload_ssh_services "$NEW_PORT"; then
        fail 1 "Failed to restart SSH with the new port."
    fi

    # --- 7. Self-check ---------------------------------------------------------
    if ! verify_ssh_listeners "$NEW_PORT"; then
        if [[ "$USE_SOCKET" -eq 1 ]]; then
            show_service_logs "$SOCKET_UNIT"
        else
            show_service_logs "$SSH_SERVICE"
        fi
        fail 1 "Self-check failed — SSH is not serving port $NEW_PORT correctly."
    fi

    # Смена порта состоялась и проверена: с этого места сбой/Ctrl-C в
    # необязательной уборке НЕ должен откатывать рабочий результат.
    COMPLETED=1
    log_success "SSH is now serving port $NEW_PORT."

    # --- 8. Старый порт (только после успешного self-check) -------------------
    if [[ "$REMOVE_OLD_PORT" -eq 1 ]]; then
        remove_old_ports
    elif [[ "$AUTO_YES" -eq 0 && -n "$ORIG_ACTIVE_PORT" && "$ORIG_ACTIVE_PORT" != "$NEW_PORT" ]]; then
        if confirm "Remove old SSH port $ORIG_ACTIVE_PORT from the firewall now? (safer: keep it until the new port is verified)"; then
            remove_old_ports
        fi
    fi

    print_summary
    FINALIZED=1
    exit 0
}

# Запуск
trap 'on_error $? $LINENO' ERR
trap 'on_signal' INT TERM HUP
trap 'on_exit' EXIT
main "$@"
