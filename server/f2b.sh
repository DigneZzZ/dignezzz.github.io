#!/bin/bash

# Версия скрипта
SCRIPT_VERSION="3.5.4"
VERSION_CHECK_URL="https://raw.githubusercontent.com/DigneZzZ/dignezzz.github.io/main/server/f2b.sh"

# Константы путей конфигурации
readonly JAIL_LOCAL="/etc/fail2ban/jail.local"
readonly F2B_LOG="/var/log/fail2ban.log"
readonly F2B_FILTER_DIR="/etc/fail2ban/filter.d"

# Таймаут для fail2ban-client команд (секунды)
readonly F2B_TIMEOUT=3

# Современная цветовая палитра
GREEN='\033[38;5;46m'      # Яркий зелёный
RED='\033[38;5;196m'       # Яркий красный
YELLOW='\033[38;5;226m'    # Яркий жёлтый
BLUE='\033[38;5;33m'       # Яркий синий
CYAN='\033[38;5;51m'       # Яркий циан
PURPLE='\033[38;5;141m'    # Мягкий фиолетовый
ORANGE='\033[38;5;208m'    # Оранжевый
GRAY='\033[38;5;240m'      # Серый
WHITE='\033[1;97m'         # Яркий белый
BOLD='\033[1m'             # Жирный
DIM='\033[2m'              # Тусклый
NC='\033[0m'               # Сброс цвета

# Unicode символы для современного дизайна
ICON_CHECK="✓"
ICON_CROSS="✗"
ICON_ARROW="→"
ICON_STAR="★"
ICON_WARNING="⚠"
ICON_INFO="ℹ"
ICON_LOCK="🔒"
ICON_SHIELD="🛡"
ICON_FIRE="🔥"
ICON_CHART="📊"
ICON_BOOK="📖"
ICON_GEAR="⚙"
ICON_ROCKET="🚀"

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
        grep "\[$2\]" "$F2B_LOG" | tail -20
      else
        tail -n 50 "$F2B_LOG"
      fi
      exit 0
      ;;
    recent)
      echo "Recent bans (last 10):"
      if [ -f "$F2B_LOG" ]; then
        grep "Ban " "$F2B_LOG" | tail -10 | while read line; do
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
      if [ -f "$JAIL_LOCAL" ]; then
        F2B_SSH_PORT=$(grep -A 10 "\[sshd\]" "$JAIL_LOCAL" | grep "^port" | cut -d'=' -f2 | tr -d ' ')
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
  echo ""
  echo -e "${BOLD}${CYAN}${ICON_SHIELD} Fail2Ban Security Manager${NC}"
  echo -e "${DIM}${GRAY}Version ${SCRIPT_VERSION} • Advanced SSH Protection${NC}"
  echo ""
}

function check_version() {
  echo -e "${BLUE}${ICON_INFO} Проверка обновлений...${NC}"
  if command -v curl &>/dev/null; then
    LATEST_VERSION=$(curl -s --connect-timeout 3 --max-time 5 "$VERSION_CHECK_URL" 2>/dev/null | grep -o 'SCRIPT_VERSION="[0-9.]*"' | cut -d'"' -f2)
    if [ -n "$LATEST_VERSION" ] && [ "$LATEST_VERSION" != "$SCRIPT_VERSION" ]; then
      echo -e "${GREEN}${ICON_ROCKET} Доступна новая версия: ${BOLD}$LATEST_VERSION${NC}"
      echo -e "${GRAY}   Текущая версия: $SCRIPT_VERSION${NC}"
      echo -e "${CYAN}   ${ICON_ARROW} $VERSION_CHECK_URL${NC}"
      echo ""
      
      # Предлагаем автоматическое обновление если скрипт установлен в системе
      if [ -f "$INSTALL_PATH" ] && [ "$EUID" -eq 0 ]; then
        echo -e "${CYAN}Обновить автоматически? (Y/n):${NC}"
        read -r response
        if [[ -z "$response" || "$response" =~ ^[Yy]$ ]]; then
          update_script
          return $?
        fi
      elif [ "$EUID" -ne 0 ]; then
        echo -e "${YELLOW}Note: Run as root to enable automatic update option${NC}"
      else
        echo -e "${YELLOW}Note: Script not installed in system. Use option 13 to install first.${NC}"
      fi
      
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

function update_script() {
  echo -e "${YELLOW}Обновление скрипта...${NC}"
  
  if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Требуются права root для обновления${NC}"
    return 1
  fi
  
  # Создаем резервную копию если файл существует
  if [ -f "$INSTALL_PATH" ]; then
    cp "$INSTALL_PATH" "${INSTALL_PATH}.bak_$(date +%Y%m%d_%H%M%S)"
    echo -e "${CYAN}Резервная копия создана${NC}"
  fi
  
  # Скачиваем новую версию во временный файл
  local tmp_file="/tmp/f2b_update_$$"
  
  if command -v curl &>/dev/null; then
    if curl -sL --connect-timeout 10 --max-time 30 "$VERSION_CHECK_URL" -o "$tmp_file" && [ -s "$tmp_file" ]; then
      # Проверяем что скачался валидный скрипт
      if head -1 "$tmp_file" | grep -q "^#!/bin/bash"; then
        mv "$tmp_file" "$INSTALL_PATH"
        chmod +x "$INSTALL_PATH"
        echo -e "${GREEN}✓ Скрипт успешно обновлён!${NC}"
        echo -e "${CYAN}Новая версия установлена в $INSTALL_PATH${NC}"
        echo ""
        echo -e "${YELLOW}Перезапустите скрипт для использования новой версии${NC}"
        return 0
      else
        rm -f "$tmp_file"
        echo -e "${RED}✗ Скачанный файл не является валидным скриптом${NC}"
        return 1
      fi
    else
      rm -f "$tmp_file" 2>/dev/null
      echo -e "${RED}✗ Ошибка загрузки${NC}"
      return 1
    fi
  elif command -v wget &>/dev/null; then
    if wget -q --timeout=30 -O "$tmp_file" "$VERSION_CHECK_URL" && [ -s "$tmp_file" ]; then
      if head -1 "$tmp_file" | grep -q "^#!/bin/bash"; then
        mv "$tmp_file" "$INSTALL_PATH"
        chmod +x "$INSTALL_PATH"
        echo -e "${GREEN}✓ Скрипт успешно обновлён!${NC}"
        echo -e "${CYAN}Новая версия установлена в $INSTALL_PATH${NC}"
        echo ""
        echo -e "${YELLOW}Перезапустите скрипт для использования новой версии${NC}"
        return 0
      else
        rm -f "$tmp_file"
        echo -e "${RED}✗ Скачанный файл не является валидным скриптом${NC}"
        return 1
      fi
    else
      rm -f "$tmp_file" 2>/dev/null
      echo -e "${RED}✗ Ошибка загрузки${NC}"
      return 1
    fi
  else
    echo -e "${RED}Ни curl, ни wget не доступны для загрузки${NC}"
    return 1
  fi
}

function check_root() {
  if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run this script as root.${NC}"
    exit 1
  fi
}

function show_statistics() {
  echo -e "${BOLD}${CYAN}${ICON_CHART} СТАТИСТИКА FAIL2BAN${NC}"
  echo ""
  
  # Фоновая проверка версии (с таймаутом, не блокирует)
  check_version > /dev/null 2>&1 &
  
  # Проверка статуса сервиса
  if systemctl is-active --quiet fail2ban; then
    echo -e "  ${GREEN}${ICON_CHECK} Сервис Fail2ban:${NC} ${BOLD}${GREEN}АКТИВЕН${NC}"
  else
    echo -e "  ${RED}${ICON_CROSS} Сервис Fail2ban:${NC} ${BOLD}${RED}НЕ АКТИВЕН${NC}"
    echo ""
    return 1
  fi
  
  # Проверка SSH портов
  check_ssh_port_consistency_quiet
  echo ""
  
  # Получение статистики jail'ов по категориям
  if command -v fail2ban-client &>/dev/null; then
    local jails=$(get_active_jails)
    
    if [ -n "$jails" ]; then
      # SSH Services
      local ssh_services_found=false
      for jail in ${jails//,/ }; do
        if [[ "$jail" =~ ^(sshd|ssh)$ ]]; then
          if [ "$ssh_services_found" = false ]; then
            echo -e "  ${BOLD}${BLUE}${ICON_LOCK} SSH Сервисы:${NC}"
            ssh_services_found=true
          fi
          show_jail_stats "$jail" "    "
        fi
      done
      
      # Web Services  
      local web_services_found=false
      for jail in ${jails//,/ }; do
        if [[ "$jail" =~ ^(nginx|caddy|phpmyadmin).*$ ]]; then
          if [ "$web_services_found" = false ]; then
            echo -e "  ${BOLD}${PURPLE}🌐 Web Сервисы:${NC}"
            web_services_found=true
          fi
          show_jail_stats "$jail" "    "
        fi
      done
      
      # Database Services
      local db_services_found=false
      for jail in ${jails//,/ }; do
        if [[ "$jail" =~ ^(mysql|mariadb).*$ ]]; then
          if [ "$db_services_found" = false ]; then
            echo -e "  ${BOLD}${ORANGE}🗄️ База данных:${NC}"
            db_services_found=true
          fi
          show_jail_stats "$jail" "    "
        fi
      done
      
      # Other Services
      local other_services_found=false
      for jail in ${jails//,/ }; do
        if ! [[ "$jail" =~ ^(sshd|ssh|nginx|apache|caddy|httpd|wordpress|phpmyadmin|roundcube|postfix|dovecot|exim|sendmail|mysql|mariadb|postgresql|mongo|vsftpd|proftpd|pureftpd|ftp).*$ ]]; then
          if [ "$other_services_found" = false ]; then
            echo -e "  ${BOLD}${GRAY}${ICON_GEAR} Прочие сервисы:${NC}"
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
    if [ -f "$F2B_LOG" ]; then
      local recent_bans=$(grep "Ban " "$F2B_LOG" | tail -5)
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
  local status=$(timeout $F2B_TIMEOUT fail2ban-client status "$jail" 2>/dev/null)
  if [ $? -eq 0 ] && [ -n "$status" ]; then
    local currently_failed=$(echo "$status" | grep "Currently failed:" | awk -F: '{print $2}' | tr -d ' \t')
    local total_failed=$(echo "$status" | grep "Total failed:" | awk -F: '{print $2}' | tr -d ' \t')
    local currently_banned=$(echo "$status" | grep "Currently banned:" | awk -F: '{print $2}' | tr -d ' \t')
    local total_banned=$(echo "$status" | grep "Total banned:" | awk -F: '{print $2}' | tr -d ' \t')
    
    local status_icon="${ICON_CHECK}"
    local status_color="${GREEN}"
    if [ "${currently_banned:-0}" -gt 0 ]; then
      status_icon="${ICON_FIRE}"
      status_color="${RED}"
    elif [ "${currently_failed:-0}" -gt 0 ]; then
      status_icon="${ICON_WARNING}"
      status_color="${YELLOW}"
    fi
    
    # Получаем путь к логу
    local logpath=$(get_jail_logpath "$jail")
    local log_status=$(get_jail_log_status "$logpath")
    
    echo -e "${indent}${status_color}${status_icon} ${BOLD}$jail${NC} ${GRAY}│${NC} Попытки: ${YELLOW}${currently_failed:-0}${NC}/${DIM}${total_failed:-0}${NC} ${GRAY}│${NC} Блоки: ${RED}${currently_banned:-0}${NC}/${DIM}${total_banned:-0}${NC}"
    echo -e "${indent}   ${log_status}"
  fi
}

# Получить путь к логу для jail'а
# Возвращает: путь к файлу ИЛИ "systemd" если используется journald
function get_jail_logpath() {
  local jail="$1"
  local logpath=""
  local backend=""
  
  # Читаем backend и logpath из jail.local для конкретного jail
  if [ -f "$JAIL_LOCAL" ]; then
    backend=$(awk -v jail="$jail" '
      BEGIN { in_section=0 }
      /^\[/ { in_section=0 }
      $0 ~ "^\\[" jail "\\]" { in_section=1; next }
      in_section && /^backend/ { gsub(/^backend[[:space:]]*=[[:space:]]*/, ""); print; exit }
    ' "$JAIL_LOCAL")
    
    logpath=$(awk -v jail="$jail" '
      BEGIN { in_section=0 }
      /^\[/ { in_section=0 }
      $0 ~ "^\\[" jail "\\]" { in_section=1; next }
      in_section && /^logpath/ { gsub(/^logpath[[:space:]]*=[[:space:]]*/, ""); print; exit }
    ' "$JAIL_LOCAL")
  fi
  
  # Если у jail'а есть свой logpath — это файл, не systemd
  if [ -n "$logpath" ]; then
    echo "$logpath"
    return
  fi
  
  # Если у jail'а явно указан backend=systemd
  if [ "$backend" = "systemd" ]; then
    echo "systemd"
    return
  fi
  
  # Стандартные пути для известных jail'ов
  case "$jail" in
    sshd|ssh)
      # SSH обычно использует systemd на современных системах
      for p in /var/log/auth.log /var/log/secure; do
        [ -f "$p" ] && { echo "$p"; return; }
      done
      # Файлы не найдены — значит systemd
      echo "systemd"
      ;;
    caddy)
      for p in /var/log/caddy/access.log /var/log/caddy/caddy.log; do
        [ -f "$p" ] && { echo "$p"; return; }
      done
      ;;
    nginx|nginx-*)
      for p in /var/log/nginx/access.log /var/log/nginx/error.log; do
        [ -f "$p" ] && { echo "$p"; return; }
      done
      ;;
    apache|apache-*)
      for p in /var/log/apache2/access.log /var/log/apache2/error.log /var/log/httpd/access_log; do
        [ -f "$p" ] && { echo "$p"; return; }
      done
      ;;
    mysql|mariadb)
      for p in /var/log/mysql/error.log /var/log/mariadb/mariadb.log; do
        [ -f "$p" ] && { echo "$p"; return; }
      done
      ;;
    postfix|postfix-*)
      [ -f /var/log/mail.log ] && { echo "/var/log/mail.log"; return; }
      ;;
  esac
}

# Проверка статуса лог-файла для jail'а (принимает путь к логу)
function get_jail_log_status() {
  local logpath="$1"
  
  if [ -z "$logpath" ]; then
    echo -e "${GRAY}└─ ${DIM}Лог: путь не определён${NC}"
    return
  fi
  
  # Если используется systemd journal
  if [ "$logpath" = "systemd" ]; then
    echo -e "${CYAN}└─ ${ICON_INFO} Лог: systemd journal${NC}"
    return
  fi
  
  # Проверяем существование файла
  if [ ! -e "$logpath" ]; then
    echo -e "${RED}└─ ${ICON_CROSS} Лог не найден:${NC} ${DIM}$logpath${NC}"
    return
  fi
  
  if [ ! -r "$logpath" ]; then
    echo -e "${RED}└─ ${ICON_CROSS} Лог недоступен для чтения:${NC} ${DIM}$logpath${NC}"
    return
  fi
  
  # Получаем информацию о файле (только stat, без wc -l для скорости)
  local file_size last_modified
  file_size=$(stat -c%s "$logpath" 2>/dev/null || stat -f%z "$logpath" 2>/dev/null)
  last_modified=$(stat -c%Y "$logpath" 2>/dev/null || stat -f%m "$logpath" 2>/dev/null)
  
  # Форматируем размер
  local file_size_hr
  if [ "$file_size" -gt 1073741824 ]; then
    file_size_hr="$(( file_size / 1073741824 ))GiB"
  elif [ "$file_size" -gt 1048576 ]; then
    file_size_hr="$(( file_size / 1048576 ))MiB"
  elif [ "$file_size" -gt 1024 ]; then
    file_size_hr="$(( file_size / 1024 ))KiB"
  else
    file_size_hr="${file_size}B"
  fi
  
  local now age
  now=$(date +%s)
  age=$((now - last_modified))
  
  # Определяем "свежесть" лога
  local freshness_icon freshness_text
  if [ "$age" -lt 300 ]; then
    freshness_icon="${GREEN}●${NC}"
    freshness_text="активен"
  elif [ "$age" -lt 3600 ]; then
    freshness_icon="${YELLOW}●${NC}"
    freshness_text="$(( age / 60 ))м назад"
  elif [ "$age" -lt 86400 ]; then
    freshness_icon="${ORANGE}●${NC}"
    freshness_text="$(( age / 3600 ))ч назад"
  else
    freshness_icon="${RED}●${NC}"
    freshness_text="$(( age / 86400 ))д назад"
  fi
  
  echo -e "${GRAY}└─${NC} ${freshness_icon} ${DIM}$logpath${NC} ${GRAY}(${file_size_hr}, ${freshness_text})${NC}"
}

function check_ssh_port_consistency_quiet() {
  # Тихая проверка портов SSH для статистики
  local current_ssh_port=$(grep -Po '(?<=^Port )\d+' /etc/ssh/sshd_config 2>/dev/null | head -n1)
  current_ssh_port=${current_ssh_port:-22}
  
  local f2b_ssh_port=""
  if [ -f "$JAIL_LOCAL" ]; then
    # Используем awk для извлечения порта только из секции [sshd], останавливаемся на следующей секции
    f2b_ssh_port=$(awk '/^\[sshd\]/,/^\[/{if(/^port[[:space:]]*=/){gsub(/.*=[[:space:]]*/,""); gsub(/[[:space:]]*$/,""); print; exit}}' "$JAIL_LOCAL" 2>/dev/null)
  fi
  
  if [ -n "$f2b_ssh_port" ] && [ "$current_ssh_port" != "$f2b_ssh_port" ]; then
    echo -e "  ${RED}${ICON_WARNING} Несоответствие SSH портов:${NC} SSH(${BOLD}$current_ssh_port${NC}) vs F2B(${BOLD}$f2b_ssh_port${NC})"
  else
    echo -e "  ${GREEN}${ICON_CHECK} SSH порт:${NC} ${BOLD}$current_ssh_port${NC}"
  fi
}

function show_recent_bans() {
  echo -e "${BOLD}${YELLOW}${ICON_FIRE} Последние блокировки (10 шт)${NC}"
  echo ""
  
  if [ -f "$F2B_LOG" ]; then
    grep "Ban " "$F2B_LOG" | tail -10 | while read line; do
      DATE=$(echo "$line" | awk '{print $1, $2}')
      IP=$(echo "$line" | grep -o '[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}')
      echo -e "  ${GRAY}${DATE}${NC} ${GRAY}│${NC} ${RED}${ICON_CROSS} ${BOLD}$IP${NC}"
    done
  else
    echo -e "  ${RED}${ICON_CROSS} Лог Fail2ban не найден${NC}"
  fi
  echo ""
}

function unban_all() {
  echo -e "${YELLOW}${ICON_INFO} Разблокировка всех IP адресов...${NC}"
  if systemctl is-active --quiet fail2ban; then
    fail2ban-client unban --all
    echo -e "${GREEN}${ICON_CHECK} Все IP адреса разблокированы${NC}"
  else
    echo -e "${RED}${ICON_CROSS} Fail2ban не запущен${NC}"
  fi
}

# Helper function: Get list of active jails (с таймаутом)
function get_active_jails() {
  if command -v fail2ban-client &>/dev/null && systemctl is-active --quiet fail2ban; then
    timeout $F2B_TIMEOUT fail2ban-client status 2>/dev/null | grep "Jail list:" | cut -d: -f2 | tr -d ' 	'
  fi
}

# Helper function: Validate IP address format
function validate_ip() {
  local ip="$1"
  [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]
}

# Helper function: Unban IP from all or specific jail
function unban_ip_from_jails() {
  local ip="$1"
  local specific_jail="$2"
  local unbanned=false
  
  if ! validate_ip "$ip"; then
    echo -e "${RED}${ICON_CROSS} Неверный формат IP адреса${NC}"
    return 1
  fi
  
  if ! systemctl is-active --quiet fail2ban; then
    echo -e "${RED}${ICON_CROSS} Fail2ban не запущен${NC}"
    return 1
  fi
  
  if [ -n "$specific_jail" ]; then
    # Unban from specific jail
    if fail2ban-client set "$specific_jail" unbanip "$ip" 2>/dev/null; then
      echo -e "${GREEN}${ICON_CHECK} IP ${BOLD}$ip${NC} разблокирован в ${BOLD}$specific_jail${NC}"
      return 0
    else
      echo -e "${RED}${ICON_CROSS} Не удалось разблокировать или IP не был заблокирован в ${BOLD}$specific_jail${NC}"
      return 1
    fi
  else
    # Unban from all jails
    local jails=$(get_active_jails)
    for jail in ${jails//,/ }; do
      if fail2ban-client set "$jail" unbanip "$ip" 2>/dev/null; then
        echo -e "${GREEN}${ICON_CHECK} IP ${BOLD}$ip${NC} разблокирован в ${BOLD}$jail${NC}"
        unbanned=true
      fi
    done
    
    if [ "$unbanned" = false ]; then
      echo -e "${YELLOW}${ICON_INFO} IP ${BOLD}$ip${NC} не был заблокирован ни в одном jail${NC}"
      return 1
    fi
  fi
  return 0
}

# Helper function: Show all banned IPs
function show_all_banned_ips() {
  echo -e "${BOLD}${RED}${ICON_FIRE} Заблокированные IP адреса${NC}"
  echo ""
  
  if ! systemctl is-active --quiet fail2ban; then
    echo -e "  ${RED}${ICON_CROSS} Fail2ban не запущен${NC}"
    return 1
  fi
  
  local jails=$(get_active_jails)
  local found_bans=false
  
  for jail in ${jails//,/ }; do
    local banned=$(fail2ban-client status "$jail" 2>/dev/null | grep 'Banned IP list:' | cut -d: -f2)
    if [ -n "$banned" ] && [ "$banned" != " " ]; then
      echo -e "  ${YELLOW}${ICON_LOCK} ${BOLD}$jail${NC} ${GRAY}│${NC} ${RED}$banned${NC}"
      found_bans=true
    fi
  done
  
  if [ "$found_bans" = false ]; then
    echo -e "  ${GREEN}${ICON_CHECK} Заблокированных IP адресов нет${NC}"
  fi
  echo ""
}

# Helper function: Quick SSH protection setup
function quick_ssh_protection_setup() {
  echo ""
  echo -e "${BOLD}${CYAN}${ICON_ROCKET} БЫСТРАЯ УСТАНОВКА SSH ЗАЩИТЫ${NC}"
  echo ""
  
  echo -e "${BLUE}${ICON_INFO} Установка и настройка Fail2ban...${NC}"
  install_fail2ban
  echo ""
  
  echo -e "${BLUE}${ICON_INFO} Определение SSH порта...${NC}"
  detect_ssh_port
  echo ""
  
  echo -e "${BLUE}${ICON_INFO} Настройка конфигурации...${NC}"
  backup_and_configure_fail2ban
  echo ""
  
  echo -e "${BLUE}${ICON_INFO} Перезапуск сервиса...${NC}"
  restart_fail2ban
  echo ""
  
  echo -e "${BLUE}${ICON_INFO} Настройка firewall...${NC}"
  allow_firewall_port
  echo ""
  
  echo -e "${BOLD}${GREEN}${ICON_CHECK} SSH ЗАЩИТА НАСТРОЕНА!${NC}"
  echo ""
  echo -e "${CYAN}${ICON_INFO} Для установки быстрых команд:${NC}"
  echo -e "  ${WHITE}sudo $0 --install-system${NC}"
  echo ""
}

# Helper function: Display menu
function display_interactive_menu() {
  echo -e "${BOLD}${CYAN}${ICON_BOOK} ГЛАВНОЕ МЕНЮ${NC}"
  echo ""
  
  echo -e "${DIM}Установка и настройка:${NC}"
  echo -e "  ${CYAN}1${NC}  ${ICON_ROCKET} Быстрая установка SSH защиты"
  echo -e "  ${CYAN}2${NC}  ${ICON_GEAR} Управление сервисами (SSH, Nginx, Caddy...)"
  echo ""
  
  echo -e "${DIM}Мониторинг:${NC}"
  echo -e "  ${CYAN}3${NC}  ${ICON_CHART} Подробный статус"
  echo -e "  ${CYAN}4${NC}  ${ICON_FIRE} Заблокированные IP (все сервисы)"
  echo -e "  ${CYAN}5${NC}  ${ICON_BOOK} Последние блокировки (20 шт)"
  echo ""
  
  echo -e "${DIM}Управление блокировками:${NC}"
  echo -e "  ${CYAN}6${NC}  ${ICON_ARROW} Разблокировать конкретный IP"
  echo -e "  ${CYAN}7${NC}  ${ICON_WARNING} Разблокировать ВСЕ IP"
  echo ""
  
  echo -e "${DIM}Система:${NC}"
  echo -e "  ${CYAN}8${NC}  ${ICON_GEAR} Включить/Выключить Fail2ban"
  echo -e "  ${CYAN}9${NC}  🔄 Перезапустить Fail2ban"
  echo -e " ${CYAN}10${NC}  ${ICON_CHECK} Проверить согласованность SSH портов"
  echo -e " ${CYAN}11${NC}  ${ICON_BOOK} Просмотр логов Fail2ban"
  echo -e " ${CYAN}12${NC}  ${ICON_ROCKET} Проверить обновления скрипта"
  echo -e " ${CYAN}13${NC}  ${ICON_GEAR} Установить f2b команду в систему"
  echo -e " ${CYAN}14${NC}  🗑️  Удалить f2b команду из системы"
  echo ""
  
  echo -e "  ${RED}0${NC}  Выход"
  echo ""
  echo -ne "${YELLOW}${ICON_ARROW}${NC} Выберите опцию ${DIM}[0-14]${NC}: "
}

# Helper function: Show detailed status for all jails
function show_detailed_status() {
  echo -e "${GREEN}Detailed Status:${NC}"
  
  if ! command -v fail2ban-client &>/dev/null || ! systemctl is-active --quiet fail2ban; then
    echo -e "${RED}Fail2ban not running${NC}"
    return 1
  fi
  
  fail2ban-client status
  echo ""
  
  local jails=$(get_active_jails)
  for jail in ${jails//,/ }; do
    echo -e "${CYAN}═══ $jail ═══${NC}"
    fail2ban-client status "$jail"
    echo ""
  done
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
    echo -e "${CYAN} 8.${NC} ${ICON_GEAR} Detect Installed Services"
    echo -e "${RED} 0.${NC} Back to Main Menu"
    echo ""
    echo -ne "${YELLOW}Select service [0-8]:${NC} "
    
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
      8) show_detected_services ;;
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
  if ! systemctl is-active --quiet fail2ban; then
    echo -e "${RED}Fail2ban not running${NC}"
    echo ""
    return
  fi
  
  local jails=$(get_active_jails)
  if [ -n "$jails" ]; then
    echo -e "${GREEN}Active Jails: ${CYAN}${jails//,/, }${NC}"
  else
    echo -e "${YELLOW}No active jails${NC}"
  fi
  echo ""
}

function manage_service_jail() {
  local service="$1"
  local service_name="$2"
  
  # Валидация входных параметров
  if [ -z "$service" ] || [ -z "$service_name" ]; then
    echo -e "${RED}Error: Service name and description are required${NC}"
    return 1
  fi
  
  while true; do
    print_header
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${WHITE}               $service_name PROTECTION               ${BLUE}║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Проверяем статус jail'а
    local jail_status="INACTIVE"
    local jail_color="${RED}"
    if is_f2b_running; then
      if fail2ban-client status "$service" &>/dev/null; then
        jail_status="ACTIVE"
        jail_color="${GREEN}"
        
        # Показываем статистику
        show_jail_stats "$service" ""
        echo ""
      fi
    fi
    
    # Показываем информацию о сервисе
    local service_location="not found"
    local docker_info=""
    if is_service_installed "$service"; then
      if is_service_in_docker "$service"; then
        local container_name
        container_name=$(get_docker_container_name "$service")
        docker_info=" ${CYAN}🐳 Docker: ${container_name}${NC}"
      fi
      service_location="installed"
    fi
    
    echo -e "Jail Status: ${jail_color}$jail_status${NC}${docker_info}"
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
  
  if [ -f "$JAIL_LOCAL" ]; then
    # Показываем конфигурацию конкретного jail'а
    awk "/^\[$service\]/,/^\[/{if(/^\[/ && !/^\[$service\]/) exit; print}" "$JAIL_LOCAL"
  else
    echo -e "${RED}No jail.local configuration found${NC}"
  fi
}

function show_service_logs() {
  local service="$1"
  local service_name="$2"
  
  echo -e "${GREEN}$service_name related logs (last 20):${NC}"
  echo -e "${CYAN}─────────────────────────────${NC}"
  
  if [ -f "$F2B_LOG" ]; then
    grep "\[$service\]" "$F2B_LOG" | tail -20
  else
    echo -e "${RED}No fail2ban log found${NC}"
  fi
}

function create_service_jail_config() {
  local service="$1"
  
  # Создаем резервную копию
  backup_jail_local
  
  # Если файл не существует, создаем базовый
  if [ ! -f "$JAIL_LOCAL" ]; then
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

EOF
  fi
  
  # Добавляем конфигурацию для конкретного сервиса
  case "$service" in
    "sshd")
      local ssh_port
      ssh_port=$(grep -Po '(?<=^Port )\d+' /etc/ssh/sshd_config | head -n1)
      ssh_port=${ssh_port:-22}
      local ssh_log_path
      ssh_log_path=$(get_ssh_log_path)
      add_jail_config "$service" "enabled = true" "port = $ssh_port" "filter = sshd" "logpath = $ssh_log_path" "maxretry = 3" "bantime = 600"
      ;;
    "nginx")
      # Автодетект пути к логам
      local nginx_error_log
      nginx_error_log=$(get_nginx_log_path "error")
      local nginx_access_log
      nginx_access_log=$(get_nginx_log_path "access")
      
      # Проверяем существование логов
      if [ ! -f "$nginx_error_log" ]; then
        echo -e "${YELLOW}${ICON_WARNING} Лог Nginx не найден: ${nginx_error_log}${NC}"
        if is_service_in_docker "nginx"; then
          echo -e "${CYAN}${ICON_INFO} Nginx работает в Docker. Убедитесь, что логи примонтированы на хост.${NC}"
          echo -e "${GRAY}   Пример: -v /var/log/nginx:/var/log/nginx${NC}"
        fi
        echo -ne "${CYAN}Введите путь к error.log вручную (или Enter для пропуска):${NC} "
        read -r manual_path
        if [ -n "$manual_path" ] && [ -f "$manual_path" ]; then
          nginx_error_log="$manual_path"
        elif [ -n "$manual_path" ]; then
          echo -e "${YELLOW}Файл не найден, используем указанный путь${NC}"
          nginx_error_log="$manual_path"
        fi
      fi
      
      echo -e "${GREEN}${ICON_CHECK} Используем лог: ${nginx_error_log}${NC}"
      
      # Nginx HTTP Auth failures
      add_jail_config "nginx-http-auth" "enabled = true" "port = http,https" "filter = nginx-http-auth" "logpath = $nginx_error_log" "maxretry = 3" "bantime = 600"
      
      # Nginx limit requests (too many requests)
      add_jail_config "nginx-limit-req" "enabled = true" "port = http,https" "filter = nginx-limit-req" "logpath = $nginx_error_log" "maxretry = 10" "findtime = 600" "bantime = 600"
      
      # Nginx botsearch (сканирование уязвимостей) - используем access log
      if [ -f "$nginx_access_log" ]; then
        create_nginx_botsearch_filter
        add_jail_config "nginx-botsearch" "enabled = true" "port = http,https" "filter = nginx-botsearch" "logpath = $nginx_access_log" "maxretry = 5" "findtime = 600" "bantime = 3600"
      fi
      ;;
    "caddy")
      # Создаем фильтр для Caddy (его нет в стандартном fail2ban)
      create_caddy_filter
      
      # Автодетект пути к логам
      local caddy_log
      caddy_log=$(get_caddy_log_path)
      
      if [ "$caddy_log" = "systemd-journal" ]; then
        echo -e "${CYAN}${ICON_INFO} Caddy использует systemd journal для логирования${NC}"
        echo -e "${YELLOW}${ICON_WARNING} Для работы Fail2ban настройте логирование Caddy в файл${NC}"
        echo -e "${GRAY}   В Caddyfile добавьте:${NC}"
        echo -e "${GRAY}   log {${NC}"
        echo -e "${GRAY}     output file /var/log/caddy/access.log${NC}"
        echo -e "${GRAY}     format json${NC}"
        echo -e "${GRAY}   }${NC}"
        return 1
      fi
      
      if [ ! -f "$caddy_log" ]; then
        echo -e "${YELLOW}${ICON_WARNING} Лог Caddy не найден: ${caddy_log}${NC}"
        if is_service_in_docker "caddy"; then
          echo -e "${CYAN}${ICON_INFO} Caddy работает в Docker. Убедитесь, что логи примонтированы.${NC}"
          echo -e "${GRAY}   Пример: -v /var/log/caddy:/var/log/caddy${NC}"
        fi
        echo -ne "${CYAN}Введите путь к логу вручную (или Enter для пропуска):${NC} "
        read -r manual_path
        if [ -n "$manual_path" ]; then
          caddy_log="$manual_path"
        fi
      fi
      
      echo -e "${GREEN}${ICON_CHECK} Используем лог: ${caddy_log}${NC}"
      add_jail_config "$service" "enabled = true" "port = http,https" "filter = caddy-auth" "logpath = $caddy_log" "maxretry = 3" "bantime = 600"
      ;;
    "mysql")
      local mysql_log
      mysql_log=$(get_mysql_log_path)
      
      if [ ! -f "$mysql_log" ]; then
        echo -e "${YELLOW}${ICON_WARNING} Лог MySQL/MariaDB не найден: ${mysql_log}${NC}"
        if is_service_in_docker "mysql" || is_service_in_docker "mariadb"; then
          echo -e "${CYAN}${ICON_INFO} MySQL/MariaDB работает в Docker.${NC}"
          echo -e "${GRAY}   Пример: -v /var/log/mysql:/var/log/mysql${NC}"
        fi
        echo -ne "${CYAN}Введите путь к логу (или Enter для пропуска):${NC} "
        read -r manual_path
        if [ -n "$manual_path" ]; then
          mysql_log="$manual_path"
        fi
      fi
      
      echo -e "${GREEN}${ICON_CHECK} Используем лог: ${mysql_log}${NC}"
      add_jail_config "mysqld-auth" "enabled = true" "port = 3306" "filter = mysqld-auth" "logpath = $mysql_log" "maxretry = 3" "bantime = 600"
      ;;
    "phpmyadmin")
      add_jail_config "phpmyadmin-syslog" "enabled = true" "port = http,https" "filter = phpmyadmin-syslog" "logpath = /var/log/syslog" "maxretry = 3" "bantime = 600"
      ;;
  esac
}

# Helper function: Create backup of jail.local
function backup_jail_local() {
  if [ -f "$JAIL_LOCAL" ]; then
    cp "$JAIL_LOCAL" "${JAIL_LOCAL}.bak_$(date +%Y%m%d_%H%M%S)" 2>/dev/null
  fi
}

function add_jail_config() {
  local jail_name="$1"
  shift
  
  # Создаем резервную копию перед изменениями
  backup_jail_local
  
  # Удаляем существующую конфигурацию если есть
  sed -i "/^\[$jail_name\]/,/^\[/{/^\[/ {/^\[$jail_name\]/!b}; d}" "$JAIL_LOCAL"
  
  # Добавляем новую конфигурацию
  echo "" >> "$JAIL_LOCAL"
  echo "[$jail_name]" >> "$JAIL_LOCAL"
  for config in "$@"; do
    echo "$config" >> "$JAIL_LOCAL"
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
  local jails=$(get_active_jails)
  
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
  local jails=$(get_active_jails)
  
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
      sed -i "/^\[$jail_name\]/,/^\[/{/^\[/ {/^\[$jail_name\]/!b}; d}" "$JAIL_LOCAL"
      
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
  
  if [ -f "$JAIL_LOCAL" ]; then
    cat "$JAIL_LOCAL"
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
    display_interactive_menu
    
    read -r choice
    echo ""
    
    case $choice in
      1)
        quick_ssh_protection_setup
        ;;
      2)
        manage_services_menu
        ;;
      3)
        echo ""
        show_detailed_status
        ;;
      4)
        echo ""
        show_all_banned_ips
        ;;
      5)
        echo ""
        show_recent_bans
        ;;
      6)
        echo -ne "${CYAN}Enter IP address to unban:${NC} "
        read -r ip
        echo -e "${YELLOW}Unbanning $ip from all jails...${NC}"
        unban_ip_from_jails "$ip"
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
        echo -e "${YELLOW}Restarting Fail2ban...${NC}"
        systemctl restart fail2ban
        if systemctl is-active --quiet fail2ban; then
          echo -e "${GREEN}✓ Fail2ban restarted successfully${NC}"
        else
          echo -e "${RED}✗ Failed to restart Fail2ban${NC}"
        fi
        ;;
      10)
        echo ""
        check_ssh_port_consistency
        ;;
      11)
        echo -e "${GREEN}Fail2ban Log (last 30 lines):${NC}"
        echo -e "${CYAN}─────────────────────────────${NC}"
        if [ -f "$F2B_LOG" ]; then
          tail -30 "$F2B_LOG"
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
        echo -e "${GREEN}Goodbye!${NC}"
        exit 0
        ;;
      *)
        echo -e "${RED}Invalid option. Please try again.${NC}"
        ;;
    esac
    
    if [ "$choice" != "0" ]; then
      echo ""
      echo -e "${YELLOW}Press Enter to continue...${NC}"
      read -r
    fi
  done
}

function detect_os() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$NAME
    OS_ID=$ID
    VERSION=$VERSION_ID
  elif type lsb_release >/dev/null 2>&1; then
    OS=$(lsb_release -si)
    VERSION=$(lsb_release -sr)
  elif [ -f /etc/lsb-release ]; then
    . /etc/lsb-release
    OS=$DISTRIB_ID
    VERSION=$DISTRIB_RELEASE
  elif [ -f /etc/debian_version ]; then
    OS=Debian
    VERSION=$(cat /etc/debian_version)
  elif [ -f /etc/redhat-release ]; then
    OS=$(cat /etc/redhat-release | awk '{print $1}')
    VERSION=$(cat /etc/redhat-release | grep -o '[0-9]\+\.[0-9]\+' | head -1)
  else
    OS=$(uname -s)
    VERSION=$(uname -r)
  fi
}

function get_ssh_log_path() {
  # Определяем путь к SSH логам в зависимости от ОС
  detect_os
  
  case "$OS_ID" in
    ubuntu|debian)
      echo "/var/log/auth.log"
      ;;
    almalinux|rocky|rhel|centos|fedora)
      echo "/var/log/secure"
      ;;
    opensuse*|sles)
      echo "/var/log/messages"
      ;;
    arch)
      echo "/var/log/auth.log"
      ;;
    *)
      # Пробуем найти существующий лог файл
      if [ -f "/var/log/auth.log" ]; then
        echo "/var/log/auth.log"
      elif [ -f "/var/log/secure" ]; then
        echo "/var/log/secure"
      elif [ -f "/var/log/messages" ]; then
        echo "/var/log/messages"
      else
        echo "/var/log/auth.log"  # По умолчанию
      fi
      ;;
  esac
}

# ═══════════════════════════════════════════════════════════════════
# ФУНКЦИИ АВТОДЕТЕКТА СЕРВИСОВ И ЛОГОВ
# ═══════════════════════════════════════════════════════════════════

# Проверка, запущен ли Fail2ban
function is_f2b_running() {
  systemctl is-active --quiet fail2ban
}

# Проверка, установлен ли сервис (нативно или в Docker)
function is_service_installed() {
  local service="$1"
  
  # Проверяем нативную установку
  case "$service" in
    nginx)
      command -v nginx &>/dev/null && return 0
      ;;
    caddy)
      command -v caddy &>/dev/null && return 0
      ;;
    mysql|mariadb)
      command -v mysql &>/dev/null || command -v mariadb &>/dev/null && return 0
      ;;
  esac
  
  # Проверяем Docker контейнеры
  if command -v docker &>/dev/null; then
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qi "$service" && return 0
  fi
  
  return 1
}

# Проверка, работает ли сервис в Docker
function is_service_in_docker() {
  local service="$1"
  if command -v docker &>/dev/null; then
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qi "$service"
    return $?
  fi
  return 1
}

# Получить имя Docker контейнера для сервиса
function get_docker_container_name() {
  local service="$1"
  if command -v docker &>/dev/null; then
    docker ps --format '{{.Names}}' 2>/dev/null | grep -i "$service" | head -1
  fi
}

# Автодетект пути к логам Nginx
function get_nginx_log_path() {
  local log_type="${1:-error}"  # error или access
  local log_paths=()
  
  # Стандартные пути
  if [ "$log_type" = "error" ]; then
    log_paths=(
      "/var/log/nginx/error.log"
      "/var/log/nginx/errors.log"
      "/usr/local/nginx/logs/error.log"
      "/opt/nginx/logs/error.log"
    )
  else
    log_paths=(
      "/var/log/nginx/access.log"
      "/usr/local/nginx/logs/access.log"
      "/opt/nginx/logs/access.log"
    )
  fi
  
  # Проверяем стандартные пути
  for path in "${log_paths[@]}"; do
    if [ -f "$path" ]; then
      echo "$path"
      return 0
    fi
  done
  
  # Проверяем Docker volumes (популярные паттерны)
  local docker_log_paths=(
    "/var/lib/docker/volumes/*nginx*/_data/${log_type}.log"
    "/var/lib/docker/volumes/*nginx*/_data/logs/${log_type}.log"
    "/opt/docker/nginx/logs/${log_type}.log"
    "/opt/nginx-proxy/logs/${log_type}.log"
    "/data/nginx/logs/${log_type}.log"
    "$HOME/docker/nginx/logs/${log_type}.log"
  )
  
  for pattern in "${docker_log_paths[@]}"; do
    # Используем compgen для glob expansion
    local found_path
    found_path=$(compgen -G "$pattern" 2>/dev/null | head -1)
    if [ -n "$found_path" ] && [ -f "$found_path" ]; then
      echo "$found_path"
      return 0
    fi
  done
  
  # Пробуем получить путь из конфигурации nginx
  if command -v nginx &>/dev/null; then
    local nginx_conf_path
    nginx_conf_path=$(nginx -V 2>&1 | grep -oP '(?<=--conf-path=)[^\s]+')
    if [ -n "$nginx_conf_path" ] && [ -f "$nginx_conf_path" ]; then
      local log_from_conf
      log_from_conf=$(grep -Po "(?<=${log_type}_log\s)[^\s;]+" "$nginx_conf_path" 2>/dev/null | head -1)
      if [ -n "$log_from_conf" ] && [ -f "$log_from_conf" ]; then
        echo "$log_from_conf"
        return 0
      fi
    fi
  fi
  
  # Возвращаем стандартный путь если ничего не найдено
  echo "/var/log/nginx/${log_type}.log"
  return 1
}

# Автодетект пути к логам Caddy
function get_caddy_log_path() {
  local log_paths=(
    "/var/log/caddy/caddy.log"
    "/var/log/caddy/access.log"
    "/var/log/caddy/errors.log"
    "/var/log/caddy.log"
    "/opt/caddy/logs/access.log"
    "$HOME/.local/share/caddy/caddy.log"
  )
  
  # Проверяем стандартные пути
  for path in "${log_paths[@]}"; do
    if [ -f "$path" ]; then
      echo "$path"
      return 0
    fi
  done
  
  # Проверяем Docker volumes
  local docker_log_paths=(
    "/var/lib/docker/volumes/*caddy*/_data/*.log"
    "/var/lib/docker/volumes/*caddy*/_data/logs/*.log"
    "/opt/docker/caddy/logs/*.log"
    "/data/caddy/logs/*.log"
    "$HOME/docker/caddy/logs/*.log"
  )
  
  for pattern in "${docker_log_paths[@]}"; do
    local found_path
    found_path=$(compgen -G "$pattern" 2>/dev/null | head -1)
    if [ -n "$found_path" ] && [ -f "$found_path" ]; then
      echo "$found_path"
      return 0
    fi
  done
  
  # Пробуем найти через systemd
  if systemctl is-active --quiet caddy 2>/dev/null; then
    # Caddy может логировать в journald
    echo "systemd-journal"
    return 0
  fi
  
  # Возвращаем стандартный путь
  echo "/var/log/caddy/access.log"
  return 1
}

# Автодетект пути к логам MySQL/MariaDB
function get_mysql_log_path() {
  local log_paths=(
    "/var/log/mysql/error.log"
    "/var/log/mariadb/mariadb.log"
    "/var/log/mysqld.log"
    "/var/lib/mysql/*.err"
  )
  
  for path in "${log_paths[@]}"; do
    local found_path
    found_path=$(compgen -G "$path" 2>/dev/null | head -1)
    if [ -n "$found_path" ] && [ -f "$found_path" ]; then
      echo "$found_path"
      return 0
    fi
  done
  
  # Docker volumes
  local docker_paths=(
    "/var/lib/docker/volumes/*mysql*/_data/*.err"
    "/var/lib/docker/volumes/*mariadb*/_data/*.err"
    "/opt/docker/mysql/logs/*.log"
  )
  
  for pattern in "${docker_paths[@]}"; do
    local found_path
    found_path=$(compgen -G "$pattern" 2>/dev/null | head -1)
    if [ -n "$found_path" ] && [ -f "$found_path" ]; then
      echo "$found_path"
      return 0
    fi
  done
  
  echo "/var/log/mysql/error.log"
  return 1
}

# Создание фильтра для Caddy (его нет в стандартном fail2ban)
function create_caddy_filter() {
  local filter_file="${F2B_FILTER_DIR}/caddy-auth.conf"
  
  if [ ! -d "$F2B_FILTER_DIR" ]; then
    mkdir -p "$F2B_FILTER_DIR"
  fi
  
  # Создаем фильтр только если его нет
  if [ ! -f "$filter_file" ]; then
    cat > "$filter_file" <<'EOF'
# Fail2Ban filter for Caddy web server
# Matches failed authentication attempts and suspicious requests

[Definition]

# Caddy JSON log format (common setup)
# Match 401/403 responses
failregex = ^.*"client_ip":\s*"<HOST>".*"status":\s*(401|403).*$
            ^.*"remote_ip":\s*"<HOST>".*"status":\s*(401|403).*$
            ^<HOST> - .* "(GET|POST|HEAD|PUT|DELETE|PATCH).*" (401|403) .*$
            ^.*"request":\{.*"remote_ip":\s*"<HOST>".*"status":\s*(401|403).*$

# Common Log Format fallback
# ^<HOST> - .* \[.*\] ".*" (401|403) .*$

ignoreregex =

# Author: f2b.sh auto-generated
EOF
    echo -e "${GREEN}${ICON_CHECK} Создан фильтр Caddy: ${filter_file}${NC}"
    return 0
  fi
  return 0
}

# Создание фильтра для Nginx botsearch (сканеры уязвимостей)
function create_nginx_botsearch_filter() {
  local filter_file="${F2B_FILTER_DIR}/nginx-botsearch.conf"
  
  if [ ! -f "$filter_file" ]; then
    cat > "$filter_file" <<'EOF'
# Fail2Ban filter for Nginx - Bot/Scanner detection
# Blocks IPs scanning for vulnerabilities

[Definition]

failregex = ^<HOST> -.*"(GET|POST|HEAD).*(\.php|\.asp|\.exe|\.pl|\.cgi|\.env|\.git|wp-login|wp-admin|phpmyadmin|admin|mysql|setup|install|config).*" (404|403|400) .*$
            ^<HOST> -.*"(GET|POST|HEAD).*/\.\." .* (400|403|404) .*$

ignoreregex = \.(?:js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)

# Author: f2b.sh auto-generated
EOF
    echo -e "${GREEN}${ICON_CHECK} Создан фильтр nginx-botsearch: ${filter_file}${NC}"
  fi
}

# Показать информацию о найденных сервисах
function show_detected_services() {
  echo -e "${BOLD}${CYAN}${ICON_GEAR} Обнаруженные сервисы:${NC}"
  echo ""
  
  local services=("nginx" "caddy" "mysql" "mariadb")
  
  for service in "${services[@]}"; do
    local status_icon="${RED}${ICON_CROSS}${NC}"
    local status_text="не найден"
    local location=""
    
    if is_service_installed "$service"; then
      if is_service_in_docker "$service"; then
        status_icon="${CYAN}🐳${NC}"
        local container_name
        container_name=$(get_docker_container_name "$service")
        status_text="Docker: ${CYAN}${container_name}${NC}"
      else
        status_icon="${GREEN}${ICON_CHECK}${NC}"
        status_text="установлен нативно"
      fi
      
      # Показываем путь к логам
      case "$service" in
        nginx)
          location=$(get_nginx_log_path)
          ;;
        caddy)
          location=$(get_caddy_log_path)
          ;;
        mysql|mariadb)
          location=$(get_mysql_log_path)
          ;;
      esac
    fi
    
    echo -e "  ${status_icon} ${BOLD}${service}${NC}: ${status_text}"
    if [ -n "$location" ] && [ "$location" != "systemd-journal" ]; then
      if [ -f "$location" ]; then
        echo -e "     ${DIM}Лог: ${location}${NC}"
      else
        echo -e "     ${YELLOW}Лог не найден: ${location}${NC}"
      fi
    elif [ "$location" = "systemd-journal" ]; then
      echo -e "     ${DIM}Лог: systemd journal${NC}"
    fi
  done
  echo ""
}

function install_fail2ban() {
  if ! command -v fail2ban-server &>/dev/null; then
    echo -e "${YELLOW}Installing Fail2ban...${NC}"
    
    # Определяем операционную систему
    detect_os
    
    case "$OS_ID" in
      ubuntu|debian)
        echo -e "${CYAN}Detected: $OS${NC}"
        apt update && apt install -y fail2ban || { echo -e "${RED}Failed to install fail2ban${NC}"; exit 1; }
        ;;
      almalinux|rocky|rhel|centos|fedora)
        echo -e "${CYAN}Detected: $OS${NC}"
        if command -v dnf &>/dev/null; then
          # AlmaLinux 8+, Rocky Linux, RHEL 8+, Fedora
          dnf install -y epel-release && dnf install -y fail2ban || { echo -e "${RED}Failed to install fail2ban${NC}"; exit 1; }
        elif command -v yum &>/dev/null; then
          # CentOS 7, RHEL 7
          yum install -y epel-release && yum install -y fail2ban || { echo -e "${RED}Failed to install fail2ban${NC}"; exit 1; }
        else
          echo -e "${RED}No package manager found (dnf/yum)${NC}"
          exit 1
        fi
        ;;
      opensuse*|sles)
        echo -e "${CYAN}Detected: $OS${NC}"
        zypper install -y fail2ban || { echo -e "${RED}Failed to install fail2ban${NC}"; exit 1; }
        ;;
      arch)
        echo -e "${CYAN}Detected: $OS${NC}"
        pacman -S --noconfirm fail2ban || { echo -e "${RED}Failed to install fail2ban${NC}"; exit 1; }
        ;;
      *)
        echo -e "${YELLOW}Unknown OS: $OS${NC}"
        echo -e "${YELLOW}Trying apt (Debian/Ubuntu)...${NC}"
        apt update && apt install -y fail2ban || {
          echo -e "${YELLOW}Trying dnf (RHEL/AlmaLinux/Rocky)...${NC}"
          dnf install -y epel-release && dnf install -y fail2ban || {
            echo -e "${YELLOW}Trying yum (CentOS)...${NC}"
            yum install -y epel-release && yum install -y fail2ban || {
              echo -e "${RED}Failed to install fail2ban on this system${NC}"
              echo -e "${CYAN}Please install fail2ban manually and run this script again${NC}"
              exit 1
            }
          }
        }
        ;;
    esac
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
  if [ -f "$JAIL_LOCAL" ]; then
    F2B_SSH_PORT=$(grep -A 10 "\[sshd\]" "$JAIL_LOCAL" | grep "^port" | cut -d'=' -f2 | tr -d ' ')
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
  
  if [ -f "$JAIL_LOCAL" ]; then
    # Создаем резервную копию
    cp "$JAIL_LOCAL" "${JAIL_LOCAL}.bak_$(date +%Y%m%d_%H%M%S)"
    
    # Обновляем порт в конфиге
    sed -i "/^\[sshd\]/,/^\[/ s/^port = .*/port = $new_port/" "$JAIL_LOCAL"
    
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
  # Создаем директорию fail2ban если её нет
  if [ ! -d "/etc/fail2ban" ]; then
    mkdir -p /etc/fail2ban
    echo -e "${YELLOW}Created /etc/fail2ban directory${NC}"
  fi
  
  # Создаем резервную копию если файл существует
  if [ -f "$JAIL_LOCAL" ]; then
    cp -f "$JAIL_LOCAL" "${JAIL_LOCAL}.bak_$(date +%Y%m%d_%H%M%S)" 2>/dev/null
  fi

  # Получаем правильный путь к SSH логам
  local ssh_log_path=$(get_ssh_log_path)

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
logpath = $ssh_log_path
EOF

  echo -e "${GREEN}Fail2ban configured with dynamic SSH blocking.${NC}"
}

function restart_fail2ban() {
  # Сначала включаем службу в systemd если она не включена
  if ! systemctl is-enabled --quiet fail2ban 2>/dev/null; then
    systemctl enable fail2ban 2>/dev/null
    echo -e "${YELLOW}Enabling Fail2ban service in systemd...${NC}"
  fi
  
  # Перезапускаем службу
  systemctl restart fail2ban
  sleep 2
  
  # Проверяем статус
  if systemctl is-active --quiet fail2ban; then
    echo -e "${GREEN}Fail2ban service is running.${NC}"
  else
    echo -e "${RED}Fail2ban failed to start. Check the config!${NC}"
    
    # Показываем более подробную информацию об ошибке
    echo -e "${YELLOW}Checking Fail2ban status...${NC}"
    systemctl status fail2ban --no-pager || true
    
    # Пробуем показать детали конфигурации
    if command -v fail2ban-client &>/dev/null; then
      echo -e "${YELLOW}Testing Fail2ban configuration...${NC}"
      fail2ban-client -d || true
    fi
    
    exit 1
  fi
}

function allow_firewall_port() {
  # Определяем ОС для выбора подходящего файервола
  detect_os
  
  if command -v ufw > /dev/null; then
    # Ubuntu/Debian с UFW
    ufw allow "$SSH_PORT"/tcp || true
    echo -e "${YELLOW}UFW: allowed SSH port $SSH_PORT${NC}"
  elif command -v firewall-cmd > /dev/null; then
    # RHEL/CentOS/AlmaLinux/Rocky с firewalld
    firewall-cmd --permanent --add-port="$SSH_PORT"/tcp || true
    firewall-cmd --reload || true
    echo -e "${YELLOW}Firewalld: allowed SSH port $SSH_PORT${NC}"
  elif command -v iptables > /dev/null; then
    # Fallback к iptables
    iptables -A INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT || true
    echo -e "${YELLOW}iptables: allowed SSH port $SSH_PORT${NC}"
    echo -e "${CYAN}Note: iptables rules may not persist after reboot${NC}"
  else
    echo -e "${YELLOW}No supported firewall found (ufw/firewalld/iptables)${NC}"
    echo -e "${CYAN}Please manually allow SSH port $SSH_PORT in your firewall${NC}"
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
    
    echo -e "${BOLD}${CYAN}${ICON_ROCKET} ПОЛНАЯ УСТАНОВКА И НАСТРОЙКА${NC}"
    echo ""
    
    # Шаг 1: Установка Fail2ban
    echo -e "${BLUE}[${CYAN}1/3${BLUE}]${NC} ${ICON_INFO} Установка пакета Fail2ban..."
    install_fail2ban
    echo ""
    
    # Шаг 2: Настройка SSH защиты
    echo -e "${BLUE}[${CYAN}2/3${BLUE}]${NC} ${ICON_GEAR} Настройка SSH защиты..."
    detect_ssh_port
    backup_and_configure_fail2ban
    restart_fail2ban
    allow_firewall_port
    echo ""
    
    # Шаг 3: Установка скрипта в систему
    echo -e "${BLUE}[${CYAN}3/3${BLUE}]${NC} ${ICON_ROCKET} Установка команды f2b..."
    if install_script_to_system "$VERSION_CHECK_URL"; then
      echo ""
      echo -e "${BOLD}${GREEN}${ICON_CHECK} УСТАНОВКА ЗАВЕРШЕНА!${NC}"
      echo ""
      echo -e "  ${GREEN}${ICON_CHECK}${NC} Fail2ban установлен и настроен"
      echo -e "  ${GREEN}${ICON_CHECK}${NC} SSH защита активна на порту ${BOLD}$SSH_PORT${NC}"
      echo -e "  ${GREEN}${ICON_CHECK}${NC} Команда f2b установлена в систему"
      echo ""
      echo -e "${BOLD}${CYAN}${ICON_STAR} Доступные команды${NC}"
      echo -e "  ${WHITE}f2b${NC}         Интерактивное меню"
      echo -e "  ${WHITE}f2b status${NC}  Проверить статус Fail2ban"
      echo -e "  ${WHITE}f2b stats${NC}   Показать статистику"
      echo -e "  ${WHITE}f2b banned${NC}  Показать заблокированные IP"
      echo -e "  ${WHITE}f2b help${NC}    Показать все команды"
      echo ""
    else
      echo -e "${YELLOW}${ICON_WARNING} Не удалось установить скрипт в систему${NC}"
      echo -e "${GREEN}${ICON_CHECK} SSH защита Fail2ban активна.${NC}"
      echo -e "${CYAN}${ICON_INFO} Для ручной установки команд f2b:${NC}"
      echo -e "  ${WHITE}sudo $0 --install-system${NC}"
    fi
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
    echo "Supported Operating Systems:"
    echo "  • Ubuntu/Debian (apt)"
    echo "  • AlmaLinux/Rocky Linux/RHEL/CentOS (dnf/yum)"
    echo "  • Fedora (dnf)"
    echo "  • openSUSE/SLES (zypper)"
    echo "  • Arch Linux (pacman)"
    echo ""
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Installation:"
    echo "  bash <(wget -qO- https://dignezzz.github.io/server/f2b.sh)          # Auto-install"
    echo "  bash <(wget -qO- https://dignezzz.github.io/server/f2b.sh) --menu   # Interactive menu only"
    echo ""
    echo "Options:"
    echo "  --install              Complete installation: Fail2ban + SSH protection + f2b command"
    echo "  --install-system [URL] Install only f2b script to system (/usr/local/bin/f2b)"
    echo "  --uninstall-system     Remove f2b script from system"
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
      check_root
      
      echo ""
      echo -e "${BOLD}${CYAN}${ICON_ROCKET} Автоматическая установка v$SCRIPT_VERSION${NC}"
      echo ""
      
      # Проверяем, установлен ли уже Fail2ban
      is_update=false
      if command -v fail2ban-server &>/dev/null; then
        echo -e "${GREEN}${ICON_CHECK} Fail2ban уже установлен${NC}"
        is_update=true
      fi
      echo ""
      
      # Шаг 1: Установка Fail2ban (если не установлен)
      if [ "$is_update" = false ]; then
        echo -e "${BLUE}[${CYAN}1/3${BLUE}]${NC} ${ICON_INFO} Установка Fail2ban..."
        install_fail2ban
        echo ""
      else
        echo -e "${BLUE}[${CYAN}1/3${BLUE}]${NC} ${GREEN}${ICON_CHECK} Fail2ban уже установлен - пропускаем${NC}"
        echo ""
      fi
      
      # Шаг 2: Настройка SSH защиты
      echo -e "${BLUE}[${CYAN}2/3${BLUE}]${NC} ${ICON_GEAR} Настройка SSH защиты..."
      detect_ssh_port
      backup_and_configure_fail2ban
      restart_fail2ban
      allow_firewall_port
      echo ""
      
      # Шаг 3: Установка скрипта в систему
      echo -e "${BLUE}[${CYAN}3/3${BLUE}]${NC} ${ICON_ROCKET} Установка f2b команды..."
      if install_script_to_system "$VERSION_CHECK_URL"; then
        echo ""
        echo -e "${BOLD}${GREEN}${ICON_CHECK} УСТАНОВКА ЗАВЕРШЕНА!${NC}"
        echo ""
        echo -e "  ${GREEN}${ICON_CHECK}${NC} Fail2ban установлен и настроен"
        echo -e "  ${GREEN}${ICON_CHECK}${NC} SSH защита активна на порту ${BOLD}$SSH_PORT${NC}"
        echo -e "  ${GREEN}${ICON_CHECK}${NC} Команда f2b установлена в систему"
        echo ""
        echo -e "${BOLD}${CYAN}${ICON_STAR} Доступные команды${NC}"
        echo -e "  ${WHITE}f2b${NC}         Интерактивное меню"
        echo -e "  ${WHITE}f2b status${NC}  Статус Fail2ban"
        echo -e "  ${WHITE}f2b stats${NC}   Статистика"
        echo -e "  ${WHITE}f2b banned${NC}  Заблокированные IP"
        echo -e "  ${WHITE}f2b help${NC}    Все команды"
        echo ""
        exit 0
      else
        echo -e "${RED}${ICON_CROSS} Ошибка установки скрипта в систему${NC}"
        exit 1
      fi
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
