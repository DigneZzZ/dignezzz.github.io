#!/bin/bash
# Вывод заголовка
echo '  
██╗  ██╗██████╗  █████╗ ██╗   ██╗     ██████╗ ██████╗ ██████╗ ███████╗    ██╗   ██╗██████╗ ██████╗  █████╗ ████████╗███████╗██████╗ 
╚██╗██╔╝██╔══██╗██╔══██╗╚██╗ ██╔╝    ██╔════╝██╔═══██╗██╔══██╗██╔════╝    ██║   ██║██╔══██╗██╔══██╗██╔══██╗╚══██╔══╝██╔════╝██╔══██╗
 ╚███╔╝ ██████╔╝███████║ ╚████╔╝     ██║     ██║   ██║██████╔╝█████╗      ██║   ██║██████╔╝██║  ██║███████║   ██║   █████╗  ██████╔╝
 ██╔██╗ ██╔══██╗██╔══██║  ╚██╔╝      ██║     ██║   ██║██╔══██╗██╔══╝      ██║   ██║██╔═══╝ ██║  ██║██╔══██║   ██║   ██╔══╝  ██╔══██╗
██╔╝ ██╗██║  ██║██║  ██║   ██║       ╚██████╗╚██████╔╝██║  ██║███████╗    ╚██████╔╝██║     ██████╔╝██║  ██║   ██║   ███████╗██║  ██║
╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝   ╚═╝        ╚═════╝ ╚═════╝ ╚═╝  ╚═╝╚══════╝     ╚═════╝ ╚═╝     ╚═════╝ ╚═╝  ╚═╝   ╚═╝   ╚══════╝╚═╝  ╚═╝
                                                                                                                                    
                                                                                                
███████╗ ██████╗ ██████╗     ███╗   ███╗ █████╗ ██████╗ ███████╗██████╗  █████╗ ███╗   ██╗
██╔════╝██╔═══██╗██╔══██╗    ████╗ ████║██╔══██╗██╔══██╗╚══███╔╝██╔══██╗██╔══██╗████╗  ██║
█████╗  ██║   ██║██████╔╝    ██╔████╔██║███████║██████╔╝  ███╔╝ ██████╔╝███████║██╔██╗ ██║
██╔══╝  ██║   ██║██╔══██╗    ██║╚██╔╝██║██╔══██║██╔══██╗ ███╔╝  ██╔══██╗██╔══██║██║╚██╗██║
██║     ╚██████╔╝██║  ██║    ██║ ╚═╝ ██║██║  ██║██║  ██║███████╗██████╔╝██║  ██║██║ ╚████║
╚═╝      ╚═════╝ ╚═╝  ╚═╝    ╚═╝     ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═══╝
                                                                                          

██████╗ ██╗   ██╗    ██████╗ ██╗ ██████╗ ███╗   ██╗███████╗███████╗███████╗███████╗    
██╔══██╗╚██╗ ██╔╝    ██╔══██╗██║██╔════╝ ████╗  ██║██╔════╝╚══███╔╝╚══███╔╝╚══███╔╝    
██████╔╝ ╚████╔╝     ██║  ██║██║██║  ███╗██╔██╗ ██║█████╗    ███╔╝   ███╔╝   ███╔╝     
██╔══██╗  ╚██╔╝      ██║  ██║██║██║   ██║██║╚██╗██║██╔══╝   ███╔╝   ███╔╝   ███╔╝      
██████╔╝   ██║       ██████╔╝██║╚██████╔╝██║ ╚████║███████╗███████╗███████╗███████╗    
╚═════╝    ╚═╝       ╚═════╝ ╚═╝ ╚═════╝ ╚═╝  ╚═══╝╚══════╝╚══════╝╚══════╝╚══════╝    
                                                                                                                                                                                               
'
echo -e "\e[1m\e[33|Our community: https://openode.xyz\n\e[0m"
sleep 2s

echo -e "\e[1m\e[33mДанный скрипт устанавливает ядро Xray в Marzban и Marzban Node\n\e[0m"
sleep 1

# Проверяем операционную систему
if [[ $(uname) != "Linux" ]]; then
    echo "Этот скрипт предназначен только для Linux"
    exit 1
fi

# Проверяем архитектуру
if [[ $(uname -m) != "x86_64" ]]; then
    echo "Этот скрипт предназначен только для архитектуры x64"
    exit 1
fi

# Функция загрузки файла
get_xray_core() {
# Отправляем запрос к GitHub API для получения информации о последних четырех релизах
latest_releases=$(curl -s "https://api.github.com/repos/XTLS/Xray-core/releases?per_page=4")

# Извлекаем версии из JSON-ответа
versions=($(echo "$latest_releases" | grep -oP '"tag_name": "\K(.*?)(?=")'))

# Печатаем доступные версии
echo "Доступные версии Xray-core:"
for ((i=0; i<${#versions[@]}; i++)); do
    echo "$(($i + 1)): ${versions[i]}"
done

# Предлагаем пользователю выбрать версию
printf "Выберите версию для установки (1-${#versions[@]}), или нажмите Enter для выбора последней по умолчанию (${versions[0]}): "
read choice

# Проверяем, был ли сделан выбор пользователем
if [ -z "$choice" ]; then
    choice="1"  # Выбираем самую свежую версию по умолчанию
fi

# Преобразуем выбор пользователя в индекс массива
choice=$((choice - 1))

# Проверяем, что выбор пользователя в пределах доступных версий
if [ "$choice" -lt 0 ] || [ "$choice" -ge "${#versions[@]}" ]; then
    echo "Неверный выбор. Выбрана последняя версия по умолчанию (${versions[0]})."
    choice=$((${#versions[@]} - 1))  # Выбираем последнюю версию по умолчанию
fi

# Выбираем версию Xray-core для установки
selected_version=${versions[choice]}
echo "Выбрана версия $selected_version для установки."

# Проверяем, установлены ли необходимые пакеты
if ! dpkg -s unzip >/dev/null 2>&1; then
  echo "Установка необходимых пакетов..."
  apt install -y unzip
fi

# Создаем папку /var/lib/marzban/xray-core
mkdir -p /var/lib/marzban/xray-core
# Переходим в папку /var/lib/marzban/xray-core
cd /var/lib/marzban/xray-core

# Скачиваем Xray-core выбранной версии
xray_filename="Xray-linux-64.zip"
xray_download_url="https://github.com/XTLS/Xray-core/releases/download/${selected_version}/${xray_filename}"

echo "Скачивание Xray-core версии ${selected_version}..."
wget "${xray_download_url}"

# Извлекаем файл из архива и удаляем архив
echo "Извлечение Xray-core..."
unzip -o "${xray_filename}"
rm "${xray_filename}"

}

# Функция для обновления ядра Marzban Main
update_marzban_main() {
get_xray_core
# Изменение ядра Marzban
marzban_folder="/opt/marzban"
marzban_env_file="${marzban_folder}/.env"
xray_executable_path='XRAY_EXECUTABLE_PATH="/var/lib/marzban/xray-core/xray"'

echo "Изменение ядра Marzban..."
# Проверяем, существует ли уже строка XRAY_EXECUTABLE_PATH в файле .env
if ! grep -q "^${xray_executable_path}" "$marzban_env_file"; then
  # Если строка отсутствует, добавляем ее
  echo "${xray_executable_path}" >> "${marzban_env_file}"
fi


# Перезапускаем Marzban
echo "Перезапуск Marzban..."
marzban restart -n

echo "Установка завершена."
}

# Функция для обновления ядра Marzban Node
update_marzban_node() {
get_xray_core

    # Поиск пути до папки Marzban-node и файла docker-compose.yml
    marzban_node_dir=$(find / -type d -name "Marzban-node" -exec test -f "{}/docker-compose.yml" \; -print -quit)

    if [ -z "$marzban_node_dir" ]; then
        echo "Папка Marzban-node с файлом docker-compose.yml не найдена"
        exit 1
    fi

    # Проверяем, существует ли уже строка XRAY_EXECUTABLE_PATH в файле docker-compose.yml
    if ! grep -q "XRAY_EXECUTABLE_PATH: \"/var/lib/marzban/xray-core/xray\"" "$marzban_node_dir/docker-compose.yml"; then
        # Если строка отсутствует, добавляем ее
        sed -i '/environment:/!b;n;/XRAY_EXECUTABLE_PATH/!a\      XRAY_EXECUTABLE_PATH: "/var/lib/marzban/xray-core/xray"' "$marzban_node_dir/docker-compose.yml"
    fi
# Проверяем, существует ли уже строка /var/lib/marzban:/var/lib/marzban в файле docker-compose.yml
if ! grep -q "^\s*- /var/lib/marzban:/var/lib/marzban\s*$" "$marzban_node_dir/docker-compose.yml"; then
    # Если строка отсутствует, добавляем ее
    sed -i '/volumes:/!b;n;/^- \/var\/lib\/marzban:\/var\/lib\/marzban/!a\      - \/var\/lib\/marzban:\/var\/lib\/marzban' "$marzban_node_dir/docker-compose.yml"
fi

    # Перезапускаем Marzban-node
    echo "Перезапуск Marzban..."
    cd "$marzban_node_dir" || exit
    docker compose up -d --force-recreate

    echo "Обновление ядра на Marzban-node завершено. Ядро установлено версии $xray_version"
}

# Печатаем доступные опции для пользователя
echo "Выберите Marzban, для которого необходимо обновить ядро:"
echo "1. Marzban Main"
echo "2. Marzban Node"

# Запрос на выбор опции у пользователя
read -p "Введите номер выбранной опции: " option

# Проверяем выбор пользователя и вызываем соответствующую функцию
case $option in
    1)  
        update_marzban_main
        ;;
    2)
        update_marzban_node
        ;;
    *)
        echo "Неверный выбор. Выберите 1 или 2."
        ;;
esac
