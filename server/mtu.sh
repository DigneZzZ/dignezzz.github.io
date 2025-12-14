#!/bin/bash

GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

BACKUP_DIR="/etc/mtu_backups"
BACKUP_FILE="$BACKUP_DIR/mtu_backup_$(date +%F_%T).conf"
CURRENT_CONFIG="/tmp/current_mtu.conf"
LANG_CURRENT="ru"

msg_ru() {
    case $1 in
        "error_root") echo "Ошибка: Скрипт требует права root (sudo)." ;;
        "backup_saved") echo "Конфигурация сохранена в $BACKUP_FILE" ;;
        "current_mtu") echo "Текущие значения MTU:" ;;
        "rollback") echo "Откат изменений из последнего бэкапа..." ;;
        "mtu_restored") echo "Восстановлен MTU $2 для $3" ;;
        "no_backup") echo "Бэкап не найден! Откат невозможен." ;;
        "set_mtu") echo "Установка MTU $2 для $3..." ;;
        "mtu_set_success") echo "MTU успешно установлен на $2" ;;
        "mtu_set_error") echo "Ошибка установки MTU!" ;;
        "invalid_mtu") echo "Недопустимое значение MTU! Должно быть от 576 до 1500." ;;
        "invalid_interface") echo "Неверный выбор интерфейса!" ;;
        "select_interface") echo "Доступные сетевые интерфейсы:" ;;
        "choose_interface") echo "Выберите номер интерфейса (или Enter для автоопределения): " ;;
        "selected_interface") echo "Выбран интерфейс: $2" ;;
        "auto_interface") echo "Автоматически выбран внешний интерфейс: $2" ;;
        "enter_mtu") echo "Введите MTU (576-1500): " ;;
        "choose_preset") echo "Выберите пресет MTU: 1=1500 (Ethernet), 2=1492 (PPPoE), 3=1350 (VPN), 4=1280 (IPv6)" ;;
        "invalid_preset") echo "Неверный пресет! Используйте 1-4." ;;
        "menu_title") echo "=== Управление MTU ===" ;;
        "menu_guide") echo "0) Показать гайд" ;;
        "menu_show_mtu") echo "1) Показать текущие MTU" ;;
        "menu_set_mtu") echo "2) Установить MTU вручную" ;;
        "menu_preset") echo "3) Выбрать пресет MTU" ;;
        "menu_rollback") echo "4) Откатить изменения" ;;
        "menu_exit") echo "5) Выход" ;;
        "choose_action") echo "Выберите действие (0-5): " ;;
        "invalid_choice") echo "Неверный выбор!" ;;
        "exit") echo "Выход." ;;
        "forum") echo "Форум: openode.xyz" ;;
        "blog") echo "Блог: neonode.cc" ;;
        "intro_title") echo "Что вы хотите сделать с MTU?" ;;
        "intro_option1") echo "1) Оптимизировать для нод Marzban" ;;
        "intro_option2") echo "2) Настроить для VPN/туннеля" ;;
        "intro_option3") echo "3) Исправить проблемы с сетью" ;;
        "intro_option4") echo "4) Просто посмотреть текущие MTU" ;;
        "intro_choose") echo "Выберите вариант (1-4): " ;;
        "apply_mtu_prompt") echo "Применить MTU $2 для $3? (да/нет): " ;;
    esac
}

msg_en() {
    case $1 in
        "error_root") echo "Error: Script requires root privileges (sudo)." ;;
        "backup_saved") echo "Configuration saved to $BACKUP_FILE" ;;
        "current_mtu") echo "Current MTU values:" ;;
        "rollback") echo "Rolling back from last backup..." ;;
        "mtu_restored") echo "Restored MTU $2 for $3" ;;
        "no_backup") echo "Backup not found! Rollback impossible." ;;
        "set_mtu") echo "Setting MTU $2 for $3..." ;;
        "mtu_set_success") echo "MTU successfully set to $2" ;;
        "mtu_set_error") echo "Error setting MTU!" ;;
        "invalid_mtu") echo "Invalid MTU value! Must be between 576 and 1500." ;;
        "invalid_interface") echo "Invalid interface choice!" ;;
        "select_interface") echo "Available network interfaces:" ;;
        "choose_interface") echo "Choose interface number (or Enter for auto-detection): " ;;
        "selected_interface") echo "Selected interface: $2" ;;
        "auto_interface") echo "Automatically selected external interface: $2" ;;
        "enter_mtu") echo "Enter MTU (576-1500): " ;;
        "choose_preset") echo "Choose MTU preset: 1=1500 (Ethernet), 2=1492 (PPPoE), 3=1350 (VPN), 4=1280 (IPv6)" ;;
        "invalid_preset") echo "Invalid preset! Use 1-4." ;;
        "menu_title") echo "=== MTU Management ===" ;;
        "menu_guide") echo "0) Show guide" ;;
        "menu_show_mtu") echo "1) Show current MTU" ;;
        "menu_set_mtu") echo "2) Set MTU manually" ;;
        "menu_preset") echo "3) Choose MTU preset" ;;
        "menu_rollback") echo "4) Rollback changes" ;;
        "menu_exit") echo "5) Exit" ;;
        "choose_action") echo "Choose action (0-5): " ;;
        "invalid_choice") echo "Invalid choice!" ;;
        "exit") echo "Exiting." ;;
        "forum") echo "Forum: openode.xyz" ;;
        "blog") echo "Blog: neonode.cc" ;;
        "intro_title") echo "What do you want to do with MTU?" ;;
        "intro_option1") echo "1) Optimize for Marzban nodes" ;;
        "intro_option2") echo "2) Configure for VPN/tunnel" ;;
        "intro_option3") echo "3) Fix network issues" ;;
        "intro_option4") echo "4) Just view current MTU" ;;
        "intro_choose") echo "Choose option (1-4): " ;;
        "apply_mtu_prompt") echo "Apply MTU $2 to $3? (yes/no): " ;;
    esac
}

msg() {
    if [ "$LANG_CURRENT" == "ru" ]; then
        msg_ru "$1" "$2" "$3"
    else
        msg_en "$1" "$2" "$3"
    fi
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}$(msg "error_root")${NC}"
        exit 1
    fi
}

backup_mtu() {
    mkdir -p "$BACKUP_DIR"
    ip link > "$CURRENT_CONFIG"
    cp "$CURRENT_CONFIG" "$BACKUP_FILE"
    echo -e "${GREEN}$(msg "backup_saved")${NC}"
}

show_current_mtu() {
    echo -e "${BLUE}$(msg "current_mtu")${NC}"
    ip link show | grep -E "mtu [0-9]+" | awk '{print $2 " - mtu " $5}'
}

rollback_mtu() {
    if [ -f "$BACKUP_FILE" ]; then
        echo -e "${BLUE}$(msg "rollback")${NC}"
        while read -r line; do
            interface=$(echo "$line" | awk '{print $2}' | sed 's/://')
            mtu=$(echo "$line" | grep -o "mtu [0-9]*" | awk '{print $2}')
            if [ -n "$interface" ] && [ -n "$mtu" ]; then
                ip link set dev "$interface" mtu "$mtu" 2>/dev/null
                echo -e "${GREEN}$(msg "mtu_restored" "$mtu" "$interface")${NC}"
            fi
        done < "$BACKUP_FILE"
        echo -e "${GREEN}$(msg "forum")${NC}"
        echo -e "${GREEN}$(msg "blog")${NC}"
    else
        echo -e "${RED}$(msg "no_backup")${NC}"
    fi
}

apply_mtu() {
    local mtu=$1
    echo -e "${BLUE}$(msg "set_mtu" "$mtu" "$INTERFACE")${NC}"
    ip link set dev "$INTERFACE" mtu "$mtu" && \
    { echo -e "${GREEN}$(msg "mtu_set_success" "$mtu")${NC}"; echo -e "${GREEN}$(msg "forum")${NC}"; echo -e "${GREEN}$(msg "blog")${NC}"; } || \
    { echo -e "${RED}$(msg "mtu_set_error")${NC}"; exit 1; }
}

select_interface() {
    echo -e "${BLUE}$(msg "select_interface")${NC}"
    ip link | grep -E "^[0-9]+" | awk '{print $2}' | sed 's/://' | nl -s ") "
    DEFAULT_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n 1)
    echo -e "${GREEN}Рекомендуемый внешний интерфейс: $DEFAULT_INTERFACE${NC}"
    read -p "$(msg "choose_interface")" choice
    if [ -z "$choice" ] && [ -n "$DEFAULT_INTERFACE" ]; then
        INTERFACE="$DEFAULT_INTERFACE"
        echo -e "${GREEN}$(msg "auto_interface" "$INTERFACE")${NC}"
    else
        INTERFACE=$(ip link | grep -E "^[0-9]+" | awk '{print $2}' | sed 's/://' | sed -n "${choice}p")
        if [ -n "$INTERFACE" ]; then
            echo -e "${GREEN}$(msg "selected_interface" "$INTERFACE")${NC}"
        else
            echo -e "${RED}$(msg "invalid_interface")${NC}"
            exit 1
        fi
    fi
}

interactive_start() {
    clear
    echo -e "${BLUE}=======================${NC}"
    echo -e "${BLUE}$(msg "intro_title")${NC}"
    echo -e "${BLUE}=======================${NC}"
    echo "$(msg "intro_option1")"
    echo "$(msg "intro_option2")"
    echo "$(msg "intro_option3")"
    echo "$(msg "intro_option4")"
    echo -e "${BLUE}-----------------------${NC}"
    read -p "$(msg "intro_choose")" intro_choice
    DEFAULT_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n 1)
    INTERFACE="$DEFAULT_INTERFACE"
    case $intro_choice in
        1) echo -e "${GREEN}Рекомендуется MTU 1350 для нод Marzban с туннелями.${NC}"
           read -p "$(msg "apply_mtu_prompt" "1350" "$INTERFACE")" apply
           if [ "$apply" == "да" ] || [ "$apply" == "yes" ]; then
               backup_mtu
               apply_mtu 1350
           fi ;;
        2) echo -e "${GREEN}Для VPN/туннелей рекомендуется MTU 1350.${NC}"
           read -p "$(msg "apply_mtu_prompt" "1350" "$INTERFACE")" apply
           if [ "$apply" == "да" ] || [ "$apply" == "yes" ]; then
               backup_mtu
               apply_mtu 1350
           fi ;;
        3) echo -e "${GREEN}Попробуйте MTU 1492 или 1350 для устранения фрагментации.${NC}"
           read -p "$(msg "apply_mtu_prompt" "1350" "$INTERFACE")" apply
           if [ "$apply" == "да" ] || [ "$apply" == "yes" ]; then
               backup_mtu
               apply_mtu 1350
           fi ;;
        4) show_current_mtu ;;
        *) echo -e "${RED}$(msg "invalid_choice")${NC}" ;;
    esac
    echo -e "${GREEN}$(msg "forum")${NC}"
    echo -e "${GREEN}$(msg "blog")${NC}"
    read -p "Нажмите Enter для продолжения..."
}

while getopts "i:m:p:rl:" opt; do
    case $opt in
        i) INTERFACE=$OPTARG ;;
        m) MTU=$OPTARG ;;
        p) PRESET=$OPTARG ;;
        r) ROLLBACK=true ;;
        l) LANG_CURRENT=$OPTARG ;;
        *) echo -e "${RED}Неверный параметр!${NC}"; exit 1 ;;
    esac
done

if [ -n "$ROLLBACK" ]; then
    check_root
    rollback_mtu
elif [ -n "$INTERFACE" ] && [ -n "$MTU" ]; then
    check_root
    if [[ "$MTU" =~ ^[0-9]+$ ]] && [ "$MTU" -ge 576 ] && [ "$MTU" -le 1500 ]; then
        backup_mtu
        apply_mtu "$MTU"
    else
        echo -e "${RED}$(msg "invalid_mtu")${NC}"
        exit 1
    fi
elif [ -n "$INTERFACE" ] && [ -n "$PRESET" ]; then
    check_root
    case $PRESET in
        1) MTU=1500 ;;
        2) MTU=1492 ;;
        3) MTU=1350 ;;
        4) MTU=1280 ;;
        *) echo -e "${RED}$(msg "invalid_preset")${NC}"; exit 1 ;;
    esac
    backup_mtu
    apply_mtu "$MTU"
else
    interactive_start
    check_root
    while true; do
        clear
        echo -e "${BLUE}=======================${NC}"
        echo -e "${BLUE}$(msg "menu_title")${NC}"
        echo -e "${BLUE}=======================${NC}"
        echo -e "${GREEN}$(msg "forum")${NC}"
        echo -e "${GREEN}$(msg "blog")${NC}"
        echo -e "${BLUE}-----------------------${NC}"
        echo "$(msg "menu_guide")"
        echo "$(msg "menu_show_mtu")"
        echo "$(msg "menu_set_mtu")"
        echo "$(msg "menu_preset")"
        echo "$(msg "menu_rollback")"
        echo "$(msg "menu_exit")"
        echo -e "${BLUE}-----------------------${NC}"
        read -p "$(msg "choose_action")" action
        case $action in
            0) interactive_start;;
            1) show_current_mtu; read -p "Нажмите Enter...";;
            2) select_interface; backup_mtu; read -p "$(msg "enter_mtu")" custom_mtu
               if [[ "$custom_mtu" =~ ^[0-9]+$ ]] && [ "$custom_mtu" -ge 576 ] && [ "$custom_mtu" -le 1500 ]; then
                   apply_mtu "$custom_mtu"
               else
                   echo -e "${RED}$(msg "invalid_mtu")${NC}"
               fi; read -p "Нажмите Enter...";;
            3) select_interface; backup_mtu; echo "$(msg "choose_preset")"
               read -p "Выберите пресет (1-4): " preset
               case $preset in
                   1) apply_mtu 1500;;
                   2) apply_mtu 1492;;
                   3) apply_mtu 1350;;
                   4) apply_mtu 1280;;
                   *) echo -e "${RED}$(msg "invalid_preset")${NC}";;
               esac; read -p "Нажмите Enter...";;
            4) rollback_mtu; read -p "Нажмите Enter...";;
            5) echo -e "${GREEN}$(msg "exit")${NC}"; exit 0;;
            *) echo -e "${RED}$(msg "invalid_choice")${NC}"; read -p "Нажмите Enter...";;
        esac
    done
fi
