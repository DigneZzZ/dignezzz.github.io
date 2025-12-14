#!/bin/bash

# ==============================
# Fail2Ban SSH + Web Services
# ==============================
# This script installs and configures Fail2Ban with dynamic ban times.
# It automatically detects and secures SSH, plus offers optional support
# for Nginx/Caddy (and easily extensible for other services).
# A helper tool 'f2b' is placed in /usr/local/bin for easy management.
# ==============================

# === COLORS ===
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
NC='\033[0m'

F2B_HELPER="/usr/local/bin/f2b"
JAIL_LOCAL="/etc/fail2ban/jail.local"
JAIL_D_DIR="/etc/fail2ban/jail.d"

# ===============
# PRINT HEADER
# ===============
print_header() {
  echo -e "${BLUE}========================================${NC}"
  echo -e "${GREEN}Fail2Ban Security Installer${NC}"
  echo -e "${BLUE}========================================${NC}"
}

# ===============
# CHECK ROOT
# ===============
check_root() {
  if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run this script as root (sudo).${NC}"
    exit 1
  fi
}

# ===============
# INSTALL FAIL2BAN
# ===============
install_fail2ban() {
  if ! command -v fail2ban-server &>/dev/null; then
    echo -e "${YELLOW}Installing Fail2ban...${NC}"
    apt update && apt install -y fail2ban || { echo -e "${RED}Failed to install fail2ban${NC}"; exit 1; }
  else
    echo -e "${GREEN}Fail2Ban is already installed.${NC}"
  fi
}

# ===============
# DETECT SSH PORT
# ===============
detect_ssh_port() {
  local port=$(grep -Po '(?<=^Port )\d+' /etc/ssh/sshd_config | head -n1)
  echo "${port:-22}"
}

# ===============
# BACKUP AND CONFIGURE FAIL2BAN (SSH)
# ===============
configure_ssh_fail2ban() {
  # Dynamic ban settings + SSH config in jail.local
  cp -f "$JAIL_LOCAL" "${JAIL_LOCAL}.bak_$(date +%Y%m%d_%H%M%S)" 2>/dev/null
  local ssh_port="$1"

  cat > "$JAIL_LOCAL" <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8
bantime.increment = true
bantime.factor = 2
bantime.formula = ban.Time * (1<<(ban.Count if ban.Count<20 else 20)) * banFactor
bantime.maxtime = 1w
findtime = 10m
maxretry = 3
backend = systemd

[sshd]
enabled = true
port = $ssh_port
filter = sshd
logpath = /var/log/auth.log
EOF

  echo -e "${GREEN}Configured Fail2Ban for SSH on port $ssh_port.${NC}"
}

# ===============
# SERVICE DETECTION
# ===============
detect_service() {
  local svc="$1"  # 'nginx' or 'caddy'
  command -v "$svc" &>/dev/null && return 0 || return 1
}

# ===============
# CREATE JAIL CONFIG FOR NGINX/CADDY
# ===============
create_jail_config() {
  local name="$1"       # short name: 'nginx', 'caddy'
  local filter="$2"     # fail2ban filter (e.g. 'nginx-http-auth' or 'caddy'
  local logfile="$3"    # log path
  local jail_file="$JAIL_D_DIR/${name}.conf"

  mkdir -p "$JAIL_D_DIR"
  echo -e "${YELLOW}Creating jail config for $name...${NC}"

  cat > "$jail_file" <<EOF
[$name]
enabled = true
port = http,https
filter = $filter
logpath = $logfile
maxretry = 5
EOF
  echo -e "${GREEN}Jail config created: $jail_file${NC}"
}

# ===============
# PROMPT SERVICES
# ===============
prompt_services() {
  local ssh_port="$1"

  echo -e "${CYAN}Detected installed services:${NC}"
  local found_any=false

  if detect_service "nginx"; then
    found_any=true
    echo -e "  ${GREEN}[NGINX]${NC}"
  fi
  if detect_service "caddy"; then
    found_any=true
    echo -e "  ${GREEN}[CADDY]${NC}"
  fi

  if [ "$found_any" = false ]; then
    echo -e "${RED}No additional (NGINX/Caddy) services detected.${NC}"
    return
  fi

  echo -e "${YELLOW}Do you want to enable Fail2Ban for these services? (y/n) [default: y]${NC}"
  read -r enable_web
  enable_web=${enable_web:-y}
  if [[ "$enable_web" =~ ^[Yy]$ ]]; then
    if detect_service "nginx"; then
      create_jail_config "nginx" "nginx-http-auth" "/var/log/nginx/access.log"
    fi
    if detect_service "caddy"; then
      # caddy logs typically at /var/log/caddy/access.log or /var/log/syslog
      # adjust as needed
      create_jail_config "caddy" "caddy" "/var/log/syslog"
    fi
  else
    echo -e "${RED}Skipping web service jails.${NC}"
  fi
}

# ===============
# ALLOW FIREWALL PORT
# ===============
allow_firewall_port() {
  local port="$1"
  if command -v ufw >/dev/null; then
    ufw allow "$port"/tcp || true
    echo -e "${YELLOW}UFW: Allowed port $port.${NC}"
  fi
}

# ===============
# RESTART FAIL2BAN
# ===============
restart_fail2ban() {
  systemctl restart fail2ban
  sleep 1
  if systemctl is-active --quiet fail2ban; then
    echo -e "${GREEN}Fail2Ban service is running.${NC}"
  else
    echo -e "${RED}Fail2Ban failed to start. Check the config!${NC}"
    fail2ban-client -d
    exit 1
  fi
}

# ===============
# CREATE/UPDATE F2B HELPER
# ===============
create_f2b_helper() {
  mkdir -p "$(dirname "$F2B_HELPER")"
  cat > "$F2B_HELPER" <<'EOF'
#!/bin/bash
JAIL_D_DIR="/etc/fail2ban/jail.d"

function usage() {
  echo "Fail2Ban Helper (f2b)"
  echo "Usage:" >&2
  echo "  f2b status         - Show systemd status for fail2ban" >&2
  echo "  f2b restart        - Restart fail2ban service" >&2
  echo "  f2b list           - Show jail status (sshd, caddy, nginx, etc.)" >&2
  echo "  f2b banned         - Show banned IPs for all jails" >&2
  echo "  f2b log            - Tail fail2ban log" >&2
  echo "  f2b add <service>  - Enable fail2ban for a known service (nginx, caddy)" >&2
  echo "  f2b remove <service> - Disable fail2ban for a service" >&2
  echo "  f2b help           - Show this help" >&2
}

function add_service() {
  service="$1"
  case "$service" in
    nginx)
      cat > "$JAIL_D_DIR/nginx.conf" <<CFG
[nginx]
enabled = true
port = http,https
filter = nginx-http-auth
logpath = /var/log/nginx/access.log
maxretry = 5
CFG
      echo "Nginx jail added.";;
    caddy)
      cat > "$JAIL_D_DIR/caddy.conf" <<CFG
[caddy]
enabled = true
port = http,https
filter = caddy
logpath = /var/log/syslog
maxretry = 5
CFG
      echo "Caddy jail added.";;
    *)
      echo "Service '$service' is not recognized." >&2
      exit 1;;
  esac
  systemctl restart fail2ban
}

function remove_service() {
  service="$1"
  case "$service" in
    nginx|caddy)
      rm -f "$JAIL_D_DIR/${service}.conf"
      echo "Removed jail for '$service'.";;
    *)
      echo "Service '$service' is not recognized." >&2
      exit 1;;
  esac
  systemctl restart fail2ban
}

case "$1" in
  status)
    systemctl status fail2ban
    ;;
  restart)
    systemctl restart fail2ban && echo "Fail2ban restarted."
    ;;
  list)
    fail2ban-client status
    ;;
  banned)
    for jail in $(fail2ban-client status | sed -n '/Jail list/,/Server/p' | grep -oE '[a-z]+' | sort | uniq); do
      echo "===== $jail ====="
      fail2ban-client status $jail | grep 'Banned IP list'
    done
    ;;
  log)
    tail -n 50 /var/log/fail2ban.log
    ;;
  add)
    add_service "$2"
    ;;
  remove)
    remove_service "$2"
    ;;
  help|*)
    usage
    ;;
esac
EOF
  chmod +x "$F2B_HELPER"
  echo -e "${GREEN}Helper command created/updated: ${CYAN}f2b${NC}"
}

# ===============
# UNINSTALL F2B HELPER
# ===============
uninstall_f2b_helper() {
  if [ -f "$F2B_HELPER" ]; then
    rm -f "$F2B_HELPER"
    echo -e "${YELLOW}Removed f2b helper: $F2B_HELPER${NC}"
  else
    echo -e "${RED}No helper found at $F2B_HELPER${NC}"
  fi
}

# ===============
# MAIN
# ===============
case "$1" in
  uninstall-helper)
    check_root
    uninstall_f2b_helper
    exit 0
    ;;
  install-helper)
    check_root
    create_f2b_helper
    exit 0
    ;;
esac

print_header
check_root
install_fail2ban

SSH_PORT="$(detect_ssh_port)"
configure_ssh_fail2ban "$SSH_PORT"

prompt_services "$SSH_PORT"

restart_fail2ban
allow_firewall_port "$SSH_PORT"

create_f2b_helper

echo -e "\n${BLUE}You can now use 'f2b' command to manage fail2ban easily:${NC}"
echo -e "  ${CYAN}f2b status${NC}     - Show systemd status"
echo -e "  ${CYAN}f2b list${NC}       - Show all jails"
echo -e "  ${CYAN}f2b banned${NC}     - Show banned IPs by jail"
echo -e "  ${CYAN}f2b log${NC}        - Tail fail2ban log"
echo -e "  ${CYAN}f2b add <srv>${NC}  - Add jail (nginx, caddy)"
echo -e "  ${CYAN}f2b remove <srv>${NC} - Remove jail"
echo -e "  ${CYAN}f2b restart${NC}    - Restart fail2ban"
echo -e "  ${CYAN}f2b help${NC}       - Show help"

echo -e "${GREEN}Fail2ban security is now active. SSH + optional web services are protected!${NC}\n"
