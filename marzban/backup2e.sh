#!/bin/bash

# Переменные для Telegram
TELEGRAM_BOT_TOKEN="YOUR BOT TOKEN"
TELEGRAM_CHAT_ID="LOG CHANNEL ID"

# Переменные для первой базы данных
DB1_CONTAINER_NAME="mysql"
DB1_NAME="marzban"
DB1_USER="marzban"
DB1_PASSWORD="password"
DB1_HOST="127.0.0.1"
DB1_PORT="3306"
DB1_CUSTOM_NAME="CustomName1"

# Переменные для второй базы данных
DB2_CONTAINER_NAME="mysql"
DB2_NAME="another_db"
DB2_USER="another_user"
DB2_PASSWORD="another_password"
DB2_HOST="127.0.0.1"
DB2_PORT="3306"
DB2_CUSTOM_NAME="CustomName2"

DOCKER_COMPOSE_PATH="/opt/marzban/docker-compose.yml"
SRC_DIRS=("/opt/marzban" "/var/lib/marzban")
EXCLUDE_DIRS=("/opt/marzban/exclude_dir1" "/opt/marzban/exclude_dir2")
BACKUP_DIR="/opt/marzban/backup"
SERVER_IP=$(hostname -I | awk '{print $1}')
DEST_DIR="/root"
DATE=$(date +'%Y-%m-%d_%H-%M-%S')
ARCHIVE_NAME="VsemVPN_backup_$DATE.zip"
ARCHIVE_PATH="$DEST_DIR/$ARCHIVE_NAME"
TARGET_DIR="s3cf:dir/"

send_telegram_message() {
  MESSAGE=$1
  curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" -d chat_id="${TELEGRAM_CHAT_ID}" -d text="${MESSAGE}"
}

send_backup_to_telegram() {
  local file_path="$1"
  curl -s -F chat_id="${TELEGRAM_CHAT_ID}" -F caption=$'#MySQL #backup\n<code>'"$SERVER_IP"'</code>' -F parse_mode="HTML" -F document=@"$file_path" "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument"
}

backup_mysql() {
  local container_name=$1
  local db_name=$2
  local db_user=$3
  local db_password=$4
  local db_host=$5
  local db_port=$6
  local custom_name=$7

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] - Starting MySQL backup for $custom_name..."

  mkdir -p "$BACKUP_DIR"
  SQL_FILE="$BACKUP_DIR/db_${db_name}.sql"

  docker compose -f "$DOCKER_COMPOSE_PATH" exec "$container_name" mysqldump -u "$db_user" -p"$db_password" -h "$db_host" -P "$db_port" "$db_name" > "$SQL_FILE"

  if [ -f "$SQL_FILE" ]; then
    DB_DUMP_NAME="MySQL-$custom_name-$DATE.tar.gz"
    DB_DUMP_PATH="$BACKUP_DIR/$DB_DUMP_NAME"
    tar czvf "$DB_DUMP_PATH" -C "$BACKUP_DIR" "$(basename "$SQL_FILE")"

    if rclone copy "$DB_DUMP_PATH" "$TARGET_DIR"; then
      send_telegram_message "Дамп базы данных $custom_name ($DB_DUMP_NAME) успешно загружен в Cloudflare R2."
      send_backup_to_telegram "$DB_DUMP_PATH"
      rm "$DB_DUMP_PATH"
    else
      send_telegram_message "Ошибка при загрузке дампа базы данных $custom_name ($DB_DUMP_NAME) в Cloudflare R2."
    fi

    rm "$SQL_FILE"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] - MySQL backup for $custom_name completed!"
  else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] - MySQL backup for $custom_name failed!"
    send_telegram_message "Ошибка при создании дампа базы данных $custom_name."
  fi
}

# Формирование списка исключаемых директорий для zip
EXCLUDE_PARAMS=()
for DIR in "${EXCLUDE_DIRS[@]}"; do
  EXCLUDE_PARAMS+=("--exclude=${DIR}")
done

# Архивирование с исключением директорий
zip -r "$ARCHIVE_PATH" "${SRC_DIRS[@]}" "${EXCLUDE_PARAMS[@]}"

if rclone copy "$ARCHIVE_PATH" "$TARGET_DIR"; then
  send_telegram_message "Архив $ARCHIVE_NAME успешно загружен в Cloudflare R2."
  rm "$ARCHIVE_PATH"
else
  send_telegram_message "Ошибка при загрузке архива $ARCHIVE_NAME в Cloudflare R2."
}

rclone delete --min-age 7d "$TARGET_DIR"

# Выполнение резервного копирования баз данных
backup_mysql "$DB1_CONTAINER_NAME" "$DB1_NAME" "$DB1_USER" "$DB1_PASSWORD" "$DB1_HOST" "$DB1_PORT" "$DB1_CUSTOM_NAME"
backup_mysql "$DB2_CONTAINER_NAME" "$DB2_NAME" "$DB2_USER" "$DB2_PASSWORD" "$DB2_HOST" "$DB2_PORT" "$DB2_CUSTOM_NAME"
