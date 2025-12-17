#!/bin/bash

# ============================================================================
# GIG Traffic Limiter - Network Bandwidth Control Script
# ============================================================================
# Description: Simple tc-based traffic limiter for Linux servers
# Author: DigneZzZ - https://gig.ovh
# Version: 2025.12.17.4
# License: MIT
# ============================================================================

set -euo pipefail

# ============================================================================
# CONSTANTS
# ============================================================================
readonly SCRIPT_VERSION="2025.12.17.4"
readonly SCRIPT_NAME="GIG Traffic Limiter"
readonly REMOTE_URL="https://dignezzz.github.io/server/trafic.sh"
readonly INSTALL_PATH="/usr/local/bin/trafic"
readonly CONFIG_FILE="/etc/trafic.conf"

# ============================================================================
# COLOR FUNCTIONS
# ============================================================================
_color() { printf "\033[%sm%s\033[0m" "$1" "$2"; }
_red() { _color "0;31" "$1"; }
_green() { _color "0;32" "$1"; }
_yellow() { _color "0;33" "$1"; }
_blue() { _color "0;36" "$1"; }
_bold() { _color "1" "$1"; }

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================
ok="✅"
fail="❌"
warn="⚠️"
info_icon="ℹ️"

_exists() { command -v "$1" >/dev/null 2>&1; }

print_header() {
    echo ""
    echo "$(_bold "==========================================")"
    echo "$(_bold "  $1")"
    echo "$(_bold "==========================================")"
    echo ""
}

info() { echo "$(_blue "$info_icon")  $*"; }
success() { echo "$(_green "$ok") $*"; }
warning() { echo "$(_yellow "$warn")  $*"; }
error_exit() { echo "$(_red "$fail") $*" >&2; exit 1; }

# ============================================================================
# VERSION CHECK & AUTO-UPDATE
# ============================================================================
check_updates() {
    local cache_file="/tmp/trafic-update-check"
    local version_cache="/tmp/trafic-remote-version"
    
    # Проверяем кэш (раз в 24 часа)
    if [ -f "$version_cache" ]; then
        local mtime
        mtime=$(stat -c %Y "$version_cache" 2>/dev/null || stat -f %m "$version_cache" 2>/dev/null || echo 0)
        if [ $(($(date +%s) - mtime)) -lt 86400 ]; then
            [ -f "$cache_file" ] && cat "$cache_file"
            return
        fi
    fi
    
    # Запускаем проверку в фоне
    (
        REMOTE_VERSION=$(timeout 3 curl -s "$REMOTE_URL" 2>/dev/null | grep '^readonly SCRIPT_VERSION=' | head -n1 | cut -d'"' -f2)
        echo "$REMOTE_VERSION" > "$version_cache" 2>/dev/null
        if [ -n "$REMOTE_VERSION" ] && [ "$REMOTE_VERSION" != "$SCRIPT_VERSION" ]; then
            echo "${warn} Доступна новая версия: $REMOTE_VERSION (текущая: $SCRIPT_VERSION)" > "$cache_file"
            echo "💡 Обновление: trafic --update" >> "$cache_file"
        else
            rm -f "$cache_file" 2>/dev/null
        fi
    ) &>/dev/null &
    
    [ -f "$cache_file" ] && { cat "$cache_file"; echo ""; }
}

do_update() {
    info "Обновление $SCRIPT_NAME..."
    
    local tmp_file
    tmp_file=$(mktemp)
    
    if curl -fsSL "$REMOTE_URL" -o "$tmp_file" 2>/dev/null; then
        local new_version
        new_version=$(grep '^readonly SCRIPT_VERSION=' "$tmp_file" | head -n1 | cut -d'"' -f2)
        
        if [ -n "$new_version" ]; then
            if [ "$new_version" = "$SCRIPT_VERSION" ]; then
                success "Уже установлена последняя версия: $SCRIPT_VERSION"
                rm -f "$tmp_file"
                return 0
            fi
            
            chmod +x "$tmp_file"
            mv "$tmp_file" "$INSTALL_PATH"
            rm -f /tmp/trafic-update-check /tmp/trafic-remote-version 2>/dev/null
            success "Обновлено до версии: $new_version"
            info "Перезапустите команду: trafic"
            exit 0
        else
            error_exit "Не удалось определить версию"
        fi
    else
        rm -f "$tmp_file"
        error_exit "Не удалось загрузить обновление"
    fi
}

# ============================================================================
# INSTALLATION
# ============================================================================
install_script() {
    if [ "$EUID" -ne 0 ]; then
        error_exit "Для установки требуются права root. Запустите: sudo bash trafic.sh"
    fi
    
    info "Установка $SCRIPT_NAME в $INSTALL_PATH..."
    
    # Проверяем, запущен ли скрипт через pipe (bash <(wget ...))
    if [ ! -f "$0" ] || [ "$0" = "bash" ] || [[ "$0" == /dev/* ]] || [[ "$0" == /proc/* ]]; then
        # Скачиваем скрипт напрямую
        info "Загрузка скрипта с $REMOTE_URL..."
        if curl -fsSL "$REMOTE_URL" -o "$INSTALL_PATH" 2>/dev/null; then
            chmod +x "$INSTALL_PATH"
            success "Установлено: $INSTALL_PATH"
            info "Теперь можете использовать команду: trafic"
        else
            error_exit "Не удалось загрузить скрипт"
        fi
    else
        # Копируем локальный файл
        cp "$0" "$INSTALL_PATH"
        chmod +x "$INSTALL_PATH"
        success "Установлено: $INSTALL_PATH"
        info "Теперь можете использовать команду: trafic"
    fi
}

# ============================================================================
# NETWORK INTERFACE DETECTION
# ============================================================================
detect_interfaces() {
    # Получаем список активных интерфейсов (кроме lo)
    ip -o link show up | awk -F': ' '{print $2}' | grep -v '^lo$' | sed 's/@.*//'
}

get_default_interface() {
    # Получаем интерфейс по умолчанию (для маршрута 0.0.0.0)
    ip route show default 2>/dev/null | awk '/default/ {print $5; exit}'
}

select_interface() {
    local interfaces
    interfaces=$(detect_interfaces)
    local default_iface
    default_iface=$(get_default_interface)
    local iface_count
    iface_count=$(echo "$interfaces" | wc -l)
    
    if [ -z "$interfaces" ]; then
        error_exit "Не найдено активных сетевых интерфейсов"
    fi
    
    # Если есть default интерфейс и он единственный - используем его автоматически
    if [ -n "$default_iface" ] && [ "$iface_count" -eq 1 ]; then
        SELECTED_IFACE="$default_iface"
        success "Автоматически выбран интерфейс: $SELECTED_IFACE"
        return
    fi
    
    # Если есть default - предлагаем его, но даём выбрать другой
    if [ -n "$default_iface" ]; then
        echo ""
        info "Обнаружен основной интерфейс: $(_bold "$default_iface")"
        read -p "Использовать $default_iface? [Y/n]: " use_default
        
        if [[ ! "$use_default" =~ ^[Nn]$ ]]; then
            SELECTED_IFACE="$default_iface"
            success "Выбран интерфейс: $SELECTED_IFACE"
            return
        fi
    fi
    
    # Показываем список для выбора
    echo ""
    echo "$(_bold "Доступные сетевые интерфейсы:")"
    echo ""
    
    local i=1
    local iface_array=()
    while IFS= read -r iface; do
        iface_array+=("$iface")
        local mark=""
        [ "$iface" = "$default_iface" ] && mark=" $(_green "(default)")"
        echo "  $i) $iface$mark"
        ((i++))
    done <<< "$interfaces"
    
    echo ""
    read -p "Выберите интерфейс [1-$((i-1))]: " choice
    
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#iface_array[@]}" ]; then
        SELECTED_IFACE="${iface_array[$((choice-1))]}"
    else
        SELECTED_IFACE="$default_iface"
        [ -z "$SELECTED_IFACE" ] && SELECTED_IFACE="${iface_array[0]}"
    fi
    
    success "Выбран интерфейс: $SELECTED_IFACE"
}

# ============================================================================
# TC LIMITER FUNCTIONS
# ============================================================================
check_tc() {
    if ! _exists tc; then
        error_exit "Утилита tc не найдена. Установите: apt install iproute2"
    fi
}

get_current_limit() {
    local iface="$1"
    
    # Проверяем наличие htb qdisc
    local qdisc_info
    qdisc_info=$(tc qdisc show dev "$iface" 2>/dev/null | grep "htb" || true)
    
    if [ -z "$qdisc_info" ]; then
        echo "не установлено"
        return
    fi
    
    # Получаем текущий лимит из class (совместимый вариант без grep -P)
    local rate
    rate=$(tc class show dev "$iface" 2>/dev/null | grep "htb 1:10" | sed -n 's/.*rate \([0-9]*[KMG]*bit\).*/\1/p' || true)
    
    if [ -n "$rate" ]; then
        echo "$rate"
    else
        echo "htb активен (лимит не определён)"
    fi
}

show_current_status() {
    echo ""
    echo "$(_bold "Текущий статус ограничений:")"
    echo ""
    
    local interfaces
    interfaces=$(detect_interfaces)
    
    while IFS= read -r iface; do
        local limit
        limit=$(get_current_limit "$iface")
        printf "  %-15s : %s\n" "$iface" "$limit"
    done <<< "$interfaces"
    echo ""
}

apply_limit() {
    local iface="$1"
    local rate="$2"  # в Mbit/s
    
    check_tc
    
    info "Применение ограничения ${rate}Mbit/s на $iface..."
    
    # Удаляем существующие правила
    tc qdisc del dev "$iface" root 2>/dev/null || true
    
    # Рассчитываем burst: для стабильной работы ~1-2% от rate или минимум 15k
    # burst = rate / HZ, где HZ обычно 250-1000. Берём безопасное значение.
    local burst="64k"
    
    # Добавляем корневую qdisc с htb
    # default 10 означает, что весь трафик без явного фильтра идёт в класс 1:10
    if ! tc qdisc add dev "$iface" root handle 1: htb default 10 2>/dev/null; then
        error_exit "Не удалось создать htb qdisc на $iface"
    fi
    
    # Добавляем класс с ограничением
    # burst и cburst одинаковые для плавной работы без "рваной" скорости
    if ! tc class add dev "$iface" parent 1: classid 1:10 htb rate "${rate}mbit" ceil "${rate}mbit" burst "$burst" cburst "$burst" 2>/dev/null; then
        tc qdisc del dev "$iface" root 2>/dev/null || true
        error_exit "Не удалось создать класс htb на $iface"
    fi
    
    # Фильтр НЕ нужен — default 10 уже направляет весь трафик в класс 1:10
    
    success "Ограничение ${rate}Mbit/s применено на $iface"
}

remove_limit() {
    local iface="$1"
    
    check_tc
    
    info "Удаление ограничения на $iface..."
    
    if tc qdisc del dev "$iface" root 2>/dev/null; then
        success "Ограничение удалено с $iface"
    else
        warning "Ограничение на $iface не было установлено"
    fi
}

apply_limit_all() {
    local rate="$1"
    
    local interfaces
    interfaces=$(detect_interfaces)
    
    while IFS= read -r iface; do
        apply_limit "$iface" "$rate"
    done <<< "$interfaces"
}

remove_limit_all() {
    local interfaces
    interfaces=$(detect_interfaces)
    
    while IFS= read -r iface; do
        remove_limit "$iface"
    done <<< "$interfaces"
}

# ============================================================================
# PERSISTENT CONFIGURATION
# ============================================================================
save_config() {
    local iface="$1"
    local rate="$2"
    
    cat > "$CONFIG_FILE" << EOF
# GIG Traffic Limiter Configuration
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
TRAFIC_IFACE="$iface"
TRAFIC_RATE="$rate"
EOF
    
    success "Конфигурация сохранена в $CONFIG_FILE"
}

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        return 0
    fi
    return 1
}

create_systemd_service() {
    local iface="$1"
    local rate="$2"
    
    cat > /etc/systemd/system/trafic-limiter.service << EOF
[Unit]
Description=GIG Traffic Limiter
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$INSTALL_PATH --apply $iface $rate
ExecStop=$INSTALL_PATH --remove $iface

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable trafic-limiter.service 2>/dev/null
    
    success "Создан systemd сервис: trafic-limiter.service"
    info "Ограничение будет применяться автоматически при загрузке"
}

remove_systemd_service() {
    if [ -f /etc/systemd/system/trafic-limiter.service ]; then
        systemctl disable trafic-limiter.service 2>/dev/null || true
        rm -f /etc/systemd/system/trafic-limiter.service
        systemctl daemon-reload
        success "Systemd сервис удалён"
    fi
}

# ============================================================================
# INTERACTIVE MENU
# ============================================================================
show_menu() {
    clear
    print_header "$SCRIPT_NAME v$SCRIPT_VERSION"
    
    check_updates
    
    echo "  Автор: DigneZzZ - https://gig.ovh"
    echo ""
    
    show_current_status
    
    echo "────────────────────────────────────────────"
    echo ""
    echo "  1) Установить ограничение скорости"
    echo "  2) Удалить ограничение"
    echo "  3) Показать текущие правила tc"
    echo "  4) Сделать ограничение постоянным (systemd)"
    echo "  5) Удалить постоянное ограничение"
    echo ""
    echo "  u) Обновить скрипт"
    echo "  h) Справка"
    echo "  0) Выход"
    echo ""
    echo "────────────────────────────────────────────"
    echo ""
    read -p "Выберите действие: " choice
    
    case "$choice" in
        1) menu_set_limit ;;
        2) menu_remove_limit ;;
        3) menu_show_rules ;;
        4) menu_make_persistent ;;
        5) menu_remove_persistent ;;
        u|U) do_update ;;
        h|H) show_help; read -p "Нажмите Enter для продолжения..." ;;
        0|q|Q) exit 0 ;;
        *) warning "Неверный выбор" ;;
    esac
}

menu_set_limit() {
    echo ""
    select_interface
    
    echo ""
    read -p "Введите ограничение скорости (Mbit/s): " rate
    
    if ! [[ "$rate" =~ ^[0-9]+$ ]] || [ "$rate" -lt 1 ] || [ "$rate" -gt 10000 ]; then
        warning "Некорректное значение. Введите число от 1 до 10000"
        read -p "Нажмите Enter для продолжения..."
        return
    fi
    
    apply_limit "$SELECTED_IFACE" "$rate"
    save_config "$SELECTED_IFACE" "$rate"
    
    echo ""
    read -p "Нажмите Enter для продолжения..."
}

menu_remove_limit() {
    echo ""
    select_interface
    remove_limit "$SELECTED_IFACE"
    
    echo ""
    read -p "Нажмите Enter для продолжения..."
}

menu_show_rules() {
    echo ""
    echo "$(_bold "Текущие правила tc:")"
    echo ""
    
    local interfaces
    interfaces=$(detect_interfaces)
    
    while IFS= read -r iface; do
        echo "=== $iface ==="
        tc qdisc show dev "$iface" 2>/dev/null || echo "  (нет правил)"
        tc class show dev "$iface" 2>/dev/null || true
        tc filter show dev "$iface" 2>/dev/null || true
        echo ""
    done <<< "$interfaces"
    
    read -p "Нажмите Enter для продолжения..."
}

menu_make_persistent() {
    echo ""
    
    if load_config; then
        info "Найдена конфигурация: $TRAFIC_IFACE @ ${TRAFIC_RATE}Mbit/s"
        read -p "Использовать эти настройки? [Y/n]: " confirm
        
        if [[ ! "$confirm" =~ ^[Nn]$ ]]; then
            create_systemd_service "$TRAFIC_IFACE" "$TRAFIC_RATE"
            read -p "Нажмите Enter для продолжения..."
            return
        fi
    fi
    
    select_interface
    
    read -p "Введите ограничение скорости (Mbit/s): " rate
    
    if ! [[ "$rate" =~ ^[0-9]+$ ]] || [ "$rate" -lt 1 ]; then
        warning "Некорректное значение"
        read -p "Нажмите Enter для продолжения..."
        return
    fi
    
    save_config "$SELECTED_IFACE" "$rate"
    create_systemd_service "$SELECTED_IFACE" "$rate"
    
    read -p "Нажмите Enter для продолжения..."
}

menu_remove_persistent() {
    echo ""
    remove_systemd_service
    rm -f "$CONFIG_FILE"
    success "Конфигурация удалена"
    
    read -p "Нажмите Enter для продолжения..."
}

# ============================================================================
# HELP
# ============================================================================
show_help() {
    cat << EOF

$(_bold "$SCRIPT_NAME v$SCRIPT_VERSION")

$(_bold "ИСПОЛЬЗОВАНИЕ:")
    trafic                          Интерактивный режим (рекомендуется)
    trafic --set <rate>             Установить лимит (интерфейс автоматически)
    trafic --apply <iface> <rate>   Применить ограничение на конкретный интерфейс
    trafic --remove [iface]         Удалить ограничение (интерфейс опционален)
    trafic --status                 Показать статус всех интерфейсов
    trafic --update                 Обновить скрипт
    trafic --install                Установить в систему
    trafic --help                   Показать справку
    trafic --version                Показать версию

$(_bold "ПРИМЕРЫ:")
    trafic --set 100                Ограничить до 100 Mbit/s (авто-интерфейс)
    trafic --apply eth0 100         Ограничить eth0 до 100 Mbit/s
    trafic --apply ens3 50          Ограничить ens3 до 50 Mbit/s
    trafic --remove                 Удалить ограничение (авто-интерфейс)
    trafic --remove eth0            Удалить ограничение с eth0

$(_bold "ОПИСАНИЕ:")
    Скрипт использует tc (traffic control) с HTB (Hierarchical Token Bucket)
    для ограничения скорости сетевых интерфейсов.
    
    Интерфейс определяется автоматически через таблицу маршрутизации.
    На VPS с одним интерфейсом никаких вопросов не задаётся.
    
    Поддерживает:
    ✅ Ограничение исходящего трафика (egress)
    ✅ Автоматическое определение интерфейса по default route
    ✅ Сохранение настроек через systemd (переживает перезагрузку)
    ✅ Автообновление скрипта

$(_bold "ТРЕБОВАНИЯ:")
    - Linux с поддержкой tc (iproute2)
    - Права root для применения ограничений

EOF
}

show_version() {
    echo "$SCRIPT_NAME v$SCRIPT_VERSION"
    echo "Author: DigneZzZ - https://gig.ovh"
}

# ============================================================================
# MAIN
# ============================================================================
main() {
    # Проверка аргументов
    case "${1:-}" in
        --help|-h)
            show_help
            exit 0
            ;;
        --version|-v)
            show_version
            exit 0
            ;;
        --update|-u)
            if [ "$EUID" -ne 0 ]; then
                error_exit "Требуются права root для обновления"
            fi
            do_update
            exit 0
            ;;
        --install|-i)
            install_script
            exit 0
            ;;
        --status|-s)
            print_header "$SCRIPT_NAME v$SCRIPT_VERSION"
            show_current_status
            exit 0
            ;;
        --set)
            # Упрощённая команда: автоопределение интерфейса
            if [ "$EUID" -ne 0 ]; then
                error_exit "Требуются права root"
            fi
            if [ -z "${2:-}" ]; then
                error_exit "Использование: trafic --set <rate_mbit>"
            fi
            check_tc
            local auto_iface
            auto_iface=$(get_default_interface)
            if [ -z "$auto_iface" ]; then
                error_exit "Не удалось определить интерфейс. Используйте: trafic --apply <iface> <rate>"
            fi
            info "Автоопределён интерфейс: $auto_iface"
            apply_limit "$auto_iface" "$2"
            save_config "$auto_iface" "$2"
            exit 0
            ;;
        --apply|-a)
            if [ "$EUID" -ne 0 ]; then
                error_exit "Требуются права root"
            fi
            if [ -z "${2:-}" ] || [ -z "${3:-}" ]; then
                error_exit "Использование: trafic --apply <interface> <rate_mbit>"
            fi
            apply_limit "$2" "$3"
            exit 0
            ;;
        --remove|-r)
            if [ "$EUID" -ne 0 ]; then
                error_exit "Требуются права root"
            fi
            check_tc
            local rm_iface="${2:-}"
            if [ -z "$rm_iface" ]; then
                # Автоопределение интерфейса
                rm_iface=$(get_default_interface)
                if [ -z "$rm_iface" ]; then
                    error_exit "Не удалось определить интерфейс. Используйте: trafic --remove <iface>"
                fi
                info "Автоопределён интерфейс: $rm_iface"
            fi
            remove_limit "$rm_iface"
            exit 0
            ;;
        "")
            # Интерактивный режим
            if [ "$EUID" -ne 0 ]; then
                error_exit "Для управления трафиком требуются права root. Запустите: sudo trafic"
            fi
            
            # Проверяем установлен ли скрипт
            if [ ! -f "$INSTALL_PATH" ]; then
                warning "Скрипт не установлен в систему"
                read -p "Установить сейчас? [Y/n]: " install_confirm
                if [[ ! "$install_confirm" =~ ^[Nn]$ ]]; then
                    install_script
                fi
            fi
            
            check_tc
            
            while true; do
                show_menu
            done
            ;;
        *)
            warning "Неизвестный аргумент: $1"
            echo "Используйте: trafic --help"
            exit 1
            ;;
    esac
}

main "$@"
