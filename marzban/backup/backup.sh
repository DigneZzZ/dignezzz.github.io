#!/bin/bash

# Переменные для Telegram
TELEGRAM_BOT_TOKEN="YOUR BOT TOKEN"
TELEGRAM_CHAT_ID="LOG CHANNEL ID"

# Переменные для базы данных
DB_CONTAINER_NAME="mysql"
DB_NAME="marzban"
DB_USER="marzban"
DB_PASSWORD="password"
DB_HOST="127.0.0.1"
DB_PORT="3306"
DOCKER_COMPOSE_PATH="/opt/marzban/docker-compose.yml"

# Папки для архивации
SRC_DIRS=("/opt/marzban" "/var/lib/marzban")
BACKUP_DIR="/opt/marzban/backup"

SERVER_IP=$(hostname -I | awk '{print $1}')

# Папка для хранения архива
DEST_DIR="/root"

# Имя архива с датой и временем
DATE=$(date +'%Y-%m-%d_%H-%M-%S')
ARCHIVE_NAME="backup_$DATE.zip"
ARCHIVE_PATH="$DEST_DIR/$ARCHIVE_NAME"

# Имя файла дампа базы данных с датой и временем
DB_DUMP_NAME="MySQL-$DATE.tar.gz"
DB_DUMP_PATH="$BACKUP_DIR/$DB_DUMP_NAME"

# Целевая папка в Cloudflare R2
TARGET_DIR="s3cf:dir/"

# Функция для отправки уведомления в Telegram
send_telegram_message() {
    MESSAGE=$1
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" -d chat_id="${TELEGRAM_CHAT_ID}" -d text="${MESSAGE}"
}

# Функция для отправки файла в Telegram
send_backup_to_telegram() {
    local file_path="$1"
    curl -s -F chat_id="${TELEGRAM_CHAT_ID}" -F caption=$'#MySQL #backup\n<code>'"$SERVER_IP"'</code>' -F parse_mode="HTML" -F document=@"$file_path" ">
}

# Функция для резервного копирования базы данных MySQL
backup_mysql() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] - Starting MySQL backup..."

    # Создание директории для резервного копирования, если она не существует
    mkdir -p "$BACKUP_DIR"

    SQL_FILE="$BACKUP_DIR/db_${DB_NAME}.sql"

    # Создание дампа базы данных
    docker compose -f "$DOCKER_COMPOSE_PATH" exec "$DB_CONTAINER_NAME" mysqldump -u "$DB_USER" -p"$DB_PASSWORD" -h "$DB_HOST" -P "$DB_PORT" "$DB_NAME" >

    # Проверка успешного создания дампа базы данных
    if [ -f "$SQL_FILE" ]; then
        # Создание архива с дампом базы данных
        tar czvf "$DB_DUMP_PATH" -C "$BACKUP_DIR" "$(basename "$SQL_FILE")"

        # Загрузка архива дампа базы данных в Cloudflare R2
        if rclone copy "$DB_DUMP_PATH" "$TARGET_DIR"; then
            send_telegram_message "Дамп базы данных $DB_DUMP_NAME успешно загружен в Cloudflare R2."
            # Отправка архива дампа базы данных в Telegram
            send_backup_to_telegram "$DB_DUMP_PATH"
            # Удаление локального архива дампа после копирования
            rm "$DB_DUMP_PATH"
        else
            send_telegram_message "Ошибка при загрузке дампа базы данных $DB_DUMP_NAME в Cloudflare R2."
        fi

        # Удаление временного файла дампа базы данных
        rm "$SQL_FILE"

        echo "[$(date '+%Y-%m-%d %H:%M:%S')] - MySQL backup completed!"
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] - MySQL backup failed!"
        send_telegram_message "Ошибка при создании дампа базы данных $DB_NAME."
    fi
}

# Создание архива файлов
zip -r "$ARCHIVE_PATH" "${SRC_DIRS[@]}"

# Загрузка архива в Cloudflare R2 и отправка уведомления
if rclone copy "$ARCHIVE_PATH" "$TARGET_DIR"; then
    send_telegram_message "Архив $ARCHIVE_NAME успешно загружен в Cloudflare R2."
    # Удаление локального архива после копирования
    rm "$ARCHIVE_PATH"
else
    send_telegram_message "Ошибка при загрузке архива $ARCHIVE_NAME в Cloudflare R2."
fi

# Ротация архивов в Cloudflare R2 (оставить только за последние 7 дней)
rclone delete --min-age 7d "$TARGET_DIR"

# Выполнение резервного копирования базы данных
backup_mysql
