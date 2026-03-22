#!/bin/bash
set -e

# Цвета для вывода
red="\033[31m"
green="\033[32m"
yellow="\033[33m"
blue="\033[34m"
reset="\033[0m"

# Функции для вывода сообщений
print() { printf "${blue}%s${reset}\n" "$1"; }
error() { printf "${red}[Error] %s${reset}\n" "$1"; }
success() { printf "${green}[Success] %s${reset}\n" "$1"; }
input() {
    local __resultvar=$2
    read -p "$(printf "${yellow}%s: ${reset}" "$1")" __temp
    eval "$__resultvar=\"\$__temp\""
}
input_secure() {
    local __resultvar=$2
    read -s -p "$(printf "${yellow}%s: ${reset}" "$1")" __temp
    echo
    eval "$__resultvar=\"\$__temp\""
}
confirm() {
    read -n1 -s -r -p "$(printf "\n${yellow}Press any key to continue...${reset}")"
    echo
}

# Проверка успешности выполнения команды
check_success() {
    if [ $? -eq 0 ]; then
        success "$1"
    else
        error "$2"
        exit 1
    fi
}

# Проверка прав root
if [ "$EUID" -ne 0 ]; then
    error "Please run the script as root."
    exit 1
fi

# Установка зависимостей
install_dependencies() {
    print "Updating system..."
    apt update -y > /dev/null 2>&1
    check_success "System updated successfully." "Failed to update the system."

    print "Installing SQLite3..."
    apt install -y sqlite3 > /dev/null 2>&1
    check_success "SQLite3 installed successfully." "Failed to install SQLite3."
}

# Выбор целевой базы данных
select_database() {
    while true; do
        print "Select the target database for migration:"
        print "1. MariaDB LTS"
        print "2. MySQL LTS"
        input "Enter your choice" DB_CHOICE
        case $DB_CHOICE in
            1)
                DB_ENGINE="mariadb"
                break
                ;;
            2)
                DB_ENGINE="mysql"
                break
                ;;
            *)
                error "Invalid choice. Please select 1 or 2."
                ;;
        esac
    done
}

# Получение пользовательского ввода
get_user_input() {
    default_docker_compose_path="/opt/marzban/docker-compose.yml"
    default_env_file_path="/opt/marzban/.env"

    while true; do
        input_secure "Enter MySQL root password" DB_PASSWORD
        if [ -z "$DB_PASSWORD" ]; then
            error "Password cannot be empty."
        else
            break
        fi
    done

    while true; do
        input "Enter path to docker-compose.yml [${default_docker_compose_path}]" DOCKER_COMPOSE_PATH
        DOCKER_COMPOSE_PATH=${DOCKER_COMPOSE_PATH:-$default_docker_compose_path}
        if [[ ! -f $DOCKER_COMPOSE_PATH ]]; then
            error "File $DOCKER_COMPOSE_PATH does not exist."
        else
            break
        fi
    done

    while true; do
        input "Enter path to .env file [${default_env_file_path}]" ENV_FILE_PATH
        ENV_FILE_PATH=${ENV_FILE_PATH:-$default_env_file_path}
        if [[ ! -f $ENV_FILE_PATH ]]; then
            error "File $ENV_FILE_PATH does not exist."
        else
            break
        fi
    done
}

# Обновление файла .env
update_env_file() {
    if [ "$DB_ENGINE" = "mariadb" ]; then
        DB_URL="mysql+pymysql://marzban:${DB_PASSWORD}@127.0.0.1:3306/marzban"
    else
        DB_URL="mysql+pymysql://marzban:${DB_PASSWORD}@127.0.0.1:3306/marzban"
    fi
    sed -i "s|^SQLALCHEMY_DATABASE_URL.*|SQLALCHEMY_DATABASE_URL = \"$DB_URL\"|" "$ENV_FILE_PATH"
    check_success ".env configuration updated successfully." "Failed to update .env file."
}

# Создание резервных копий файлов
backup_files() {
    local timestamp=$(date +%Y%m%d_%H%M%S)

    cp "$ENV_FILE_PATH" "${ENV_FILE_PATH}_$timestamp.bak"
    check_success ".env file backed up." "Failed to back up .env file."

    cp "$DOCKER_COMPOSE_PATH" "${DOCKER_COMPOSE_PATH}_$timestamp.bak"
    check_success "docker-compose.yml file backed up." "Failed to back up docker-compose.yml file."

    if [ -f /var/lib/marzban/db.sqlite3 ]; then
        cp /var/lib/marzban/db.sqlite3 /var/lib/marzban/db.sqlite3_$timestamp.bak
        check_success "db.sqlite3 file backed up." "Failed to back up db.sqlite3 file."
    else
        error "db.sqlite3 file not found, skipping."
    fi
}

# Настройка MariaDB в docker-compose.yml
setup_mariadb() {
    cat <<EOF > "$DOCKER_COMPOSE_PATH"
services:
  marzban:
    image: gozargah/marzban:latest
    restart: always
    env_file: .env
    network_mode: host
    volumes:
      - /var/lib/marzban:/var/lib/marzban
    depends_on:
      mariadb:
        condition: service_healthy

  mariadb:
    image: mariadb:lts
    env_file: .env
    network_mode: host
    restart: always
    environment:
      MYSQL_ROOT_PASSWORD: ${DB_PASSWORD}
      MYSQL_ROOT_HOST: '%'
      MYSQL_DATABASE: marzban
      MYSQL_USER: marzban
      MYSQL_PASSWORD: ${DB_PASSWORD}
    command:
      - --bind-address=127.0.0.1
      - --character_set_server=utf8mb4
      - --collation_server=utf8mb4_unicode_ci
      - --host-cache-size=0
      - --innodb-open-files=1024
      - --innodb-buffer-pool-size=256M
      - --binlog_expire_logs_seconds=1209600
      - --innodb-log-file-size=64M
      - --innodb-log-files-in-group=2
      - --innodb-doublewrite=0
      - --general_log=0
      - --slow_query_log=1
      - --slow_query_log_file=/var/lib/mysql/slow.log
      - --long_query_time=2
    volumes:
      - /var/lib/marzban/mysql:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      start_period: 10s
      start_interval: 3s
      interval: 10s
      timeout: 5s
      retries: 3
EOF
}

# Настройка MySQL в docker-compose.yml
setup_mysql() {
    cat <<EOF > "$DOCKER_COMPOSE_PATH"
services:
  marzban:
    image: gozargah/marzban:latest
    restart: always
    env_file: .env
    network_mode: host
    volumes:
      - /var/lib/marzban:/var/lib/marzban
    depends_on:
      mysql:
        condition: service_healthy

  mysql:
    image: mysql:lts
    env_file: .env
    network_mode: host
    restart: always
    environment:
      MYSQL_ROOT_PASSWORD: ${DB_PASSWORD}
      MYSQL_ROOT_HOST: '%'
      MYSQL_DATABASE: marzban
      MYSQL_USER: marzban
      MYSQL_PASSWORD: ${DB_PASSWORD}
    command:
      - --mysqlx=OFF
      - --bind-address=127.0.0.1
      - --character_set_server=utf8mb4
      - --collation_server=utf8mb4_unicode_ci
      - --log-bin=mysql-bin
      - --binlog_expire_logs_seconds=1209600
      - --host-cache-size=0
      - --innodb-open-files=1024
      - --innodb-buffer-pool-size=256M
      - --innodb-log-file-size=64M
      - --innodb-log-files-in-group=2
      - --general_log=0
      - --slow_query_log=1
      - --slow_query_log_file=/var/lib/mysql/slow.log
      - --long_query_time=2
    volumes:
      - /var/lib/marzban/mysql:/var/lib/mysql
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "127.0.0.1", "-u", "marzban", "--password=\${MYSQL_PASSWORD}"]
      start_period: 5s
      interval: 5s
      timeout: 5s
      retries: 55
EOF
}

# Миграция базы данных
migrate_database() {
    if [ ! -f /var/lib/marzban/db.sqlite3 ]; then
        error "db.sqlite3 file not found."
        exit 1
    fi

    # Создание дампа только с INSERT-запросами
    sqlite3 /var/lib/marzban/db.sqlite3 ".dump" | grep -E "^INSERT" > /tmp/dump.sql
    check_success "SQLite dump created." "Failed to create SQLite dump."

    # Замена INSERT на REPLACE
    sed "s/INSERT INTO \([^ ]*\)/REPLACE INTO \1/g" /tmp/dump.sql > /tmp/dump_fixed.sql
    check_success "SQL dump fixed." "Failed to fix SQL dump."

    # Остановка и запуск контейнеров
    docker compose -f "$DOCKER_COMPOSE_PATH" down --remove-orphans || true
    docker compose -f "$DOCKER_COMPOSE_PATH" up -d $DB_ENGINE marzban

    # Ожидание инициализации базы данных
    print "Waiting 20 seconds for database tables to be created..."
    sleep 20

    # Копирование и выполнение дампа
    docker compose -f "$DOCKER_COMPOSE_PATH" cp /tmp/dump_fixed.sql $DB_ENGINE:/dump.sql
    docker compose -f "$DOCKER_COMPOSE_PATH" exec $DB_ENGINE $DB_ENGINE -u root -p"${DB_PASSWORD}" -h 127.0.0.1 marzban -e "SET FOREIGN_KEY_CHECKS = 0; SET NAMES utf8mb4; SOURCE /dump.sql;"
    check_success "Data restored successfully." "Failed to restore data."

    # Очистка временных файлов и перезапуск Marzban
    rm /tmp/dump.sql /tmp/dump_fixed.sql
    docker compose -f "$DOCKER_COMPOSE_PATH" restart marzban
    check_success "Marzban restarted successfully." "Failed to restart Marzban."

    success "Migration complete."
    confirm
}

# Главное меню
main_menu() {
    while true; do
        print ""
        print "Marzban Migration Script from SQLite3 to Selected Database"
        print ""
        print "1. Start Migration"
        print "0. Exit"
        print ""
        input "Enter your choice" choice
        case $choice in
            1)
                install_dependencies
                select_database
                get_user_input
                backup_files
                update_env_file
                if [ "$DB_ENGINE" = "mariadb" ]; then
                    setup_mariadb
                else
                    setup_mysql
                fi
                migrate_database
                ;;
            0)
                print "Exiting..."
                exit 0
                ;;
            *)
                error "Invalid choice."
                ;;
        esac
    done
}

# Запуск скрипта
clear
main_menu
