#!/bin/bash
set -e

# Функция для вывода сообщения об успешном выполнении
function success_message {
    printf "\e[42m%s\e[0m\n" "$1"
}

# Функция для вывода сообщения об ошибке
function error_message {
    printf "\e[41m%s\e[0m\n" "$1"
}

# Функция для форматирования размера адаптивно в КБ, МБ или ГБ
function format_size {
    local size_in_bytes=$1
    if (( size_in_bytes >= 1073741824 )); then
        size_in_gb=$(awk "BEGIN {printf \"%.2f\", $size_in_bytes/1073741824}")
        echo "${size_in_gb} ГБ"
    elif (( size_in_bytes >= 1048576 )); then
        size_in_mb=$(awk "BEGIN {printf \"%.2f\", $size_in_bytes/1048576}")
        echo "${size_in_mb} МБ"
    elif (( size_in_bytes >= 1024 )); then
        size_in_kb=$(awk "BEGIN {printf \"%.2f\", $size_in_bytes/1024}")
        echo "${size_in_kb} КБ"
    else
        echo "${size_in_bytes} байт"
    fi
}

# Проверка прав суперпользователя
if [[ $EUID -ne 0 ]]; then
  error_message "Пожалуйста, запустите скрипт с правами суперпользователя."
  exit 1
fi

# Проверка наличия необходимых утилит
for cmd in fallocate numfmt awk; do
  if ! command -v $cmd &> /dev/null; then
    error_message "Необходимая утилита $cmd не найдена. Пожалуйста, установите её."
    exit 1
  fi
done

# Проверить, существует ли файл подкачки /swapfile
if grep -q '^/swapfile ' /etc/fstab; then
    success_message "Файл подкачки уже существует."
    currentswapsize_bytes=$(grep /swapfile /proc/swaps | awk '{print $3 * 1024}')
    currentswapsize_formatted=$(format_size "$currentswapsize_bytes")
    success_message "Текущий размер подкачки: $currentswapsize_formatted"
    printf "Вы хотите создать новый файл подкачки? (y/n) "
    read -r choice
    case "${choice,,}" in
        y|yes ) ;;
        n|no ) exit;;
        * ) error_message "Неправильный выбор. Отмена."; exit;;
    esac
    # Удалить старый файл подкачки и запись из /etc/fstab
    swapoff /swapfile || true
    rm /swapfile
    sed -i '/^\/swapfile /d' /etc/fstab
fi

# Получить размер ОЗУ в килобайтах
mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')

# Получить суммарный объем дискового пространства в байтах на разделе, где будет создан swapfile
swap_dir=$(dirname /swapfile)
disk_bytes=$(df --output=avail -B1 "$swap_dir" | tail -n 1)

# Проверить, достаточно ли дискового пространства
if (( disk_bytes < 10000000000 )); then
    # Если суммарный объем диска менее 10 ГБ, размер подкачки не больше 1 ГБ
    swapsize=$((1 * 1024 * 1024 * 1024))
else
    # Рассчитать размер файла подкачки в зависимости от размера ОЗУ
    mem_bytes=$((mem_kb * 1024))
    if (( mem_bytes < 2147483648 )); then
        # Вдвое больше объема ОЗУ, если ОЗУ менее 2 ГБ
        swapsize=$(( mem_bytes * 2 ))
    else
        # ОЗУ больше или равно 2 ГБ, размер подкачки равен ОЗУ + 2 ГБ
        swapsize=$(( mem_bytes + 2147483648 ))
    fi
fi

# Проверить, монтирован ли файл подкачки
if grep -q '/swapfile' /proc/swaps; then
    # Если файл подкачки уже монтирован, отключите его
    success_message "Отключение файла подкачки..."
    swapoff /swapfile
fi

# Создать файл подкачки
success_message "Создание файла подкачки..."
if ! fallocate -l "$swapsize" /swapfile; then
    success_message "fallocate не поддерживается, используем dd..."
    dd if=/dev/zero of=/swapfile bs=1M count=$((swapsize / 1024 / 1024)) status=progress
fi

# Назначить правильные разрешения на файл подкачки
success_message "Назначение правильных разрешений на файл подкачки..."
chmod 600 /swapfile

# Форматировать файл подкачки как swap
success_message "Форматирование файла подкачки как swap..."
mkswap /swapfile

# Включить файл подкачки
success_message "Включение файла подкачки..."
swapon /swapfile

# Создать резервную копию /etc/fstab
success_message "Создание резервной копии /etc/fstab..."
cp /etc/fstab /etc/fstab.bak

# Добавить запись в /etc/fstab для автоматического включения файла подкачки при загрузке системы
success_message "Добавление записи в /etc/fstab для автоматического включения файла подкачки при загрузке системы..."
if ! grep -q '^/swapfile ' /etc/fstab; then
    echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab
fi

# Вывод информации о созданном swap файле и размере ОЗУ
swap_size_formatted=$(format_size "$swapsize")
mem_size_formatted=$(format_size "$((mem_kb * 1024))")
success_message "Swap файл размером $swap_size_formatted был успешно создан."
success_message "Размер ОЗУ: $mem_size_formatted"
