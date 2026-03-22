```
# Проверка, что скрипт запущен от имени root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root" >&2
    exit 1
fi

# Функция установки и настройки сервиса
install_service() {
    # Запрос URL и периодичности отправки
    read -p "Enter URL for push status: " URL
    read -p "Enter push interval in seconds: " PERIOD

    # Установка Python и необходимых утилит, если они не установлены
    apt-get update
    apt-get install -y python3 iputils-ping python3-pip

    # Установка библиотеки docker для Python
    pip3 install docker requests

    # Создание Python скрипта отправки статуса
    cat <<EOL > /usr/local/bin/stpush.py
#!/usr/bin/env python3

import docker
import requests
import os
import sys
import json
import time
import subprocess

# URL для отправки push статуса
URL = "$URL"
PERIOD = $PERIOD
STATUS_FILE = "/usr/local/bin/container_statuses.json"

# Инициализация Docker клиента
client = docker.from_env()

# Функция для получения пинга
def get_ping():
    try:
        result = subprocess.run(['ping', '-c', '1', '8.8.8.8'], stdout=subprocess.PIPE)
        output = result.stdout.decode()
        if "time=" in output:
            return float(output.split("time=")[1].split(" ")[0])
        return None
    except Exception as e:
        print(f"Ping error: {e}")
        return None

# Функция для отправки статуса в Uptime Kuma
def send_status(msg, ping):
    try:
        url_with_msg_and_ping = f"{URL}&msg={msg}&ping={ping}" if ping is not None else f"{URL}&msg={msg}"
        response = requests.get(url_with_msg_and_ping)
        if response.status_code == 200:
            print(f"Status sent successfully with ping {ping} ms and message: {msg}")
        else:
            print(f"Failed to send status. HTTP Status Code: {response.status_code}")
    except Exception as e:
        print(f"An error occurred: {e}")

# Функция для загрузки состояния контейнеров
def load_statuses():
    if os.path.exists(STATUS_FILE):
        with open(STATUS_FILE, 'r') as file:
            return json.load(file)
    return {}

# Функция для сохранения состояния контейнеров
def save_statuses(statuses):
    with open(STATUS_FILE, 'w') as file:
        json.dump(statuses, file)

# Функция для обработки событий Docker
def handle_event(event):
    status = event['status']
    container_name = event['Actor']['Attributes']['name']
    message = f"Container {container_name} changed status: {status}"
    ping = get_ping()
    send_status(message, ping)

# Функция для вывода и отправки статуса контейнеров
def print_and_send_containers_status():
    statuses = load_statuses()
    current_statuses = {}
    containers = client.containers.list(all=True)
    for container in containers:
        status = container.status
        current_statuses[container.name] = status
        if container.name not in statuses or statuses[container.name] != status:
            message = f"Container {container.name}: {status}"
            ping = get_ping()
            send_status(message, ping)
        if status == "running":
            print(f"\033[32mContainer {container.name}: {status}\033[0m")  # Зеленый цвет для running
        else:
            print(f"\033[31mContainer {container.name}: {status}\033[0m")  # Красный цвет для не-running
    save_statuses(current_statuses)

# Проверка аргументов командной строки
if len(sys.argv) > 1 and sys.argv[1] == "status":
    print_and_send_containers_status()
    sys.exit(0)

# Первоначальная проверка и уведомление
print_and_send_containers_status()

# Основной цикл обработки событий Docker
for event in client.events(decode=True):
    handle_event(event)
EOL

    # Установка прав на выполнение
    chmod +x /usr/local/bin/stpush.py

    # Создание сервиса systemd
    cat <<EOL > /etc/systemd/system/stpush.service
[Unit]
Description=Service to send push status to Uptime Kuma
After=network.target

[Service]
Environment="KUMA_URL=$URL"
Environment="KUMA_PERIOD=$PERIOD"
ExecStart=/usr/local/bin/stpush.py
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOL

    # Перезагрузка systemd и запуск сервиса
    systemctl daemon-reload
    systemctl enable stpush.service
    systemctl start stpush.service

    echo "Installation completed. Use the 'stpush {start|stop|status|restart|uninstall|reinstall|help}' command to manage the service."
}

# Основная установка или переустановка
if [ "$1" == "reinstall" ]; then
    install_service
else
    # Создание управляющего скрипта
    cat <<EOL > /usr/local/bin/stpush
#!/bin/bash

case "\$1" in
    start)
        systemctl start stpush.service
        ;;
    stop)
        systemctl stop stpush.service
        ;;
    status)
        systemctl status stpush.service
        ;;
    restart)
        systemctl restart stpush.service
        ;;
    uninstall)
        systemctl stop stpush.service
        systemctl disable stpush.service
        rm /etc/systemd/system/stpush.service
        rm /usr/local/bin/stpush.py
        rm /usr/local/bin/stpush
        rm /usr/local/bin/container_statuses.json
        systemctl daemon-reload
        echo "stpush service uninstalled"
        ;;
    reinstall)
        \$0 uninstall
        echo "Reinstalling stpush service..."
        sudo ./install_stpush.sh reinstall
        ;;
    help)
        echo "Usage: stpush {start|stop|status|restart|uninstall|reinstall|help}"
        echo "start     : Start the stpush service"
        echo "stop      : Stop the stpush service"
        echo "status    : Get the status of the stpush service"
        echo "restart   : Restart the stpush service"
        echo "uninstall : Uninstall the stpush service"
        echo "reinstall : Reinstall the stpush service with a new URL"
        echo "help      : Display this help message"
        ;;
    *)
        echo "Usage: stpush {start|stop|status|restart|uninstall|reinstall|help}"
        exit 1
        ;;
esac
EOL

    # Установка прав на выполнение управляющего скрипта
    chmod +x /usr/local/bin/stpush

    # Начальная установка сервиса
    install_service
fi
