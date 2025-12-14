#!/bin/bash

# MTProxy Final Installation Script (Fixed)
# Creates systemd service with custom port, saves secrets to info.txt
# and creates management utility in /usr/local/bin/mtproxy
#
# Usage:
#   ./mt-fixed.sh          - Install MTProxy
#   ./mt-fixed.sh uninstall - Remove MTProxy completely

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BLUE}MTProxy Installation (Fixed)${NC}\n"

# Require root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}This installer must be run as root (use sudo).${NC}"
    exit 1
fi

# Check for uninstall option
if [[ "$1" == "uninstall" ]]; then
    echo -e "${YELLOW}🗑️  MTProxy Uninstallation${NC}\n"
    
    echo -e "${RED}WARNING: This will completely remove MTProxy and all related files!${NC}"
    echo -e "${YELLOW}The following will be deleted:${NC}"
    echo -e "  • Service: /etc/systemd/system/mtproxy.service"
    echo -e "  • Installation directory: /opt/MTProxy"
    echo -e "  • Management utility: /usr/local/bin/mtproxy"
    echo -e "  • All configuration files and secrets"
    echo ""
    
    read -p "Are you sure you want to continue? (type 'YES' to confirm): " CONFIRM
    
    if [[ "$CONFIRM" != "YES" ]]; then
        echo -e "${GREEN}Uninstallation cancelled.${NC}"
        exit 0
    fi
    
    echo -e "\n${YELLOW}Removing MTProxy...${NC}"
    
    # Stop and disable service
    if systemctl is-active --quiet mtproxy; then
        echo -e "${YELLOW}Stopping MTProxy service...${NC}"
        systemctl stop mtproxy
    fi
    
    if systemctl is-enabled --quiet mtproxy 2>/dev/null; then
        echo -e "${YELLOW}Disabling MTProxy service...${NC}"
        systemctl disable mtproxy
    fi
    
    # Remove service file
    if [[ -f "/etc/systemd/system/mtproxy.service" ]]; then
        echo -e "${YELLOW}Removing service file...${NC}"
        rm -f "/etc/systemd/system/mtproxy.service"
        systemctl daemon-reload
    fi
    
    # Remove installation directory
    if [[ -d "/opt/MTProxy" ]]; then
        echo -e "${YELLOW}Removing installation directory...${NC}"
        rm -rf "/opt/MTProxy"
    fi
    
    # Remove management utility
    if [[ -f "/usr/local/bin/mtproxy" ]]; then
        echo -e "${YELLOW}Removing management utility...${NC}"
        rm -f "/usr/local/bin/mtproxy"
    fi
    
    # Remove firewall rule (if UFW is active)
    if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
        echo -e "${YELLOW}Checking firewall rules...${NC}"
        # Try to remove common MTProxy ports
        for port in 8080 8443 9443 1080 3128; do
            if ufw status | grep -q "${port}/tcp"; then
                echo -e "${YELLOW}Removing firewall rule for port $port...${NC}"
                ufw delete allow ${port}/tcp 2>/dev/null
            fi
        done
    fi
    
    echo -e "\n${GREEN}✅ MTProxy has been completely removed!${NC}"
    echo -e "${CYAN}All files, services, and configurations have been deleted.${NC}"
    echo -e "${YELLOW}Note: You may need to manually remove any custom firewall rules.${NC}"
    
    exit 0
fi

# Check for help or invalid arguments
if [[ "$1" == "help" || "$1" == "-h" || "$1" == "--help" ]]; then
    echo -e "${BLUE}MTProxy Installation Script${NC}\n"
    echo "Usage:"
    echo -e "  ${GREEN}$0${NC}              - Install MTProxy with interactive setup"
    echo -e "  ${GREEN}$0 uninstall${NC}    - Completely remove MTProxy and all files"
    echo -e "  ${GREEN}$0 help${NC}         - Show this help message"
    echo ""
    echo "After installation, use 'mtproxy' command to manage the service."
    exit 0
fi

if [[ -n "$1" && "$1" != "install" ]]; then
    echo -e "${RED}Error: Unknown argument '$1'${NC}"
    echo -e "Use '${GREEN}$0 help${NC}' for usage information."
    exit 1
fi

# Configuration
INSTALL_DIR="/opt/MTProxy"
SERVICE_NAME="mtproxy"
DEFAULT_PORT=9443
DEFAULT_CHANNEL="vsemvpn_com"

# Get user input
read -p "Enter proxy port (default: $DEFAULT_PORT): " USER_PORT
PORT=${USER_PORT:-$DEFAULT_PORT}

echo -e "\n${YELLOW}📢 Channel Promotion Setup:${NC}"
echo -e "${CYAN}You can promote your Telegram channel to users connecting through your proxy.${NC}"
echo -e "${CYAN}Options:${NC}"
echo -e "${CYAN}  1. Set default channel now (works immediately)${NC}"
echo -e "${CYAN}  2. Configure later via @MTProxybot (after registration, higher priority)${NC}"
echo ""
read -p "Enter channel/bot username to promote (default: $DEFAULT_CHANNEL, leave empty for none): " USER_CHANNEL
CHANNEL_TAG=${USER_CHANNEL:-$DEFAULT_CHANNEL}

if [[ "$CHANNEL_TAG" == "$DEFAULT_CHANNEL" ]]; then
    echo -e "${CYAN}Using default channel @$CHANNEL_TAG. You can override this via @MTProxybot later.${NC}"
elif [[ -z "$CHANNEL_TAG" ]]; then
    CHANNEL_TAG=""
    echo -e "${CYAN}No default channel set. Configure promotion via @MTProxybot after registration.${NC}"
else
    echo -e "${CYAN}Using channel @$CHANNEL_TAG. You can change this via @MTProxybot later.${NC}"
fi

echo -e "\n${YELLOW}Installing MTProxy native service...${NC}"

# Install dependencies
echo -e "${YELLOW}Installing dependencies...${NC}"
if command -v apt >/dev/null 2>&1; then
    apt update -qq
    # Ensure xxd is available (on some systems it is provided by vim-common)
    apt install -y git curl python3 python3-pip xxd || apt install -y vim-common
else
    echo -e "${RED}apt not found. This script currently supports Debian/Ubuntu (apt).${NC}"
    echo -e "${YELLOW}Install dependencies manually: git curl python3 python3-pip xxd (or vim-common).${NC}"
    exit 1
fi

# Create installation directory
mkdir -p $INSTALL_DIR
cd $INSTALL_DIR

# Stop existing service if running
systemctl stop mtproxy 2>/dev/null

# Download Python MTProxy
echo -e "${YELLOW}Installing Python MTProxy...${NC}"
if curl -s -L "https://raw.githubusercontent.com/alexbers/mtprotoproxy/master/mtprotoproxy.py" -o mtprotoproxy.py; then
    chmod +x mtprotoproxy.py
    echo -e "${GREEN}Successfully downloaded Python MTProxy${NC}"
else
    echo -e "${RED}Failed to download MTProxy${NC}"
    exit 1
fi

# Generate user secret (or use existing one)
if [[ -f "/opt/MTProxy/info.txt" ]] && grep -q "Base Secret:" /opt/MTProxy/info.txt; then
    USER_SECRET=$(grep "Base Secret:" /opt/MTProxy/info.txt | awk '{print $3}')
    echo -e "${GREEN}Using existing secret: $USER_SECRET${NC}"
else
    USER_SECRET=$(head -c 16 /dev/urandom | xxd -ps)
    echo -e "${GREEN}Generated new secret: $USER_SECRET${NC}"
fi

# Get external IP (IPv4 only)
echo -e "${YELLOW}Getting external IPv4 address...${NC}"
EXTERNAL_IP=""
for service in "ipv4.icanhazip.com" "ipv4.ident.me" "ifconfig.me/ip" "api.ipify.org"; do
    if EXTERNAL_IP=$(curl -4 -s --connect-timeout 10 "$service" 2>/dev/null) && [[ -n "$EXTERNAL_IP" ]]; then
        # Check if it's a valid IPv4 address
        if [[ $EXTERNAL_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            # Additional validation for IPv4 ranges
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

# Ask for domain (optional)
echo -e "\n${YELLOW}🌐 Domain Setup (Optional):${NC}"
echo -e "${CYAN}You can use a domain name instead of IP address for better user experience.${NC}"
echo -e "${CYAN}Examples: proxy.example.com, vpn.mydomain.org${NC}"
echo -e "${CYAN}Leave empty to use IP address: $EXTERNAL_IP${NC}"
echo ""
read -p "Enter domain name (optional): " USER_DOMAIN

if [[ -n "$USER_DOMAIN" ]]; then
    # Validate domain format (basic check)
    if [[ $USER_DOMAIN =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        PROXY_HOST="$USER_DOMAIN"
        echo -e "${GREEN}Using domain: $PROXY_HOST${NC}"
        echo -e "${YELLOW}Checking DNS for domain...${NC}"
        DOMAIN_IP=$(getent ahostsv4 "$PROXY_HOST" 2>/dev/null | awk '/STREAM/ {print $1; exit}')
        if [[ -n "$DOMAIN_IP" && -n "$EXTERNAL_IP" && "$DOMAIN_IP" != "$EXTERNAL_IP" ]]; then
            echo -e "${YELLOW}Warning:${NC} DNS ($PROXY_HOST -> ${DOMAIN_IP}) doesn't match detected external IP (${EXTERNAL_IP})."
            echo -e "${YELLOW}Make sure your domain A-record points to ${EXTERNAL_IP}.${NC}"
        else
            echo -e "${GREEN}DNS looks ok.${NC}"
        fi
    else
        echo -e "${RED}Invalid domain format. Using IP address instead.${NC}"
        PROXY_HOST="$EXTERNAL_IP"
    fi
else
    PROXY_HOST="$EXTERNAL_IP"
    echo -e "${GREEN}Using IP address: $PROXY_HOST${NC}"
fi

# TLS Domain setup for better security
echo -e "\n${YELLOW}🔒 TLS Domain Setup:${NC}"
echo -e "${CYAN}MTProxy uses a domain for TLS certificate masking to avoid detection.${NC}"
echo -e "${CYAN}Using random existing domains is more secure than default google.com${NC}"
echo -e "${CYAN}Examples: github.com, cloudflare.com, microsoft.com, amazon.com${NC}"
echo ""

# List of good TLS domains
TLS_DOMAINS=("github.com" "cloudflare.com" "microsoft.com" "amazon.com" "yahoo.com" "wikipedia.org" "stackoverflow.com" "reddit.com")
RANDOM_DOMAIN=${TLS_DOMAINS[$RANDOM % ${#TLS_DOMAINS[@]}]}

read -p "Enter TLS domain for masking (default: $RANDOM_DOMAIN): " USER_TLS_DOMAIN
TLS_DOMAIN=${USER_TLS_DOMAIN:-$RANDOM_DOMAIN}

echo -e "${GREEN}Using TLS domain: $TLS_DOMAIN${NC}"

# Create initial info.txt with setup details (persist chosen host)
mkdir -p $INSTALL_DIR
cat > "$INSTALL_DIR/info.txt" << EOL
MTProxy Setup Information
========================
Setup Date: $(date)
Selected Port: $PORT
Selected Channel: @$CHANNEL_TAG
External IPv4: $EXTERNAL_IP
Proxy Host: $PROXY_HOST
TLS Domain: $TLS_DOMAIN
Registration Secret (32 hex, for @MTProxybot): $USER_SECRET
Status: Installing...
EOL

# Create systemd service
echo -e "${YELLOW}Creating systemd service...${NC}"
cat > "/etc/systemd/system/$SERVICE_NAME.service" << EOL
[Unit]
Description=MTProxy Telegram Proxy (Python)
After=network.target
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=python3 $INSTALL_DIR/mtprotoproxy.py $PORT $USER_SECRET
Environment=TAG=$CHANNEL_TAG
Environment=TLS_DOMAIN=$TLS_DOMAIN
Environment=MASK_HOST=$TLS_DOMAIN
Environment=FAKE_TLS_DOMAIN=$TLS_DOMAIN
Environment=USERS_FILE=$INSTALL_DIR/users.txt
Restart=always
RestartSec=10
StartLimitBurst=3
StartLimitIntervalSec=60
KillMode=mixed
KillSignal=SIGTERM
TimeoutStopSec=30

# Resource limits for stability
LimitNOFILE=65536
LimitNPROC=4096

# Security settings
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$INSTALL_DIR
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOL

# Set permissions
chown -R root:root $INSTALL_DIR
chmod +x $INSTALL_DIR/mtprotoproxy.py

# Configure firewall
if command -v ufw &> /dev/null; then
    if ufw status | grep -q "Status: active"; then
        ufw allow $PORT/tcp
        echo -e "${GREEN}UFW: Opened port $PORT/tcp${NC}"
    fi
fi

# Create management utility - first create temporary file
echo -e "${YELLOW}Creating management utility...${NC}"

cat > "/tmp/mtproxy_utility" << 'UTILITY_EOF'
#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

INSTALL_DIR="/opt/MTProxy"
SERVICE_NAME="mtproxy"

# Function to convert domain to hex for TLS link
domain_to_hex() {
    local domain="$1"
    echo -n "$domain" | xxd -p | tr -d '\n'
}

show_help() {
    echo -e "${BLUE}MTProxy Management Utility${NC}\n"
    echo "Usage: mtproxy [command]"
    echo ""
    echo "Commands:"
    echo -e "  ${GREEN}status${NC}    - Show service status and connection links"
    echo -e "  ${GREEN}start${NC}     - Start MTProxy service"
    echo -e "  ${GREEN}stop${NC}      - Stop MTProxy service"
    echo -e "  ${GREEN}restart${NC}   - Restart MTProxy service"
    echo -e "  ${GREEN}logs${NC}      - Show service logs"
    echo -e "  ${GREEN}links${NC}     - Show connection links only"
    echo -e "  ${GREEN}info${NC}      - Show detailed configuration"
    echo -e "  ${GREEN}test${NC}      - Test proxy connectivity"
    echo -e "  ${GREEN}help${NC}      - Show this help"
}

get_service_config() {
    if [[ -f "/etc/systemd/system/$SERVICE_NAME.service" ]]; then
        EXEC_START=$(grep "ExecStart=" "/etc/systemd/system/$SERVICE_NAME.service" | cut -d'=' -f2-)
        PORT=$(echo "$EXEC_START" | awk '{print $(NF-1)}')
        SECRET=$(echo "$EXEC_START" | awk '{print $NF}')
        # Get promoted channel from environment
        PROMOTED_CHANNEL=$(grep "Environment=TAG=" "/etc/systemd/system/$SERVICE_NAME.service" | cut -d'=' -f3)
    fi
}

get_links() {
    if systemctl is-active --quiet $SERVICE_NAME; then
        # Get recent logs and extract full proxy URLs
        LOGS=$(journalctl -u $SERVICE_NAME --no-pager -n 20 --since "5 minutes ago")
        
    # Extract the full tg://proxy URLs from logs with IPv4 addresses only
    ANY_LINK=$(echo "$LOGS" | grep -o "tg://proxy[^[:space:]]*secret=[^[:space:]]*" | grep -E "server=[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}" | tail -1)
    DD_LINK=$(echo "$LOGS" | grep -o "tg://proxy[^[:space:]]*secret=dd[^[:space:]]*" | grep -E "server=[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}" | tail -1)
    EE_LINK=$(echo "$LOGS" | grep -o "tg://proxy[^[:space:]]*secret=ee[^[:space:]]*" | grep -E "server=[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}" | tail -1)
        
        # If no recent IPv4 links found, check all logs for IPv4 only
        if [[ -z "$DD_LINK" || -z "$EE_LINK" ]]; then
            LOGS=$(journalctl -u $SERVICE_NAME --no-pager -n 50)
            ANY_LINK=$(echo "$LOGS" | grep -o "tg://proxy[^[:space:]]*secret=[^[:space:]]*" | grep -E "server=[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}" | tail -1)
            DD_LINK=$(echo "$LOGS" | grep -o "tg://proxy[^[:space:]]*secret=dd[^[:space:]]*" | grep -E "server=[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}" | tail -1)
            EE_LINK=$(echo "$LOGS" | grep -o "tg://proxy[^[:space:]]*secret=ee[^[:space:]]*" | grep -E "server=[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}" | tail -1)
        fi
        
        # If still no IPv4 links found, generate them manually
        if [[ -z "$ANY_LINK" || -z "$EE_LINK" ]]; then
            get_service_config
            if [[ -n "$PORT" && -n "$SECRET" ]]; then
                # Get external IPv4 or use domain from info.txt
                PROXY_HOST=""
                
                # Try to get host from existing info.txt
                if [[ -f "$INSTALL_DIR/info.txt" ]]; then
                    PROXY_HOST=$(grep "Proxy Host:" "$INSTALL_DIR/info.txt" 2>/dev/null | awk '{print $3}')
                fi
                
                # If no host found, detect IPv4 only
                if [[ -z "$PROXY_HOST" ]]; then
                    for service in "ipv4.icanhazip.com" "ipv4.ident.me" "ifconfig.me/ip" "api.ipify.org"; do
                        if DETECTED_IP=$(curl -4 -s --connect-timeout 5 "$service" 2>/dev/null) && [[ -n "$DETECTED_IP" ]]; then
                            # Check if it's a valid IPv4 address
                            if [[ $DETECTED_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                                # Additional validation for IPv4 ranges
                                IFS='.' read -ra ADDR <<< "$DETECTED_IP"
                                valid=true
                                for i in "${ADDR[@]}"; do
                                    if [[ $i -gt 255 || $i -lt 0 ]]; then
                                        valid=false
                                        break
                                    fi
                                done
                                if [[ $valid == true ]]; then
                                    PROXY_HOST="$DETECTED_IP"
                                    break
                                fi
                            fi
                        fi
                    done
                fi
                
                # Fallback
                if [[ -z "$PROXY_HOST" ]]; then
                    PROXY_HOST="YOUR_SERVER_IP"
                fi
                
                # Get TLS domain from service config or use default
                if [[ -z "$TLS_DOMAIN" ]]; then
                    TLS_DOMAIN=$(grep "Environment=TLS_DOMAIN=" /etc/systemd/system/mtproxy.service 2>/dev/null | cut -d'=' -f3)
                    [[ -z "$TLS_DOMAIN" ]] && TLS_DOMAIN="github.com"
                fi
                
                # Convert TLS domain to hex
                TLS_DOMAIN_HEX=$(domain_to_hex "$TLS_DOMAIN")
                
                # Generate links: plain (no prefix), dd and ee
                PLAIN_LINK="tg://proxy?server=$PROXY_HOST&port=$PORT&secret=${SECRET}"
                DD_LINK="tg://proxy?server=$PROXY_HOST&port=$PORT&secret=dd${SECRET}"
                EE_LINK="tg://proxy?server=$PROXY_HOST&port=$PORT&secret=ee${SECRET}${TLS_DOMAIN_HEX}"
            fi
        fi

        # Always regenerate all links using the current SECRET from service config
        # This ensures consistency between Plain/DD/EE links
        get_service_config
        if [[ -n "$PORT" && -n "$SECRET" ]]; then
            # Determine host from existing links or fallback detection
            PROXY_HOST=""
            LINK_SRC="${ANY_LINK:-${DD_LINK:-$EE_LINK}}"
            if [[ -n "$LINK_SRC" ]]; then
                PROXY_HOST=$(echo "$LINK_SRC" | sed -E 's/.*server=([^&]+).*/\1/')
            fi
            
            # Fallback to info.txt or IP detection
            if [[ -z "$PROXY_HOST" ]]; then
                if [[ -f "$INSTALL_DIR/info.txt" ]]; then
                    PROXY_HOST=$(grep "Proxy Host:" "$INSTALL_DIR/info.txt" 2>/dev/null | awk '{print $3}')
                fi
                if [[ -z "$PROXY_HOST" ]]; then
                    for service in "ipv4.icanhazip.com" "ipv4.ident.me"; do
                        if DETECTED_IP=$(curl -4 -s --connect-timeout 3 "$service" 2>/dev/null) && [[ $DETECTED_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                            PROXY_HOST="$DETECTED_IP"
                            break
                        fi
                    done
                fi
            fi
            
            if [[ -n "$PROXY_HOST" ]]; then
                # Get TLS domain
                TLS_DOMAIN=$(grep "Environment=TLS_DOMAIN=" /etc/systemd/system/mtproxy.service 2>/dev/null | cut -d'=' -f3)
                [[ -z "$TLS_DOMAIN" ]] && TLS_DOMAIN="github.com"
                TLS_DOMAIN_HEX=$(domain_to_hex "$TLS_DOMAIN")
                
                # Generate consistent links with current SECRET
                PLAIN_LINK="tg://proxy?server=$PROXY_HOST&port=$PORT&secret=${SECRET}"
                DD_LINK="tg://proxy?server=$PROXY_HOST&port=$PORT&secret=dd${SECRET}"
                EE_LINK="tg://proxy?server=$PROXY_HOST&port=$PORT&secret=ee${SECRET}${TLS_DOMAIN_HEX}"
            fi
        fi
    fi
}

show_status() {
    echo -e "${BLUE}=== MTProxy Status ===${NC}\n"
    
    if systemctl is-active --quiet $SERVICE_NAME; then
        echo -e "${GREEN}✅ Service: Running${NC}"
    else
        echo -e "${RED}❌ Service: Stopped${NC}"
        return 1
    fi
    
    get_service_config
    echo -e "${YELLOW}📊 Configuration:${NC}"
    echo -e "   Port: ${GREEN}${PORT:-unknown}${NC}"
    echo -e "   Secret: ${GREEN}${SECRET:-unknown}${NC}"
    echo -e "   Registration Secret (plain for @MTProxybot): ${GREEN}${SECRET:-unknown}${NC}"
    echo -e "   Promoted Channel: ${GREEN}@${PROMOTED_CHANNEL:-unknown}${NC}"
    
    # Show proxy host from info.txt if available
    if [[ -f "$INSTALL_DIR/info.txt" ]]; then
        PROXY_HOST=$(grep "Proxy Host:" "$INSTALL_DIR/info.txt" 2>/dev/null | awk '{print $3}')
        [[ -n "$PROXY_HOST" && "$PROXY_HOST" != "unknown" ]] && echo -e "   Proxy Host: ${GREEN}$PROXY_HOST${NC}"
    fi
    
    get_links
    if [[ -n "$ANY_LINK" || -n "$PLAIN_LINK" || -n "$DD_LINK" || -n "$EE_LINK" ]]; then
        echo -e "\n${YELLOW}🔗 Connection Links:${NC}"
        [[ -n "$PLAIN_LINK" ]] && echo -e "${GREEN}Plain (for @MTProxybot):${NC} $PLAIN_LINK"
        [[ -n "$DD_LINK" ]] && echo -e "${GREEN}DD (legacy clients):${NC} $DD_LINK"
        [[ -n "$EE_LINK" ]] && echo -e "${GREEN}TLS:${NC}      $EE_LINK"
        
        echo -e "\n${YELLOW}🌐 Web Links:${NC}"
        [[ -n "$PLAIN_LINK" ]] && echo -e "${GREEN}Plain:${NC} $(echo "$PLAIN_LINK" | sed 's/tg:/https:\/\/t.me/')"
        [[ -n "$DD_LINK" ]] && echo -e "${GREEN}DD:${NC} $(echo "$DD_LINK" | sed 's/tg:/https:\/\/t.me/')"
        [[ -n "$EE_LINK" ]] && echo -e "${GREEN}TLS:${NC}      $(echo "$EE_LINK" | sed 's/tg:/https:\/\/t.me/')"
    else
        echo -e "\n${RED}❌ No links available${NC}"
    fi
}

show_links() {
    get_links
    if [[ -n "$PLAIN_LINK" || -n "$DD_LINK" || -n "$EE_LINK" ]]; then
        echo -e "${YELLOW}🔗 MTProxy Connection Links:${NC}"
        [[ -n "$PLAIN_LINK" ]] && echo "$PLAIN_LINK"
        [[ -n "$DD_LINK" ]] && echo "$DD_LINK"
        [[ -n "$EE_LINK" ]] && echo "$EE_LINK"
    else
        echo -e "${RED}❌ No active links found. Is service running?${NC}"
        return 1
    fi
}

show_info() {
    echo -e "${BLUE}=== MTProxy Detailed Information ===${NC}\n"
    
    # Service status
    show_status
    
    # Show info file if exists
    if [[ -f "$INSTALL_DIR/info.txt" ]]; then
        echo -e "\n${YELLOW}📄 Configuration File:${NC}"
        cat "$INSTALL_DIR/info.txt"
    fi
    
    echo -e "\n${YELLOW}🛠️  Management Commands:${NC}"
    echo -e "${GREEN}mtproxy status${NC}    - Show status and links"
    echo -e "${GREEN}mtproxy restart${NC}   - Restart service"
    echo -e "${GREEN}mtproxy logs${NC}      - View logs"
}

update_info_file() {
    get_service_config
    get_links
    
    # Determine the proxy host from links or detect it
    PROXY_HOST=""
    if [[ -n "$PLAIN_LINK" ]]; then
        PROXY_HOST=$(echo "$PLAIN_LINK" | sed -E 's/.*server=([^&]+).*/\1/')
    elif [[ -n "$DD_LINK" ]]; then
        PROXY_HOST=$(echo "$DD_LINK" | sed -E 's/.*server=([^&]+).*/\1/')
    elif [[ -n "$ANY_LINK" ]]; then
        PROXY_HOST=$(echo "$ANY_LINK" | sed -E 's/.*server=([^&]+).*/\1/')
    else
        # Try to detect IPv4 if no links available
        for service in "ipv4.icanhazip.com" "ipv4.ident.me" "ifconfig.me/ip" "api.ipify.org"; do
            if DETECTED_IP=$(curl -4 -s --connect-timeout 5 "$service" 2>/dev/null) && [[ -n "$DETECTED_IP" ]]; then
                if [[ $DETECTED_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                    IFS='.' read -ra ADDR <<< "$DETECTED_IP"
                    valid=true
                    for i in "${ADDR[@]}"; do
                        if [[ $i -gt 255 || $i -lt 0 ]]; then
                            valid=false
                            break
                        fi
                    done
                    if [[ $valid == true ]]; then
                        PROXY_HOST="$DETECTED_IP"
                        break
                    fi
                fi
            fi
        done
    fi
    
    mkdir -p "$INSTALL_DIR"
    cat > "$INSTALL_DIR/info.txt" << EOL
MTProxy Final Configuration
==========================
Installation Date: $(date)
Installation Path: $INSTALL_DIR
Service Name: $SERVICE_NAME
Proxy Type: Python MTProxy

Connection Details:
------------------
Proxy Host: ${PROXY_HOST:-unknown}
External IP: ${EXTERNAL_IP:-unknown}
Port: ${PORT:-unknown}
Base Secret: ${SECRET:-unknown}
Registration Secret (plain, for @MTProxybot): ${SECRET:-unknown}
Promoted Channel: @${PROMOTED_CHANNEL:-${CHANNEL_TAG:-unknown}}

Working Connection Links:
------------------------
Plain Link (for registration): ${PLAIN_LINK:-Not available}
DD Link: ${DD_LINK:-Not available}
TLS Link: ${EE_LINK:-Not available}

Web Browser Links:
-----------------
Plain: $(echo "${PLAIN_LINK:-Not available}" | sed 's/tg:/https:\/\/t.me/')
DD: $(echo "${DD_LINK:-Not available}" | sed 's/tg:/https:\/\/t.me/')
TLS: $(echo "${EE_LINK:-Not available}" | sed 's/tg:/https:\/\/t.me/')

Service Management:
------------------
Status:  mtproxy status
Start:   mtproxy start
Stop:    mtproxy stop
Restart: mtproxy restart
Logs:    mtproxy logs
Info:    mtproxy info

IMPORTANT: Секреты сохраняются при перезапуске!
Last Updated: $(date)
EOL
}

# Main command handler
case "${1:-status}" in
    "start")
        echo -e "${YELLOW}Starting MTProxy service...${NC}"
        systemctl start $SERVICE_NAME
        sleep 2
        if systemctl is-active --quiet $SERVICE_NAME; then
            echo -e "${GREEN}✅ Service started successfully${NC}"
            update_info_file
            show_links
        else
            echo -e "${RED}❌ Failed to start service${NC}"
            exit 1
        fi
        ;;
    "stop")
        echo -e "${YELLOW}Stopping MTProxy service...${NC}"
        systemctl stop $SERVICE_NAME
        echo -e "${GREEN}✅ Service stopped${NC}"
        ;;
    "restart")
        echo -e "${YELLOW}Restarting MTProxy service...${NC}"
        systemctl restart $SERVICE_NAME
        sleep 2
        if systemctl is-active --quiet $SERVICE_NAME; then
            echo -e "${GREEN}✅ Service restarted successfully${NC}"
            update_info_file
            show_links
        else
            echo -e "${RED}❌ Failed to restart service${NC}"
            exit 1
        fi
        ;;
    "status")
        show_status
        update_info_file
        ;;
    "links")
        show_links
        ;;
    "logs")
        echo -e "${YELLOW}Showing MTProxy logs (Ctrl+C to exit):${NC}"
        journalctl -u $SERVICE_NAME -f
        ;;
    "info")
        show_info
        ;;
    "test")
        echo -e "${YELLOW}Testing MTProxy connectivity...${NC}"
        get_service_config
        if [[ -n "$PORT" ]]; then
            echo -e "Testing port $PORT connectivity..."
            if command -v nc >/dev/null 2>&1; then
                if timeout 5 nc -z localhost "$PORT" 2>/dev/null; then
                    echo -e "${GREEN}✅ Port $PORT is open locally${NC}"
                else
                    echo -e "${RED}❌ Port $PORT is not accessible locally${NC}"
                fi
            elif command -v telnet >/dev/null 2>&1; then
                if timeout 5 bash -c "echo | telnet localhost $PORT" 2>/dev/null | grep -q "Connected"; then
                    echo -e "${GREEN}✅ Port $PORT is open locally${NC}"
                else
                    echo -e "${RED}❌ Port $PORT is not accessible locally${NC}"
                fi
            else
                echo -e "${YELLOW}⚠️  nc/telnet not available for port testing${NC}"
            fi
            
            # Check if service is actually listening
            if ss -tlnp 2>/dev/null | grep -q ":$PORT "; then
                echo -e "${GREEN}✅ Service is listening on port $PORT${NC}"
            else
                echo -e "${RED}❌ No service listening on port $PORT${NC}"
            fi
            
            # Check logs for errors
            RECENT_ERRORS=$(journalctl -u mtproxy --no-pager -n 10 --since "10 minutes ago" | grep -i "error\|fail\|exception" | tail -3)
            if [[ -n "$RECENT_ERRORS" ]]; then
                echo -e "${RED}Recent errors in logs:${NC}"
                echo "$RECENT_ERRORS"
            else
                echo -e "${GREEN}✅ No recent errors in logs${NC}"
            fi
        else
            echo -e "${RED}❌ Cannot determine port from service config${NC}"
        fi
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

# Move the utility to final location and set permissions
mv "/tmp/mtproxy_utility" "/usr/local/bin/mtproxy"
chmod +x "/usr/local/bin/mtproxy"

# Reload and start service
systemctl daemon-reload
systemctl enable $SERVICE_NAME
systemctl start $SERVICE_NAME

sleep 3

# Check service status and create info file
if systemctl is-active --quiet $SERVICE_NAME; then
    echo -e "${GREEN}✅ MTProxy service is running!${NC}"
    
    # Update info file using the management utility
    /usr/local/bin/mtproxy status
    
    echo -e "\n${YELLOW}🎉 Installation Complete!${NC}"
    echo -e "\n${CYAN}📋 Quick Commands:${NC}"
    echo -e "${GREEN}mtproxy${NC}         - Show status and links"
    echo -e "${GREEN}mtproxy restart${NC} - Restart service"
    echo -e "${GREEN}mtproxy links${NC}   - Show connection links"
    echo -e "${GREEN}mtproxy help${NC}    - Show all commands"
    
    echo -e "\n${YELLOW}📢 Promoted Channel: ${GREEN}@$CHANNEL_TAG${NC}"
    echo -e "${CYAN}Users connecting through your proxy will see this channel promoted.${NC}"
    
else
    echo -e "${RED}❌ Service failed to start${NC}"
    systemctl status $SERVICE_NAME --no-pager
    exit 1
fi

echo -e "\n${BLUE}📄 Configuration saved to: ${GREEN}$INSTALL_DIR/info.txt${NC}"
echo -e "${BLUE}🔧 Management utility: ${GREEN}/usr/local/bin/mtproxy${NC}"
echo -e "${BLUE}🔄 Service will auto-start on boot${NC}"
echo -e "\n${YELLOW}💡 To completely remove MTProxy later:${NC}"
echo -e "${GREEN}$0 uninstall${NC}"
