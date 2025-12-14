#!/usr/bin/env bash
set -euo pipefail
declare -a unused_ports=()
declare -a missing_ports=()

# ufw-cleaner: автоматическая проверка и очистка неиспользуемых портов UFW
# Поддерживает --dry-run и логирование

LOG=/var/log/ufw-cleaner.log
DRY_RUN=false

# Цвета для вывода
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

usage() {
  echo "Usage: $0 [--dry-run]" >&2
  exit 1
}

# Разбор опций
while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run) DRY_RUN=true; shift ;;  
    -h|--help) usage ;;  
    *) usage ;;  
  esac
done

log() {
  echo "$(date '+%F %T') $*" >> "$LOG"
}

ensure_root() {
  [[ $EUID -eq 0 ]] || { echo -e "${RED}Требуются root-права${NC}" >&2; exit 1; }
}

# Начальный статус UFW
initial_active=false
if ufw status verbose 2>/dev/null | grep -q "Status: active"; then
  initial_active=true
fi

# Структуры данных
declare -A proto_map port_set used_map service_map rule_action
declare -a unused_ports missing_ports

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

# Список высоких портов, которые обычно используются для исходящих соединений
is_high_port() {
  local port=$1
  port=${port%%/*}  # Убираем протокол, если есть
  if [[ $port =~ ^[0-9]+$ ]] && [ "$port" -gt 32000 ]; then
    return 0  # true
  fi
  return 1  # false
}

# 1) Извлечение портов из UFW или из файлов
parse_rules() {
  if $initial_active; then
    # Получаем полный список правил из ufw status
    while read -r line; do
      [[ "$line" =~ ^Status:|^To|^--$ ]] && continue
      
      # Извлекаем порт и действие
      port=$(echo "$line" | awk '{print $1}')
      action=$(echo "$line" | awk '{print $2}')
      
      # Пропускаем IPv6 дубликаты и некорректные порты
      [[ "$port" == *"(v6)"* || "$port" == "--" ]] && continue
      
      port_set["$port"]=1
      
      # Определяем действие (ALLOW/DENY)
      if [[ "$action" == "ALLOW" ]]; then
        rule_action["$port"]="ALLOW"
      elif [[ "$action" == "DENY" ]]; then
        rule_action["$port"]="DENY"
      else
        rule_action["$port"]="ALLOW" # По умолчанию
      fi
    done < <(ufw status | grep -v "^$")
  else
    # Если UFW выключен, читаем из файлов
    mapfile -t items < <(
      grep -hE '^-A ufw6?-user-input.*-(j|g) (ACCEPT|DROP|REJECT)' /etc/ufw/user.rules /etc/ufw/user6.rules |
      sed -n 's/.*--dports[[:space:]]\+\([0-9,:]\+\).*/\1/p; s/.*--dport[[:space:]]\+\([0-9]\+\).*/\1/p'
    )
    
    for it in "${items[@]}"; do
      [[ -z $it ]] && continue
      if [[ $it =~ ^([0-9:]+)/(tcp|udp)$ ]]; then
        base=${BASH_REMATCH[1]}; proto=${BASH_REMATCH[2]}
        port_set["$base/$proto"]=1
        rule_action["$base/$proto"]="ALLOW" # По умолчанию считаем ALLOW
      else
        port_set["$it"]=1
        rule_action["$it"]="ALLOW" # По умолчанию считаем ALLOW
      fi
    done
  fi
}

# Проверка, является ли порт/сервис внутренним
is_internal() {
  local port=$1
  local service=${service_map[$port]:-""}
  
  # Проверяем по списку внутренних портов
  for internal_port in "${INTERNAL_PORTS[@]}"; do
    if [[ "$port" == "$internal_port" ]]; then
      return 0  # true
    fi
  done
  
  # Проверяем по списку внутренних сервисов
  for internal_service in "${INTERNAL_SERVICES[@]}"; do
    if [[ "$service" == *"$internal_service"* ]]; then
      return 0  # true
    fi
  done
  
  # Проверяем высокие порты (обычно для исходящих соединений)
  if is_high_port "$port"; then
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
  # ss-прослушивание
  while read -r pr addr proc; do
    port=${addr##*:}
    key="$port/$pr"
    used_map["$key"]=1
    
    # Также отмечаем порт без протокола как используемый
    used_map["$port"]=1
    
    # Извлекаем имя сервиса из процесса
    if [[ -n "$proc" ]]; then
      # Извлекаем имя процесса из строки вида "users:(("nginx",pid=1234,fd=3))"
      service_name=$(echo "$proc" | grep -o '"[^"]*"' | head -1 | tr -d '"')
      if [[ -z "$service_name" ]]; then
        service_name=$(echo "$proc" | cut -d: -f2 | tr -d '(")')
      fi
      if [[ -n "$service_name" ]]; then
        service_map["$key"]="сервис: $service_name"
        service_map["$port"]="сервис: $service_name"
      fi
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

  # Проверка всех Docker-контейнеров
  if command -v docker &>/dev/null && docker ps &>/dev/null; then
    docker ps --format '{{.Names}}' | while read -r container_name; do
      docker inspect "$container_name" \
        -f '{{range $k,$v := .NetworkSettings.Ports}}{{if $v}}{{printf "%s %s\n" $k (index $v 0).HostPort}}{{end}}{{end}}' |
      while read -r kp hp; do
        # kp: containerPort/proto, hp: hostPort
        [[ -z "$hp" ]] && continue
        proto=${kp##*/}
        key="${hp}/${proto}"
        used_map["$key"]=1
        used_map["$hp"]=1
        service_map["$key"]="контейнер: $container_name"
        service_map["$hp"]="контейнер: $container_name"
        
        # Проверяем, открыт ли порт в UFW и не является ли он внутренним
        if [[ -z "${port_set[$key]:-}" && -z "${port_set[$hp]:-}" ]]; then
          # Проверяем, не является ли порт внутренним
          if ! is_internal "$key"; then
            # Порт используется, не открыт в UFW и не является внутренним
            missing_ports+=("$key")
          fi
        fi
      done
    done
  fi
}

# 3) Добавление SSH-порта
add_ssh() {
  local sk port
  for sk in "${!service_map[@]}"; do
    if [[ ${service_map[$sk]} == *"сервис: sshd"* ]] || [[ ${service_map[$sk]} == *"сервис: ssh"* ]]; then
      port=${sk%%/*}
      break
    fi
  done
  if [[ -n ${port:-} ]]; then
    echo -e "${BLUE}Добавляем SSH-порт (${port}/tcp) в UFW...${NC}"
    $DRY_RUN || { ufw allow "${port}/tcp" && log "ALLOW ${port}/tcp"; }
  else
    echo -e "${RED}⚠ SSH-порт не найден${NC}"; exit 1
  fi
}

# 4) Печать таблицы и сбор неиспользуемых
print_table() {
  echo
  echo -e "${BOLD}╔═════════════════╦═══════════════╦══════════════════════╗${NC}"
  echo -e "${BOLD}║ Порт            ║ Статус        ║ Сервис/Контейнер     ║${NC}"
  echo -e "${BOLD}╠═════════════════╬═══════════════╬══════════════════════╣${NC}"
  
  unused_ports=()
  mapfile -t entries < <(printf "%s\n" "${!port_set[@]}" | sort -V)
  for e in "${entries[@]}"; do
    # Пропускаем некорректные порты
    [[ "$e" == "--" ]] && continue
    
    used=false
    
    # Проверяем, используется ли порт
    if [[ -n "${used_map[$e]:-}" ]]; then
      used=true
    fi
    
    # Определяем статус
    if [[ $used == true ]]; then
      status="${GREEN}Используемый${NC}"
    else
      # Не добавляем DENY правила в список неиспользуемых
      if [[ "${rule_action[$e]:-ALLOW}" != "DENY" ]]; then
        status="${RED}Неиспользуемый${NC}"
        unused_ports+=("$e")
      else
        status="${YELLOW}Блокирующий${NC}"
      fi
    fi
    
    # сервис/контейнер
    svc=${service_map[$e]:-"-"}
    
    # Добавляем цвет к сервису
    if [[ $svc != "-" ]]; then
      svc="${BLUE}${svc}${NC}"
    fi
    
    printf "║ %-15s ║ %-13b ║ %-20b ║\n" "$e" "$status" "$svc"
  done
  echo -e "${BOLD}╚═════════════════╩═══════════════╩══════════════════════╝${NC}"
  
  # Выводим информацию о неоткрытых портах (только внешние)
  if ((${#missing_ports[@]})); then
    echo
    echo -e "${YELLOW}Обнаружены используемые порты, не открытые в UFW:${NC}"
    echo -e "${BOLD}╔═════════════════╦══════════════════════╗${NC}"
    echo -e "${BOLD}║ Порт            ║ Сервис/Контейнер     ║${NC}"
    echo -e "${BOLD}╠═════════════════╬══════════════════════╣${NC}"
    
    # Удаляем дубликаты
    mapfile -t unique_missing < <(printf "%s\n" "${missing_ports[@]}" | sort -u)
    
    for mp in "${unique_missing[@]}"; do
      svc=${service_map[$mp]:-"-"}
      if [[ $svc != "-" ]]; then
        svc="${BLUE}${svc}${NC}"
      fi
      printf "║ %-15s ║ %-20b ║\n" "$mp" "$svc"
    done
    echo -e "${BOLD}╚═════════════════╩══════════════════════╝${NC}"
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
            if [[ "${rule_action[$r]:-ALLOW}" == "DENY" ]]; then
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
parse_rules
missing_ports=()
check_used
  add_ssh
  print_table
  cleanup
}

main
