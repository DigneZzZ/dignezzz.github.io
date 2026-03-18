#!/bin/bash

# ============================================================================
# NetBird Egress Routing Script
# Routes specific port traffic through a NetBird peer (e.g. RU exit node)
# Supports both CLIENT (source routing) and GATEWAY (NAT/forwarding) modes
# Author: DigneZzZ
# Repository: https://github.com/DigneZzZ/dignezzz.github.io
# ============================================================================
# Usage:
#   sudo bash netbird-egress.sh                    # Interactive menu
#   sudo bash netbird-egress.sh --status            # Quick status
#   sudo bash netbird-egress.sh --remove            # Remove all rules
#
# One-liner:
#   wget -qO- https://dignezzz.github.io/server/netbird-egress.sh | sudo bash
# ============================================================================

set -euo pipefail

# ============================================================================
# Константы
# ============================================================================
VERSION="1.1"
SCRIPT_NAME="netbird-egress"
INSTALL_PATH="/usr/local/bin/nb-egress"
ROUTE_TABLE_NAME="nbegress"
ROUTE_TABLE_ID="100"
FWMARK="0x1"
STATE_DIR="/etc/netbird-egress"
STATE_FILE="${STATE_DIR}/config"

# Цвета
RED='\033[38;5;196m'
GREEN='\033[38;5;46m'
YELLOW='\033[38;5;226m'
BLUE='\033[38;5;33m'
CYAN='\033[38;5;51m'
PURPLE='\033[38;5;141m'
GRAY='\033[38;5;240m'
WHITE='\033[1;97m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# Иконки
ICON_OK="✓"
ICON_FAIL="✗"
ICON_ARROW="→"
ICON_WARN="⚠"
ICON_INFO="ℹ"
ICON_NET="🌐"
ICON_LOCK="🔒"
ICON_GEAR="⚙"
ICON_ROCKET="🚀"

# Параметры
PEER_IP=""
PORTS=""
NB_IFACE=""
WG_PEER_KEY=""
WG_ORIGINAL_IPS=""

# ============================================================================
# Вспомогательные функции
# ============================================================================

log()         { echo -e "$1"; }
ok()          { echo -e "  ${GREEN}${ICON_OK}${NC} $1"; }
fail()        { echo -e "  ${RED}${ICON_FAIL}${NC} $1"; }
warn()        { echo -e "  ${YELLOW}${ICON_WARN}${NC} $1"; }
info()        { echo -e "  ${BLUE}${ICON_INFO}${NC} $1"; }
hr()          { echo -e "${GRAY}──────────────────────────────────────────────────────${NC}"; }

die() {
    echo -e "\n  ${RED}${ICON_FAIL} $1${NC}\n"
    exit 1
}

check_root() {
    [[ "$EUID" -eq 0 ]] || die "Скрипт требует прав root. Используйте: sudo $0"
}

pause() {
    echo ""
    read -r -p "  Нажмите Enter для продолжения..." 
}

confirm() {
    local prompt="$1"
    local reply
    read -r -p "  ${prompt} [y/N]: " reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

# ============================================================================
# Автоопределение
# ============================================================================

detect_nb_iface() {
    # Пробуем найти NetBird интерфейс
    local iface=""
    for candidate in wt0 wt1 utun100 utun101 netbird0; do
        if ip link show "$candidate" &>/dev/null 2>&1; then
            iface="$candidate"
            break
        fi
    done
    # Альтернатива: ищем WireGuard-интерфейс от NetBird
    if [[ -z "$iface" ]]; then
        iface=$(ip -o link show | grep -oP '(wt\d+|netbird\d+)' | head -1 || true)
    fi
    echo "$iface"
}

detect_nb_peers() {
    # Получаем список пиров NetBird
    if command -v netbird &>/dev/null; then
        netbird status -d 2>/dev/null | grep -E '^\s+[0-9]+\.' | awk '{print $1}' || true
    fi
}

detect_external_iface() {
    # Определяем внешний интерфейс (для шлюза)
    ip route show default 2>/dev/null | awk '/default/ {print $5; exit}' || echo "eth0"
}

get_nb_my_ip() {
    # Наш IP в сети NetBird
    local iface="${1:-wt0}"
    ip -4 addr show "$iface" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 || true
}

load_state() {
    if [[ -f "$STATE_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$STATE_FILE"
        return 0
    fi
    return 1
}

# ============================================================================
# Валидация
# ============================================================================

validate_ip() {
    local ip="$1"
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    local IFS='.'
    # shellcheck disable=SC2206
    local octets=($ip)
    [[ ${#octets[@]} -eq 4 ]] || return 1
    for octet in "${octets[@]}"; do
        (( octet >= 0 && octet <= 255 )) || return 1
    done
    return 0
}

validate_ports() {
    local ports_str="$1"
    local IFS=','
    # shellcheck disable=SC2206
    local ports_arr=($ports_str)
    [[ ${#ports_arr[@]} -gt 0 ]] || return 1
    for port in "${ports_arr[@]}"; do
        [[ "$port" =~ ^[0-9]+$ ]] || return 1
        (( port >= 1 && port <= 65535 )) || return 1
    done
    return 0
}

# ============================================================================
# Главное меню
# ============================================================================

show_header() {
    clear
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${WHITE}  ${ICON_NET} NetBird Egress Routing  v${VERSION}                    ${CYAN}║${NC}"
    echo -e "${CYAN}║${GRAY}  Маршрутизация портов через NetBird пир              ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
}

show_quick_status() {
    local configured="${RED}не настроено${NC}"
    if [[ -f "$STATE_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$STATE_FILE"
        configured="${GREEN}${PEER_IP:-?} → порты: ${PORTS:-?}${NC}"
    fi
    echo -e "  ${DIM}Статус:${NC} ${configured}"

    local nb_iface
    nb_iface=$(detect_nb_iface)
    if [[ -n "$nb_iface" ]]; then
        local my_ip
        my_ip=$(get_nb_my_ip "$nb_iface")
        echo -e "  ${DIM}NetBird:${NC} ${GREEN}${nb_iface}${NC} (${my_ip:-без IP})"
    else
        echo -e "  ${DIM}NetBird:${NC} ${RED}интерфейс не найден${NC}"
    fi
    echo ""
}

show_menu() {
    show_header
    show_quick_status
    hr

    echo -e "${DIM}  Настройка клиента (этот сервер отправляет трафик через пир):${NC}"
    echo -e "  ${CYAN}1${NC}  ${ICON_ROCKET} Быстрая настройка SMTP (порты 465, 587)"
    echo -e "  ${CYAN}2${NC}  ${ICON_GEAR} Настройка произвольных портов"
    echo ""

    echo -e "${DIM}  Настройка шлюза (этот сервер принимает и NAT-ит трафик):${NC}"
    echo -e "  ${CYAN}3${NC}  ${ICON_NET} Настроить как exit-node (NAT gateway)"
    echo ""

    echo -e "${DIM}  Управление:${NC}"
    echo -e "  ${CYAN}4${NC}  ${ICON_INFO} Подробный статус"
    echo -e "  ${CYAN}5${NC}  ${ICON_FAIL} Удалить все правила"
    echo ""

    echo -e "${DIM}  Система:${NC}"
    echo -e "  ${CYAN}6${NC}  📋 Показать пиров NetBird"
    echo -e "  ${CYAN}7${NC}  ${ICON_LOCK} Установить как команду (nb-egress)"
    echo ""
    echo -e "  ${RED}0${NC}  Выход"
    echo ""
    echo -ne "  ${YELLOW}${ICON_ARROW}${NC} Выберите опцию ${DIM}[0-7]${NC}: "
}

# ============================================================================
# 1. Быстрая настройка SMTP
# ============================================================================

action_quick_smtp() {
    show_header
    echo -e "  ${ICON_ROCKET} ${WHITE}Быстрая настройка SMTP (465, 587)${NC}"
    hr
    echo ""

    PORTS="465,587"
    prompt_peer_ip
    setup_client
}

# ============================================================================
# 2. Настройка произвольных портов
# ============================================================================

action_custom_ports() {
    show_header
    echo -e "  ${ICON_GEAR} ${WHITE}Настройка произвольных портов${NC}"
    hr
    echo ""

    prompt_ports
    prompt_peer_ip
    setup_client
}

# ============================================================================
# Ввод данных
# ============================================================================

prompt_peer_ip() {
    # Автоопределяем интерфейс
    NB_IFACE=$(detect_nb_iface)
    if [[ -z "$NB_IFACE" ]]; then
        die "NetBird интерфейс не найден. Убедитесь что NetBird запущен: netbird status"
    fi
    ok "NetBird интерфейс: ${CYAN}${NB_IFACE}${NC}"
    echo ""

    # Показываем пиров если есть
    local peers
    peers=$(detect_nb_peers)
    if [[ -n "$peers" ]]; then
        info "Доступные пиры NetBird:"
        echo "$peers" | while IFS= read -r peer; do
            echo -e "    ${CYAN}${peer}${NC}"
        done
        echo ""
    fi

    # Подгружаем предыдущее значение
    local default_peer=""
    if [[ -f "$STATE_FILE" ]]; then
        default_peer=$(grep '^PEER_IP=' "$STATE_FILE" 2>/dev/null | cut -d= -f2 || true)
    fi

    while true; do
        local prompt="  Введите NetBird IP шлюза"
        [[ -n "$default_peer" ]] && prompt+=" [${default_peer}]"
        prompt+=": "
        read -r -p "$prompt" input_ip
        [[ -z "$input_ip" && -n "$default_peer" ]] && input_ip="$default_peer"

        if validate_ip "$input_ip"; then
            PEER_IP="$input_ip"
            break
        fi
        fail "Невалидный IP. Попробуйте снова."
    done
    ok "Шлюз: ${CYAN}${PEER_IP}${NC}"
    echo ""
}

prompt_ports() {
    echo -e "  ${DIM}Примеры: 465,587 (SMTP) | 443 (HTTPS) | 80,443,8080${NC}"
    echo ""

    local default_ports=""
    if [[ -f "$STATE_FILE" ]]; then
        default_ports=$(grep '^PORTS=' "$STATE_FILE" 2>/dev/null | cut -d= -f2 || true)
    fi

    while true; do
        local prompt="  Введите порты через запятую"
        [[ -n "$default_ports" ]] && prompt+=" [${default_ports}]"
        prompt+=": "
        read -r -p "$prompt" input_ports
        [[ -z "$input_ports" && -n "$default_ports" ]] && input_ports="$default_ports"

        if validate_ports "$input_ports"; then
            PORTS="$input_ports"
            break
        fi
        fail "Невалидные порты. Используйте числа через запятую (1-65535)."
    done
    ok "Порты: ${CYAN}${PORTS}${NC}"
    echo ""
}

# ============================================================================
# Настройка WireGuard туннеля для egress
# ============================================================================

setup_wg_tunnel() {
    if ! command -v wg &>/dev/null; then
        info "Установка wireguard-tools..."
        if command -v apt-get &>/dev/null; then
            apt-get update -qq &>/dev/null && apt-get install -y -qq wireguard-tools &>/dev/null
        elif command -v yum &>/dev/null; then
            yum install -y -q wireguard-tools &>/dev/null
        elif command -v dnf &>/dev/null; then
            dnf install -y -q wireguard-tools &>/dev/null
        fi
        if command -v wg &>/dev/null; then
            ok "wireguard-tools установлен"
        else
            fail "Не удалось установить wireguard-tools"
            warn "Установите вручную: apt install wireguard-tools"
            warn "Затем: wg set ${NB_IFACE} peer <KEY> allowed-ips <IPs>,0.0.0.0/0"
            return
        fi
    fi

    local peer_key
    peer_key=$(wg show "$NB_IFACE" allowed-ips 2>/dev/null | grep "$PEER_IP" | awk '{print $1}')

    if [[ -z "$peer_key" ]]; then
        warn "Не удалось найти WG ключ пира ${PEER_IP}"
        return
    fi

    WG_PEER_KEY="$peer_key"

    local current_ips
    current_ips=$(wg show "$NB_IFACE" allowed-ips 2>/dev/null | awk -v key="$peer_key" '$1 == key {for(i=2;i<=NF;i++) printf "%s%s", $i, (i<NF?",":""); print ""}')
    WG_ORIGINAL_IPS="$current_ips"

    if echo "$current_ips" | grep -q "0.0.0.0/0"; then
        info "WireGuard AllowedIPs: 0.0.0.0/0 уже разрешён"
    else
        local new_ips="${current_ips}"
        [[ -n "$new_ips" ]] && new_ips+=","
        new_ips+="0.0.0.0/0"
        if wg set "$NB_IFACE" peer "$peer_key" allowed-ips "$new_ips" 2>/dev/null; then
            ok "WireGuard: 0.0.0.0/0 добавлен для пира-шлюза"
        else
            warn "Не удалось обновить WG AllowedIPs"
        fi
    fi

    # SNAT на NB-интерфейсе (шлюз вернёт ответ через туннель)
    if ! iptables -t nat -C POSTROUTING -o "$NB_IFACE" -j MASQUERADE 2>/dev/null; then
        iptables -t nat -A POSTROUTING -o "$NB_IFACE" -j MASQUERADE
        ok "SNAT: MASQUERADE на ${NB_IFACE}"
    else
        info "SNAT на ${NB_IFACE}: уже настроен"
    fi

    # Loose rp_filter (для ассиметричных ответов)
    sysctl -qw "net.ipv4.conf.${NB_IFACE}.rp_filter=2" &>/dev/null
    ok "rp_filter=2 (loose) на ${NB_IFACE}"
}

# ============================================================================
# Настройка клиента (policy routing)
# ============================================================================

setup_client() {
    hr
    echo -e "  ${WHITE}Применение настроек...${NC}"
    echo ""

    # Шаг 1: Проверка доступности
    info "Проверка доступности пира ${PEER_IP}..."
    if ping -c 1 -W 3 "$PEER_IP" &>/dev/null; then
        ok "Пир ${PEER_IP} доступен"
    else
        warn "Пир ${PEER_IP} не отвечает на ping (продолжаем)"
    fi

    # Шаг 2: Таблица маршрутизации
    if ! grep -qE "^${ROUTE_TABLE_ID}\s+${ROUTE_TABLE_NAME}" /etc/iproute2/rt_tables 2>/dev/null; then
        echo "${ROUTE_TABLE_ID} ${ROUTE_TABLE_NAME}" >> /etc/iproute2/rt_tables
        ok "Таблица маршрутизации '${ROUTE_TABLE_NAME}' создана"
    else
        info "Таблица '${ROUTE_TABLE_NAME}' уже существует"
    fi

    # Шаг 3: Маршрут через пир
    ip route del default table "$ROUTE_TABLE_NAME" 2>/dev/null || true
    ip route add default via "$PEER_IP" dev "$NB_IFACE" table "$ROUTE_TABLE_NAME"
    ok "Маршрут: default via ${PEER_IP} dev ${NB_IFACE}"

    # Шаг 4: Маркировка трафика
    local IFS=','
    # shellcheck disable=SC2206
    local ports_arr=($PORTS)
    for port in "${ports_arr[@]}"; do
        if ! iptables -t mangle -C OUTPUT -p tcp --dport "$port" -j MARK --set-mark "$FWMARK" 2>/dev/null; then
            iptables -t mangle -A OUTPUT -p tcp --dport "$port" -j MARK --set-mark "$FWMARK"
            ok "iptables mark: TCP dport ${port} → ${FWMARK}"
        else
            info "iptables mark: порт ${port} уже настроен"
        fi
    done

    # Шаг 5: IP rule
    if ! ip rule show | grep -q "fwmark ${FWMARK} lookup ${ROUTE_TABLE_NAME}"; then
        ip rule add fwmark "$FWMARK" table "$ROUTE_TABLE_NAME"
        ok "ip rule: fwmark ${FWMARK} → table ${ROUTE_TABLE_NAME}"
    else
        info "ip rule: уже существует"
    fi

    # Шаг 6: WireGuard туннель + SNAT + rp_filter
    info "Настройка WireGuard туннеля..."
    setup_wg_tunnel

    # Шаг 7: Сохранение
    mkdir -p "$STATE_DIR"
    cat > "$STATE_FILE" <<STATEEOF
# NetBird Egress Routing Config
# Generated: $(date -Iseconds)
PEER_IP=${PEER_IP}
PORTS=${PORTS}
NB_IFACE=${NB_IFACE}
FWMARK=${FWMARK}
ROUTE_TABLE_NAME=${ROUTE_TABLE_NAME}
ROUTE_TABLE_ID=${ROUTE_TABLE_ID}
WG_PEER_KEY=${WG_PEER_KEY}
WG_ORIGINAL_IPS=${WG_ORIGINAL_IPS}
MODE=client
STATEEOF
    ok "Конфигурация сохранена"

    # Шаг 8: Systemd сервис
    create_systemd_service
    ok "Systemd сервис создан и включён"

    echo ""
    echo -e "  ${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "  ${GREEN}║  ${ICON_OK} Клиент настроен!                                  ║${NC}"
    echo -e "  ${GREEN}║                                                      ║${NC}"
    echo -e "  ${GREEN}║  Порты ${PORTS} → через ${PEER_IP}             ${GREEN}║${NC}"
    echo -e "  ${GREEN}║  Автозапуск: systemd (netbird-egress.service)        ║${NC}"
    echo -e "  ${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    warn "Убедитесь что шлюз (${PEER_IP}) настроен как exit-node!"
    info "Используйте пункт 3 меню на сервере-шлюзе"

    pause
}

create_systemd_service() {
    mkdir -p "$STATE_DIR"
    local service_file="/etc/systemd/system/netbird-egress.service"

    # Скрипт применения правил (вызывается systemd при старте)
    cat > "${STATE_DIR}/apply.sh" <<'APPLYEOF'
#!/bin/bash
source /etc/netbird-egress/config || exit 1

# Routing table
grep -qE "^${ROUTE_TABLE_ID}\s+${ROUTE_TABLE_NAME}" /etc/iproute2/rt_tables 2>/dev/null || \
    echo "${ROUTE_TABLE_ID} ${ROUTE_TABLE_NAME}" >> /etc/iproute2/rt_tables

# Route via peer
ip route replace default via "${PEER_IP}" dev "${NB_IFACE}" table "${ROUTE_TABLE_NAME}" 2>/dev/null || true

# Mark traffic
IFS=',' read -ra PORTS_ARR <<< "$PORTS"
for port in "${PORTS_ARR[@]}"; do
    iptables -t mangle -C OUTPUT -p tcp --dport "$port" -j MARK --set-mark "$FWMARK" 2>/dev/null || \
        iptables -t mangle -A OUTPUT -p tcp --dport "$port" -j MARK --set-mark "$FWMARK"
done

# IP rule
ip rule add fwmark "$FWMARK" table "$ROUTE_TABLE_NAME" 2>/dev/null || true

# SNAT on NB interface (so gateway routes responses back through tunnel)
iptables -t nat -C POSTROUTING -o "$NB_IFACE" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -o "$NB_IFACE" -j MASQUERADE

# Loose rp_filter
sysctl -qw "net.ipv4.conf.${NB_IFACE}.rp_filter=2" 2>/dev/null || true

# WireGuard: allow all traffic to gateway peer
WG_KEY=$(wg show "$NB_IFACE" allowed-ips 2>/dev/null | grep "$PEER_IP" | awk '{print $1}')
if [ -n "$WG_KEY" ]; then
    CURR=$(wg show "$NB_IFACE" allowed-ips 2>/dev/null | awk -v k="$WG_KEY" '$1==k{for(i=2;i<=NF;i++) printf "%s%s",$i,(i<NF?",":""); print ""}')
    echo "$CURR" | grep -q "0.0.0.0/0" || \
        wg set "$NB_IFACE" peer "$WG_KEY" allowed-ips "${CURR},0.0.0.0/0" 2>/dev/null || true
fi
APPLYEOF

    # Скрипт удаления правил (вызывается systemd при остановке)
    cat > "${STATE_DIR}/teardown.sh" <<'TEAREOF'
#!/bin/bash
source /etc/netbird-egress/config 2>/dev/null || exit 0

IFS=',' read -ra PORTS_ARR <<< "$PORTS"
for port in "${PORTS_ARR[@]}"; do
    iptables -t mangle -D OUTPUT -p tcp --dport "$port" -j MARK --set-mark "$FWMARK" 2>/dev/null || true
done

ip rule del fwmark "$FWMARK" table "$ROUTE_TABLE_NAME" 2>/dev/null || true
ip route del default table "$ROUTE_TABLE_NAME" 2>/dev/null || true
iptables -t nat -D POSTROUTING -o "$NB_IFACE" -j MASQUERADE 2>/dev/null || true
TEAREOF

    chmod +x "${STATE_DIR}/apply.sh" "${STATE_DIR}/teardown.sh"

    cat > "$service_file" <<SVCEOF
[Unit]
Description=NetBird Egress Routing (ports: ${PORTS} via ${PEER_IP})
After=network-online.target netbird.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/bin/sleep 3
ExecStart=/bin/bash ${STATE_DIR}/apply.sh
ExecStop=/bin/bash ${STATE_DIR}/teardown.sh

[Install]
WantedBy=multi-user.target
SVCEOF

    # Таймер для повторного применения WG AllowedIPs (NetBird может сбросить)
    cat > "/etc/systemd/system/netbird-egress-wg.service" <<WGSVCEOF
[Unit]
Description=Re-apply WireGuard AllowedIPs for NetBird Egress
After=netbird-egress.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'source ${STATE_DIR}/config 2>/dev/null || exit 0; command -v wg &>/dev/null || exit 0; WG_KEY=\$(wg show "\$NB_IFACE" allowed-ips 2>/dev/null | grep "\$PEER_IP" | awk "{print \\\$1}"); [ -n "\$WG_KEY" ] || exit 0; CURR=\$(wg show "\$NB_IFACE" allowed-ips 2>/dev/null | awk -v k="\$WG_KEY" "\\\$1==k{for(i=2;i<=NF;i++) printf \\"%s%s\\",\\\$i,(i<NF?\\",\\":\\"\\"); print \\"\\"}" ); echo "\$CURR" | grep -q "0.0.0.0/0" || wg set "\$NB_IFACE" peer "\$WG_KEY" allowed-ips "\${CURR},0.0.0.0/0" 2>/dev/null'
WGSVCEOF

    cat > "/etc/systemd/system/netbird-egress-wg.timer" <<WGTMREOF
[Unit]
Description=Periodically re-apply WG AllowedIPs for Egress

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s

[Install]
WantedBy=timers.target
WGTMREOF

    systemctl daemon-reload
    systemctl enable netbird-egress.service &>/dev/null
    systemctl enable --now netbird-egress-wg.timer &>/dev/null
}

# ============================================================================
# 3. Настройка шлюза (NAT gateway / exit node)
# ============================================================================

action_setup_gateway() {
    show_header
    echo -e "  ${ICON_NET} ${WHITE}Настройка Exit Node (NAT Gateway)${NC}"
    hr
    echo ""
    info "Этот сервер будет принимать трафик из NetBird и выпускать"
    info "его в интернет через свой внешний IP."
    echo ""

    # Автоопределяем интерфейсы
    NB_IFACE=$(detect_nb_iface)
    if [[ -z "$NB_IFACE" ]]; then
        die "NetBird интерфейс не найден. Убедитесь что NetBird запущен."
    fi

    local ext_iface
    ext_iface=$(detect_external_iface)

    ok "NetBird интерфейс: ${CYAN}${NB_IFACE}${NC}"
    ok "Внешний интерфейс: ${CYAN}${ext_iface}${NC}"
    echo ""

    # Подтверждение
    echo -e "  ${DIM}Внешний интерфейс другой? Введите его или нажмите Enter [${ext_iface}]:${NC}"
    read -r -p "  " custom_iface
    [[ -n "$custom_iface" ]] && ext_iface="$custom_iface"
    echo ""

    if ! confirm "Применить настройки шлюза?"; then
        echo ""
        info "Отменено."
        pause
        return
    fi

    echo ""
    hr
    echo -e "  ${WHITE}Применение настроек шлюза...${NC}"
    echo ""

    # 1. IP Forwarding
    local current_fwd
    current_fwd=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)
    if [[ "$current_fwd" != "1" ]]; then
        sysctl -w net.ipv4.ip_forward=1 &>/dev/null
        ok "IP forwarding включён (runtime)"
    else
        info "IP forwarding уже включён"
    fi

    # Persist
    if grep -qE '^\s*net\.ipv4\.ip_forward\s*=' /etc/sysctl.conf 2>/dev/null; then
        sed -i 's/^\s*net\.ipv4\.ip_forward\s*=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
    else
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    fi
    ok "IP forwarding persistent (/etc/sysctl.conf)"

    # 2. NAT / MASQUERADE
    if ! iptables -t nat -C POSTROUTING -o "$ext_iface" -j MASQUERADE 2>/dev/null; then
        iptables -t nat -A POSTROUTING -o "$ext_iface" -j MASQUERADE
        ok "NAT MASQUERADE: -o ${ext_iface}"
    else
        info "NAT MASQUERADE: уже настроен"
    fi

    # 3. FORWARD rules
    if ! iptables -C FORWARD -i "$NB_IFACE" -j ACCEPT 2>/dev/null; then
        iptables -A FORWARD -i "$NB_IFACE" -j ACCEPT
        ok "FORWARD: -i ${NB_IFACE} ACCEPT"
    else
        info "FORWARD IN: уже настроен"
    fi

    if ! iptables -C FORWARD -o "$NB_IFACE" -j ACCEPT 2>/dev/null; then
        iptables -A FORWARD -o "$NB_IFACE" -j ACCEPT
        ok "FORWARD: -o ${NB_IFACE} ACCEPT"
    else
        info "FORWARD OUT: уже настроен"
    fi

    # 4. Сохраняем iptables (если есть iptables-persistent)
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save &>/dev/null
        ok "iptables правила сохранены (netfilter-persistent)"
    elif command -v iptables-save &>/dev/null; then
        # Создаём systemd сервис для восстановления
        create_gateway_systemd_service "$ext_iface"
        ok "Systemd сервис для шлюза создан"
    fi

    # 5. Сохраняем state
    mkdir -p "$STATE_DIR"
    cat > "$STATE_FILE" <<GWEOF
# NetBird Egress Gateway Config
# Generated: $(date -Iseconds)
NB_IFACE=${NB_IFACE}
EXT_IFACE=${ext_iface}
MODE=gateway
GWEOF
    ok "Конфигурация шлюза сохранена"

    local my_ip
    my_ip=$(get_nb_my_ip "$NB_IFACE")

    echo ""
    echo -e "  ${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "  ${GREEN}║  ${ICON_OK} Шлюз настроен!                                   ║${NC}"
    echo -e "  ${GREEN}║                                                      ║${NC}"
    echo -e "  ${GREEN}║  NetBird IP: ${my_ip:-н/д}                              ${GREEN}║${NC}"
    echo -e "  ${GREEN}║  NAT: ${NB_IFACE} → ${ext_iface} (MASQUERADE)              ${GREEN}║${NC}"
    echo -e "  ${GREEN}║  Forwarding: включён                                 ║${NC}"
    echo -e "  ${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    info "На клиентах используйте NetBird IP: ${CYAN}${my_ip:-<ваш NB IP>}${NC}"

    pause
}

create_gateway_systemd_service() {
    local ext_iface="$1"
    local service_file="/etc/systemd/system/netbird-egress-gw.service"

    cat > "$service_file" <<GWSVCEOF
[Unit]
Description=NetBird Egress Gateway (NAT via ${ext_iface})
After=network-online.target netbird.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c '\
    sysctl -w net.ipv4.ip_forward=1; \
    iptables -t nat -C POSTROUTING -o ${ext_iface} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o ${ext_iface} -j MASQUERADE; \
    iptables -C FORWARD -i ${NB_IFACE} -j ACCEPT 2>/dev/null || iptables -A FORWARD -i ${NB_IFACE} -j ACCEPT; \
    iptables -C FORWARD -o ${NB_IFACE} -j ACCEPT 2>/dev/null || iptables -A FORWARD -o ${NB_IFACE} -j ACCEPT'
ExecStop=/bin/bash -c '\
    iptables -t nat -D POSTROUTING -o ${ext_iface} -j MASQUERADE 2>/dev/null || true; \
    iptables -D FORWARD -i ${NB_IFACE} -j ACCEPT 2>/dev/null || true; \
    iptables -D FORWARD -o ${NB_IFACE} -j ACCEPT 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
GWSVCEOF

    systemctl daemon-reload
    systemctl enable netbird-egress-gw.service &>/dev/null
}

# ============================================================================
# 4. Подробный статус
# ============================================================================

action_status() {
    show_header
    echo -e "  ${ICON_INFO} ${WHITE}Подробный статус${NC}"
    hr
    echo ""

    # Конфигурация
    if [[ -f "$STATE_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$STATE_FILE"
        local mode_label="клиент"
        [[ "${MODE:-client}" == "gateway" ]] && mode_label="шлюз (NAT gateway)"

        echo -e "  ${GREEN}Конфигурация:${NC}"
        echo -e "    Режим:     ${CYAN}${mode_label}${NC}"
        if [[ "${MODE:-client}" == "client" ]]; then
            echo -e "    Пир:       ${CYAN}${PEER_IP:-не задан}${NC}"
            echo -e "    Порты:     ${CYAN}${PORTS:-не заданы}${NC}"
        fi
        if [[ "${MODE:-client}" == "gateway" ]]; then
            echo -e "    Внешний:   ${CYAN}${EXT_IFACE:-н/д}${NC}"
        fi
        echo -e "    Интерфейс: ${CYAN}${NB_IFACE:-wt0}${NC}"
    else
        warn "Конфигурация не найдена (${STATE_FILE})"
    fi
    echo ""

    # NetBird интерфейс
    local nb
    nb=$(detect_nb_iface)
    echo -e "  ${GREEN}NetBird интерфейс:${NC}"
    if [[ -n "$nb" ]]; then
        echo -n "    "
        ip -br addr show "$nb" 2>/dev/null || echo "    недоступен"
    else
        echo -e "    ${RED}не найден${NC}"
    fi
    echo ""

    # IP forwarding
    local fwd
    fwd=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "?")
    echo -e "  ${GREEN}IP Forwarding:${NC}"
    if [[ "$fwd" == "1" ]]; then
        echo -e "    ${GREEN}${ICON_OK} включён${NC}"
    else
        echo -e "    ${YELLOW}${ICON_WARN} выключен${NC}"
    fi
    echo ""

    # Таблица маршрутизации
    echo -e "  ${GREEN}Таблица маршрутизации (${ROUTE_TABLE_NAME}):${NC}"
    if ip route show table "$ROUTE_TABLE_NAME" 2>/dev/null | grep -q .; then
        ip route show table "$ROUTE_TABLE_NAME" 2>/dev/null | sed 's/^/    /'
    else
        echo -e "    ${YELLOW}пусто / не существует${NC}"
    fi
    echo ""

    # IP rules
    echo -e "  ${GREEN}IP Rules (fwmark ${FWMARK}):${NC}"
    local rules
    rules=$(ip rule show 2>/dev/null | grep "fwmark ${FWMARK}" || true)
    if [[ -n "$rules" ]]; then
        echo "$rules" | sed 's/^/    /'
    else
        echo -e "    ${YELLOW}нет правил${NC}"
    fi
    echo ""

    # iptables mangle
    echo -e "  ${GREEN}iptables mangle OUTPUT:${NC}"
    local mangle
    mangle=$(iptables -t mangle -L OUTPUT -n --line-numbers 2>/dev/null | grep "MARK" || true)
    if [[ -n "$mangle" ]]; then
        echo "$mangle" | sed 's/^/    /'
    else
        echo -e "    ${YELLOW}нет правил маркировки${NC}"
    fi
    echo ""

    # WireGuard AllowedIPs
    echo -e "  ${GREEN}WireGuard (пир-шлюз):${NC}"
    if command -v wg &>/dev/null; then
        local wg_info
        wg_info=$(wg show "${NB_IFACE:-wt0}" allowed-ips 2>/dev/null || true)
        if [[ -n "$wg_info" ]] && echo "$wg_info" | grep -q "0.0.0.0/0"; then
            echo -e "    ${GREEN}${ICON_OK} 0.0.0.0/0 разрешён (egress активен)${NC}"
        else
            echo -e "    ${YELLOW}${ICON_WARN} 0.0.0.0/0 не найден — egress не работает${NC}"
        fi
    else
        echo -e "    ${GRAY}утилита wg не найдена${NC}"
    fi
    echo ""

    # SNAT на NB-интерфейсе
    echo -e "  ${GREEN}SNAT (${NB_IFACE:-wt0}):${NC}"
    if iptables -t nat -C POSTROUTING -o "${NB_IFACE:-wt0}" -j MASQUERADE 2>/dev/null; then
        echo -e "    ${GREEN}${ICON_OK} MASQUERADE активен${NC}"
    else
        echo -e "    ${YELLOW}${ICON_WARN} не настроен${NC}"
    fi
    echo ""

    # iptables nat
    echo -e "  ${GREEN}iptables NAT POSTROUTING:${NC}"
    local nat
    nat=$(iptables -t nat -L POSTROUTING -n --line-numbers 2>/dev/null | grep "MASQUERADE" || true)
    if [[ -n "$nat" ]]; then
        echo "$nat" | sed 's/^/    /'
    else
        echo -e "    ${YELLOW}нет NAT правил${NC}"
    fi
    echo ""

    # iptables forward
    echo -e "  ${GREEN}iptables FORWARD (NetBird):${NC}"
    local fwd_rules
    fwd_rules=$(iptables -L FORWARD -n --line-numbers 2>/dev/null | grep -E "wt[0-9]|netbird" || true)
    if [[ -n "$fwd_rules" ]]; then
        echo "$fwd_rules" | sed 's/^/    /'
    else
        echo -e "    ${YELLOW}нет forward правил для NetBird${NC}"
    fi
    echo ""

    # Systemd сервисы
    echo -e "  ${GREEN}Systemd сервисы:${NC}"
    for svc in netbird-egress.service netbird-egress-gw.service netbird-egress-wg.timer; do
        if systemctl list-unit-files "$svc" &>/dev/null 2>&1 && systemctl is-enabled "$svc" &>/dev/null 2>&1; then
            local state
            state=$(systemctl is-active "$svc" 2>/dev/null || echo "unknown")
            local color="${GREEN}"
            [[ "$state" != "active" && "$state" != "exited" ]] && color="${YELLOW}"
            echo -e "    ${svc}: ${color}${state}${NC} (enabled)"
        else
            echo -e "    ${svc}: ${GRAY}не установлен${NC}"
        fi
    done
    echo ""

    hr
    pause
}

# ============================================================================
# 5. Удаление
# ============================================================================

action_remove() {
    show_header
    echo -e "  ${ICON_FAIL} ${WHITE}Удаление всех правил${NC}"
    hr
    echo ""

    if ! confirm "Удалить все настройки egress-маршрутизации?"; then
        info "Отменено."
        pause
        return
    fi

    echo ""

    # Загружаем state
    if [[ -f "$STATE_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$STATE_FILE"
        ok "Конфигурация загружена"
    else
        warn "Конфигурация не найдена, удаляем по умолчанию"
    fi

    # Удаляем iptables mangle правила
    if [[ -n "${PORTS:-}" ]]; then
        local IFS=','
        # shellcheck disable=SC2206
        local ports_arr=($PORTS)
        for port in "${ports_arr[@]}"; do
            if iptables -t mangle -C OUTPUT -p tcp --dport "$port" -j MARK --set-mark "${FWMARK:-0x1}" 2>/dev/null; then
                iptables -t mangle -D OUTPUT -p tcp --dport "$port" -j MARK --set-mark "${FWMARK:-0x1}"
                ok "Удалено iptables mangle: порт ${port}"
            fi
        done
    fi

    # Удаляем ip rule
    while ip rule del fwmark "${FWMARK:-0x1}" table "${ROUTE_TABLE_NAME:-nbegress}" 2>/dev/null; do
        ok "Удалено ip rule"
    done

    # Удаляем маршрут
    ip route del default table "${ROUTE_TABLE_NAME:-nbegress}" 2>/dev/null && ok "Удалён маршрут" || true

    # Восстанавливаем WireGuard AllowedIPs
    local nb="${NB_IFACE:-wt0}"
    if [[ -n "${WG_PEER_KEY:-}" && -n "${WG_ORIGINAL_IPS:-}" ]]; then
        wg set "$nb" peer "$WG_PEER_KEY" allowed-ips "$WG_ORIGINAL_IPS" 2>/dev/null && \
            ok "WireGuard AllowedIPs восстановлены" || true
    fi

    # Удаляем SNAT на NB-интерфейсе
    iptables -t nat -D POSTROUTING -o "$nb" -j MASQUERADE 2>/dev/null && ok "Удалён SNAT на ${nb}" || true

    # Удаляем NAT правила (режим gateway)
    local ext="${EXT_IFACE:-}"
    if [[ -n "$ext" ]]; then
        iptables -t nat -D POSTROUTING -o "$ext" -j MASQUERADE 2>/dev/null && ok "Удалён NAT MASQUERADE" || true
    fi

    # Удаляем FORWARD правила
    iptables -D FORWARD -i "$nb" -j ACCEPT 2>/dev/null && ok "Удалён FORWARD IN" || true
    iptables -D FORWARD -o "$nb" -j ACCEPT 2>/dev/null && ok "Удалён FORWARD OUT" || true

    # Удаляем запись из rt_tables
    if grep -qE "^${ROUTE_TABLE_ID:-100}\s+${ROUTE_TABLE_NAME:-nbegress}" /etc/iproute2/rt_tables 2>/dev/null; then
        sed -i "/^${ROUTE_TABLE_ID:-100}\s\+${ROUTE_TABLE_NAME:-nbegress}/d" /etc/iproute2/rt_tables
        ok "Удалена таблица из rt_tables"
    fi

    # Удаляем systemd сервисы
    for svc in netbird-egress.service netbird-egress-gw.service netbird-egress-wg.service netbird-egress-wg.timer; do
        if [[ -f "/etc/systemd/system/${svc}" ]]; then
            systemctl disable "$svc" 2>/dev/null || true
            systemctl stop "$svc" 2>/dev/null || true
            rm -f "/etc/systemd/system/${svc}"
            ok "Удалён ${svc}"
        fi
    done
    systemctl daemon-reload 2>/dev/null

    # Удаляем state
    if [[ -d "$STATE_DIR" ]]; then
        rm -rf "$STATE_DIR"
        ok "Удалена конфигурация"
    fi

    echo ""
    echo -e "  ${GREEN}${ICON_OK} Все правила удалены${NC}"

    pause
}

# ============================================================================
# 6. Показать пиров
# ============================================================================

action_show_peers() {
    show_header
    echo -e "  📋 ${WHITE}Пиры NetBird${NC}"
    hr
    echo ""

    if ! command -v netbird &>/dev/null; then
        fail "NetBird CLI не найден"
        pause
        return
    fi

    info "netbird status -d:"
    echo ""
    netbird status -d 2>/dev/null || fail "Не удалось получить статус NetBird"
    echo ""

    local nb
    nb=$(detect_nb_iface)
    if [[ -n "$nb" ]]; then
        info "Интерфейс ${nb}:"
        ip addr show "$nb" 2>/dev/null | sed 's/^/    /'
    fi

    pause
}

# ============================================================================
# 7. Установка как команда
# ============================================================================

action_install() {
    show_header
    echo -e "  ${ICON_LOCK} ${WHITE}Установка в систему${NC}"
    hr
    echo ""

    if [[ -f "$INSTALL_PATH" ]]; then
        warn "Уже установлено: ${INSTALL_PATH}"
        if ! confirm "Переустановить?"; then
            pause
            return
        fi
    fi

    cp "$0" "$INSTALL_PATH"
    chmod +x "$INSTALL_PATH"
    ok "Установлено: ${CYAN}${INSTALL_PATH}${NC}"
    info "Теперь можно запускать: ${CYAN}sudo nb-egress${NC}"

    pause
}

# ============================================================================
# CLI парсинг
# ============================================================================

parse_args() {
    [[ $# -eq 0 ]] && return 0

    case "$1" in
        --status|-s)
            check_root
            action_status
            exit 0
            ;;
        --remove|-r)
            check_root
            action_remove
            exit 0
            ;;
        --help|-h)
            show_usage
            exit 0
            ;;
        *)
            show_usage
            exit 1
            ;;
    esac
}

show_usage() {
    echo ""
    echo -e "${CYAN}NetBird Egress Routing v${VERSION}${NC}"
    echo ""
    echo "Использование:"
    echo "  sudo $(basename "$0")             Интерактивное меню"
    echo "  sudo $(basename "$0") --status    Показать статус"
    echo "  sudo $(basename "$0") --remove    Удалить все правила"
    echo "  sudo $(basename "$0") --help      Эта справка"
    echo ""
    echo "One-liner:"
    echo "  wget -qO- https://dignezzz.github.io/server/netbird-egress.sh | sudo bash"
    echo ""
}

# ============================================================================
# Main loop
# ============================================================================

main() {
    parse_args "$@"
    check_root

    while true; do
        show_menu
        local choice
        read -r choice

        case "$choice" in
            1) action_quick_smtp ;;
            2) action_custom_ports ;;
            3) action_setup_gateway ;;
            4) action_status ;;
            5) action_remove ;;
            6) action_show_peers ;;
            7) action_install ;;
            0|q|Q) echo ""; exit 0 ;;
            *) warn "Неверный выбор"; sleep 1 ;;
        esac
    done
}

main "$@"
