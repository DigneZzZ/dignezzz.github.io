#!/bin/bash
set -euo pipefail

# Color definitions
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Print formatted messages
print_header() {
    echo -e "${GREEN}====================================================${NC}"
    echo -e "${GREEN}   $1${NC}"
    echo -e "${GREEN}====================================================${NC}"
}

print_error() {
    echo -e "${RED}✖ Error: $1${NC}" >&2
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_success() {
    echo -e "${GREEN}✔ $1${NC}"
}

print_info() {
    echo -e "${BLUE}$1${NC}"
}

# Prompt for user input with default value
prompt_input() {
    local prompt="$1"
    local var_name="$2"
    local default="$3"
    local input
    echo -ne "${prompt} [${default}]: "
    read -r input
    eval "$var_name=\"${input:-$default}\""
}

print_header "Welcome to SHM Backup Installer"
print_info "This script will create a ${YELLOW}backup.sh${NC} file with your settings.\n"

# Get SHM installation path
get_compose_path() {
    echo -e "${YELLOW}📍 Specify the path to docker-compose.yml for SHM:${NC}"
    echo -e "${BLUE}  1) /root/shm${NC}"
    echo -e "${BLUE}  2) /opt/shm${NC}"
    echo -e "${BLUE}  3) Enter manually${NC}"
    print_info "Note: Info from .env and other files will be read from this path."
    
    local choice
    echo -ne "Choose an option (1-3) [2]: "
    read -r choice
    choice=${choice:-2}

    case $choice in
        1) echo "/root/shm" ;;
        2) echo "/opt/shm" ;;
        3) 
            local path
            prompt_input "${YELLOW}Enter the path manually${NC}" path ""
            echo "$path"
            ;;
        *) echo "/opt/shm" ;;
    esac
}

# Validate compose path
validate_compose_path() {
    local path="$1"
    if [ ! -f "$path/docker-compose.yml" ]; then
        print_error "docker-compose.yml not found at $path"
        exit 1
    fi
}

# Get backup mode preference
get_backup_mode() {
    echo -e "${YELLOW}📁 Do you want to backup the entire folder ($1)?${NC}"
    echo -e "${BLUE}  1) Yes, backup all files and subfolders${NC}"
    echo -e "${BLUE}  2) No, backup only specific files (docker-compose.yml, .env)${NC}"
    
    local choice
    echo -ne "Choose an option (1-2) [1]: "
    read -r choice
    choice=${choice:-1}

    case $choice in
        1) echo "true" ;;
        2) echo "false" ;;
        *) echo "true" ;;
    esac
}

# Read environment variable from file
read_env_var() {
    local var_name="$1"
    local file="$2"
    grep "^$var_name=" "$file" 2>/dev/null | cut -d '=' -f 2-
}

# Get database configuration
get_db_config() {
    local compose_path="$1"
    local env_file="$compose_path/.env"
    
    if [ -f "$env_file" ]; then
        print_success ".env file found at $compose_path. Using it for DB connection."
        echo "USE_ENV=true"
        
        MYSQL_USER=$(read_env_var "MYSQL_USER" "$env_file")
        MYSQL_PASS=$(read_env_var "MYSQL_PASS" "$env_file")
        MYSQL_DATABASE=$(read_env_var "MYSQL_DATABASE" "$env_file")
        
        MYSQL_USER=${MYSQL_USER:-root}
        MYSQL_DATABASE=${MYSQL_DATABASE:-shm}
        
        if [ -z "$MYSQL_PASS" ]; then
            print_warning "MYSQL_PASS not found in .env file. Will use environment variables at runtime."
        fi
        
        echo "MYSQL_USER=$MYSQL_USER"
        echo "MYSQL_PASS=$MYSQL_PASS"
        echo "MYSQL_DATABASE=$MYSQL_DATABASE"
    else
        print_warning ".env file not found at $compose_path."
        print_info "You'll need to enter DB connection details manually."
        echo "USE_ENV=false"
        
        prompt_input "${YELLOW}Enter MYSQL_USER${NC}" MYSQL_USER "root"
        prompt_input "${YELLOW}Enter MYSQL_PASS${NC}" MYSQL_PASS ""
        prompt_input "${YELLOW}Enter MYSQL_DATABASE${NC}" MYSQL_DATABASE "shm"
        
        echo "MYSQL_USER=$MYSQL_USER"
        echo "MYSQL_PASS=$MYSQL_PASS"
        echo "MYSQL_DATABASE=$MYSQL_DATABASE"
    fi
}

# Get database container name
get_db_container() {
    local container
    container=$(docker ps --filter "name=mysql" --format "{{.Names}}" 2>/dev/null | head -1)
    
    if [ -z "$container" ]; then
        print_warning "Database container 'mysql' not found!"
        print_info "Please enter the correct container name for the database:"
        prompt_input "${YELLOW}Enter DB container name${NC}" container "mysql"
    fi
    
    echo "$container"
}

# Get Telegram configuration
get_telegram_config() {
    echo -e "${YELLOW}📡 Telegram Settings:${NC}"
    
    prompt_input "${BLUE}Enter Telegram Bot Token (from @BotFather)${NC}" TELEGRAM_BOT_TOKEN ""
    prompt_input "${BLUE}Enter Telegram Chat/Channel ID (e.g., -1001234567890)${NC}" TELEGRAM_CHAT_ID ""
    prompt_input "${BLUE}Enter Telegram Topic ID (optional, press Enter to skip)${NC}" TELEGRAM_TOPIC_ID ""
    
    if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
        print_error "Telegram Bot Token and Chat ID are required!"
        exit 1
    fi
    
    echo "TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN"
    echo "TELEGRAM_CHAT_ID=$TELEGRAM_CHAT_ID"
    echo "TELEGRAM_TOPIC_ID=$TELEGRAM_TOPIC_ID"
}

# Main execution
COMPOSE_PATH=$(get_compose_path)
validate_compose_path "$COMPOSE_PATH"

BACKUP_ENTIRE_FOLDER=$(get_backup_mode "$COMPOSE_PATH")

# Read DB config into variables
eval "$(get_db_config "$COMPOSE_PATH")"

DB_CONTAINER=$(get_db_container)

# Read Telegram config into variables
eval "$(get_telegram_config)"

# Generate backup script header
generate_script_header() {
    local script_file="$1"
    cat << 'EOF' > "$script_file"
#!/bin/bash
set -euo pipefail

# Error handler
error_exit() {
    echo "Error: $1" >&2
    exit 1
}

# Track backup start time
BACKUP_START=$(date +%s)

EOF

    cat << EOF >> "$script_file"
# Configuration
cd "$COMPOSE_PATH" || error_exit "Could not change to $COMPOSE_PATH"
TELEGRAM_BOT_TOKEN="$TELEGRAM_BOT_TOKEN"
TELEGRAM_CHAT_ID="$TELEGRAM_CHAT_ID"
TELEGRAM_TOPIC_ID="$TELEGRAM_TOPIC_ID"
BACKUP_DIR="/tmp/backup_\$(date +%Y%m%d_%H%M%S)"
BACKUP_DATE="\$(date '+%Y-%m-%d %H:%M:%S UTC')"
ARCHIVE_NAME="\$BACKUP_DIR.tar.gz"
MAX_SIZE_MB=49
DB_CONTAINER="$DB_CONTAINER"
EOF
}

# Generate database configuration section
generate_db_config() {
    local script_file="$1"
    
    if [ "$USE_ENV" = "true" ]; then
        cat << EOF >> "$script_file"

# Source environment variables from .env
[ -f "$COMPOSE_PATH/.env" ] && source "$COMPOSE_PATH/.env" || error_exit ".env file not found"
MYSQL_USER="\${MYSQL_USER:-$MYSQL_USER}"
MYSQL_PASS="\${MYSQL_PASS:-$MYSQL_PASS}"
MYSQL_DATABASE="\${MYSQL_DATABASE:-$MYSQL_DATABASE}"
EOF
    else
        cat << EOF >> "$script_file"

# Database credentials
MYSQL_USER="$MYSQL_USER"
MYSQL_PASS="$MYSQL_PASS"
MYSQL_DATABASE="$MYSQL_DATABASE"
EOF
    fi
}

# Generate backup logic section
generate_backup_logic() {
    local script_file="$1"
    
    cat << 'EOF' >> "$script_file"

# Create backup directory
mkdir -p "$BACKUP_DIR"

# Backup MySQL database
echo "Creating MySQL backup..."
docker exec "$DB_CONTAINER" mysqldump \
    --no-tablespaces \
    -u "$MYSQL_USER" \
    -p"$MYSQL_PASS" \
    "$MYSQL_DATABASE" > "$BACKUP_DIR/db_backup.sql" \
    || error_exit "Failed to create database backup"
echo "✔ Database backup created successfully"

# Auto-detect and backup WebDAV volume
backup_webdav_volume() {
    local volume=""
    
    if [ ! -f "docker-compose.yml" ]; then
        echo "Warning: docker-compose.yml not found, skipping volume backup"
        return 0
    fi
    
    # Try to find volume used by webdav service
    volume=$(grep -A 10 "webdav:" docker-compose.yml | \
        grep -E '^\s+- ".*:/app/data"' | \
        sed -E 's/.*- "(.*):.*/\1/' | head -1)
    
    # Try alternative format (without quotes)
    if [ -z "$volume" ]; then
        volume=$(grep -A 10 "webdav:" docker-compose.yml | \
            grep -E '^\s+- .*:/app/data' | \
            sed -E 's/.*- (.*):.*/\1/' | head -1)
    fi
    
    if [ -z "$volume" ]; then
        echo "WebDAV volume not detected in docker-compose.yml"
        return 0
    fi
    
    echo "Detected WebDAV volume: $volume"
    
    if ! docker volume inspect "$volume" >/dev/null 2>&1; then
        echo "Warning: Volume $volume not found, skipping"
        return 0
    fi
    
    echo "Backing up volume $volume..."
    docker run --rm \
        -v "$volume:/volume" \
        -v "$BACKUP_DIR:/backup" \
        alpine tar czf /backup/webdav-volume.tar.gz -C /volume . \
        || { echo "Warning: Failed to backup volume $volume"; return 1; }
    
    echo "✔ Volume $volume backed up successfully"
    echo "$volume"
}

WEBDAV_VOLUME=$(backup_webdav_volume)
EOF
}

# Generate archive creation section
generate_archive_section() {
    local script_file="$1"
    local backup_mode="$2"
    
    if [ "$backup_mode" = "true" ]; then
        cat << 'EOF' >> "$script_file"

# Create full folder backup
echo "Creating archive with entire SHM folder..."
TEMP_ARCHIVE_DIR="/tmp/archive_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$TEMP_ARCHIVE_DIR"
cp -r . "$TEMP_ARCHIVE_DIR/" || error_exit "Failed to copy SHM folder"
mv "$BACKUP_DIR/db_backup.sql" "$TEMP_ARCHIVE_DIR/db_backup.sql"
[ -f "$BACKUP_DIR/webdav-volume.tar.gz" ] && \
    mv "$BACKUP_DIR/webdav-volume.tar.gz" "$TEMP_ARCHIVE_DIR/webdav-volume.tar.gz"

tar -czf "$ARCHIVE_NAME" -C "$TEMP_ARCHIVE_DIR" . || error_exit "Failed to create archive"
rm -rf "$TEMP_ARCHIVE_DIR"

# Build contents list
CONTENTS="📁 Entire SHM folder
📋 db_backup.sql (MySQL)"
[ -n "$WEBDAV_VOLUME" ] && CONTENTS="$CONTENTS
💾 webdav-volume.tar.gz ($WEBDAV_VOLUME)"
EOF
    else
        cat << 'EOF' >> "$script_file"

# Create selective backup
echo "Creating archive with specific files..."
cp docker-compose.yml "$BACKUP_DIR/" || error_exit "Failed to copy docker-compose.yml"
[ -f .env ] && cp .env "$BACKUP_DIR/" || echo "File .env not found, skipping"

tar -czf "$ARCHIVE_NAME" -C "$BACKUP_DIR" . || error_exit "Failed to create archive"

# Build contents list
CONTENTS=""
[ -f "$BACKUP_DIR/db_backup.sql" ] && CONTENTS="${CONTENTS}📋 db_backup.sql (MySQL)
"
[ -f "$BACKUP_DIR/webdav-volume.tar.gz" ] && CONTENTS="${CONTENTS}💾 webdav-volume.tar.gz ($WEBDAV_VOLUME)
"
[ -f "$BACKUP_DIR/docker-compose.yml" ] && CONTENTS="${CONTENTS}📄 docker-compose.yml
"
[ -f "$BACKUP_DIR/.env" ] && CONTENTS="${CONTENTS}🔑 .env
"
EOF
    fi
}

# Generate Telegram send section
generate_telegram_section() {
    local script_file="$1"
    
    cat << 'EOF' >> "$script_file"

# Get system info and statistics
HOSTNAME=$(hostname)
DB_SIZE=$(docker exec "$DB_CONTAINER" mysql -u "$MYSQL_USER" -p"$MYSQL_PASS" -N \
    -e "SELECT ROUND(SUM(data_length + index_length) / 1024 / 1024, 2) \
    FROM information_schema.tables WHERE table_schema='$MYSQL_DATABASE';" 2>/dev/null || echo "N/A")

DB_TABLES=$(docker exec "$DB_CONTAINER" mysql -u "$MYSQL_USER" -p"$MYSQL_PASS" -N \
    -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$MYSQL_DATABASE';" 2>/dev/null || echo "N/A")

# Calculate archive size and file count
ARCHIVE_SIZE=$(du -m "$ARCHIVE_NAME" | cut -f1)
ARCHIVE_SIZE_HR=$(du -h "$ARCHIVE_NAME" | cut -f1)

# Count files in backup
FILE_COUNT=$(tar -tzf "$ARCHIVE_NAME" 2>/dev/null | grep -v '/$' | wc -l | tr -d ' ')

# Calculate backup execution time
BACKUP_END=$(date +%s)
BACKUP_DURATION=$((BACKUP_END - BACKUP_START))
BACKUP_TIME_HR=$(printf "%02d:%02d" $((BACKUP_DURATION / 60)) $((BACKUP_DURATION % 60)))

# Build comprehensive message
build_message() {
    local part_info="$1"
    cat << MESSAGE
✅ <b>SHM Backup Complete</b>
${part_info}
🖥 <b>Server:</b> <code>$HOSTNAME</code>
 <b>Date:</b> <code>$BACKUP_DATE</code>
⏱ <b>Duration:</b> <code>$BACKUP_TIME_HR</code>

📊 <b>Archive:</b> <code>$ARCHIVE_SIZE_HR</code>
📁 <b>Files:</b> <code>$FILE_COUNT</code>

📦 <b>Contents:</b>
$CONTENTS
💾 <b>Database:</b> <code>${MYSQL_DATABASE}</code> (<code>${DB_SIZE} MB</code>, <code>${DB_TABLES}</code> tables)
MESSAGE
}

# Send file to Telegram
send_telegram() {
    local file="$1"
    local caption="$2"
    local url="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument"
    
    local curl_args=(
        -F "chat_id=$TELEGRAM_CHAT_ID"
        -F "document=@$file"
        -F "caption=$caption"
        -F "parse_mode=HTML"
        -o "telegram_response.json"
        -s
    )
    
    [ -n "$TELEGRAM_TOPIC_ID" ] && curl_args+=(-F "message_thread_id=$TELEGRAM_TOPIC_ID")
    
    curl "${curl_args[@]}" "$url"
}

# Check if splitting is needed
if [ "$ARCHIVE_SIZE" -gt "$MAX_SIZE_MB" ]; then
    echo "Archive size ($ARCHIVE_SIZE MB) exceeds $MAX_SIZE_MB MB, splitting into parts..."
    split -b 49m "$ARCHIVE_NAME" "$BACKUP_DIR/part_"
    
    mapfile -t PARTS < <(ls -1 "$BACKUP_DIR"/part_*)
    PART_COUNT=${#PARTS[@]}
    
    for i in "${!PARTS[@]}"; do
        PART_FILE="${PARTS[$i]}"
        PART_NUM=$((i + 1))
        PART_SIZE=$(du -h "$PART_FILE" | cut -f1)
        
        MESSAGE=$(build_message "📦 <b>Part:</b> <code>$PART_NUM of $PART_COUNT</code> (<code>${PART_SIZE}</code>)")
        
        echo "Sending part $PART_NUM of $PART_COUNT..."
        send_telegram "$PART_FILE" "$MESSAGE"
        
        if grep -q '"ok":false' telegram_response.json 2>/dev/null; then
            echo "Error sending part $PART_NUM:" >&2
            cat telegram_response.json >&2
            exit 1
        fi
        echo "✔ Part $PART_NUM of $PART_COUNT sent successfully"
    done
else
    MESSAGE=$(build_message "")
    
    echo "Sending archive to Telegram..."
    send_telegram "$ARCHIVE_NAME" "$MESSAGE"
    
    if grep -q '"ok":false' telegram_response.json 2>/dev/null; then
        echo "Telegram returned an error:" >&2
        cat telegram_response.json >&2
        exit 1
    fi
    echo "✔ Archive successfully sent to Telegram"
fi

# Cleanup
rm -rf "$BACKUP_DIR"
rm -f "$ARCHIVE_NAME" telegram_response.json
echo "✔ Backup completed successfully in $BACKUP_TIME_HR"
EOF
}

# Show configuration summary before creating script
show_summary() {
    echo
    print_header "Configuration Summary"
    echo -e "${BLUE}📁 SHM Path:${NC}          ${YELLOW}$COMPOSE_PATH${NC}"
    echo -e "${BLUE}📦 Backup Mode:${NC}       ${YELLOW}$([ "$BACKUP_ENTIRE_FOLDER" = "true" ] && echo "Full folder" || echo "Selective files only")${NC}"
    echo -e "${BLUE}🗄️  DB Container:${NC}      ${YELLOW}$DB_CONTAINER${NC}"
    echo -e "${BLUE}💾 Database:${NC}          ${YELLOW}$MYSQL_DATABASE${NC} (user: ${YELLOW}$MYSQL_USER${NC})"
    echo -e "${BLUE}📱 Telegram Chat:${NC}     ${YELLOW}$TELEGRAM_CHAT_ID${NC}"
    [ -n "$TELEGRAM_TOPIC_ID" ] && echo -e "${BLUE}💬 Topic ID:${NC}          ${YELLOW}$TELEGRAM_TOPIC_ID${NC}"
    echo
    
    echo -ne "${YELLOW}Proceed with backup script creation? (Y/n):${NC} "
    read -r confirm
    confirm=${confirm:-Y}
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_warning "Script creation cancelled by user."
        exit 0
    fi
    echo
}

# Create the backup script
show_summary

BACKUP_SCRIPT="$COMPOSE_PATH/backup.sh"

generate_script_header "$BACKUP_SCRIPT"
generate_db_config "$BACKUP_SCRIPT"
generate_backup_logic "$BACKUP_SCRIPT"
generate_archive_section "$BACKUP_SCRIPT" "$BACKUP_ENTIRE_FOLDER"
generate_telegram_section "$BACKUP_SCRIPT"

chmod +x "$BACKUP_SCRIPT"

print_header "Backup script created successfully!"
print_info "Script location: ${YELLOW}$BACKUP_SCRIPT${NC}\n"
print_info "To run it manually, use:"
echo -e "  ${YELLOW}$BACKUP_SCRIPT${NC}\n"
print_info "To schedule automatic backups, add to crontab (${YELLOW}crontab -e${NC}):"
echo -e "  ${YELLOW}0 */2 * * * $BACKUP_SCRIPT${NC}  # Every 2 hours"
echo -e "  ${YELLOW}0 0 * * * $BACKUP_SCRIPT${NC}    # Daily at midnight"
echo -e "  ${YELLOW}0 */6 * * * $BACKUP_SCRIPT${NC}  # Every 6 hours"
