#!/usr/bin/env bash
set -euo pipefail

# ufw-cleaner: автоматическая проверка и очистка неиспользуемых портов UFW
# Поддерживает --dry-run, логирование и внешний конфиг
# Версия: 2.0

# ==============================================================================
# Конфигурация (переопределяется из /etc/ufw-cleaner.conf)
# ==============================================================================

LOG=/var/log/ufw-cleaner.log
BACKUP_DIR=/var/backups/ufw
CONFIG_FILE=/etc/ufw-cleaner.conf
DRY_RUN=false

# Цвета для вывода
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Список внутренних сервисов, которые не нужно открывать (по умолчанию)
DEFAULT_INTERNAL_SERVICES=(
  "systemd-resolve"
  "systemd-network"
  "supervisord"
  "dnsmasq"
  "systemd"
  "rpcbind"
  "avahi"
  "cups"
  "dhcpd"
  "named"
  "ntpd"
  "sshd"  # SSH уже обрабатывается отдельно
  "docker-proxy"  # Внутренний механизм Docker
  "containerd"
  "dockerd"
)

# Список внутренних портов, которые не нужно открывать (по умолчанию)
DEFAULT_INTERNAL_PORTS=(
  "53/tcp"  # DNS
  "53/udp"  # DNS
  "67/udp"  # DHCP
  "68/udp"  # DHCP
  "123/udp" # NTP
  "631/tcp" # CUPS
  "631/udp" # CUPS
  "546/udp" # DHCPv6
  "5353/udp" # mDNS
  "2019/tcp" # Caddy admin API
)

# Инициализируем рабочие массивы
INTERNAL_SERVICES=("${DEFAULT_INTERNAL_SERVICES[@]}")
INTERNAL_PORTS=("${DEFAULT_INTERNAL_PORTS[@]}")

# ==============================================================================
# Загрузка внешнего конфига
# ==============================================================================

load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    echo -e "${CYAN}Загружаем конфигурацию из ${CONFIG_FILE}...${NC}"
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
    log "CONFIG loaded from $CONFIG_FILE"
  fi
}

# ==============================================================================
# Создание примера конфига
# ==============================================================================

create_sample_config() {
  cat << 'EOF'
# /etc/ufw-cleaner.conf - Конфигурация ufw-cleaner
# Раскомментируйте и измените нужные параметры

# Путь к лог-файлу
# LOG=/var/log/ufw-cleaner.log

# Директория для резервных копий
# BACKUP_DIR=/var/backups/ufw

# Дополнительные внутренние сервисы (не будут предлагаться к открытию)
# INTERNAL_SERVICES+=("myservice" "anotherservice")

# Дополнительные внутренние порты (не будут предлагаться к открытию)
# INTERNAL_PORTS+=("8080/tcp" "9000/udp")

# Порты, которые нужно игнорировать (никогда не удалять и не предлагать)
# IGNORE_PORTS=("22/tcp" "443/tcp" "80/tcp")

# Включить проверку systemd-сервисов (порты остановленных сервисов)
# CHECK_SYSTEMD=true
EOF
}

usage() {
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "Опции:"
  echo "  --dry-run        Симуляция без реальных изменений"
  echo "  --show-config    Показать пример конфигурационного файла"
  echo "  --create-config  Создать конфигурационный файл /etc/ufw-cleaner.conf"
  echo "  -h, --help       Показать эту справку"
  echo ""
  echo "Конфигурация: $CONFIG_FILE"
  exit 0
}

# Разбор опций
while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run) DRY_RUN=true; shift ;;
    --show-config) create_sample_config; exit 0 ;;
    --create-config)
      if [[ -f "$CONFIG_FILE" ]]; then
        echo "Конфиг уже существует: $CONFIG_FILE"
        exit 1
      fi
      create_sample_config > "$CONFIG_FILE"
      echo "Создан конфиг: $CONFIG_FILE"
      exit 0
      ;;
    -h|--help) usage ;;  
    *) usage ;;  
  esac
done

log() {
  # Проверяем возможность записи в лог
  if [[ -w "$LOG" ]] || [[ -w "$(dirname "$LOG")" ]]; then
    echo "$(date '+%F %T') $*" >> "$LOG" 2>/dev/null || true
  fi
}

ensure_root() {
  [[ $EUID -eq 0 ]] || { echo -e "${RED}Требуются root-права${NC}" >&2; exit 1; }
}

# ==============================================================================
# Резервное копирование правил UFW
# ==============================================================================

backup_rules() {
  local backup_file="${BACKUP_DIR}/ufw-backup-$(date '+%Y%m%d-%H%M%S').txt"
  
  # Создаём директорию для бэкапов
  mkdir -p "$BACKUP_DIR"
  
  echo -e "${CYAN}Создаём резервную копию правил UFW...${NC}"
  {
    echo "# UFW Backup - $(date)"
    echo "# Восстановление: скопируйте команды ниже"
    echo ""
    echo "# Текущий статус:"
    ufw status verbose
    echo ""
    echo "# Нумерованные правила:"
    ufw status numbered
    echo ""
    echo "# Команды для восстановления:"
    # Генерируем команды для восстановления
    ufw status numbered | grep -E '^\[' | while read -r line; do
      # Извлекаем правило без номера
      rule=$(echo "$line" | sed 's/^\[[0-9]*\][[:space:]]*//')
      port=$(echo "$rule" | awk '{print $1}')
      action=$(echo "$rule" | awk '{print $2}')
      direction=$(echo "$rule" | awk '{print $3}')
      
      if [[ "$action" == "ALLOW" ]]; then
        if [[ "$direction" == "IN" ]] || [[ -z "$direction" ]]; then
          echo "ufw allow $port"
        fi
      elif [[ "$action" == "DENY" ]]; then
        echo "ufw deny $port"
      fi
    done
  } > "$backup_file" 2>/dev/null || true
  
  if [[ -f "$backup_file" ]]; then
    echo -e "${GREEN}Резервная копия сохранена: ${backup_file}${NC}"
    log "BACKUP created: $backup_file"
  else
    echo -e "${YELLOW}Не удалось создать резервную копию${NC}"
  fi
}

# Начальный статус UFW
initial_active=false
if ufw status verbose 2>/dev/null | grep -q "Status: active"; then
  initial_active=true
fi

# Структуры данных
declare -A proto_map port_set used_map service_map rule_action rule_source
declare -a unused_ports missing_ports systemd_ports
declare -a IGNORE_PORTS=()  # Порты, которые нужно игнорировать
CHECK_SYSTEMD=${CHECK_SYSTEMD:-false}  # Проверка systemd-сервисов

# Список внутренних сервисов, которые не нужно открывать
INTERNAL_SERVICES=(
  "systemd-resolve"
  "supervisord"
  "dnsmasq"
  "systemd"
  "rpcbind"
  "avahi"
  "cups"
  "dhcpd"
  "named"
  "ntpd"
  "sshd"  # SSH уже обрабатывается отдельно
)

# Список внутренних портов, которые не нужно открывать
INTERNAL_PORTS=(
  "53/tcp"  # DNS
  "53/udp"  # DNS
  "67/udp"  # DHCP
  "68/udp"  # DHCP
  "123/udp" # NTP
  "631/tcp" # CUPS
  "631/udp" # CUPS
  "5353/udp" # mDNS
)

# Список высоких портов (эфемерные порты для исходящих соединений)
# Linux использует 32768-60999 (см. /proc/sys/net/ipv4/ip_local_port_range)
is_ephemeral_port() {
  local port=$1
  local proto=${port##*/}
  port=${port%%/*}  # Убираем протокол, если есть
  
  # Эфемерные UDP порты (WireGuard, VPN и т.д.) - динамические
  if [[ $port =~ ^[0-9]+$ ]] && (( port >= 32768 && port <= 65535 )); then
    # Для UDP высоких портов - всегда эфемерные
    if [[ "$proto" == "udp" ]]; then
      return 0  # true
    fi
    # Для TCP - только выше 49152
    if [[ "$proto" == "tcp" ]] && (( port >= 49152 )); then
      return 0  # true
    fi
  fi
  return 1  # false
}

# 1) Извлечение портов из UFW или из файлов
parse_rules() {
  if $initial_active; then
    # Получаем полный список правил из ufw status
    while read -r line; do
      # Пропускаем заголовки и пустые строки
      [[ "$line" =~ ^Status:|^To|^--$|^Default:|^New|^Logging ]] && continue
      [[ -z "$line" ]] && continue
      
      # Пропускаем IPv6 правила (содержат "(v6)" в конце строки)
      [[ "$line" == *"(v6)"* ]] && continue
      
      # Формат: "22/tcp                   ALLOW       Anywhere"
      #         "443                      ALLOW       Anywhere"
      #         "45876/tcp                ALLOW       87.228.16.152"
      
      # Извлекаем порт (первый столбец)
      port=$(echo "$line" | awk '{print $1}')
      
      # Пропускаем некорректные порты
      [[ -z "$port" || "$port" == "--" || "$port" == "Anywhere" ]] && continue
      
      # Извлекаем действие (второй столбец)
      action=$(echo "$line" | awk '{print $2}')
      
      # Проверяем, есть ли ограничение по IP/подсети
      source="Anywhere"
      if echo "$line" | grep -qE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?'; then
        # Извлекаем IP или подсеть
        source=$(echo "$line" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?' | tail -1)
      fi
      
      port_set["$port"]=1
      rule_source["$port"]="$source"
      rule_action["$port"]="${action:-ALLOW}"
      
      # Если порт без протокола (например "443"), добавляем также с tcp и udp
      if [[ ! "$port" =~ / ]]; then
        port_set["${port}/tcp"]=1
        port_set["${port}/udp"]=1
        rule_source["${port}/tcp"]="$source"
        rule_source["${port}/udp"]="$source"
        rule_action["${port}/tcp"]="${action:-ALLOW}"
        rule_action["${port}/udp"]="${action:-ALLOW}"
      fi
      
    done < <(ufw status | grep -v "^$")
  else
    # Если UFW выключен, читаем из файлов с поддержкой IP/подсетей
    while read -r line; do
      # Извлекаем порт
      if [[ "$line" =~ --dport[[:space:]]+([0-9]+) ]]; then
        port="${BASH_REMATCH[1]}"
      elif [[ "$line" =~ --dports[[:space:]]+([0-9,:]+) ]]; then
        port="${BASH_REMATCH[1]}"
      else
        continue
      fi
      
      # Определяем протокол
      proto="tcp"
      [[ "$line" =~ -p[[:space:]]+(tcp|udp) ]] && proto="${BASH_REMATCH[1]}"
      
      # Определяем источник
      source="Anywhere"
      if [[ "$line" =~ -s[[:space:]]+([0-9./]+) ]]; then
        source="${BASH_REMATCH[1]}"
      fi
      
      key="$port/$proto"
      port_set["$key"]=1
      rule_source["$key"]="$source"
      
      # Определяем действие
      if [[ "$line" =~ -j[[:space:]]+(ACCEPT|DROP|REJECT) ]]; then
        case "${BASH_REMATCH[1]}" in
          ACCEPT) rule_action["$key"]="ALLOW" ;;
          DROP|REJECT) rule_action["$key"]="DENY" ;;
        esac
      else
        rule_action["$key"]="ALLOW"
      fi
    done < <(grep -hE '^-A ufw6?-user-input' /etc/ufw/user.rules /etc/ufw/user6.rules 2>/dev/null || true)
  fi
}

# Проверка, является ли порт/сервис внутренним
is_internal() {
  local port="$1"
  [[ -z "$port" ]] && return 1
  local service="${service_map["$port"]:-}"
  
  # Проверяем по списку игнорируемых портов
  for ignore_port in "${IGNORE_PORTS[@]}"; do
    if [[ "$port" == "$ignore_port" ]]; then
      return 0  # true
    fi
  done
  
  # Проверяем по списку внутренних портов
  for internal_port in "${INTERNAL_PORTS[@]}"; do
    if [[ "$port" == "$internal_port" ]]; then
      return 0  # true
    fi
  done
  
  # Проверяем docker-proxy без известного контейнера
  if [[ "$service" == *"docker: (внутренний)"* ]] || [[ "$service" == *"docker: (локальный)"* ]]; then
    return 0  # true
  fi
  
  # Проверяем по списку внутренних сервисов
  for internal_service in "${INTERNAL_SERVICES[@]}"; do
    if [[ "$service" == *"$internal_service"* ]]; then
      return 0  # true
    fi
  done
  
  # Проверяем эфемерные порты (динамические UDP, высокие TCP)
  if is_ephemeral_port "$port"; then
    return 0  # true
  fi
  
  # Проверяем локальные адреса
  if [[ "$port" == *"127.0.0.1"* || "$port" == *"::1"* ]]; then
    return 0  # true
  fi
  
  return 1  # false
}

# 2) Определение используемых портов и сервисов
check_used() {
  # Сначала собираем информацию о Docker-контейнерах (чтобы знать их порты)
  collect_docker_ports
  collect_podman_ports
  
  # ss-прослушивание
  while read -r pr addr proc; do
    # Извлекаем порт из адреса (поддержка IPv4 и IPv6)
    # IPv6: [::]:8080 или :::8080 -> 8080
    # IPv4: 0.0.0.0:8080 или *:8080 -> 8080
    local is_local=false
    
    # Проверяем, локальный ли это адрес
    if [[ "$addr" == 127.0.0.* ]] || [[ "$addr" == "127.0.0.1:"* ]] || \
       [[ "$addr" == "[::1]:"* ]] || [[ "$addr" == "::1:"* ]]; then
      is_local=true
    fi
    
    if [[ "$addr" =~ \]:([0-9]+)$ ]]; then
      port="${BASH_REMATCH[1]}"
    elif [[ "$addr" =~ :([0-9]+)$ ]]; then
      port="${BASH_REMATCH[1]}"
    else
      continue
    fi
    
    key="$port/$pr"
    used_map["$key"]=1
    
    # Также отмечаем порт без протокола как используемый
    used_map["$port"]=1
    
    # Извлекаем имя сервиса из процесса
    if [[ -n "$proc" ]]; then
      # Извлекаем имя процесса из строки вида "users:(("nginx",pid=1234,fd=3))"
      service_name=$(echo "$proc" | grep -oP '"\K[^"]+' | head -1)
      if [[ -z "$service_name" ]]; then
        service_name=$(echo "$proc" | cut -d: -f2 | tr -d '(")')
      fi
      
      # Если это docker-proxy, проверяем, есть ли информация о контейнере
      if [[ "$service_name" == "docker-proxy" ]]; then
        # Проверяем, есть ли уже информация о контейнере для этого порта
        if [[ -n "${docker_port_map[$port]:-}" ]]; then
          # Проверяем, локальный ли это Docker-порт
          if [[ "${docker_local_map[$port]:-}" == "true" ]]; then
            service_map["$key"]="docker: ${docker_port_map[$port]} (локальный)"
            service_map["$port"]="docker: ${docker_port_map[$port]} (локальный)"
          else
            service_map["$key"]="docker: ${docker_port_map[$port]}"
            service_map["$port"]="docker: ${docker_port_map[$port]}"
          fi
        else
          # docker-proxy без известного контейнера - пропускаем (внутренний)
          service_map["$key"]="docker: (внутренний)"
          service_map["$port"]="docker: (внутренний)"
        fi
      elif [[ -n "$service_name" ]]; then
        # Проверяем, нет ли уже информации о контейнере (она приоритетнее)
        if [[ -z "${service_map[$key]:-}" ]]; then
          if [[ "$is_local" == "true" ]]; then
            service_map["$key"]="сервис: $service_name (локальный)"
            service_map["$port"]="сервис: $service_name (локальный)"
          else
            service_map["$key"]="сервис: $service_name"
            service_map["$port"]="сервис: $service_name"
          fi
        fi
      fi
    fi
    
    # Пропускаем локальные порты - не добавляем в missing
    if [[ "$is_local" == "true" ]]; then
      continue
    fi
    
    # Проверяем, открыт ли порт в UFW и не является ли он внутренним
    if [[ -z "${port_set[$key]:-}" && -z "${port_set[$port]:-}" ]]; then
      # Проверяем, не является ли порт внутренним
      if ! is_internal "$key"; then
        # Порт используется, не открыт в UFW и не является внутренним
        missing_ports+=("$key")
      fi
    fi
  done < <(ss -tulnpH | awk '{print tolower($1), $5, $7}')

  # Проверка systemd-сервисов (опционально)
  if [[ "$CHECK_SYSTEMD" == "true" ]]; then
    check_systemd_services
  fi
}

# Сбор информации о Docker-портах (вызывается до ss)
declare -A docker_port_map
declare -A docker_local_map
collect_docker_ports() {
  if ! command -v docker &>/dev/null || ! docker ps &>/dev/null 2>&1; then
    return 0
  fi
  
  local containers
  mapfile -t containers < <(docker ps --format '{{.Names}}')
  
  for container_name in "${containers[@]}"; do
    [[ -z "$container_name" ]] && continue
    
    # Получаем полную информацию о портах включая IP
    local port_mappings
    mapfile -t port_mappings < <(
      docker inspect "$container_name" \
        -f '{{range $k,$v := .NetworkSettings.Ports}}{{if $v}}{{printf "%s %s %s\n" $k (index $v 0).HostIp (index $v 0).HostPort}}{{end}}{{end}}' 2>/dev/null
    )
    
    for mapping in "${port_mappings[@]}"; do
      [[ -z "$mapping" ]] && continue
      read -r kp host_ip hp <<< "$mapping"
      [[ -z "$hp" ]] && continue
      proto=${kp##*/}
      key="${hp}/${proto}"
      
      # Проверяем, локальный ли это порт
      local is_local="false"
      if [[ "$host_ip" == "127.0.0.1" ]] || [[ "$host_ip" == "::1" ]]; then
        is_local="true"
        docker_local_map["$hp"]="true"
        docker_local_map["$key"]="true"
      fi
      
      # Запоминаем соответствие порт -> контейнер
      docker_port_map["$hp"]="$container_name"
      docker_port_map["$key"]="$container_name"
      
      used_map["$key"]=1
      used_map["$hp"]=1
      
      if [[ "$is_local" == "true" ]]; then
        service_map["$key"]="docker: $container_name (локальный)"
        service_map["$hp"]="docker: $container_name (локальный)"
      else
        service_map["$key"]="docker: $container_name"
        service_map["$hp"]="docker: $container_name"
      fi
      
      # Пропускаем локальные порты - не добавляем в missing
      if [[ "$is_local" == "true" ]]; then
        continue
      fi
      
      # Проверяем, открыт ли порт в UFW
      if [[ -z "${port_set[$key]:-}" && -z "${port_set[$hp]:-}" ]]; then
        if ! is_internal "$key"; then
          missing_ports+=("$key")
        fi
      fi
    done
  done
}

# Сбор информации о Podman-портах
collect_podman_ports() {
  if ! command -v podman &>/dev/null || ! podman ps &>/dev/null 2>&1; then
    return 0
  fi
  
  local containers
  mapfile -t containers < <(podman ps --format '{{.Names}}' 2>/dev/null)
  
  for container_name in "${containers[@]}"; do
    [[ -z "$container_name" ]] && continue
    
    local port_mappings
    mapfile -t port_mappings < <(
      podman inspect "$container_name" \
        --format '{{range $k,$v := .NetworkSettings.Ports}}{{if $v}}{{printf "%s %s\n" $k (index $v 0).HostPort}}{{end}}{{end}}' 2>/dev/null
    )
    
    if [[ ${#port_mappings[@]} -eq 0 ]]; then
      mapfile -t port_mappings < <(
        podman port "$container_name" 2>/dev/null | awk -F'[ :/]+' '{print $1"/"$2, $4}'
      )
    fi
    
    for mapping in "${port_mappings[@]}"; do
      [[ -z "$mapping" ]] && continue
      read -r kp hp <<< "$mapping"
      [[ -z "$hp" ]] && continue
      proto=${kp##*/}
      key="${hp}/${proto}"
      
      docker_port_map["$hp"]="$container_name"
      docker_port_map["$key"]="$container_name"
      
      used_map["$key"]=1
      used_map["$hp"]=1
      service_map["$key"]="podman: $container_name"
      service_map["$hp"]="podman: $container_name"
      
      if [[ -z "${port_set[$key]:-}" && -z "${port_set[$hp]:-}" ]]; then
        if ! is_internal "$key"; then
          missing_ports+=("$key")
        fi
      fi
    done
  done
}

# Проверка systemd-сервисов (порты остановленных сервисов)
check_systemd_services() {
  echo -e "${CYAN}Проверяем порты systemd-сервисов...${NC}"
  
  # Список сервисов, которые обычно слушают порты
  local common_services=(
    "nginx:80/tcp,443/tcp"
    "apache2:80/tcp,443/tcp"
    "httpd:80/tcp,443/tcp"
    "mysql:3306/tcp"
    "mariadb:3306/tcp"
    "postgresql:5432/tcp"
    "redis:6379/tcp"
    "mongodb:27017/tcp"
    "docker:2375/tcp,2376/tcp"
    "sshd:22/tcp"
    "postfix:25/tcp,587/tcp"
    "dovecot:143/tcp,993/tcp,110/tcp,995/tcp"
  )
  
  for entry in "${common_services[@]}"; do
    local service_name="${entry%%:*}"
    local ports="${entry#*:}"
    
    # Проверяем, установлен ли сервис
    if systemctl list-unit-files "${service_name}.service" &>/dev/null; then
      local status
      status=$(systemctl is-active "${service_name}.service" 2>/dev/null || echo "unknown")
      
      if [[ "$status" == "inactive" ]] || [[ "$status" == "failed" ]]; then
        # Сервис установлен, но не запущен
        IFS=',' read -ra port_list <<< "$ports"
        for p in "${port_list[@]}"; do
          if [[ -n "${port_set[$p]:-}" ]]; then
            # Порт открыт в UFW, но сервис не запущен
            systemd_ports+=("$p (${service_name} - ${status})")
          fi
        done
      fi
    fi
  done
  
  if [[ ${#systemd_ports[@]} -gt 0 ]]; then
    echo -e "${YELLOW}⚠ Обнаружены открытые порты для неактивных сервисов:${NC}"
    for sp in "${systemd_ports[@]}"; do
      echo -e "  ${YELLOW}• $sp${NC}"
    done
  fi
}

# 3) Добавление SSH-порта (только если не открыт)
add_ssh() {
  local sk port
  for sk in "${!service_map[@]}"; do
    [[ -z "$sk" ]] && continue
    if [[ "${service_map["$sk"]}" == *"сервис: sshd"* ]] || [[ "${service_map["$sk"]}" == *"сервис: ssh"* ]]; then
      port=${sk%%/*}
      break
    fi
  done
  
  if [[ -z ${port:-} ]]; then
    echo -e "${YELLOW}⚠ SSH-порт не обнаружен в списке сервисов${NC}"
    return 0
  fi
  
  # Проверяем, открыт ли уже SSH-порт в UFW
  local ssh_key="${port}/tcp"
  if [[ -n "${port_set[$ssh_key]:-}" ]] || [[ -n "${port_set[$port]:-}" ]]; then
    echo -e "${GREEN}SSH-порт (${port}/tcp) уже открыт в UFW${NC}"
    return 0
  fi
  
  echo -e "${BLUE}Добавляем SSH-порт (${port}/tcp) в UFW...${NC}"
  if $DRY_RUN; then
    echo "Симуляция: ufw allow ${port}/tcp"
  else
    ufw allow "${port}/tcp" && log "ALLOW ${port}/tcp"
  fi
}

# 4) Печать таблицы и сбор неиспользуемых
print_table() {
  echo
  echo -e "${BOLD}╔══════════════════╦═══════════════╦════════════════╦══════════════════════╗${NC}"
  echo -e "${BOLD}║ Порт             ║ Статус        ║ Источник       ║ Сервис/Контейнер     ║${NC}"
  echo -e "${BOLD}╠══════════════════╬═══════════════╬════════════════╬══════════════════════╣${NC}"
  
  unused_ports=()
  
  # Собираем "оригинальные" порты (как они заданы в UFW, без синтетических /tcp /udp)
  declare -A original_ports
  while read -r line; do
    [[ "$line" =~ ^Status:|^To|^--$|^Default:|^New|^Logging ]] && continue
    [[ -z "$line" || "$line" == *"(v6)"* ]] && continue
    port=$(echo "$line" | awk '{print $1}')
    [[ -n "$port" && "$port" != "--" && "$port" != "Anywhere" ]] && original_ports["$port"]=1
  done < <(ufw status 2>/dev/null)
  
  mapfile -t entries < <(printf "%s\n" "${!original_ports[@]}" | sort -V)
  for e in "${entries[@]}"; do
    # Пропускаем пустые и некорректные порты
    [[ -z "$e" || "$e" == "--" ]] && continue
    
    # Пропускаем игнорируемые порты
    local skip=false
    for ignore_port in "${IGNORE_PORTS[@]}"; do
      if [[ "$e" == "$ignore_port" ]]; then
        skip=true
        break
      fi
    done
    [[ "$skip" == "true" ]] && continue
    
    used=false
    
    # Проверяем, используется ли порт
    # Для портов без протокола (например "443") проверяем и tcp и udp
    if [[ -n "${used_map["$e"]:-}" ]]; then
      used=true
    elif [[ ! "$e" =~ / ]]; then
      # Порт без протокола - проверяем с tcp и udp
      if [[ -n "${used_map["${e}/tcp"]:-}" ]] || [[ -n "${used_map["${e}/udp"]:-}" ]]; then
        used=true
      fi
    fi
    
    # Определяем статус
    if [[ $used == true ]]; then
      status="${GREEN}Используемый${NC}"
    else
      # Не добавляем DENY правила в список неиспользуемых
      if [[ "${rule_action["$e"]:-ALLOW}" != "DENY" ]]; then
        status="${RED}Неиспользуемый${NC}"
        unused_ports+=("$e")
      else
        status="${YELLOW}Блокирующий${NC}"
      fi
    fi
    
    # Источник (IP/подсеть)
    source="${rule_source["$e"]:-Anywhere}"
    # Сокращаем если слишком длинный
    if [[ ${#source} -gt 14 ]]; then
      source="${source:0:11}..."
    fi
    
    # сервис/контейнер - также проверяем с протоколом
    svc="${service_map["$e"]:-}"
    if [[ -z "$svc" && ! "$e" =~ / ]]; then
      svc="${service_map["${e}/tcp"]:-}"
      [[ -z "$svc" ]] && svc="${service_map["${e}/udp"]:-}"
    fi
    [[ -z "$svc" ]] && svc="-"
    
    # Добавляем цвет к сервису
    if [[ $svc != "-" ]]; then
      svc="${BLUE}${svc}${NC}"
    fi
    
    printf "║ %-16s ║ %-23b ║ %-14s ║ %-30b ║\n" "$e" "$status" "$source" "$svc"
  done
  echo -e "${BOLD}╚══════════════════╩═══════════════╩════════════════╩══════════════════════╝${NC}"
  
  # Выводим информацию о неоткрытых портах (только внешние)
  if ((${#missing_ports[@]})); then
    echo
    echo -e "${YELLOW}Обнаружены используемые порты, не открытые в UFW:${NC}"
    echo -e "${BOLD}╔══════════════════╦══════════════════════════════╗${NC}"
    echo -e "${BOLD}║ Порт             ║ Сервис/Контейнер             ║${NC}"
    echo -e "${BOLD}╠══════════════════╬══════════════════════════════╣${NC}"
    
    # Удаляем дубликаты
    mapfile -t unique_missing < <(printf "%s\n" "${missing_ports[@]}" | sort -u)
    
    for mp in "${unique_missing[@]}"; do
      [[ -z "$mp" ]] && continue
      svc="${service_map["$mp"]:-"-"}"
      if [[ $svc != "-" ]]; then
        svc="${BLUE}${svc}${NC}"
      fi
      printf "║ %-16s ║ %-38b ║\n" "$mp" "$svc"
    done
    echo -e "${BOLD}╚══════════════════╩══════════════════════════════╝${NC}"
  fi
}

# 5) Удаление неиспользуемых портов
cleanup() {
  if ! $initial_active; then
    echo -e "${YELLOW}"
    read -r -p "UFW выключен. Включить для удаления? (y/n): " ans
    echo -e "${NC}"
    if [[ $ans =~ ^[Yy]$ ]]; then
      $DRY_RUN || { ufw --force enable && log "ENABLE"; }
    else
      echo -e "${YELLOW}Включите UFW и перезапустите.${NC}"; exit 0
    fi
  fi
  
  # Предложение добавить неоткрытые порты (только внешние)
  if ((${#missing_ports[@]})); then
    echo
    mapfile -t unique_missing < <(printf "%s\n" "${missing_ports[@]}" | sort -u)
    echo -e "${YELLOW}Рекомендация: открыть используемые порты: ${GREEN}${unique_missing[*]}${NC}"
    read -r -p "Открыть? (y/n): " ans
    if [[ $ans =~ ^[Yy]$ ]]; then
      for mp in "${unique_missing[@]}"; do
        echo -e "${YELLOW}Открываю порт $mp...${NC}"
        if $DRY_RUN; then
          echo "Симуляция: ufw allow $mp"
        else
          output=$(ufw allow "$mp" 2>&1) || true
          echo -e "${GREEN}$output${NC}"
          log "ALLOW $mp"
        fi
      done
    fi
  fi
  
  # Предложение удалить неиспользуемые порты
  if ((${#unused_ports[@]})); then
    echo
    echo -e "${YELLOW}Рекомендация: удалить неиспользуемые порты: ${RED}${unused_ports[*]}${NC}"
    read -r -p "Удалить? (y/n): " ans
    if [[ $ans =~ ^[Yy]$ ]]; then
      for r in "${unused_ports[@]}"; do
        # Пропускаем некорректные порты
        [[ "$r" == "--" ]] && continue
        
        if [[ $r =~ ^([0-9]+):([0-9]+)/(tcp|udp)$ ]]; then
          # Диапазон портов с протоколом
          s=${BASH_REMATCH[1]}; t=${BASH_REMATCH[2]}; pr=${BASH_REMATCH[3]}
          echo -e "${YELLOW}Удаляю диапазон ${s}:${t}/${pr}...${NC}"
          if $DRY_RUN; then
            echo "Симуляция: ufw delete allow proto $pr from any to any port ${s}:${t}"
          else
            output=$(ufw delete allow proto "$pr" from any to any port "${s}:${t}" 2>&1) || true
            if [[ $output == *"Could not delete non-existent rule"* ]]; then
              echo -e "${RED}Правило не существует${NC}"
            else
              echo -e "${GREEN}$output${NC}"
            fi
          fi
        elif [[ $r =~ ^([0-9]+):([0-9]+)$ ]]; then
          # Диапазон портов без протокола
          s=${BASH_REMATCH[1]}; t=${BASH_REMATCH[2]}
          for pr in tcp udp; do
            echo -e "${YELLOW}Удаляю диапазон ${s}:${t}/${pr}...${NC}"
            if $DRY_RUN; then
              echo "Симуляция: ufw delete allow proto $pr from any to any port ${s}:${t}"
            else
              output=$(ufw delete allow proto "$pr" from any to any port "${s}:${t}" 2>&1) || true
              if [[ $output == *"Could not delete non-existent rule"* ]]; then
                echo -e "${RED}Правило не существует${NC}"
              else
                echo -e "${GREEN}$output${NC}"
              fi
            fi
          done
        elif [[ $r =~ ^([0-9]+)/(tcp|udp)$ ]]; then
          # Порт с протоколом
          port=${BASH_REMATCH[1]}; proto=${BASH_REMATCH[2]}
          echo -e "${YELLOW}Удаляю правило ${port}/${proto}...${NC}"
          if $DRY_RUN; then
            echo "Симуляция: ufw delete allow ${port}/${proto}"
          else
            output=$(ufw delete allow "${port}/${proto}" 2>&1) || true
            if [[ $output == *"Could not delete non-existent rule"* ]]; then
              echo -e "${RED}Правило не существует${NC}"
            else
              echo -e "${GREEN}$output${NC}"
            fi
          fi
        else
          # Порт без протокола
          echo -e "${YELLOW}Удаляю правило $r...${NC}"
          if $DRY_RUN; then
            echo "Симуляция: ufw delete allow $r"
          else
            # Проверяем, является ли правило DENY
            if [[ "${rule_action["$r"]:-ALLOW}" == "DENY" ]]; then
              output=$(ufw delete deny "$r" 2>&1) || true
            else
              output=$(ufw delete allow "$r" 2>&1) || true
            fi
            
            if [[ $output == *"Could not delete non-existent rule"* ]]; then
              # Пробуем удалить с указанием протокола
              echo -e "${YELLOW}Пробуем удалить как $r/tcp...${NC}"
              tcp_output=$(ufw delete allow "$r/tcp" 2>&1) || true
              
              echo -e "${YELLOW}Пробуем удалить как $r/udp...${NC}"
              udp_output=$(ufw delete allow "$r/udp" 2>&1) || true
              
              if [[ $tcp_output == *"Could not delete non-existent rule"* ]] && 
                 [[ $udp_output == *"Could not delete non-existent rule"* ]]; then
                echo -e "${RED}Правило не существует ни с TCP, ни с UDP${NC}"
              else
                [[ $tcp_output != *"Could not delete non-existent rule"* ]] && echo -e "${GREEN}$tcp_output${NC}"
                [[ $udp_output != *"Could not delete non-existent rule"* ]] && echo -e "${GREEN}$udp_output${NC}"
              fi
            else
              echo -e "${GREEN}$output${NC}"
            fi
          fi
        fi
      done
    fi
  else
    echo -e "\n${GREEN}Все порты используются или являются блокирующими. Очистка не требуется.${NC}"
  fi
}

main() {
  ensure_root
  load_config
  
  # Инициализация массивов
  declare -a unused_ports=()
  declare -a missing_ports=()
  declare -a systemd_ports=()
  
  echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}  UFW Cleaner v2.0 - Аудит и очистка правил файрвола${NC}"
  echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
  
  if $DRY_RUN; then
    echo -e "${YELLOW}⚠ Режим симуляции (--dry-run) - изменения не будут применены${NC}"
  fi
  
  # Создаём резервную копию перед любыми изменениями
  if ! $DRY_RUN && $initial_active; then
    backup_rules
  fi
  
  parse_rules
  check_used
  add_ssh
  print_table
  cleanup
  
  echo
  echo -e "${GREEN}Готово!${NC}"
}

main
