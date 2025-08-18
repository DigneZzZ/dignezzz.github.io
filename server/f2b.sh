#!/bin/bash

# Версия скрипта
SCRIPT_VERSION="2.2.1"
VERSION_CHECK_URL="https://raw.githubusercontent.com/DigneZzZ/dignezzz.github.io/main/server/f2b.sh"

# Цвета
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
PURPLE='\033[1;35m'
WHITE='\033[1;37m'
NC='\033[0m'

# Определяем путь установки
INSTALL_PATH="/usr/local/bin/f2b"

# Если скрипт запущен как f2b с аргументами - обрабатываем как helper команды
if [[ "$(basename "$0")" == "f2b" ]] && [[ $# -gt 0 ]]; then
  case "$1" in
    status)
      systemctl status fail2ban
      exit 0
      ;;
    restart)
      systemctl restart fail2ban && echo "Fail2ban restarted."
      exit 0
      ;;
    list)
      if [ -n "$2" ]; then
        fail2ban-client status "$2"
      else
        fail2ban-client status
      fi
      exit 0
      ;;
    banned)
      if [ -n "$2" ]; then
        fail2ban-client status "$2" | grep 'Banned IP list' || echo "No bans recorded for $2."
      else
        echo "All banned IPs:"
        jails=$(fail2ban-client status | grep "Jail list:" | cut -d: -f2 | tr -d ' 	')
        for jail in ${jails//,/ }; do
          banned=$(fail2ban-client status "$jail" | grep 'Banned IP list:' | cut -d: -f2)
          if [ -n "$banned" ] && [ "$banned" != " " ]; then
            echo "[$jail]: $banned"
          fi
        done
      fi
      exit 0
      ;;
    unban)
      if [ -n "$2" ]; then
        if [ -n "$3" ]; then
          # Unban from specific jail
          fail2ban-client set "$3" unbanip "$2" && echo "IP $2 unbanned from $3."
        else
          # Unban from all jails
          jails=$(fail2ban-client status | grep "Jail list:" | cut -d: -f2 | tr -d ' 	')
          for jail in ${jails//,/ }; do
            fail2ban-client set "$jail" unbanip "$2" 2>/dev/null && echo "IP $2 unbanned from $jail."
          done
        fi
      else
        echo "Usage: f2b unban <IP_ADDRESS> [jail_name]"
      fi
      exit 0
      ;;
    unban-all)
      if [ -n "$2" ]; then
        # Unban all from specific jail
        banned_ips=$(fail2ban-client status "$2" | grep "Banned IP list:" | cut -d: -f2)
        if [ -n "$banned_ips" ]; then
          for ip in $banned_ips; do
            fail2ban-client set "$2" unbanip "$ip" 2>/dev/null
          done
          echo "All IPs unbanned from $2."
        else
          echo "No IPs to unban from $2."
        fi
      else
        fail2ban-client unban --all && echo "All IPs unbanned from all jails."
      fi
      exit 0
      ;;
    log)
      if [ -n "$2" ]; then
        grep "\[$2\]" /var/log/fail2ban.log | tail -20
      else
        tail -n 50 /var/log/fail2ban.log
      fi
      exit 0
      ;;
    recent)
      echo "Recent bans (last 10):"
      if [ -f /var/log/fail2ban.log ]; then
        grep "Ban " /var/log/fail2ban.log | tail -10 | while read line; do
          DATE=$(echo "$line" | awk '{print $1, $2}')
          IP=$(echo "$line" | grep -o '[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}')
          JAIL=$(echo "$line" | grep -o '\[.*\]' | tr -d '[]')
          echo "$DATE - $IP ($JAIL)"
        done
      else
        echo "No fail2ban log found"
      fi
      exit 0
      ;;
    stop)
      systemctl stop fail2ban && echo "Fail2ban stopped."
      exit 0
      ;;
    start)
      systemctl start fail2ban && echo "Fail2ban started."
      exit 0
      ;;
    enable)
      if [ -n "$2" ]; then
        echo "Use the main interactive menu to enable jails: f2b"
      else
        echo "Usage: f2b enable <jail_name>"
      fi
      exit 0
      ;;
    disable)
      if [ -n "$2" ]; then
        fail2ban-client stop "$2" && echo "Jail $2 disabled."
      else
        echo "Usage: f2b disable <jail_name>"
      fi
      exit 0
      ;;
    check-ports)
      CURRENT_SSH_PORT=$(grep -Po '(?<=^Port )\d+' /etc/ssh/sshd_config | head -n1)
      CURRENT_SSH_PORT=${CURRENT_SSH_PORT:-22}
      F2B_SSH_PORT=""
      if [ -f "/etc/fail2ban/jail.local" ]; then
        F2B_SSH_PORT=$(grep -A 10 "\[sshd\]" /etc/fail2ban/jail.local | grep "^port" | cut -d'=' -f2 | tr -d ' ')
      fi
      echo "Current SSH port: $CURRENT_SSH_PORT"
      echo "Fail2ban SSH port: ${F2B_SSH_PORT:-"not configured"}"
      if [ -n "$F2B_SSH_PORT" ] && [ "$CURRENT_SSH_PORT" != "$F2B_SSH_PORT" ]; then
        echo "WARNING: Port mismatch detected!"
      else
        echo "SSH ports are consistent"
      fi
      exit 0
      ;;
    stats)
      echo "Fail2ban Statistics:"
      echo "==================="
      jails=$(fail2ban-client status | grep "Jail list:" | cut -d: -f2 | tr -d ' 	')
      for jail in ${jails//,/ }; do
        status=$(fail2ban-client status "$jail")
        currently_failed=$(echo "$status" | grep "Currently failed:" | cut -d: -f2 | tr -d ' ')
        total_failed=$(echo "$status" | grep "Total failed:" | cut -d: -f2 | tr -d ' ')
        currently_banned=$(echo "$status" | grep "Currently banned:" | cut -d: -f2 | tr -d ' ')
        total_banned=$(echo "$status" | grep "Total banned:" | cut -d: -f2 | tr -d ' ')
        echo "[$jail] Failed: ${currently_failed}/${total_failed} | Banned: ${currently_banned}/${total_banned}"
      done
      exit 0
      ;;
    help)
      echo "Fail2ban Helper (f2b) - Version $SCRIPT_VERSION"
      echo "Usage:"
      echo "  f2b status                    - Show Fail2ban system status"
      echo "  f2b restart                   - Restart Fail2ban"
      echo "  f2b start                     - Start Fail2ban"
      echo "  f2b stop                      - Stop Fail2ban"
      echo "  f2b list [jail]               - Show jail status and stats"
      echo "  f2b banned [jail]             - Show banned IPs (all or specific jail)"
      echo "  f2b unban <IP> [jail]         - Unban IP from all jails or specific jail"
      echo "  f2b unban-all [jail]          - Unban all IPs from all or specific jail"
      echo "  f2b enable <jail>             - Enable specific jail"
      echo "  f2b disable <jail>            - Disable specific jail"
      echo "  f2b recent                    - Show recent bans"
      echo "  f2b check-ports               - Check SSH port consistency"
      echo "  f2b log [jail]                - Show fail2ban log (all or specific jail)"
      echo "  f2b stats                     - Show statistics for all jails"
      echo "  f2b help                      - Show this help"
      echo ""
      echo "Interactive menu:"
      echo "  f2b                           - Launch full interactive menu"
      echo ""
      echo "Examples:"
      echo "  f2b banned                    - Show all banned IPs"
      echo "  f2b banned sshd               - Show banned IPs for SSH"
      echo "  f2b unban 1.2.3.4             - Unban IP from all jails"
      echo "  f2b unban 1.2.3.4 nginx      - Unban IP from nginx jail only"
      echo "  f2b log nginx                 - Show nginx jail logs"
      exit 0
      ;;
  esac
fi

function print_header() {
  clear
  echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
  echo -e "    Fail2Ban SSH Security Manager     "
  echo -e "            Version: $SCRIPT_VERSION            "
  echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
  echo ""
}

function check_version() {
  echo -e "${YELLOW}Checking for updates...${NC}"
  if command -v curl &>/dev/null; then
    LATEST_VERSION=$(curl -s "$VERSION_CHECK_URL" | grep -o 'SCRIPT_VERSION="[0-9.]*"' | cut -d'"' -f2)
    if [ -n "$LATEST_VERSION" ] && [ "$LATEST_VERSION" != "$SCRIPT_VERSION" ]; then
      echo -e "${GREEN}New version available: $LATEST_VERSION${NC}"
      echo -e "${YELLOW}Current version: $SCRIPT_VERSION${NC}"
      echo -e "${CYAN}Download: $VERSION_CHECK_URL${NC}"
      echo ""
      return 1
    else
      echo -e "${GREEN}You have the latest version${NC}"
      echo ""
    fi
  else
    echo -e "${RED}curl not available, can't check for updates${NC}"
    echo ""
  fi
  return 0
}

function check_root() {
  if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run this script as root.${NC}"
    exit 1
  fi
}

function show_statistics() {
  echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║${WHITE}                    FAIL2BAN STATISTICS                      ${BLUE}║${NC}"
  echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  
  # Автоматическая проверка версии при запуске
  check_version > /dev/null 2>&1
  
  # Проверка статуса сервиса
  if systemctl is-active --quiet fail2ban; then
    echo -e "${GREEN}✓ Fail2ban Service: ACTIVE${NC}"
  else
    echo -e "${RED}✗ Fail2ban Service: INACTIVE${NC}"
    echo ""
    return 1
  fi
  
  # Проверка SSH портов
  check_ssh_port_consistency_quiet
  echo ""
  
  # Получение статистики jail'ов по категориям
  if command -v fail2ban-client &>/dev/null; then
    local jails=$(fail2ban-client status 2>/dev/null | grep "Jail list:" | cut -d: -f2 | tr -d ' 	')
    
    if [ -n "$jails" ]; then
      # SSH Services
      local ssh_services_found=false
      for jail in ${jails//,/ }; do
        if [[ "$jail" =~ ^(sshd|ssh)$ ]]; then
          if [ "$ssh_services_found" = false ]; then
            echo -e "${PURPLE}📡 SSH Services:${NC}"
            ssh_services_found=true
          fi
          show_jail_stats "$jail" "  "
        fi
      done
      
      # Web Services  
      local web_services_found=false
      for jail in ${jails//,/ }; do
        if [[ "$jail" =~ ^(nginx|caddy|phpmyadmin).*$ ]]; then
          if [ "$web_services_found" = false ]; then
            echo -e "${PURPLE}🌐 Web Services:${NC}"
            web_services_found=true
          fi
          show_jail_stats "$jail" "  "
        fi
      done
      
      # Database Services
      local db_services_found=false
      for jail in ${jails//,/ }; do
        if [[ "$jail" =~ ^(mysql|mariadb).*$ ]]; then
          if [ "$db_services_found" = false ]; then
            echo -e "${PURPLE}🗄️ Database Services:${NC}"
            db_services_found=true
          fi
          show_jail_stats "$jail" "  "
        fi
      done
      
      # Other Services
      local other_services_found=false
      for jail in ${jails//,/ }; do
        if ! [[ "$jail" =~ ^(sshd|ssh|nginx|apache|caddy|httpd|wordpress|phpmyadmin|roundcube|postfix|dovecot|exim|sendmail|mysql|mariadb|postgresql|mongo|vsftpd|proftpd|pureftpd|ftp).*$ ]]; then
          if [ "$other_services_found" = false ]; then
            echo -e "${PURPLE}🔧 Other Services:${NC}"
            other_services_found=true
          fi
          show_jail_stats "$jail" "  "
        fi
      done
    else
      echo -e "${YELLOW}No active jails found${NC}"
    fi
    echo ""
    
    # Последние баны
    echo -e "${CYAN}📋 Recent Bans (last 5):${NC}"
    if [ -f "/var/log/fail2ban.log" ]; then
      local recent_bans=$(grep "Ban " /var/log/fail2ban.log | tail -5)
      if [ -n "$recent_bans" ]; then
        echo "$recent_bans" | while read -r line; do
          local timestamp=$(echo "$line" | cut -d' ' -f1-2)
          local ip=$(echo "$line" | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+')
          local jail=$(echo "$line" | grep -o '\[.*\]' | tr -d '[]')
          echo -e "  ${RED}$timestamp${NC} - IP: ${YELLOW}$ip${NC} (${CYAN}$jail${NC})"
        done
      else
        echo -e "  ${GREEN}No recent bans found${NC}"
      fi
    else
      echo -e "  ${RED}Fail2ban log not found${NC}"
    fi
  else
    echo -e "${RED}✗ fail2ban-client not available${NC}"
  fi
  echo ""
}

function show_jail_stats() {
  local jail="$1"
  local indent="$2"
  local status=$(fail2ban-client status "$jail" 2>/dev/null)
  if [ $? -eq 0 ]; then
    local currently_failed=$(echo "$status" | grep "Currently failed:" | cut -d: -f2 | tr -d ' ')
    local total_failed=$(echo "$status" | grep "Total failed:" | cut -d: -f2 | tr -d ' ')
    local currently_banned=$(echo "$status" | grep "Currently banned:" | cut -d: -f2 | tr -d ' ')
    local total_banned=$(echo "$status" | grep "Total banned:" | cut -d: -f2 | tr -d ' ')
    
    local status_color="${GREEN}"
    if [ "${currently_banned:-0}" -gt 0 ]; then
      status_color="${RED}"
    elif [ "${currently_failed:-0}" -gt 0 ]; then
      status_color="${YELLOW}"
    fi
    
    echo -e "${indent}${status_color}[$jail]${NC} Failed: ${currently_failed:-0}/${total_failed:-0} | Banned: ${currently_banned:-0}/${total_banned:-0}"
  fi
}

function check_ssh_port_consistency_quiet() {
  # Тихая проверка портов SSH для статистики
  local current_ssh_port=$(grep -Po '(?<=^Port )\d+' /etc/ssh/sshd_config | head -n1)
  current_ssh_port=${current_ssh_port:-22}
  
  local f2b_ssh_port=""
  if [ -f "/etc/fail2ban/jail.local" ]; then
    f2b_ssh_port=$(grep -A 10 "\[sshd\]" /etc/fail2ban/jail.local | grep "^port" | cut -d'=' -f2 | tr -d ' ')
  fi
  
  if [ -n "$f2b_ssh_port" ] && [ "$current_ssh_port" != "$f2b_ssh_port" ]; then
    echo -e "${RED}⚠️  SSH Port Mismatch: SSH($current_ssh_port) vs F2B($f2b_ssh_port)${NC}"
  else
    echo -e "${GREEN}✓ SSH Port: $current_ssh_port${NC}"
  fi
}

function show_recent_bans() {
  echo -e "${YELLOW}Recent bans (last 10):${NC}"
  echo -e "${CYAN}─────────────────────────────${NC}"
  
  if [ -f /var/log/fail2ban.log ]; then
    grep "Ban " /var/log/fail2ban.log | tail -10 | while read line; do
      DATE=$(echo "$line" | awk '{print $1, $2}')
      IP=$(echo "$line" | grep -o '[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}')
      echo -e "${WHITE}$DATE${NC} - ${RED}$IP${NC}"
    done
  else
    echo -e "${RED}No fail2ban log found${NC}"
  fi
  echo ""
}

function unban_all() {
  echo -e "${YELLOW}Unbanning all IPs...${NC}"
  if systemctl is-active --quiet fail2ban; then
    fail2ban-client unban --all
    echo -e "${GREEN}All IPs have been unbanned${NC}"
  else
    echo -e "${RED}Fail2ban is not running${NC}"
  fi
}

function manage_services_menu() {
  while true; do
    print_header
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${WHITE}                   SERVICE MANAGEMENT                        ${BLUE}║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Показываем текущие активные jail'ы
    show_active_jails_summary
    
    echo -e "${CYAN} 1.${NC} SSH Protection (sshd)"
    echo -e "${CYAN} 2.${NC} Nginx Protection"
    echo -e "${CYAN} 3.${NC} Caddy Protection"
    echo -e "${CYAN} 4.${NC} MySQL/MariaDB Protection"
    echo -e "${CYAN} 5.${NC} PhpMyAdmin Protection"
    echo -e "${CYAN} 6.${NC} Custom Service Management"
    echo -e "${CYAN} 7.${NC} View All Jail Configurations"
    echo -e "${RED} 0.${NC} Back to Main Menu"
    echo ""
    echo -ne "${YELLOW}Select service [0-7]:${NC} "
    
    read -r choice
    echo ""
    
    case $choice in
      1) manage_service_jail "sshd" "SSH" ;;
      2) manage_service_jail "nginx" "Nginx Web Server" ;;
      3) manage_service_jail "caddy" "Caddy Web Server" ;;
      4) manage_service_jail "mysql" "MySQL/MariaDB Database" ;;
      5) manage_service_jail "phpmyadmin" "PhpMyAdmin" ;;
      6) custom_service_management ;;
      7) show_all_jail_configs ;;
      0) return ;;
      *) echo -e "${RED}Invalid option${NC}" ;;
    esac
    
    if [ "$choice" != "0" ]; then
      echo ""
      echo -e "${YELLOW}Press Enter to continue...${NC}"
      read -r
    fi
  done
}

function show_active_jails_summary() {
  if command -v fail2ban-client &>/dev/null && systemctl is-active --quiet fail2ban; then
    local jails=$(fail2ban-client status 2>/dev/null | grep "Jail list:" | cut -d: -f2 | tr -d ' 	')
    if [ -n "$jails" ]; then
      echo -e "${GREEN}Active Jails: ${CYAN}${jails//,/, }${NC}"
    else
      echo -e "${YELLOW}No active jails${NC}"
    fi
  else
    echo -e "${RED}Fail2ban not running${NC}"
  fi
  echo ""
}

function manage_service_jail() {
  local service="$1"
  local service_name="$2"
  
  while true; do
    print_header
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${WHITE}               $service_name PROTECTION               ${BLUE}║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Проверяем статус jail'а
    local jail_status="INACTIVE"
    local jail_color="${RED}"
    if systemctl is-active --quiet fail2ban; then
      if fail2ban-client status "$service" &>/dev/null; then
        jail_status="ACTIVE"
        jail_color="${GREEN}"
        
        # Показываем статистику
        show_jail_stats "$service" ""
        echo ""
      fi
    fi
    
    echo -e "Status: ${jail_color}$jail_status${NC}"
    echo ""
    
    echo -e "${CYAN} 1.${NC} Enable/Configure $service_name protection"
    echo -e "${CYAN} 2.${NC} Disable $service_name protection"
    echo -e "${CYAN} 3.${NC} Show banned IPs for $service_name"
    echo -e "${CYAN} 4.${NC} Unban specific IP for $service_name"
    echo -e "${CYAN} 5.${NC} Unban all IPs for $service_name"
    echo -e "${CYAN} 6.${NC} View $service_name jail configuration"
    echo -e "${CYAN} 7.${NC} View $service_name logs"
    echo -e "${RED} 0.${NC} Back"
    echo ""
    echo -ne "${YELLOW}Select option [0-7]:${NC} "
    
    read -r choice
    echo ""
    
    case $choice in
      1) enable_service_jail "$service" "$service_name" ;;
      2) disable_service_jail "$service" "$service_name" ;;
      3) show_service_banned_ips "$service" "$service_name" ;;
      4) unban_service_ip "$service" "$service_name" ;;
      5) unban_all_service_ips "$service" "$service_name" ;;
      6) show_service_config "$service" "$service_name" ;;
      7) show_service_logs "$service" "$service_name" ;;
      0) return ;;
      *) echo -e "${RED}Invalid option${NC}" ;;
    esac
    
    if [ "$choice" != "0" ]; then
      echo ""
      echo -e "${YELLOW}Press Enter to continue...${NC}"
      read -r
    fi
  done
}

function enable_service_jail() {
  local service="$1"
  local service_name="$2"
  
  echo -e "${YELLOW}Enabling $service_name protection...${NC}"
  
  # Создаем конфигурацию для сервиса
  create_service_jail_config "$service"
  
  # Перезапускаем fail2ban
  systemctl reload fail2ban 2>/dev/null || systemctl restart fail2ban
  
  # Проверяем результат
  sleep 2
  if fail2ban-client status "$service" &>/dev/null; then
    echo -e "${GREEN}✓ $service_name protection enabled${NC}"
  else
    echo -e "${RED}✗ Failed to enable $service_name protection${NC}"
  fi
}

function disable_service_jail() {
  local service="$1"
  local service_name="$2"
  
  echo -e "${YELLOW}Disabling $service_name protection...${NC}"
  
  if fail2ban-client status "$service" &>/dev/null; then
    fail2ban-client stop "$service"
    echo -e "${GREEN}✓ $service_name protection disabled${NC}"
  else
    echo -e "${YELLOW}$service_name protection was not active${NC}"
  fi
}

function show_service_banned_ips() {
  local service="$1"
  local service_name="$2"
  
  echo -e "${GREEN}Banned IPs for $service_name:${NC}"
  if fail2ban-client status "$service" &>/dev/null; then
    fail2ban-client status "$service" | grep -A 1 "Banned IP list" || echo -e "${YELLOW}No IPs banned${NC}"
  else
    echo -e "${RED}$service_name jail not active${NC}"
  fi
}

function unban_service_ip() {
  local service="$1"
  local service_name="$2"
  
  echo -ne "${CYAN}Enter IP to unban from $service_name:${NC} "
  read -r ip
  
  if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    if fail2ban-client set "$service" unbanip "$ip" 2>/dev/null; then
      echo -e "${GREEN}✓ IP $ip unbanned from $service_name${NC}"
    else
      echo -e "${RED}✗ Failed to unban IP or jail not active${NC}"
    fi
  else
    echo -e "${RED}Invalid IP format${NC}"
  fi
}

function unban_all_service_ips() {
  local service="$1"
  local service_name="$2"
  
  echo -e "${YELLOW}Unbanning all IPs from $service_name...${NC}"
  if fail2ban-client status "$service" &>/dev/null; then
    # Получаем список забаненных IP и разбаниваем каждый
    local banned_ips=$(fail2ban-client status "$service" | grep "Banned IP list:" | cut -d: -f2)
    if [ -n "$banned_ips" ]; then
      for ip in $banned_ips; do
        fail2ban-client set "$service" unbanip "$ip" 2>/dev/null
      done
      echo -e "${GREEN}✓ All IPs unbanned from $service_name${NC}"
    else
      echo -e "${YELLOW}No IPs to unban${NC}"
    fi
  else
    echo -e "${RED}$service_name jail not active${NC}"
  fi
}

function show_service_config() {
  local service="$1"
  local service_name="$2"
  
  echo -e "${GREEN}$service_name jail configuration:${NC}"
  echo -e "${CYAN}─────────────────────────────${NC}"
  
  if [ -f "/etc/fail2ban/jail.local" ]; then
    # Показываем конфигурацию конкретного jail'а
    awk "/^\[$service\]/,/^\[/{if(/^\[/ && !/^\[$service\]/) exit; print}" /etc/fail2ban/jail.local
  else
    echo -e "${RED}No jail.local configuration found${NC}"
  fi
}

function show_service_logs() {
  local service="$1"
  local service_name="$2"
  
  echo -e "${GREEN}$service_name related logs (last 20):${NC}"
  echo -e "${CYAN}─────────────────────────────${NC}"
  
  if [ -f "/var/log/fail2ban.log" ]; then
    grep "\[$service\]" /var/log/fail2ban.log | tail -20
  else
    echo -e "${RED}No fail2ban log found${NC}"
  fi
}

function create_service_jail_config() {
  local service="$1"
  local jail_local="/etc/fail2ban/jail.local"
  
  # Создаем резервную копию
  cp "$jail_local" "${jail_local}.bak_$(date +%Y%m%d_%H%M%S)" 2>/dev/null
  
  # Если файл не существует, создаем базовый
  if [ ! -f "$jail_local" ]; then
    cat > "$jail_local" <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8
bantime.increment = true
bantime.factor = 5
bantime.formula = ban.Time * (1<<(ban.Count if ban.Count<20 else 20)) * banFactor
bantime.maxtime = 1M
findtime = 10m
maxretry = 3
backend = systemd

EOF
  fi
  
  # Добавляем конфигурацию для конкретного сервиса
  case "$service" in
    "sshd")
      local ssh_port=$(grep -Po '(?<=^Port )\d+' /etc/ssh/sshd_config | head -n1)
      ssh_port=${ssh_port:-22}
      add_jail_config "$service" "enabled = true" "port = $ssh_port" "filter = sshd" "logpath = /var/log/auth.log" "maxretry = 3" "bantime = 600"
      ;;
    "nginx")
      # Nginx HTTP Auth failures
      add_jail_config "nginx-http-auth" "enabled = true" "port = http,https" "filter = nginx-http-auth" "logpath = /var/log/nginx/error.log" "maxretry = 3" "bantime = 600"
      # Nginx limit requests (too many requests)
      add_jail_config "nginx-limit-req" "enabled = true" "port = http,https" "filter = nginx-limit-req" "logpath = /var/log/nginx/error.log" "maxretry = 10" "findtime = 600" "bantime = 600"
      ;;
    "caddy")
      add_jail_config "$service" "enabled = true" "port = http,https" "filter = caddy-auth" "logpath = /var/log/caddy/caddy.log" "maxretry = 3" "bantime = 600"
      ;;
    "mysql")
      add_jail_config "mysqld-auth" "enabled = true" "port = 3306" "filter = mysqld-auth" "logpath = /var/log/mysql/error.log" "maxretry = 3" "bantime = 600"
      ;;
    "phpmyadmin")
      add_jail_config "phpmyadmin-syslog" "enabled = true" "port = http,https" "filter = phpmyadmin-syslog" "logpath = /var/log/syslog" "maxretry = 3" "bantime = 600"
      ;;
  esac
}

function add_jail_config() {
  local jail_name="$1"
  shift
  local jail_local="/etc/fail2ban/jail.local"
  
  # Удаляем существующую конфигурацию если есть
  sed -i "/^\[$jail_name\]/,/^\[/{/^\[/ {/^\[$jail_name\]/!b}; d}" "$jail_local"
  
  # Добавляем новую конфигурацию
  echo "" >> "$jail_local"
  echo "[$jail_name]" >> "$jail_local"
  for config in "$@"; do
    echo "$config" >> "$jail_local"
  done
}

function custom_service_management() {
  while true; do
    print_header
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${WHITE}                 CUSTOM SERVICE MANAGEMENT                  ${BLUE}║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    show_active_jails_summary
    
    echo -e "${CYAN} 1.${NC} Create new custom jail"
    echo -e "${CYAN} 2.${NC} Manage existing custom jail"
    echo -e "${CYAN} 3.${NC} Delete custom jail"
    echo -e "${RED} 0.${NC} Back"
    echo ""
    echo -ne "${YELLOW}Select option [0-3]:${NC} "
    
    read -r choice
    echo ""
    
    case $choice in
      1) create_custom_jail ;;
      2) manage_existing_custom_jail ;;
      3) delete_custom_jail ;;
      0) return ;;
      *) echo -e "${RED}Invalid option${NC}" ;;
    esac
    
    if [ "$choice" != "0" ]; then
      echo ""
      echo -e "${YELLOW}Press Enter to continue...${NC}"
      read -r
    fi
  done
}

function create_custom_jail() {
  echo -e "${YELLOW}Creating custom jail...${NC}"
  echo ""
  
  echo -ne "${CYAN}Enter jail name (e.g., 'my-service'):${NC} "
  read -r jail_name
  
  if [ -z "$jail_name" ]; then
    echo -e "${RED}Jail name cannot be empty${NC}"
    return 1
  fi
  
  echo -ne "${CYAN}Enter ports (e.g., '80,443' or 'ssh'):${NC} "
  read -r ports
  
  echo -ne "${CYAN}Enter filter name (e.g., 'apache-auth'):${NC} "
  read -r filter
  
  echo -ne "${CYAN}Enter log path (e.g., '/var/log/service.log'):${NC} "
  read -r logpath
  
  echo -ne "${CYAN}Enter max retry (default 3):${NC} "
  read -r maxretry
  maxretry=${maxretry:-3}
  
  echo -ne "${CYAN}Enter ban time in seconds (default 600):${NC} "
  read -r bantime
  bantime=${bantime:-600}
  
  # Создаем конфигурацию
  add_jail_config "$jail_name" \
    "enabled = true" \
    "port = $ports" \
    "filter = $filter" \
    "logpath = $logpath" \
    "maxretry = $maxretry" \
    "bantime = $bantime"
  
  # Перезапускаем fail2ban
  systemctl reload fail2ban 2>/dev/null || systemctl restart fail2ban
  
  echo -e "${GREEN}✓ Custom jail '$jail_name' created${NC}"
}

function manage_existing_custom_jail() {
  local jails=$(fail2ban-client status 2>/dev/null | grep "Jail list:" | cut -d: -f2 | tr -d ' 	')
  
  if [ -z "$jails" ]; then
    echo -e "${YELLOW}No active jails found${NC}"
    return
  fi
  
  echo -e "${CYAN}Available jails:${NC}"
  local i=1
  for jail in ${jails//,/ }; do
    echo -e "  ${i}. $jail"
    ((i++))
  done
  echo ""
  
  echo -ne "${CYAN}Enter jail name to manage:${NC} "
  read -r jail_name
  
  if [[ " ${jails//,/ } " =~ " $jail_name " ]]; then
    manage_service_jail "$jail_name" "Custom Service ($jail_name)"
  else
    echo -e "${RED}Jail '$jail_name' not found${NC}"
  fi
}

function delete_custom_jail() {
  local jails=$(fail2ban-client status 2>/dev/null | grep "Jail list:" | cut -d: -f2 | tr -d ' 	')
  
  if [ -z "$jails" ]; then
    echo -e "${YELLOW}No active jails found${NC}"
    return
  fi
  
  echo -e "${CYAN}Available jails:${NC}"
  local i=1
  for jail in ${jails//,/ }; do
    echo -e "  ${i}. $jail"
    ((i++))
  done
  echo ""
  
  echo -ne "${CYAN}Enter jail name to delete:${NC} "
  read -r jail_name
  
  if [[ " ${jails//,/ } " =~ " $jail_name " ]]; then
    echo -e "${RED}Are you sure you want to delete jail '$jail_name'? (y/N):${NC} "
    read -r confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
      # Останавливаем jail
      fail2ban-client stop "$jail_name" 2>/dev/null
      
      # Удаляем из конфигурации
      local jail_local="/etc/fail2ban/jail.local"
      sed -i "/^\[$jail_name\]/,/^\[/{/^\[/ {/^\[$jail_name\]/!b}; d}" "$jail_local"
      
      # Перезапускаем fail2ban
      systemctl reload fail2ban 2>/dev/null || systemctl restart fail2ban
      
      echo -e "${GREEN}✓ Jail '$jail_name' deleted${NC}"
    else
      echo -e "${YELLOW}Deletion cancelled${NC}"
    fi
  else
    echo -e "${RED}Jail '$jail_name' not found${NC}"
  fi
}

function show_all_jail_configs() {
  echo -e "${GREEN}All Jail Configurations:${NC}"
  echo -e "${CYAN}═══════════════════════════${NC}"
  
  if [ -f "/etc/fail2ban/jail.local" ]; then
    cat /etc/fail2ban/jail.local
  else
    echo -e "${RED}No jail.local found${NC}"
  fi
  
  echo ""
  echo -e "${CYAN}═══════════════════════════${NC}"
}

function toggle_fail2ban() {
  if systemctl is-active --quiet fail2ban; then
    echo -e "${YELLOW}Stopping Fail2ban...${NC}"
    systemctl stop fail2ban
    echo -e "${RED}Fail2ban has been stopped${NC}"
  else
    echo -e "${YELLOW}Starting Fail2ban...${NC}"
    systemctl start fail2ban
    if systemctl is-active --quiet fail2ban; then
      echo -e "${GREEN}Fail2ban has been started${NC}"
    else
      echo -e "${RED}Failed to start Fail2ban${NC}"
    fi
  fi
}

function interactive_menu() {
  # Автоматическая проверка версии при запуске
  local version_check_result=""
  if ! check_version > /dev/null 2>&1; then
    version_check_result="${YELLOW}⚠️ New version available!${NC}"
  fi
  
  while true; do
    print_header
    
    # Показываем уведомление об обновлении если есть
    if [ -n "$version_check_result" ]; then
      echo -e "$version_check_result"
      echo ""
    fi
    
    show_statistics
    
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${WHITE}                    INTERACTIVE MENU                         ${BLUE}║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN} 1.${NC} Quick Install/Configure SSH Protection"
    echo -e "${CYAN} 2.${NC} 🛠️  Service Management (SSH, Nginx, Caddy, etc.)"
    echo -e "${CYAN} 3.${NC} 📊 Show detailed status"
    echo -e "${CYAN} 4.${NC} 🚫 Show banned IPs (all services)"
    echo -e "${CYAN} 5.${NC} 📋 Show recent bans (last 20)"
    echo -e "${CYAN} 6.${NC} ⚡ Unban specific IP"
    echo -e "${CYAN} 7.${NC} 🔄 Unban ALL IPs (all services)"
    echo -e "${CYAN} 8.${NC} 🔧 Enable/Disable Fail2ban service"
    echo -e "${CYAN} 9.${NC} 🔄 Restart Fail2ban"
    echo -e "${CYAN}10.${NC} 🔍 Check SSH port consistency"
    echo -e "${CYAN}11.${NC} 📜 View Fail2ban logs"
    echo -e "${CYAN}12.${NC} 🆙 Check for script updates"
    echo -e "${CYAN}13.${NC} ⚙️  Install script to system (enables f2b commands)"
    echo -e "${CYAN}14.${NC} 🗑️  Uninstall script from system"
    echo -e "${RED} 0.${NC} Exit"
    echo ""
    echo -ne "${YELLOW}Select option [0-14]:${NC} "
    
    read -r choice
    echo ""
    
    case $choice in
      1)
        echo -e "\n${GREEN}Installing/Configuring SSH Protection...${NC}"
        install_fail2ban
        detect_ssh_port
        backup_and_configure_fail2ban
        restart_fail2ban
        allow_firewall_port
        echo -e "\n${GREEN}SSH Protection configured!${NC}"
        echo -e "${CYAN}To enable quick commands, install script to system:${NC}"
        echo -e "${WHITE}sudo $0 --install-system${NC}"
        ;;
      2)
        manage_services_menu
        ;;
      3)
        echo -e "\n${GREEN}Detailed Status:${NC}"
        if command -v fail2ban-client &>/dev/null && systemctl is-active --quiet fail2ban; then
          fail2ban-client status
          echo ""
          local jails=$(fail2ban-client status | grep "Jail list:" | cut -d: -f2 | tr -d ' 	')
          for jail in ${jails//,/ }; do
            echo -e "${CYAN}═══ $jail ═══${NC}"
            fail2ban-client status "$jail"
            echo ""
          done
        else
          echo -e "${RED}Fail2ban not running${NC}"
        fi
        ;;
      4)
        echo -e "\n${GREEN}Currently Banned IPs (All Services):${NC}"
        if command -v fail2ban-client &>/dev/null && systemctl is-active --quiet fail2ban; then
          local jails=$(fail2ban-client status | grep "Jail list:" | cut -d: -f2 | tr -d ' 	')
          local found_bans=false
          for jail in ${jails//,/ }; do
            local banned=$(fail2ban-client status "$jail" | grep 'Banned IP list:' | cut -d: -f2)
            if [ -n "$banned" ] && [ "$banned" != " " ]; then
              echo -e "${YELLOW}[$jail]:${NC} $banned"
              found_bans=true
            fi
          done
          if [ "$found_bans" = false ]; then
            echo -e "${GREEN}No IPs currently banned${NC}"
          fi
        else
          echo -e "${RED}Fail2ban not running${NC}"
        fi
        ;;
      5)
        show_recent_bans
        ;;
      6)
        echo -ne "${CYAN}Enter IP address to unban:${NC} "
        read -r ip
        if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
          echo -e "${YELLOW}Unbanning $ip from all jails...${NC}"
          if command -v fail2ban-client &>/dev/null && systemctl is-active --quiet fail2ban; then
            local jails=$(fail2ban-client status | grep "Jail list:" | cut -d: -f2 | tr -d ' 	')
            local unbanned=false
            for jail in ${jails//,/ }; do
              if fail2ban-client set "$jail" unbanip "$ip" 2>/dev/null; then
                echo -e "${GREEN}✓ Unbanned $ip from $jail${NC}"
                unbanned=true
              fi
            done
            if [ "$unbanned" = false ]; then
              echo -e "${YELLOW}IP $ip was not banned in any jail${NC}"
            fi
          else
            echo -e "${RED}Fail2ban not running${NC}"
          fi
        else
          echo -e "${RED}Invalid IP address format${NC}"
        fi
        ;;
      7)
        unban_all
        ;;
      8)
        toggle_fail2ban
        ;;
      9)
        echo -e "${YELLOW}Restarting Fail2ban...${NC}"
        systemctl restart fail2ban
        if systemctl is-active --quiet fail2ban; then
          echo -e "${GREEN}✓ Fail2ban restarted successfully${NC}"
        else
          echo -e "${RED}✗ Failed to restart Fail2ban${NC}"
        fi
        ;;
      10)
        check_ssh_port_consistency
        ;;
      11)
        echo -e "\n${GREEN}Fail2ban Log (last 30 lines):${NC}"
        echo -e "${CYAN}─────────────────────────────${NC}"
        if [ -f /var/log/fail2ban.log ]; then
          tail -30 /var/log/fail2ban.log
        else
          echo -e "${RED}No fail2ban log found${NC}"
        fi
        ;;
      12)
        echo ""
        check_version
        version_check_result=""  # Сбрасываем уведомление после проверки
        ;;
      13)
        echo -ne "${CYAN}Enter download URL (or press Enter to use current script):${NC} "
        read -r url
        install_script_to_system "$url"
        ;;
      14)
        uninstall_script_from_system
        ;;
      0)
        echo -e "\n${GREEN}Goodbye!${NC}"
        exit 0
        ;;
      *)
        echo -e "\n${RED}Invalid option. Please try again.${NC}"
        ;;
    esac
    
    if [ "$choice" != "0" ]; then
      echo -e "$version_check_result"
      echo ""
    fi
    
    show_statistics
    
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${WHITE}                    INTERACTIVE MENU                         ${BLUE}║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN} 1.${NC} Quick Install/Configure SSH Protection"
    echo -e "${CYAN} 2.${NC} 🛠️  Service Management (SSH, Nginx, Caddy, etc.)"
    echo -e "${CYAN} 3.${NC} 📊 Show detailed status"
    echo -e "${CYAN} 4.${NC} 🚫 Show banned IPs (all services)"
    echo -e "${CYAN} 5.${NC} 📋 Show recent bans (last 20)"
    echo -e "${CYAN} 6.${NC} ⚡ Unban specific IP"
    echo -e "${CYAN} 7.${NC} 🔄 Unban ALL IPs (all services)"
    echo -e "${CYAN} 8.${NC} 🔧 Enable/Disable Fail2ban service"
    echo -e "${CYAN} 9.${NC} 🔄 Restart Fail2ban"
    echo -e "${CYAN}10.${NC} 🔍 Check SSH port consistency"
    echo -e "${CYAN}11.${NC} 📜 View Fail2ban logs"
    echo -e "${CYAN}12.${NC} 🆙 Check for script updates"
    echo -e "${CYAN}13.${NC} ⚙️  Install script to system (enables f2b commands)"
    echo -e "${CYAN}14.${NC} 🗑️  Uninstall script from system"
    echo -e "${RED} 0.${NC} Exit"
    echo ""
    echo -ne "${YELLOW}Select option [0-14]:${NC} "
    
    read -r choice
    echo ""
    
    case $choice in
      1)
        echo -e "\n${GREEN}Installing/Configuring SSH Protection...${NC}"
        install_fail2ban
        detect_ssh_port
        backup_and_configure_fail2ban
        restart_fail2ban
        allow_firewall_port
        echo -e "\n${GREEN}SSH Protection configured!${NC}"
        echo -e "${CYAN}To enable quick commands, install script to system:${NC}"
        echo -e "${WHITE}sudo $0 --install-system${NC}"
        ;;
      2)
        manage_services_menu
        ;;
      3)
        echo -e "\n${GREEN}Detailed Status:${NC}"
        if command -v fail2ban-client &>/dev/null && systemctl is-active --quiet fail2ban; then
          fail2ban-client status
          echo ""
          local jails=$(fail2ban-client status | grep "Jail list:" | cut -d: -f2 | tr -d ' 	')
          for jail in ${jails//,/ }; do
            echo -e "${CYAN}═══ $jail ═══${NC}"
            fail2ban-client status "$jail"
            echo ""
          done
        else
          echo -e "${RED}Fail2ban not running${NC}"
        fi
        ;;
      4)
        echo -e "\n${GREEN}Currently Banned IPs (All Services):${NC}"
        if command -v fail2ban-client &>/dev/null && systemctl is-active --quiet fail2ban; then
          local jails=$(fail2ban-client status | grep "Jail list:" | cut -d: -f2 | tr -d ' 	')
          local found_bans=false
          for jail in ${jails//,/ }; do
            local banned=$(fail2ban-client status "$jail" | grep 'Banned IP list:' | cut -d: -f2)
            if [ -n "$banned" ] && [ "$banned" != " " ]; then
              echo -e "${YELLOW}[$jail]:${NC} $banned"
              found_bans=true
            fi
          done
          if [ "$found_bans" = false ]; then
            echo -e "${GREEN}No IPs currently banned${NC}"
          fi
        else
          echo -e "${RED}Fail2ban not running${NC}"
        fi
        ;;
      5)
        echo ""
        show_recent_bans
        ;;
      6)
        echo -ne "${CYAN}Enter IP address to unban:${NC} "
        read -r ip_to_unban
        if [[ $ip_to_unban =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
          local unbanned=false
          local jails=$(fail2ban-client status 2>/dev/null | grep "Jail list:" | cut -d: -f2 | tr -d ' 	')
          for jail in ${jails//,/ }; do
            if fail2ban-client set "$jail" unbanip "$ip_to_unban" 2>/dev/null; then
              echo -e "${GREEN}✓ IP $ip_to_unban unbanned from $jail${NC}"
              unbanned=true
            fi
          done
          if [ "$unbanned" = false ]; then
            echo -e "${YELLOW}IP $ip_to_unban was not banned or no active jails${NC}"
          fi
        else
          echo -e "${RED}Invalid IP address format${NC}"
        fi
        ;;
      7)
        echo ""
        unban_all
        ;;
      8)
        echo ""
        toggle_fail2ban
        ;;
      9)
        echo -e "\n${YELLOW}Restarting Fail2ban...${NC}"
        systemctl restart fail2ban
        if systemctl is-active --quiet fail2ban; then
          echo -e "${GREEN}Fail2ban restarted successfully${NC}"
        else
          echo -e "${RED}Failed to restart Fail2ban${NC}"
        fi
        ;;
      10)
        echo ""
        check_ssh_port_consistency
        ;;
      11)
        echo -e "\n${GREEN}Fail2ban Log (last 30 lines):${NC}"
        echo -e "${CYAN}─────────────────────────────${NC}"
        if [ -f /var/log/fail2ban.log ]; then
          tail -30 /var/log/fail2ban.log
        else
          echo -e "${RED}No fail2ban log found${NC}"
        fi
        ;;
      12)
        echo ""
        check_version
        version_check_result=""  # Сбрасываем уведомление после проверки
        ;;
      13)
        echo -ne "${CYAN}Enter download URL (or press Enter to use current script):${NC} "
        read -r url
        install_script_to_system "$url"
        ;;
      14)
        uninstall_script_from_system
        ;;
      0)
        echo -e "\n${GREEN}Goodbye!${NC}"
        exit 0
        ;;
      *)
        echo -e "\n${RED}Invalid option. Please try again.${NC}"
        ;;
    esac
    
    if [ "$choice" != "0" ]; then
      echo ""
      echo -e "${YELLOW}Press Enter to continue...${NC}"
      read -r
    fi
  done
}

function install_fail2ban() {
  if ! command -v fail2ban-server &>/dev/null; then
    echo -e "${YELLOW}Installing Fail2ban...${NC}"
    apt update && apt install -y fail2ban || { echo -e "${RED}Failed to install fail2ban${NC}"; exit 1; }
  else
    echo -e "${GREEN}Fail2ban is already installed${NC}"
  fi
}

function detect_ssh_port() {
  SSH_PORT=$(grep -Po '(?<=^Port )\d+' /etc/ssh/sshd_config | head -n1)
  SSH_PORT=${SSH_PORT:-22}
  echo -e "${CYAN}Detected SSH port:${NC} ${GREEN}$SSH_PORT${NC}"
}

function check_ssh_port_consistency() {
  echo -e "${YELLOW}Checking SSH port consistency...${NC}"
  
  # Получаем текущий SSH порт
  CURRENT_SSH_PORT=$(grep -Po '(?<=^Port )\d+' /etc/ssh/sshd_config | head -n1)
  CURRENT_SSH_PORT=${CURRENT_SSH_PORT:-22}
  
  # Получаем порт из конфига fail2ban
  F2B_SSH_PORT=""
  if [ -f "/etc/fail2ban/jail.local" ]; then
    F2B_SSH_PORT=$(grep -A 10 "\[sshd\]" /etc/fail2ban/jail.local | grep "^port" | cut -d'=' -f2 | tr -d ' ')
  fi
  
  echo -e "${CYAN}Current SSH port:${NC} ${GREEN}$CURRENT_SSH_PORT${NC}"
  echo -e "${CYAN}Fail2ban SSH port:${NC} ${GREEN}${F2B_SSH_PORT:-"not configured"}${NC}"
  
  if [ -n "$F2B_SSH_PORT" ] && [ "$CURRENT_SSH_PORT" != "$F2B_SSH_PORT" ]; then
    echo -e "${RED}⚠️  WARNING: SSH port mismatch detected!${NC}"
    echo -e "${YELLOW}Fail2ban is monitoring port $F2B_SSH_PORT, but SSH is running on port $CURRENT_SSH_PORT${NC}"
    echo ""
    echo -e "${CYAN}Do you want to update fail2ban configuration? (y/n):${NC}"
    read -r response
    if [[ "$response" =~ ^[Yy]$ ]]; then
      update_fail2ban_ssh_port "$CURRENT_SSH_PORT"
      return 0
    else
      echo -e "${YELLOW}Port mismatch not fixed. Fail2ban may not work correctly.${NC}"
      return 1
    fi
  else
    echo -e "${GREEN}✓ SSH ports are consistent${NC}"
    return 0
  fi
}

function update_fail2ban_ssh_port() {
  local new_port="$1"
  echo -e "${YELLOW}Updating fail2ban SSH port to $new_port...${NC}"
  
  if [ -f "/etc/fail2ban/jail.local" ]; then
    # Создаем резервную копию
    cp "/etc/fail2ban/jail.local" "/etc/fail2ban/jail.local.bak_$(date +%Y%m%d_%H%M%S)"
    
    # Обновляем порт в конфиге
    sed -i "/^\[sshd\]/,/^\[/ s/^port = .*/port = $new_port/" /etc/fail2ban/jail.local
    
    # Перезапускаем fail2ban
    systemctl restart fail2ban
    if systemctl is-active --quiet fail2ban; then
      echo -e "${GREEN}✓ Fail2ban configuration updated and restarted${NC}"
    else
      echo -e "${RED}✗ Failed to restart fail2ban. Check configuration.${NC}"
    fi
  else
    echo -e "${RED}✗ Fail2ban configuration file not found${NC}"
  fi
}

function backup_and_configure_fail2ban() {
  JAIL_LOCAL="/etc/fail2ban/jail.local"
  cp -f "$JAIL_LOCAL" "${JAIL_LOCAL}.bak_$(date +%Y%m%d_%H%M%S)" 2>/dev/null

  cat > "$JAIL_LOCAL" <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8
bantime.increment = true
bantime.factor = 5
bantime.formula = ban.Time * (1<<(ban.Count if ban.Count<20 else 20)) * banFactor
bantime.maxtime = 1M
findtime = 10m
maxretry = 3
backend = systemd

[sshd]
enabled = true
port = $SSH_PORT
filter = sshd
logpath = /var/log/auth.log
EOF

  echo -e "${GREEN}Fail2ban configured with dynamic SSH blocking.${NC}"
}

function restart_fail2ban() {
  systemctl restart fail2ban
  sleep 1
  if systemctl is-active --quiet fail2ban; then
    echo -e "${GREEN}Fail2ban service is running.${NC}"
  else
    echo -e "${RED}Fail2ban failed to start. Check the config!${NC}"
    fail2ban-client -d
    exit 1
  fi
}

function allow_firewall_port() {
  if command -v ufw > /dev/null; then
    ufw allow "$SSH_PORT"/tcp || true
    echo -e "${YELLOW}UFW: allowed SSH port $SSH_PORT${NC}"
  fi
}

function check_system_path() {
  local target_path="/usr/local/bin"
  if [[ ":$PATH:" == *":$target_path:"* ]]; then
    return 0
  else
    echo -e "${YELLOW}Warning: $target_path is not in your PATH${NC}"
    echo -e "${CYAN}You may need to add it to your shell profile${NC}"
    return 1
  fi
}

function install_script_to_system() {
  echo -e "${YELLOW}Installing f2b script to system...${NC}"
  
  # Проверяем права root
  if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Root privileges required for system installation${NC}"
    return 1
  fi
  
  # Проверяем PATH
  check_system_path
  
  local script_path="$INSTALL_PATH"
  
  # Скачиваем или копируем скрипт
  if [ -n "$1" ] && [[ "$1" =~ ^https?:// ]]; then
    echo -e "${CYAN}Downloading script from: $1${NC}"
    if command -v curl &>/dev/null; then
      if curl -s "$1" > "$script_path"; then
        echo -e "${GREEN}✓ Downloaded successfully${NC}"
      else
        echo -e "${RED}✗ Download failed${NC}"
        return 1
      fi
    elif command -v wget &>/dev/null; then
      if wget -q -O "$script_path" "$1"; then
        echo -e "${GREEN}✓ Downloaded successfully${NC}"
      else
        echo -e "${RED}✗ Download failed${NC}"
        return 1
      fi
    else
      echo -e "${RED}Neither curl nor wget available for download${NC}"
      return 1
    fi
  else
    # Копируем текущий скрипт (только если это реальный файл)
    if [ -f "$0" ] && [ -s "$0" ]; then
      cp "$0" "$script_path"
      echo -e "${GREEN}✓ Copied from local file${NC}"
    else
      echo -e "${RED}✗ Cannot copy current script (not a valid file)${NC}"
      echo -e "${YELLOW}Try downloading from URL instead${NC}"
      return 1
    fi
  fi
  
  # Проверяем успешность и делаем исполняемым
  if [ -f "$script_path" ] && [ -s "$script_path" ]; then
    chmod +x "$script_path"
    echo -e "${GREEN}✓ Script installed to $script_path${NC}"
    echo -e "${CYAN}You can now run:${NC}"
    echo -e "  ${WHITE}f2b${NC}                    - Interactive menu"
    echo -e "  ${WHITE}f2b help${NC}               - Show help"
    echo -e "  ${WHITE}f2b status${NC}             - Check status"
    echo -e "  ${WHITE}f2b stats${NC}              - Show statistics"
    
    # Создаем символическую ссылку в /usr/bin если нужно и если путь есть в PATH
    if [ ! -f "/usr/bin/f2b" ] && [[ ":$PATH:" == *":/usr/bin:"* ]]; then
      ln -s "$script_path" "/usr/bin/f2b" 2>/dev/null
    fi
    
    return 0
  else
    echo -e "${RED}✗ Failed to install script (file is empty or missing)${NC}"
    return 1
  fi
}

function uninstall_script_from_system() {
  echo -e "${YELLOW}Uninstalling f2b script from system...${NC}"
  
  if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Root privileges required for system uninstallation${NC}"
    return 1
  fi
  
  local removed_files=()
  
  # Удаляем основной скрипт
  if [ -f "$INSTALL_PATH" ]; then
    rm -f "$INSTALL_PATH"
    removed_files+=("$INSTALL_PATH")
  fi
  
  # Удаляем символическую ссылку
  if [ -L "/usr/bin/f2b" ]; then
    rm -f "/usr/bin/f2b"
    removed_files+=("/usr/bin/f2b")
  fi
  
  if [ ${#removed_files[@]} -gt 0 ]; then
    echo -e "${GREEN}✓ Removed files:${NC}"
    for file in "${removed_files[@]}"; do
      echo -e "  ${CYAN}- $file${NC}"
    done
  else
    echo -e "${YELLOW}No f2b installations found${NC}"
  fi
}

# Обработка аргументов командной строки
case "$1" in
  --version|-v)
    echo "Fail2Ban SSH Security Manager v$SCRIPT_VERSION"
    exit 0
    ;;
  --check-update)
    check_version
    exit $?
    ;;
  --install)
    print_header
    check_root
    install_fail2ban
    detect_ssh_port
    backup_and_configure_fail2ban
    restart_fail2ban
    allow_firewall_port
    echo -e "\n${GREEN}Fail2ban SSH protection is now active.${NC}"
    echo -e "${CYAN}To enable quick f2b commands, install to system:${NC}"
    echo -e "${WHITE}sudo $0 --install-system${NC}"
    exit 0
    ;;
  --install-system)
    check_root
    install_script_to_system "$2"
    exit $?
    ;;
  --uninstall-system)
    check_root
    uninstall_script_from_system
    exit $?
    ;;
  --check-ports)
    check_ssh_port_consistency
    exit $?
    ;;
  --menu)
    # Принудительный интерактивный режим
    check_root
    interactive_menu
    ;;
  --help|-h)
    echo "Fail2Ban SSH Security Manager v$SCRIPT_VERSION"
    echo ""
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Installation:"
    echo "  bash <(wget -qO- https://dignezzz.github.io/server/f2b.sh)          # Auto-install"
    echo "  bash <(wget -qO- https://dignezzz.github.io/server/f2b.sh) --menu   # Interactive menu only"
    echo ""
    echo "Options:"
    echo "  --install              Quick install SSH protection only"
    echo "  --install-system [URL] Install script to system (/usr/local/bin/f2b)"
    echo "  --uninstall-system     Remove script from system"
    echo "  --menu                 Force interactive menu (skip auto-install)"
    echo "  --check-ports          Check SSH port consistency"
    echo "  --version, -v          Show version"
    echo "  --check-update         Check for script updates"
    echo "  --help, -h             Show this help"
    echo ""
    echo "Run without arguments for interactive menu with full service management"
    echo ""
    echo "After installing to system with --install-system, you can use:"
    echo "  f2b                    - Interactive menu"
    echo "  f2b help               - Show f2b commands"
    echo "  f2b status             - Check Fail2ban status"
    echo "  f2b stats              - Show statistics"
    exit 0
    ;;
  "")
    # Проверяем, запущен ли скрипт через wget/curl (временный файл)
    if [[ "$0" =~ ^/tmp/ ]] || [[ "$0" =~ ^/dev/fd/ ]] || [[ "$0" == "bash" ]] || [[ -z "$0" ]]; then
      # Автоматическая установка при загрузке через wget/curl
      echo -e "${CYAN}🚀 Обнаружена установка через wget/curl${NC}"
      echo -e "${YELLOW}Устанавливаем скрипт в систему...${NC}"
      echo
      
      check_root
      
      # Проверяем, установлен ли уже скрипт
      if [[ -f "$INSTALL_PATH" ]]; then
        echo -e "${YELLOW}⚠️ Скрипт уже установлен в $INSTALL_PATH${NC}"
        echo -e "${BLUE}Обновляем до версии $SCRIPT_VERSION...${NC}"
      else
        echo -e "${GREEN}📦 Устанавливаем Fail2ban Manager v$SCRIPT_VERSION${NC}"
      fi
      
      # При установке через wget/curl всегда скачиваем с GitHub
      install_script_to_system "$VERSION_CHECK_URL"
      exit $?
    else
      # Интерактивный режим (запуск локального файла)
      check_root
      interactive_menu
    fi
    ;;
  *)
    echo -e "${RED}Unknown option: $1${NC}"
    echo "Use --help for available options"
    exit 1
    ;;
esac
