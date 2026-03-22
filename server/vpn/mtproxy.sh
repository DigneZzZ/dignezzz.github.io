#!/bin/bash

# MTProxy Docker Installation Script
# Uses official telegrammessenger/proxy:latest Docker image
# Supports TAG configuration via @MTProxybot for channel branding
#
# Usage:
#   ./mtproxy.sh install      - Install MTProxy with Docker
#   ./mtproxy.sh uninstall    - Remove MTProxy completely
#   ./mtproxy.sh update-tag   - Update TAG from @MTProxybot
#   ./mtproxy.sh help         - Show help

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${BLUE}MTProxy Docker Installation${NC}\n"

# Configuration
INSTALL_DIR="/opt/MTProxy"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
ENV_FILE="$INSTALL_DIR/.env"
INFO_FILE="$INSTALL_DIR/info.txt"

# Require root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}This installer must be run as root (use sudo).${NC}"
    exit 1
fi

# Function to generate random hex secret
generate_secret() {
    head -c 16 /dev/urandom | xxd -ps -c 16
}

# Function to update TAG
update_tag() {
    echo -e "${YELLOW}🏷️  Update TAG from @MTProxybot${NC}\n"
    
    if [[ ! -f "$ENV_FILE" ]]; then
        echo -e "${RED}MTProxy not installed. Please install first.${NC}"
        exit 1
    fi
    
    echo -e "${CYAN}To get your TAG:${NC}"
    echo -e "1. Open Telegram and find @MTProxybot"
    echo -e "2. Send /newproxy command"
    echo -e "3. Register your proxy with the bot"
    echo -e "4. Bot will provide you with a TAG (32 hex characters)"
    echo ""
    
    read -p "Enter TAG from @MTProxybot (leave empty to remove TAG): " NEW_TAG
    
    if [[ -n "$NEW_TAG" ]]; then
        # Validate TAG format (should be 32 hex characters)
        if [[ ! "$NEW_TAG" =~ ^[0-9a-fA-F]{32}$ ]]; then
            echo -e "${RED}Invalid TAG format. TAG should be 32 hexadecimal characters.${NC}"
            exit 1
        fi
        
        # Update TAG in .env file
        if grep -q "^TAG=" "$ENV_FILE"; then
            sed -i "s/^TAG=.*/TAG=$NEW_TAG/" "$ENV_FILE"
        else
            echo "TAG=$NEW_TAG" >> "$ENV_FILE"
        fi
        echo -e "${GREEN}✅ TAG updated successfully!${NC}"
    else
        # Remove TAG from .env
        sed -i '/^TAG=/d' "$ENV_FILE"
        echo -e "${YELLOW}TAG removed. No channel will be promoted.${NC}"
    fi
    
    # Restart container to apply changes
    echo -e "${YELLOW}Restarting MTProxy container...${NC}"
    cd "$INSTALL_DIR" || exit 1
    docker-compose down
    docker-compose up -d
    
    echo -e "${GREEN}✅ MTProxy restarted with new configuration!${NC}"
    echo -e "\n${CYAN}Run 'mtproxy status' to see updated configuration.${NC}"
}

# Check for uninstall option
if [[ "$1" == "uninstall" ]]; then
    echo -e "${YELLOW}🗑️  MTProxy Uninstallation${NC}\n"
    
    echo -e "${RED}WARNING: This will completely remove MTProxy and all related files!${NC}"
    echo -e "${YELLOW}The following will be deleted:${NC}"
    echo -e "  • Docker containers and images"
    echo -e "  • Installation directory: $INSTALL_DIR"
    echo -e "  • Management utility: /usr/local/bin/mtproxy"
    echo -e "  • All configuration files and secrets"
    echo ""
    
    read -p "Are you sure you want to continue? (type 'YES' to confirm): " CONFIRM
    
    if [[ "$CONFIRM" != "YES" ]]; then
        echo -e "${GREEN}Uninstallation cancelled.${NC}"
        exit 0
    fi
    
    echo -e "\n${YELLOW}Removing MTProxy...${NC}"
    
    # Stop and remove Docker containers
    if [[ -f "$COMPOSE_FILE" ]]; then
        echo -e "${YELLOW}Stopping Docker containers...${NC}"
        cd "$INSTALL_DIR" || exit 1
        docker-compose down -v 2>/dev/null || true
    fi
    
    # Remove Docker image
    echo -e "${YELLOW}Removing Docker image...${NC}"
    docker rmi telegrammessenger/proxy:latest 2>/dev/null || true
    
    # Remove installation directory
    if [[ -d "$INSTALL_DIR" ]]; then
        echo -e "${YELLOW}Removing installation directory...${NC}"
        rm -rf "$INSTALL_DIR"
    fi
    
    # Remove management utility
    if [[ -f "/usr/local/bin/mtproxy" ]]; then
        echo -e "${YELLOW}Removing management utility...${NC}"
        rm -f "/usr/local/bin/mtproxy"
    fi
    
    # Remove firewall rules (if UFW is active)
    if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
        echo -e "${YELLOW}Checking firewall rules...${NC}"
        for port in 443 8443 9443; do
            if ufw status | grep -q "${port}/tcp"; then
                echo -e "${YELLOW}Removing firewall rule for port $port...${NC}"
                ufw delete allow ${port}/tcp 2>/dev/null
            fi
        done
    fi
    
    echo -e "\n${GREEN}✅ MTProxy has been completely removed!${NC}"
    echo -e "${CYAN}All files, containers, and configurations have been deleted.${NC}"
    
    exit 0
fi

# Check for update-tag option
if [[ "$1" == "update-tag" ]]; then
    update_tag
    exit 0
fi

# Check for help or invalid arguments
if [[ "$1" == "help" || "$1" == "-h" || "$1" == "--help" ]]; then
    echo -e "${BLUE}MTProxy Docker Installation Script${NC}\n"
    echo "Usage:"
    echo -e "  ${GREEN}$0 install${NC}      - Install MTProxy with Docker"
    echo -e "  ${GREEN}$0 uninstall${NC}    - Completely remove MTProxy and all files"
    echo -e "  ${GREEN}$0 update-tag${NC}   - Update TAG from @MTProxybot for channel branding"
    echo -e "  ${GREEN}$0 help${NC}         - Show this help message"
    echo ""
    echo -e "${CYAN}After installation:${NC}"
    echo -e "  • Use 'mtproxy' command to manage the service"
    echo -e "  • Get TAG from @MTProxybot to enable channel promotion"
    echo -e "  • Run '$0 update-tag' to add/update your TAG"
    exit 0
fi

if [[ -n "$1" && "$1" != "install" ]]; then
    echo -e "${RED}Error: Unknown argument '$1'${NC}"
    echo -e "Use '${GREEN}$0 help${NC}' for usage information."
    exit 1
fi

# Get user input
DEFAULT_PORT=443
echo -e "${YELLOW}📡 Port Configuration:${NC}"
echo -e "${CYAN}MTProxy will listen on a port for incoming connections.${NC}"
echo -e "${CYAN}Default is 443 (HTTPS port), but you can use any free port.${NC}"
echo -e "${CYAN}Examples: 443, 8443, 9443${NC}"
echo ""
read -p "Enter proxy port (default: $DEFAULT_PORT): " USER_PORT
PORT=${USER_PORT:-$DEFAULT_PORT}

echo -e "\n${YELLOW}Installing MTProxy with Docker...${NC}"

# Check if Docker is installed
if ! command -v docker &> /dev/null; then
    echo -e "${RED}Docker is not installed!${NC}"
    echo -e "${YELLOW}Installing Docker...${NC}"
    
    # Install Docker
    if command -v apt >/dev/null 2>&1; then
        apt update -qq
        apt install -y docker.io docker-compose
        systemctl start docker
        systemctl enable docker
        echo -e "${GREEN}Docker installed successfully!${NC}"
    else
        echo -e "${RED}apt not found. Please install Docker manually:${NC}"
        echo -e "${CYAN}https://docs.docker.com/engine/install/${NC}"
        exit 1
    fi
fi

# Check if docker-compose is installed
if ! command -v docker-compose &> /dev/null; then
    echo -e "${YELLOW}Installing docker-compose...${NC}"
    if command -v apt >/dev/null 2>&1; then
        apt install -y docker-compose
    else
        echo -e "${RED}Please install docker-compose manually.${NC}"
        exit 1
    fi
fi

# Check if xxd is available (needed for secret generation)
if ! command -v xxd &> /dev/null; then
    echo -e "${YELLOW}Installing xxd utility...${NC}"
    if command -v apt >/dev/null 2>&1; then
        apt install -y xxd || apt install -y vim-common
    fi
fi

# Generate SECRET
echo -e "${YELLOW}Generating SECRET...${NC}"
SECRET=$(generate_secret)
echo -e "${GREEN}Generated SECRET: $SECRET${NC}"

# Get external IP (IPv4 only)
echo -e "${YELLOW}Getting external IPv4 address...${NC}"
EXTERNAL_IP=""
for service in "ipv4.icanhazip.com" "ipv4.ident.me" "ifconfig.me/ip" "api.ipify.org"; do
    if EXTERNAL_IP=$(curl -4 -s --connect-timeout 10 "$service" 2>/dev/null) && [[ -n "$EXTERNAL_IP" ]]; then
        if [[ $EXTERNAL_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            IFS='.' read -ra ADDR <<< "$EXTERNAL_IP"
            valid=true
            for i in "${ADDR[@]}"; do
                if [[ $i -gt 255 || $i -lt 0 ]]; then
                    valid=false
                    break
                fi
            done
            if [[ $valid == true ]]; then
                break
            fi
        fi
    fi
    EXTERNAL_IP=""
done

if [[ -z "$EXTERNAL_IP" ]]; then
    EXTERNAL_IP="YOUR_SERVER_IP"
    echo -e "${RED}Failed to detect external IPv4 address${NC}"
    echo -e "${YELLOW}Please manually check your IPv4 with: curl -4 ifconfig.me${NC}"
else
    echo -e "${GREEN}Detected external IPv4: $EXTERNAL_IP${NC}"
fi

# TAG Information
echo -e "\n${YELLOW}🏷️  TAG Configuration (Optional):${NC}"
echo -e "${CYAN}TAG is used for channel branding/promotion.${NC}"
echo -e "${CYAN}To get your TAG:${NC}"
echo -e "${CYAN}  1. Open Telegram and find @MTProxybot${NC}"
echo -e "${CYAN}  2. Send /newproxy command${NC}"
echo -e "${CYAN}  3. Register your proxy with the bot${NC}"
echo -e "${CYAN}  4. Bot will provide you with a TAG (32 hex characters)${NC}"
echo ""
echo -e "${YELLOW}You can add TAG later using: $0 update-tag${NC}"
echo ""
read -p "Enter TAG from @MTProxybot (leave empty to skip): " USER_TAG

# Create installation directory
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR" || exit 1

# Stop existing container if running
docker-compose down 2>/dev/null || true

# Create .env file
cat > "$ENV_FILE" << EOL
SECRET=$SECRET
PORT=$PORT
EOL

# Add TAG if provided
if [[ -n "$USER_TAG" ]]; then
    if [[ "$USER_TAG" =~ ^[0-9a-fA-F]{32}$ ]]; then
        echo "TAG=$USER_TAG" >> "$ENV_FILE"
        echo -e "${GREEN}TAG added to configuration.${NC}"
    else
        echo -e "${YELLOW}Invalid TAG format (should be 32 hex characters). Skipping TAG.${NC}"
    fi
fi

# Create docker-compose.yml
cat > "$COMPOSE_FILE" << 'EOL'
version: '3.8'

services:
  mtproto-proxy:
    image: telegrammessenger/proxy:latest
    container_name: mtproto-proxy
    restart: always
    ports:
      - "${PORT}:443"
    environment:
      SECRET: "${SECRET}"
      TAG: "${TAG}"
    volumes:
      - proxy-config:/data
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

volumes:
  proxy-config:
EOL

echo -e "${GREEN}Docker Compose configuration created.${NC}"

# Configure firewall
if command -v ufw &> /dev/null; then
    if ufw status | grep -q "Status: active"; then
        ufw allow $PORT/tcp
        echo -e "${GREEN}UFW: Opened port $PORT/tcp${NC}"
    fi
fi

# Start Docker containers
echo -e "${YELLOW}Starting MTProxy container...${NC}"
docker-compose up -d

# Wait for container to start
sleep 3

# Check if container is running
if docker ps | grep -q "mtproto-proxy"; then
    echo -e "${GREEN}✅ MTProxy container is running!${NC}"
else
    echo -e "${RED}❌ Failed to start MTProxy container${NC}"
    docker-compose logs
    exit 1
fi

# Generate connection links
PROXY_LINK="tg://proxy?server=$EXTERNAL_IP&port=$PORT&secret=$SECRET"

# Save information
cat > "$INFO_FILE" << EOL
MTProxy Docker Configuration
============================
Installation Date: $(date)
Installation Path: $INSTALL_DIR

Connection Details:
------------------
Server IP: $EXTERNAL_IP
Port: $PORT
Secret: $SECRET

Connection Link:
---------------
$PROXY_LINK

Web Browser Link:
----------------
https://t.me/proxy?server=$EXTERNAL_IP&port=$PORT&secret=$SECRET

TAG Configuration:
-----------------
EOL

if [[ -n "$USER_TAG" ]]; then
    echo "TAG: $USER_TAG (configured)" >> "$INFO_FILE"
    echo "Channel branding is ENABLED" >> "$INFO_FILE"
else
    echo "TAG: Not configured" >> "$INFO_FILE"
    echo "Channel branding is DISABLED" >> "$INFO_FILE"
    echo "" >> "$INFO_FILE"
    echo "To enable channel branding:" >> "$INFO_FILE"
    echo "1. Get TAG from @MTProxybot" >> "$INFO_FILE"
    echo "2. Run: $0 update-tag" >> "$INFO_FILE"
fi

cat >> "$INFO_FILE" << EOL

Management Commands:
-------------------
View logs:      docker-compose -f $COMPOSE_FILE logs -f
Restart:        docker-compose -f $COMPOSE_FILE restart
Stop:           docker-compose -f $COMPOSE_FILE down
Start:          docker-compose -f $COMPOSE_FILE up -d
Update TAG:     $0 update-tag
Uninstall:      $0 uninstall

Or use the mtproxy utility:
mtproxy status      - Show status and links
mtproxy logs        - View container logs
mtproxy restart     - Restart container
mtproxy update-tag  - Update TAG
mtproxy help        - Show all commands

Docker Container:
----------------
Container name: mtproto-proxy
Image: telegrammessenger/proxy:latest

Last Updated: $(date)
EOL

# Create management utility
echo -e "${YELLOW}Creating management utility...${NC}"

cat > "/usr/local/bin/mtproxy" << 'UTILITY_EOF'
#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

INSTALL_DIR="/opt/MTProxy"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
ENV_FILE="$INSTALL_DIR/.env"
INFO_FILE="$INSTALL_DIR/info.txt"

show_help() {
    echo -e "${BLUE}MTProxy Management Utility${NC}\n"
    echo "Usage: mtproxy [command]"
    echo ""
    echo "Commands:"
    echo -e "  ${GREEN}status${NC}      - Show service status and connection links"
    echo -e "  ${GREEN}start${NC}       - Start MTProxy container"
    echo -e "  ${GREEN}stop${NC}        - Stop MTProxy container"
    echo -e "  ${GREEN}restart${NC}     - Restart MTProxy container"
    echo -e "  ${GREEN}logs${NC}        - Show container logs"
    echo -e "  ${GREEN}update-tag${NC}  - Update TAG from @MTProxybot"
    echo -e "  ${GREEN}info${NC}        - Show detailed configuration"
    echo -e "  ${GREEN}help${NC}        - Show this help"
}

get_config() {
    if [[ -f "$ENV_FILE" ]]; then
        SECRET=$(grep "^SECRET=" "$ENV_FILE" | cut -d'=' -f2)
        PORT=$(grep "^PORT=" "$ENV_FILE" | cut -d'=' -f2)
        TAG=$(grep "^TAG=" "$ENV_FILE" | cut -d'=' -f2)
    fi
}

get_external_ip() {
    for service in "ipv4.icanhazip.com" "ipv4.ident.me" "ifconfig.me/ip"; do
        if EXTERNAL_IP=$(curl -4 -s --connect-timeout 5 "$service" 2>/dev/null) && [[ -n "$EXTERNAL_IP" ]]; then
            if [[ $EXTERNAL_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                echo "$EXTERNAL_IP"
                return
            fi
        fi
    done
    echo "YOUR_SERVER_IP"
}

show_status() {
    echo -e "${BLUE}=== MTProxy Status ===${NC}\n"
    
    if docker ps | grep -q "mtproto-proxy"; then
        echo -e "${GREEN}✅ Container: Running${NC}"
    else
        echo -e "${RED}❌ Container: Stopped${NC}"
        return 1
    fi
    
    get_config
    EXTERNAL_IP=$(get_external_ip)
    
    echo -e "${YELLOW}📊 Configuration:${NC}"
    echo -e "   Server IP: ${GREEN}${EXTERNAL_IP}${NC}"
    echo -e "   Port: ${GREEN}${PORT:-unknown}${NC}"
    echo -e "   Secret: ${GREEN}${SECRET:-unknown}${NC}"
    
    if [[ -n "$TAG" ]]; then
        echo -e "   TAG: ${GREEN}${TAG} (branding enabled)${NC}"
    else
        echo -e "   TAG: ${YELLOW}Not configured (branding disabled)${NC}"
    fi
    
    if [[ -n "$SECRET" && -n "$PORT" ]]; then
        PROXY_LINK="tg://proxy?server=$EXTERNAL_IP&port=$PORT&secret=$SECRET"
        WEB_LINK="https://t.me/proxy?server=$EXTERNAL_IP&port=$PORT&secret=$SECRET"
        
        echo -e "\n${YELLOW}🔗 Connection Links:${NC}"
        echo -e "${GREEN}Telegram:${NC} $PROXY_LINK"
        echo -e "${GREEN}Web:${NC}      $WEB_LINK"
    fi
}

show_info() {
    echo -e "${BLUE}=== MTProxy Detailed Information ===${NC}\n"
    
    show_status
    
    if [[ -f "$INFO_FILE" ]]; then
        echo -e "\n${YELLOW}📄 Configuration File:${NC}"
        cat "$INFO_FILE"
    fi
}

update_tag() {
    echo -e "${YELLOW}🏷️  Update TAG from @MTProxybot${NC}\n"
    
    if [[ ! -f "$ENV_FILE" ]]; then
        echo -e "${RED}MTProxy not installed. Please install first.${NC}"
        exit 1
    fi
    
    echo -e "${CYAN}To get your TAG:${NC}"
    echo -e "1. Open Telegram and find @MTProxybot"
    echo -e "2. Send /newproxy command"
    echo -e "3. Register your proxy with the bot"
    echo -e "4. Bot will provide you with a TAG (32 hex characters)"
    echo ""
    
    read -p "Enter TAG from @MTProxybot (leave empty to remove TAG): " NEW_TAG
    
    if [[ -n "$NEW_TAG" ]]; then
        if [[ ! "$NEW_TAG" =~ ^[0-9a-fA-F]{32}$ ]]; then
            echo -e "${RED}Invalid TAG format. TAG should be 32 hexadecimal characters.${NC}"
            exit 1
        fi
        
        if grep -q "^TAG=" "$ENV_FILE"; then
            sed -i "s/^TAG=.*/TAG=$NEW_TAG/" "$ENV_FILE"
        else
            echo "TAG=$NEW_TAG" >> "$ENV_FILE"
        fi
        echo -e "${GREEN}✅ TAG updated successfully!${NC}"
    else
        sed -i '/^TAG=/d' "$ENV_FILE"
        echo -e "${YELLOW}TAG removed. No channel will be promoted.${NC}"
    fi
    
    echo -e "${YELLOW}Restarting container...${NC}"
    cd "$INSTALL_DIR"
    docker-compose down
    docker-compose up -d
    
    echo -e "${GREEN}✅ MTProxy restarted with new configuration!${NC}"
}

case "${1:-status}" in
    "start")
        echo -e "${YELLOW}Starting MTProxy container...${NC}"
        cd "$INSTALL_DIR"
        docker-compose up -d
        sleep 2
        if docker ps | grep -q "mtproto-proxy"; then
            echo -e "${GREEN}✅ Container started successfully${NC}"
            show_status
        else
            echo -e "${RED}❌ Failed to start container${NC}"
            exit 1
        fi
        ;;
    "stop")
        echo -e "${YELLOW}Stopping MTProxy container...${NC}"
        cd "$INSTALL_DIR"
        docker-compose down
        echo -e "${GREEN}✅ Container stopped${NC}"
        ;;
    "restart")
        echo -e "${YELLOW}Restarting MTProxy container...${NC}"
        cd "$INSTALL_DIR"
        docker-compose restart
        sleep 2
        if docker ps | grep -q "mtproto-proxy"; then
            echo -e "${GREEN}✅ Container restarted successfully${NC}"
            show_status
        else
            echo -e "${RED}❌ Failed to restart container${NC}"
            exit 1
        fi
        ;;
    "status")
        show_status
        ;;
    "logs")
        echo -e "${YELLOW}Showing MTProxy logs (Ctrl+C to exit):${NC}"
        cd "$INSTALL_DIR"
        docker-compose logs -f
        ;;
    "info")
        show_info
        ;;
    "update-tag")
        update_tag
        ;;
    "help"|"-h"|"--help")
        show_help
        ;;
    *)
        echo -e "${RED}Unknown command: $1${NC}"
        show_help
        exit 1
        ;;
esac
UTILITY_EOF

chmod +x "/usr/local/bin/mtproxy"

echo -e "\n${GREEN}✅ Installation Complete!${NC}"
echo -e "\n${CYAN}📋 Quick Commands:${NC}"
echo -e "${GREEN}mtproxy${NC}             - Show status and links"
echo -e "${GREEN}mtproxy restart${NC}     - Restart container"
echo -e "${GREEN}mtproxy logs${NC}        - Show container logs"
echo -e "${GREEN}mtproxy update-tag${NC}  - Update TAG from @MTProxybot"
echo -e "${GREEN}mtproxy help${NC}        - Show all commands"

echo -e "\n${YELLOW}📢 TAG Configuration:${NC}"
if [[ -n "$USER_TAG" ]]; then
    echo -e "${GREEN}TAG is configured. Channel branding is enabled.${NC}"
else
    echo -e "${CYAN}To enable channel branding:${NC}"
    echo -e "${CYAN}1. Get TAG from @MTProxybot (send /newproxy)${NC}"
    echo -e "${CYAN}2. Run: $0 update-tag${NC}"
fi

echo -e "\n${BLUE}📄 Configuration saved to: ${GREEN}$INFO_FILE${NC}"
echo -e "${BLUE}🔧 Management utility: ${GREEN}/usr/local/bin/mtproxy${NC}"
echo -e "${BLUE}🐳 Docker container: ${GREEN}mtproto-proxy${NC}"

echo -e "\n${YELLOW}💡 Connection Link:${NC}"
PROXY_LINK="tg://proxy?server=$EXTERNAL_IP&port=$PORT&secret=$SECRET"
echo -e "${GREEN}$PROXY_LINK${NC}"

echo -e "\n${YELLOW}🌐 Web Link:${NC}"
WEB_LINK="https://t.me/proxy?server=$EXTERNAL_IP&port=$PORT&secret=$SECRET"
echo -e "${GREEN}$WEB_LINK${NC}"

echo -e "\n${YELLOW}💡 To uninstall:${NC}"
echo -e "${GREEN}$0 uninstall${NC}"
