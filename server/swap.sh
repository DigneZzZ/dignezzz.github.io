#!/bin/bash
set -euo pipefail

# ==============================================================================
# Скрипт управления swap-файлом
# Автоматически создаёт файл подкачки оптимального размера
# ==============================================================================

# Константы размеров (в байтах)
readonly SWAPFILE="/swapfile"
readonly KB=1024
readonly MB=$((KB * 1024))
readonly GB=$((MB * 1024))
readonly MIN_DISK_FOR_LARGE_SWAP=$((10 * GB))

# Пороговые значения ОЗУ
readonly RAM_2GB=$((2 * GB))
readonly RAM_8GB=$((8 * GB))
readonly RAM_64GB=$((64 * GB))

# Лимиты swap
readonly MIN_SWAP=$((512 * MB))
readonly MAX_SWAP=$((8 * GB))

# Цвета для вывода
readonly COLOR_SUCCESS="\e[42m"
readonly COLOR_ERROR="\e[41m"
readonly COLOR_RESET="\e[0m"

# Функция для вывода сообщения об успешном выполнении
success_message() {
    printf "${COLOR_SUCCESS}%s${COLOR_RESET}\n" "$1"
}

# Функция для вывода сообщения об ошибке
error_message() {
    printf "${COLOR_ERROR}%s${COLOR_RESET}\n" "$1" >&2
}

# Функция для форматирования размера адаптивно в КБ, МБ или ГБ
format_size() {
    local size_in_bytes=$1
    if (( size_in_bytes >= GB )); then
        awk -v bytes="$size_in_bytes" -v gb="$GB" 'BEGIN {printf "%.2f ГБ", bytes/gb}'
    elif (( size_in_bytes >= MB )); then
        awk -v bytes="$size_in_bytes" -v mb="$MB" 'BEGIN {printf "%.2f МБ", bytes/mb}'
    elif (( size_in_bytes >= KB )); then
        awk -v bytes="$size_in_bytes" -v kb="$KB" 'BEGIN {printf "%.2f КБ", bytes/kb}'
    else
        echo "${size_in_bytes} байт"
    fi
}

# Проверка прав суперпользователя
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error_message "Пожалуйста, запустите скрипт с правами суперпользователя."
        exit 1
    fi
}

# Проверка наличия необходимых утилит
check_dependencies() {
    local missing=()
    for cmd in fallocate awk; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done
    
    if (( ${#missing[@]} > 0 )); then
        error_message "Необходимые утилиты не найдены: ${missing[*]}"
        exit 1
    fi
}

check_root
check_dependencies

# Расчёт оптимального размера swap (современные рекомендации)
# Без гибернации, для серверов
calculate_swap_size() {
    local mem_kb=$1
    local disk_bytes=$2
    local mem_bytes=$((mem_kb * KB))
    local swapsize
    
    # Расчёт по объёму ОЗУ
    if (( mem_bytes < RAM_2GB )); then
        # ОЗУ < 2 ГБ: swap = ОЗУ × 2
        swapsize=$((mem_bytes * 2))
    elif (( mem_bytes < RAM_8GB )); then
        # ОЗУ 2-8 ГБ: swap = ОЗУ
        swapsize=$mem_bytes
    elif (( mem_bytes < RAM_64GB )); then
        # ОЗУ 8-64 ГБ: swap = 4-8 ГБ (половина ОЗУ, но не более MAX_SWAP)
        swapsize=$((mem_bytes / 2))
    else
        # ОЗУ > 64 ГБ: фиксированный swap
        swapsize=$MAX_SWAP
    fi
    
    # Применяем ограничения
    (( swapsize < MIN_SWAP )) && swapsize=$MIN_SWAP
    (( swapsize > MAX_SWAP )) && swapsize=$MAX_SWAP
    
    # Проверяем доступное место (оставляем минимум 2 ГБ свободного места)
    local max_available=$((disk_bytes - 2 * GB))
    if (( max_available < MIN_SWAP )); then
        error_message "Недостаточно места на диске для создания swap"
        exit 1
    fi
    (( swapsize > max_available )) && swapsize=$max_available
    
    # Для маленьких дисков (< 10 ГБ) — не более 1 ГБ
    if (( disk_bytes < MIN_DISK_FOR_LARGE_SWAP && swapsize > GB )); then
        swapsize=$GB
    fi
    
    echo "$swapsize"
}

# Удаление существующего swap-файла
remove_existing_swap() {
    success_message "Отключение файла подкачки..."
    swapoff "$SWAPFILE" 2>/dev/null || true
    rm -f "$SWAPFILE"
    sed -i "/^${SWAPFILE//\//\\/} /d" /etc/fstab
}

# Создание нового swap-файла
create_swap_file() {
    local size=$1
    
    success_message "Создание файла подкачки..."
    if ! fallocate -l "$size" "$SWAPFILE" 2>/dev/null; then
        success_message "fallocate не поддерживается, используем dd..."
        dd if=/dev/zero of="$SWAPFILE" bs=1M count=$((size / MB)) status=progress
    fi
    
    success_message "Назначение разрешений..."
    chmod 600 "$SWAPFILE"
    
    success_message "Форматирование как swap..."
    mkswap "$SWAPFILE"
    
    success_message "Включение файла подкачки..."
    swapon "$SWAPFILE"
}

# Добавление записи в fstab
update_fstab() {
    success_message "Создание резервной копии /etc/fstab..."
    cp /etc/fstab /etc/fstab.bak
    
    if ! grep -q "^${SWAPFILE} " /etc/fstab; then
        success_message "Добавление записи в /etc/fstab..."
        echo "${SWAPFILE} none swap sw 0 0" >> /etc/fstab
    fi
}

# ==============================================================================
# Основная логика
# ==============================================================================

# Проверка существующего swap-файла (в fstab ИЛИ активного в системе)
swap_exists_in_fstab=$(grep -q "^${SWAPFILE} " /etc/fstab && echo "yes" || echo "no")
swap_is_active=$(grep -q "^${SWAPFILE} " /proc/swaps && echo "yes" || echo "no")

if [[ "$swap_exists_in_fstab" == "yes" ]] || [[ "$swap_is_active" == "yes" ]] || [[ -f "$SWAPFILE" ]]; then
    success_message "Файл подкачки уже существует."
    
    if [[ "$swap_is_active" == "yes" ]]; then
        currentswapsize_bytes=$(awk -v sf="$SWAPFILE" '$1 == sf {print $3 * 1024}' /proc/swaps)
        success_message "Текущий размер подкачки: $(format_size "$currentswapsize_bytes")"
    fi
    
    printf "Вы хотите создать новый файл подкачки? (y/n) "
    read -r choice
    case "${choice,,}" in
        y|yes) remove_existing_swap ;;
        n|no)  exit 0 ;;
        *)     error_message "Неправильный выбор. Отмена."; exit 1 ;;
    esac
fi

# Получение информации о системе
mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
swap_dir=$(dirname "$SWAPFILE")
disk_bytes=$(df --output=avail -B1 "$swap_dir" | tail -n 1)

# Расчёт и создание swap
swapsize=$(calculate_swap_size "$mem_kb" "$disk_bytes")
create_swap_file "$swapsize"
update_fstab

# Итоговая информация
success_message "Swap файл размером $(format_size "$swapsize") успешно создан."
success_message "Размер ОЗУ: $(format_size "$((mem_kb * KB))")"
