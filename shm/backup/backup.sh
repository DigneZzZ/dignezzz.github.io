#!/bin/bash
set -euo pipefail

# Color definitions
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Detect OS and version
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        OS_VERSION=$VERSION_ID
        OS_NAME=$PRETTY_NAME
    elif [ -f /etc/redhat-release ]; then
        OS="rhel"
        OS_VERSION=$(grep -oE '[0-9]+\.[0-9]+' /etc/redhat-release | head -1)
        OS_NAME=$(< /etc/redhat-release)
    else
        OS="unknown"
        OS_VERSION="unknown"
        OS_NAME="Unknown OS"
    fi
}

# Check OS compatibility
check_os_compatibility() {
    detect_os
    
    local compatible=false
    local os_info=""
    
    case $OS in
        debian)
            if [[ "$OS_VERSION" =~ ^(11|12|13) ]]; then
                compatible=true
                os_info="Debian $OS_VERSION"
            fi
            ;;
        ubuntu)
            if [[ "$OS_VERSION" =~ ^(20|22|24) ]]; then
                compatible=true
                os_info="Ubuntu $OS_VERSION"
            fi
            ;;
        centos|rhel)
            if [[ "$OS_VERSION" =~ ^[7-9] ]]; then
                compatible=true
                os_info="CentOS/RHEL $OS_VERSION"
            fi
            ;;
        almalinux|rocky)
            if [[ "$OS_VERSION" =~ ^[8-9] ]]; then
                compatible=true
                os_info="AlmaLinux/Rocky $OS_VERSION"
            fi
            ;;
        fedora)
            compatible=true
            os_info="Fedora $OS_VERSION"
            ;;
    esac
    
    if [ "$compatible" = true ]; then
        echo -e "${GREEN}✔ OS Detected:${NC} $os_info"
        return 0
    else
        echo -e "${YELLOW}⚠ Warning: OS not officially tested${NC}"
        echo -e "${BLUE}Detected:${NC} $OS_NAME"
        echo -e "${BLUE}The script should work on any Linux with Docker and bash 4+${NC}"
        echo
        echo -ne "${YELLOW}Continue anyway? (y/N):${NC} "
        read -r confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo -e "${RED}Installation cancelled.${NC}"
            exit 1
        fi
    fi
}

# Check and install required dependencies
check_dependencies() {
    local missing_deps=()
    
    # Required commands
    local required_cmds=("docker" "curl" "tar" "grep" "sed" "split")
    
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done
    
    # Handle missing dependencies
    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo -e "${RED}✖ Missing required dependencies:${NC}"
        for dep in "${missing_deps[@]}"; do
            echo -e "  ${YELLOW}- $dep${NC}"
        done
        echo
        
        # Check if Docker is missing
        if [[ " ${missing_deps[*]} " =~ " docker " ]]; then
            echo -e "${RED}✖ Docker is required but not found!${NC}"
            echo -e "${YELLOW}SHM requires Docker to run. Please install Docker first:${NC}"
            echo -e "  ${BLUE}curl -fsSL https://get.docker.com | sh${NC}"
            echo
            exit 1
        fi
        
        # Ask for automatic installation of other packages
        echo -ne "${YELLOW}Install missing packages automatically? (Y/n):${NC} "
        read -r confirm
        confirm=${confirm:-Y}
        
        if [[ ! "$confirm" =~ ^[Nn]$ ]]; then
            echo -e "${YELLOW}Installing packages: ${missing_deps[*]}${NC}"
            
            case $OS in
                debian|ubuntu)
                    sudo apt-get update
                    sudo apt-get install -y "${missing_deps[@]}"
                    ;;
                centos|rhel|almalinux|rocky|fedora)
                    if command -v dnf &> /dev/null; then
                        sudo dnf install -y "${missing_deps[@]}"
                    else
                        sudo yum install -y "${missing_deps[@]}"
                    fi
                    ;;
                *)
                    echo -e "${RED}✖ Cannot auto-install on $OS_NAME${NC}"
                    echo -e "${YELLOW}Please install manually: ${missing_deps[*]}${NC}"
                    exit 1
                    ;;
            esac
            
            echo -e "${GREEN}✔ Packages installed successfully${NC}"
        else
            echo -e "${RED}Installation cancelled. Please install dependencies manually.${NC}"
            exit 1
        fi
    fi
    
    # Check bash version
    if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
        echo -e "${RED}✖ Bash 4.0+ required (current: $BASH_VERSION)${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}✔ All dependencies satisfied${NC}"
}

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
    echo -e "${YELLOW}⚠ $1${NC}" >&2
}

print_success() {
    echo -e "${GREEN}✔ $1${NC}" >&2
}

print_info() {
    echo -e "${BLUE}$1${NC}" >&2
}

# Prompt for user input with default value
prompt_input() {
    local prompt="$1"
    local var_name="$2"
    local default="$3"
    local input
    echo -ne "${prompt} [${default}]: " >&2
    read -r input
    printf -v "$var_name" '%s' "${input:-$default}"
}

# Check system compatibility and dependencies
check_os_compatibility
check_dependencies
echo

print_header "Welcome to SHM Backup Installer"
print_info "This script will create a ${YELLOW}backup.sh${NC} file with your settings.\n"

# Get SHM installation path
get_compose_path() {
    echo -e "${YELLOW}📍 Specify the path to docker-compose.yml for SHM:${NC}" >&2
    echo -e "${BLUE}  1) /root/shm${NC}" >&2
    echo -e "${BLUE}  2) /opt/shm${NC}" >&2
    echo -e "${BLUE}  3) Enter manually${NC}" >&2
    print_info "Note: Info from .env and other files will be read from this path."
    
    local choice
    echo -ne "Choose an option (1-3) [2]: " >&2
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
    echo -e "${YELLOW}📁 Do you want to backup the entire folder ($1)?${NC}" >&2
    echo -e "${BLUE}  1) Yes, backup all files and subfolders${NC}" >&2
    echo -e "${BLUE}  2) No, backup only specific files (docker-compose.yml, .env)${NC}" >&2
    
    local choice
    echo -ne "Choose an option (1-2) [1]: " >&2
    read -r choice
    choice=${choice:-1}

    case $choice in
        1) echo "true" ;;
        2) echo "false" ;;
        *) echo "true" ;;
    esac
}

# Read environment variable from file (strips surrounding quotes)
read_env_var() {
    local var_name="$1"
    local file="$2"
    local value
    value=$(grep "^$var_name=" "$file" 2>/dev/null | cut -d '=' -f 2-)
    # Strip surrounding quotes (single or double)
    value="${value#\"}"; value="${value%\"}"
    value="${value#\'}"; value="${value%\'}"
    echo "$value"
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
    echo -e "${YELLOW}📡 Telegram Settings:${NC}" >&2
    
    prompt_input "${BLUE}Enter Telegram Bot Token (from @BotFather)${NC}" TELEGRAM_BOT_TOKEN ""
    prompt_input "${BLUE}Enter Telegram Chat/Channel ID (e.g., -1001234567890)${NC}" TELEGRAM_CHAT_ID ""
    prompt_input "${BLUE}Enter Telegram Topic ID (optional, press Enter to skip)${NC}" TELEGRAM_TOPIC_ID ""
    
    if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
        print_error "Telegram Bot Token and Chat ID are required!" >&2
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

# Lock file to prevent concurrent runs
LOCK_FILE="/tmp/shm_backup.lock"
if [ -f "$LOCK_FILE" ]; then
    LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null)
    if kill -0 "$LOCK_PID" 2>/dev/null; then
        echo "Error: Backup already running (PID $LOCK_PID)" >&2
        exit 1
    fi
    rm -f "$LOCK_FILE"
fi
echo $$ > "$LOCK_FILE"

# Error handler
error_exit() {
    echo "Error: $1" >&2
    exit 1
}

# Cleanup on exit (success or failure)
cleanup() {
    rm -rf "$BACKUP_DIR" "${TEMP_ARCHIVE_DIR:-}" 2>/dev/null || true
    rm -f "$ARCHIVE_NAME" /tmp/shm_tg_response.json "$LOCK_FILE" 2>/dev/null || true
}
trap cleanup EXIT

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
TEMP_ARCHIVE_DIR=""
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
    --single-transaction \
    -u "$MYSQL_USER" \
    -p"$MYSQL_PASS" \
    "$MYSQL_DATABASE" > "$BACKUP_DIR/db_backup.sql" \
    || error_exit "Failed to create database backup"
echo "✔ Database backup created successfully"

# Auto-detect and backup WebDAV volume
backup_webdav_volume() {
    local volume=""
    
    if [ ! -f "docker-compose.yml" ]; then
        echo "Warning: docker-compose.yml not found, skipping volume backup" >&2
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
        echo "WebDAV volume not detected in docker-compose.yml" >&2
        return 0
    fi
    
    echo "Detected WebDAV volume: $volume" >&2
    
    if ! docker volume inspect "$volume" >/dev/null 2>&1; then
        echo "Warning: Volume $volume not found, skipping" >&2
        return 0
    fi
    
    echo "Backing up volume $volume..." >&2
    docker run --rm \
        -v "$volume:/volume" \
        -v "$BACKUP_DIR:/backup" \
        alpine tar czf /backup/webdav-volume.tar.gz -C /volume . \
        || { echo "Warning: Failed to backup volume $volume" >&2; return 1; }
    
    echo "✔ Volume $volume backed up successfully" >&2
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
        -o "/tmp/shm_tg_response.json"
        -s
        -w "%{http_code}"
    )
    
    [ -n "$TELEGRAM_TOPIC_ID" ] && curl_args+=(-F "message_thread_id=$TELEGRAM_TOPIC_ID")
    
    local http_code
    http_code=$(curl "${curl_args[@]}" "$url") || error_exit "curl request failed (network error)"
    
    if [ "$http_code" != "200" ] || grep -q '"ok":false' /tmp/shm_tg_response.json 2>/dev/null; then
        echo "Telegram API error (HTTP $http_code):" >&2
        cat /tmp/shm_tg_response.json >&2
        return 1
    fi
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
        send_telegram "$PART_FILE" "$MESSAGE" \
            || error_exit "Failed to send part $PART_NUM"
        echo "✔ Part $PART_NUM of $PART_COUNT sent successfully"
    done
else
    MESSAGE=$(build_message "")
    
    echo "Sending archive to Telegram..."
    send_telegram "$ARCHIVE_NAME" "$MESSAGE" \
        || error_exit "Failed to send archive to Telegram"
    echo "✔ Archive successfully sent to Telegram"
fi

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

# Setup automatic backups via crontab
setup_crontab() {
    echo
    print_header "Automatic Backup Schedule Setup"
    echo -e "${YELLOW}Would you like to set up automatic backups?${NC}\n"
    echo -e "${BLUE}  1) Every 1 hour${NC}"
    echo -e "${BLUE}  2) Every 2 hours${NC}"
    echo -e "${BLUE}  3) Every 3 hours${NC}"
    echo -e "${BLUE}  4) Every 4 hours${NC}"
    echo -e "${BLUE}  5) Every 6 hours${NC}"
    echo -e "${BLUE}  6) Every 12 hours${NC}"
    echo -e "${BLUE}  7) Once a day (at 03:00)${NC}"
    echo -e "${BLUE}  8) Twice a day (at 03:00 and 15:00)${NC}"
    echo -e "${BLUE}  9) Skip (configure manually later)${NC}"
    echo
    echo -ne "Choose an option (1-9) [7]: "
    read -r choice
    choice=${choice:-7}
    
    local cron_schedule=""
    local description=""
    
    case $choice in
        1) cron_schedule="0 * * * *"; description="every hour" ;;
        2) cron_schedule="0 */2 * * *"; description="every 2 hours" ;;
        3) cron_schedule="0 */3 * * *"; description="every 3 hours" ;;
        4) cron_schedule="0 */4 * * *"; description="every 4 hours" ;;
        5) cron_schedule="0 */6 * * *"; description="every 6 hours" ;;
        6) cron_schedule="0 */12 * * *"; description="every 12 hours" ;;
        7) cron_schedule="0 3 * * *"; description="once a day at 03:00" ;;
        8) cron_schedule="0 3,15 * * *"; description="twice a day (03:00 and 15:00)" ;;
        9) 
            echo
            print_warning "Skipping automatic setup."
            print_info "To configure manually later, run: ${YELLOW}crontab -e${NC}"
            print_info "Example: ${YELLOW}0 */6 * * * $BACKUP_SCRIPT${NC}"
            return 0
            ;;
        *) 
            print_error "Invalid choice. Skipping automatic setup."
            return 1
            ;;
    esac
    
    # Check if cron job already exists
    local existing_cron=$(crontab -l 2>/dev/null | grep -F "$BACKUP_SCRIPT" || true)
    
    if [ -n "$existing_cron" ]; then
        echo
        print_warning "Found existing cron job for this backup script:"
        echo -e "  ${YELLOW}$existing_cron${NC}"
        echo
        echo -ne "${YELLOW}Replace it with new schedule? (y/N):${NC} "
        read -r replace
        if [[ ! "$replace" =~ ^[Yy]$ ]]; then
            print_info "Keeping existing cron job."
            return 0
        fi
        # Remove old cron job
        crontab -l 2>/dev/null | grep -vF "$BACKUP_SCRIPT" | crontab - 2>/dev/null || true
    fi
    
    # Add new cron job
    if (crontab -l 2>/dev/null || true; echo "$cron_schedule $BACKUP_SCRIPT # SHM Backup") | crontab - 2>/dev/null; then
        echo
        print_success "Cron job added successfully!"
        echo -e "${BLUE}📅 Schedule:${NC} ${GREEN}$description${NC}"
        echo -e "${BLUE}⏰ Cron:${NC}     ${YELLOW}$cron_schedule${NC}"
        echo
        print_info "Useful commands:"
        echo -e "  ${YELLOW}crontab -l${NC}  # View all cron jobs"
        echo -e "  ${YELLOW}crontab -e${NC}  # Edit cron jobs"
    else
        echo
        print_error "Failed to add cron job. You can add it manually:"
        print_info "Run: ${YELLOW}crontab -e${NC}"
        print_info "Add: ${YELLOW}$cron_schedule $BACKUP_SCRIPT${NC}"
    fi
}

setup_crontab

echo
print_header "Installation Complete!"
print_info "Script location: ${YELLOW}$BACKUP_SCRIPT${NC}\n"
print_info "To run backup manually:"
echo -e "  ${YELLOW}$BACKUP_SCRIPT${NC}\n"
print_info "To test the backup right now:"
echo -e "  ${YELLOW}$BACKUP_SCRIPT${NC} ${GREEN}# Run this to verify everything works${NC}"
