#!/usr/bin/env bash
set -euo pipefail

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  UFW Cleaner v3.0 — аудит и очистка правил файрвола                      ║
# ║  Поддерживает: Docker, Podman, systemd, --dry-run, логирование, конфиг   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

readonly VERSION="3.0"

# ─── Конфигурация (переопределяется из /etc/ufw-cleaner.conf) ─────────────

LOG=/var/log/ufw-cleaner.log
BACKUP_DIR=/var/backups/ufw
CONFIG_FILE=/etc/ufw-cleaner.conf
DRY_RUN=false
CHECK_SYSTEMD=${CHECK_SYSTEMD:-false}

# ─── Цвета и символы ─────────────────────────────────────────────────────

if [[ -t 1 ]]; then
  GREEN='\033[38;5;114m'
  RED='\033[38;5;204m'
  YELLOW='\033[38;5;221m'
  BLUE='\033[38;5;111m'
  CYAN='\033[38;5;117m'
  GRAY='\033[38;5;245m'
  WHITE='\033[38;5;255m'
  BOLD='\033[1m'
  DIM='\033[2m'
  NC='\033[0m'
  ICON_OK="✔"
  ICON_FAIL="✘"
  ICON_WARN="⚠"
  ICON_ARROW="▸"
  ICON_BULLET="•"
  ICON_SHIELD="🛡"
  ICON_LOCK="🔒"
  ICON_DOCKER="🐳"
  ICON_GEAR="⚙"
else
  GREEN="" RED="" YELLOW="" BLUE="" CYAN="" GRAY="" WHITE=""
  BOLD="" DIM="" NC=""
  ICON_OK="[OK]" ICON_FAIL="[X]" ICON_WARN="[!]" ICON_ARROW=">"
  ICON_BULLET="*" ICON_SHIELD="" ICON_LOCK=""
  ICON_DOCKER="" ICON_GEAR=""
fi

# ─── Внутренние сервисы (не предлагаются к открытию) ─────────────────────

INTERNAL_SERVICES=(
  "systemd-resolve" "systemd-network" "supervisord" "dnsmasq"
  "systemd" "rpcbind" "avahi" "cups" "dhcpd" "named" "ntpd"
  "sshd"           # SSH обрабатывается отдельно
  "docker-proxy"   # Внутренний механизм Docker
  "containerd" "dockerd"
)

# ─── Внутренние порты (не предлагаются к открытию) ───────────────────────

INTERNAL_PORTS=(
  "53/tcp" "53/udp"     # DNS
  "67/udp" "68/udp"     # DHCP
  "123/udp"             # NTP
  "631/tcp" "631/udp"   # CUPS
  "546/udp"             # DHCPv6
  "5353/udp"            # mDNS
  "2019/tcp"            # Caddy admin API
)

# ─── Игнорируемые порты ──────────────────────────────────────────────────

declare -a IGNORE_PORTS=()

# ─── Структуры данных ────────────────────────────────────────────────────

declare -A proto_map=() port_set=() used_map=() service_map=()
declare -A rule_action=() rule_source=()
declare -A docker_port_map=() docker_local_map=()
declare -a unused_ports=() missing_ports=() systemd_ports=()

# ═════════════════════════════════════════════════════════════════════════════
#  Вспомогательные функции
# ═════════════════════════════════════════════════════════════════════════════

log() {
  if [[ -w "$LOG" ]] || [[ -w "$(dirname "$LOG")" ]]; then
    printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG" 2>/dev/null || true
  fi
}

msg()      { printf '%b\n' "$*"; }
msg_ok()   { msg "  ${GREEN}${ICON_OK}${NC} $*"; }
msg_fail() { msg "  ${RED}${ICON_FAIL}${NC} $*"; }
msg_warn() { msg "  ${YELLOW}${ICON_WARN}${NC} $*"; }
msg_info() { msg "  ${BLUE}${ICON_ARROW}${NC} $*"; }

header() {
  local text="$1"
  local width=62
  msg ""
  msg "${CYAN}${BOLD}  ┌$(printf '─%.0s' $(seq 1 $width))┐${NC}"
  printf "  ${CYAN}${BOLD}│${NC} %-$((width - 1))s${CYAN}${BOLD}│${NC}\n" "$text"
  msg "${CYAN}${BOLD}  └$(printf '─%.0s' $(seq 1 $width))┘${NC}"
}

section() {
  msg ""
  msg "  ${CYAN}${BOLD}${ICON_ARROW} $*${NC}"
  msg "  ${GRAY}$(printf '─%.0s' $(seq 1 58))${NC}"
}

ensure_root() {
  if [[ $EUID -ne 0 ]]; then
    msg "${RED}${BOLD}${ICON_FAIL} Требуются root-права для работы с UFW${NC}"
    exit 1
  fi
}

# ═════════════════════════════════════════════════════════════════════════════
#  Конфигурация
# ═════════════════════════════════════════════════════════════════════════════

load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    msg_info "Загрузка конфигурации из ${WHITE}${CONFIG_FILE}${NC}"
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
    log "CONFIG loaded from $CONFIG_FILE"
  fi
}

create_sample_config() {
  cat << 'CONF'
# /etc/ufw-cleaner.conf — Конфигурация UFW Cleaner
# Раскомментируйте и измените нужные параметры

# LOG=/var/log/ufw-cleaner.log
# BACKUP_DIR=/var/backups/ufw

# Дополнительные внутренние сервисы
# INTERNAL_SERVICES+=("myservice" "anotherservice")

# Дополнительные внутренние порты
# INTERNAL_PORTS+=("8080/tcp" "9000/udp")

# Порты, которые нельзя удалять/предлагать
# IGNORE_PORTS=("22/tcp" "443/tcp" "80/tcp")

# Проверка systemd-сервисов
# CHECK_SYSTEMD=true
CONF
}

show_banner() {
  msg ""
  msg "  ${CYAN}${BOLD}${ICON_SHIELD} ╔═══════════════════════════════════════════════╗${NC}"
  msg "  ${CYAN}${BOLD}  ║                                               ║${NC}"
  msg "  ${CYAN}${BOLD}  ║   ${WHITE}UFW Cleaner ${CYAN}v${VERSION}                           ${CYAN}${BOLD}║${NC}"
  msg "  ${CYAN}${BOLD}  ║   ${GRAY}Аудит и очистка правил файрвола${CYAN}${BOLD}              ║${NC}"
  msg "  ${CYAN}${BOLD}  ║                                               ║${NC}"
  msg "  ${CYAN}${BOLD}  ╚═══════════════════════════════════════════════╝${NC}"
  msg ""
}

usage() {
  show_banner
  msg "  ${WHITE}${BOLD}Использование:${NC} $0 [ОПЦИИ]"
  msg ""
  msg "  ${WHITE}Опции:${NC}"
  msg "    ${GREEN}--dry-run${NC}        Симуляция без реальных изменений"
  msg "    ${GREEN}--show-config${NC}    Показать пример конфигурации"
  msg "    ${GREEN}--create-config${NC}  Создать ${CONFIG_FILE}"
  msg "    ${GREEN}-h, --help${NC}       Показать справку"
  msg ""
  msg "  ${GRAY}Конфигурация: ${CONFIG_FILE}${NC}"
  exit 0
}

# ─── Разбор аргументов ───────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)       DRY_RUN=true; shift ;;
    --show-config)   create_sample_config; exit 0 ;;
    --create-config)
      if [[ -f "$CONFIG_FILE" ]]; then
        msg_fail "Конфиг уже существует: ${CONFIG_FILE}"
        exit 1
      fi
      create_sample_config > "$CONFIG_FILE"
      msg_ok "Создан конфиг: ${CONFIG_FILE}"
      exit 0
      ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

# ═════════════════════════════════════════════════════════════════════════════
#  Резервное копирование
# ═════════════════════════════════════════════════════════════════════════════

backup_rules() {
  local backup_file="${BACKUP_DIR}/ufw-backup-$(date '+%Y%m%d-%H%M%S').txt"
  mkdir -p "$BACKUP_DIR"

  section "Резервное копирование"

  {
    echo "# UFW Backup — $(date)"
    echo "# Восстановление: выполните команды ниже"
    echo ""
    echo "# Текущий статус:"
    ufw status verbose
    echo ""
    echo "# Нумерованные правила:"
    ufw status numbered
    echo ""
    echo "# Команды для восстановления:"
    ufw status numbered 2>/dev/null | grep -E '^\[' | while read -r line; do
      local rule port action direction
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
    msg_ok "Резервная копия: ${WHITE}${backup_file}${NC}"
    log "BACKUP created: $backup_file"
  else
    msg_warn "Не удалось создать резервную копию"
  fi
}

# ═════════════════════════════════════════════════════════════════════════════
#  Проверки портов
# ═════════════════════════════════════════════════════════════════════════════

# Начальный статус UFW
initial_active=false
if ufw status verbose 2>/dev/null | grep -q "Status: active"; then
  initial_active=true
fi

# Эфемерный порт?
is_ephemeral_port() {
  local port_str="$1"
  local proto="${port_str##*/}"
  local port="${port_str%%/*}"

  [[ "$port" =~ ^[0-9]+$ ]] || return 1

  # UDP ≥ 32768 — эфемерный (кроме известных, напр. WireGuard 51820)
  if [[ "$proto" == "udp" ]] && (( port >= 32768 && port <= 65535 )); then
    (( port == 51820 )) && return 1
    return 0
  fi
  # TCP ≥ 49152 — эфемерный
  if [[ "$proto" == "tcp" ]] && (( port >= 49152 )); then
    return 0
  fi
  return 1
}

# Внутренний порт/сервис?
is_internal() {
  local port="$1"
  [[ -z "$port" ]] && return 1
  local service="${service_map["$port"]:-}"

  # Игнорируемые порты
  local p
  for p in "${IGNORE_PORTS[@]}"; do
    [[ "$port" == "$p" ]] && return 0
  done

  # Внутренние порты
  for p in "${INTERNAL_PORTS[@]}"; do
    [[ "$port" == "$p" ]] && return 0
  done

  # Docker внутренний/локальный
  if [[ "$service" == *"(внутренний)"* || "$service" == *"(локальный)"* ]]; then
    return 0
  fi

  # Внутренние сервисы
  local s
  for s in "${INTERNAL_SERVICES[@]}"; do
    [[ "$service" == *"$s"* ]] && return 0
  done

  # Эфемерные порты
  is_ephemeral_port "$port" && return 0

  # Локальные адреса
  [[ "$port" == *"127.0.0.1"* || "$port" == *"::1"* ]] && return 0

  return 1
}

# ═════════════════════════════════════════════════════════════════════════════
#  Парсинг правил UFW
# ═════════════════════════════════════════════════════════════════════════════

parse_rules() {
  section "Парсинг правил UFW"

  if $initial_active; then
    while read -r line; do
      [[ "$line" =~ ^Status:|^To|^--$|^Default:|^New|^Logging ]] && continue
      [[ -z "$line" || "$line" == *"(v6)"* ]] && continue

      local port action source
      port=$(echo "$line" | awk '{print $1}')
      [[ -z "$port" || "$port" == "--" || "$port" == "Anywhere" ]] && continue

      action=$(echo "$line" | awk '{print $2}')

      source="Anywhere"
      if echo "$line" | grep -qE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?'; then
        source=$(echo "$line" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?' | tail -1)
      fi

      port_set["$port"]=1
      rule_source["$port"]="$source"
      rule_action["$port"]="${action:-ALLOW}"

      # Порт без протокола → добавляем tcp+udp
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
    while read -r line; do
      local port proto source key
      if [[ "$line" =~ --dport[[:space:]]+([0-9]+) ]]; then
        port="${BASH_REMATCH[1]}"
      elif [[ "$line" =~ --dports[[:space:]]+([0-9,:]+) ]]; then
        port="${BASH_REMATCH[1]}"
      else
        continue
      fi

      proto="tcp"
      [[ "$line" =~ -p[[:space:]]+(tcp|udp) ]] && proto="${BASH_REMATCH[1]}"

      source="Anywhere"
      [[ "$line" =~ -s[[:space:]]+([0-9./]+) ]] && source="${BASH_REMATCH[1]}"

      key="$port/$proto"
      port_set["$key"]=1
      rule_source["$key"]="$source"

      if [[ "$line" =~ -j[[:space:]]+(ACCEPT|DROP|REJECT) ]]; then
        case "${BASH_REMATCH[1]}" in
          ACCEPT)       rule_action["$key"]="ALLOW" ;;
          DROP|REJECT)  rule_action["$key"]="DENY"  ;;
        esac
      else
        rule_action["$key"]="ALLOW"
      fi
    done < <(grep -hE '^-A ufw6?-user-input' /etc/ufw/user.rules /etc/ufw/user6.rules 2>/dev/null || true)
  fi

  local count=${#port_set[@]}
  msg_ok "Найдено правил: ${WHITE}${count}${NC}"
}

# ═════════════════════════════════════════════════════════════════════════════
#  Docker / Podman
# ═════════════════════════════════════════════════════════════════════════════

collect_docker_ports() {
  command -v docker &>/dev/null && docker ps &>/dev/null 2>&1 || return 0

  local containers
  mapfile -t containers < <(docker ps --format '{{.Names}}')

  local container_name
  for container_name in "${containers[@]}"; do
    [[ -z "$container_name" ]] && continue

    local port_mappings
    mapfile -t port_mappings < <(
      docker inspect "$container_name" \
        -f '{{range $k,$v := .NetworkSettings.Ports}}{{if $v}}{{printf "%s %s %s\n" $k (index $v 0).HostIp (index $v 0).HostPort}}{{end}}{{end}}' 2>/dev/null
    )

    local mapping
    for mapping in "${port_mappings[@]}"; do
      [[ -z "$mapping" ]] && continue
      local kp host_ip hp
      read -r kp host_ip hp <<< "$mapping"
      [[ -z "$hp" ]] && continue

      local proto="${kp##*/}"
      local key="${hp}/${proto}"
      local is_local="false"

      if [[ "$host_ip" == "127.0.0.1" || "$host_ip" == "::1" ]]; then
        is_local="true"
        docker_local_map["$hp"]="true"
        docker_local_map["$key"]="true"
      fi

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

      # Локальные порты не добавляем в missing
      [[ "$is_local" == "true" ]] && continue

      if [[ -z "${port_set[$key]:-}" && -z "${port_set[$hp]:-}" ]]; then
        is_internal "$key" || missing_ports+=("$key")
      fi
    done
  done
}

collect_podman_ports() {
  command -v podman &>/dev/null && podman ps &>/dev/null 2>&1 || return 0

  local containers
  mapfile -t containers < <(podman ps --format '{{.Names}}' 2>/dev/null)

  local container_name
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

    local mapping
    for mapping in "${port_mappings[@]}"; do
      [[ -z "$mapping" ]] && continue
      local kp hp
      read -r kp hp <<< "$mapping"
      [[ -z "$hp" ]] && continue

      local proto="${kp##*/}"
      local key="${hp}/${proto}"

      docker_port_map["$hp"]="$container_name"
      docker_port_map["$key"]="$container_name"
      used_map["$key"]=1
      used_map["$hp"]=1
      service_map["$key"]="podman: $container_name"
      service_map["$hp"]="podman: $container_name"

      if [[ -z "${port_set[$key]:-}" && -z "${port_set[$hp]:-}" ]]; then
        is_internal "$key" || missing_ports+=("$key")
      fi
    done
  done
}

# ═════════════════════════════════════════════════════════════════════════════
#  Сбор используемых портов (ss)
# ═════════════════════════════════════════════════════════════════════════════

check_used() {
  section "Сбор используемых портов"

  # Сначала Docker/Podman (чтобы знать контейнеры)
  collect_docker_ports
  collect_podman_ports

  while read -r pr addr proc; do
    local is_local=false

    if [[ "$addr" == 127.0.0.* || "$addr" == "127.0.0.1:"* || \
          "$addr" == "[::1]:"*  || "$addr" == "::1:"* ]]; then
      is_local=true
    fi

    local port
    if [[ "$addr" =~ \]:([0-9]+)$ ]]; then
      port="${BASH_REMATCH[1]}"
    elif [[ "$addr" =~ :([0-9]+)$ ]]; then
      port="${BASH_REMATCH[1]}"
    else
      continue
    fi

    local key="$port/$pr"
    used_map["$key"]=1
    used_map["$port"]=1

    # Определяем сервис
    if [[ -n "$proc" ]]; then
      local service_name
      service_name=$(echo "$proc" | grep -oP '"\K[^"]+' | head -1)
      [[ -z "$service_name" ]] && service_name=$(echo "$proc" | cut -d: -f2 | tr -d '(")')

      if [[ "$service_name" == "docker-proxy" ]]; then
        if [[ -n "${docker_port_map[$port]:-}" ]]; then
          if [[ "${docker_local_map[$port]:-}" == "true" ]]; then
            service_map["$key"]="docker: ${docker_port_map[$port]} (локальный)"
            service_map["$port"]="docker: ${docker_port_map[$port]} (локальный)"
          else
            service_map["$key"]="docker: ${docker_port_map[$port]}"
            service_map["$port"]="docker: ${docker_port_map[$port]}"
          fi
        else
          service_map["$key"]="docker: (внутренний)"
          service_map["$port"]="docker: (внутренний)"
        fi
      elif [[ -n "$service_name" && -z "${service_map[$key]:-}" ]]; then
        if [[ "$is_local" == true ]]; then
          service_map["$key"]="сервис: $service_name (локальный)"
          service_map["$port"]="сервис: $service_name (локальный)"
        else
          service_map["$key"]="сервис: $service_name"
          service_map["$port"]="сервис: $service_name"
        fi
      fi
    fi

    [[ "$is_local" == true ]] && continue

    # Порт используется, но не открыт в UFW?
    if [[ -z "${port_set[$key]:-}" && -z "${port_set[$port]:-}" ]]; then
      is_internal "$key" || missing_ports+=("$key")
    fi
  done < <(ss -tulnpH | awk '{print tolower($1), $5, $7}')

  # systemd-сервисы (опционально)
  [[ "$CHECK_SYSTEMD" == "true" ]] && check_systemd_services

  msg_ok "Проверено портов: ${WHITE}${#used_map[@]}${NC}"
}

# ═════════════════════════════════════════════════════════════════════════════
#  Проверка systemd-сервисов
# ═════════════════════════════════════════════════════════════════════════════

check_systemd_services() {
  msg_info "Проверка systemd-сервисов…"

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

  local entry
  for entry in "${common_services[@]}"; do
    local svc_name="${entry%%:*}"
    local ports="${entry#*:}"

    if systemctl list-unit-files "${svc_name}.service" &>/dev/null; then
      local status
      status=$(systemctl is-active "${svc_name}.service" 2>/dev/null || echo "unknown")

      if [[ "$status" == "inactive" || "$status" == "failed" ]]; then
        IFS=',' read -ra port_list <<< "$ports"
        local p
        for p in "${port_list[@]}"; do
          if [[ -n "${port_set[$p]:-}" ]]; then
            systemd_ports+=("$p (${svc_name} — ${status})")
          fi
        done
      fi
    fi
  done

  if (( ${#systemd_ports[@]} )); then
    msg_warn "Открытые порты для неактивных сервисов:"
    local sp
    for sp in "${systemd_ports[@]}"; do
      msg "    ${YELLOW}${ICON_BULLET} ${sp}${NC}"
    done
  fi
}

# ═════════════════════════════════════════════════════════════════════════════
#  SSH
# ═════════════════════════════════════════════════════════════════════════════

add_ssh() {
  section "Проверка SSH"

  local sk port=""
  for sk in "${!service_map[@]}"; do
    [[ -z "$sk" ]] && continue
    if [[ "${service_map["$sk"]}" == *"сервис: sshd"* || \
          "${service_map["$sk"]}" == *"сервис: ssh"*  ]]; then
      port="${sk%%/*}"
      break
    fi
  done

  if [[ -z "$port" ]]; then
    msg_warn "SSH-порт не обнаружен в списке сервисов"
    return 0
  fi

  local ssh_key="${port}/tcp"
  if [[ -n "${port_set[$ssh_key]:-}" || -n "${port_set[$port]:-}" ]]; then
    msg_ok "SSH (${WHITE}${port}/tcp${NC}) уже открыт в UFW"
    return 0
  fi

  msg_info "Добавляем SSH-порт ${WHITE}${port}/tcp${NC}…"
  if $DRY_RUN; then
    msg "    ${DIM}(dry-run) ufw allow ${port}/tcp${NC}"
  else
    ufw allow "${port}/tcp" && log "ALLOW ${port}/tcp"
    msg_ok "SSH-порт добавлен"
  fi
}

# ═════════════════════════════════════════════════════════════════════════════
#  Таблица аудита
# ═════════════════════════════════════════════════════════════════════════════

print_table() {
  section "Результаты аудита"

  local hdr_port="Порт" hdr_status="Статус" hdr_src="Источник" hdr_svc="Сервис"
  local w_port=16 w_status=16 w_src=16 w_svc=24

  msg ""
  printf "  ${BOLD}${WHITE} %-${w_port}s  %-${w_status}s  %-${w_src}s  %-${w_svc}s${NC}\n" \
    "$hdr_port" "$hdr_status" "$hdr_src" "$hdr_svc"
  msg "  ${GRAY}$(printf '─%.0s' $(seq 1 $((w_port + w_status + w_src + w_svc + 6))))${NC}"

  unused_ports=()

  # Используем уже собранные правила из port_set (работает и при выключенном UFW)
  # Фильтруем дублирующие /tcp и /udp записи если есть общее правило без протокола
  declare -A display_ports
  local k
  for k in "${!port_set[@]}"; do
    [[ -z "$k" || "$k" == "--" ]] && continue
    # Если есть правило без протокола (напр. "80"), пропускаем авто-дубли "80/tcp" и "80/udp"
    if [[ "$k" =~ ^([0-9:]+)/(tcp|udp)$ ]]; then
      local base="${BASH_REMATCH[1]}"
      [[ -n "${port_set[$base]:-}" ]] && continue
    fi
    display_ports["$k"]=1
  done

  mapfile -t entries < <(printf "%s\n" "${!display_ports[@]}" | sort -V)

  local e
  for e in "${entries[@]}"; do
    [[ -z "$e" || "$e" == "--" ]] && continue

    # Пропуск игнорируемых
    local skip=false p
    for p in "${IGNORE_PORTS[@]}"; do
      [[ "$e" == "$p" ]] && { skip=true; break; }
    done
    [[ "$skip" == true ]] && continue

    # Определяем использование
    local used=false
    if [[ -n "${used_map["$e"]:-}" ]]; then
      used=true
    elif [[ ! "$e" =~ / ]]; then
      [[ -n "${used_map["${e}/tcp"]:-}" || -n "${used_map["${e}/udp"]:-}" ]] && used=true
    fi

    # Статус
    local status_text status_color
    if [[ "$used" == true ]]; then
      status_text="${ICON_OK} Используется"
      status_color="$GREEN"
    elif [[ "${rule_action["$e"]:-ALLOW}" == "DENY" ]]; then
      status_text="${ICON_LOCK} Блокирует"
      status_color="$YELLOW"
    else
      status_text="${ICON_FAIL} Не используется"
      status_color="$RED"
      unused_ports+=("$e")
    fi

    # Источник
    local source="${rule_source["$e"]:-Anywhere}"
    (( ${#source} > w_src )) && source="${source:0:$((w_src - 3))}…"

    # Сервис
    local svc="${service_map["$e"]:-}"
    if [[ -z "$svc" && ! "$e" =~ / ]]; then
      svc="${service_map["${e}/tcp"]:-}"
      [[ -z "$svc" ]] && svc="${service_map["${e}/udp"]:-}"
    fi
    [[ -z "$svc" ]] && svc="${DIM}-${NC}"

    # Иконки для типа сервиса
    if [[ "$svc" == *"docker:"* || "$svc" == *"podman:"* ]]; then
      svc="${ICON_DOCKER} ${svc}"
    elif [[ "$svc" == *"сервис:"* ]]; then
      svc="${ICON_GEAR} ${svc}"
    fi

    printf "  ${status_color}%-${w_port}s${NC}  ${status_color}%-${w_status}s${NC}  ${GRAY}%-${w_src}s${NC}  ${BLUE}%b${NC}\n" \
      "$e" "$status_text" "$source" "$svc"
  done

  msg "  ${GRAY}$(printf '─%.0s' $(seq 1 $((w_port + w_status + w_src + w_svc + 6))))${NC}"

  # Статистика
  local total=${#entries[@]} unused_count=${#unused_ports[@]}
  local used_count=$(( total - unused_count ))
  msg ""
  msg "  ${WHITE}${BOLD}Итого:${NC} ${WHITE}${total}${NC} правил  ${GREEN}${ICON_OK} ${used_count} используются${NC}  ${RED}${ICON_FAIL} ${unused_count} не используются${NC}"

  # Неоткрытые порты
  if (( ${#missing_ports[@]} )); then
    msg ""
    msg "  ${YELLOW}${BOLD}${ICON_WARN} Используемые порты, не открытые в UFW:${NC}"
    msg "  ${GRAY}$(printf '─%.0s' $(seq 1 48))${NC}"

    mapfile -t unique_missing < <(printf "%s\n" "${missing_ports[@]}" | sort -u)
    local mp
    for mp in "${unique_missing[@]}"; do
      [[ -z "$mp" ]] && continue
      local svc="${service_map["$mp"]:-"-"}"
      if [[ "$svc" == *"docker:"* || "$svc" == *"podman:"* ]]; then
        svc="${ICON_DOCKER} ${svc}"
      elif [[ "$svc" == *"сервис:"* ]]; then
        svc="${ICON_GEAR} ${svc}"
      fi
      printf "    ${YELLOW}${ICON_BULLET}${NC} %-16s ${BLUE}%b${NC}\n" "$mp" "$svc"
    done
  fi
}

# ═════════════════════════════════════════════════════════════════════════════
#  Удаление одного правила UFW
# ═════════════════════════════════════════════════════════════════════════════

delete_ufw_rule() {
  local r="$1"

  if [[ "$r" =~ ^([0-9]+):([0-9]+)/(tcp|udp)$ ]]; then
    # Диапазон с протоколом
    local s="${BASH_REMATCH[1]}" t="${BASH_REMATCH[2]}" pr="${BASH_REMATCH[3]}"
    msg_info "Удаляю ${WHITE}${s}:${t}/${pr}${NC}…"
    if $DRY_RUN; then
      msg "    ${DIM}(dry-run) ufw delete allow proto $pr from any to any port ${s}:${t}${NC}"
    else
      local out
      out=$(ufw delete allow proto "$pr" from any to any port "${s}:${t}" 2>&1) || true
      _report_delete "$out"
    fi

  elif [[ "$r" =~ ^([0-9]+):([0-9]+)$ ]]; then
    # Диапазон без протокола
    local s="${BASH_REMATCH[1]}" t="${BASH_REMATCH[2]}"
    local pr
    for pr in tcp udp; do
      msg_info "Удаляю ${WHITE}${s}:${t}/${pr}${NC}…"
      if $DRY_RUN; then
        msg "    ${DIM}(dry-run) ufw delete allow proto $pr from any to any port ${s}:${t}${NC}"
      else
        local out
        out=$(ufw delete allow proto "$pr" from any to any port "${s}:${t}" 2>&1) || true
        _report_delete "$out"
      fi
    done

  elif [[ "$r" =~ ^([0-9]+)/(tcp|udp)$ ]]; then
    # Порт с протоколом
    msg_info "Удаляю ${WHITE}${r}${NC}…"
    if $DRY_RUN; then
      msg "    ${DIM}(dry-run) ufw delete allow ${r}${NC}"
    else
      local out
      out=$(ufw delete allow "${r}" 2>&1) || true
      _report_delete "$out"
    fi

  else
    # Порт без протокола
    msg_info "Удаляю ${WHITE}${r}${NC}…"
    if $DRY_RUN; then
      msg "    ${DIM}(dry-run) ufw delete allow ${r}${NC}"
    else
      local action="${rule_action["$r"]:-allow}"
      action="${action,,}"  # lowercase
      local out
      out=$(ufw delete "$action" "$r" 2>&1) || true

      if [[ "$out" == *"Could not delete non-existent rule"* ]]; then
        # Пробуем с протоколом
        local tcp_out udp_out
        tcp_out=$(ufw delete "$action" "$r/tcp" 2>&1) || true
        udp_out=$(ufw delete "$action" "$r/udp" 2>&1) || true
        if [[ "$tcp_out" == *"Could not delete"* && "$udp_out" == *"Could not delete"* ]]; then
          msg_fail "Правило не найдено ни с TCP, ни с UDP"
        else
          [[ "$tcp_out" != *"Could not delete"* ]] && msg_ok "$tcp_out"
          [[ "$udp_out" != *"Could not delete"* ]] && msg_ok "$udp_out"
        fi
      else
        _report_delete "$out"
      fi
    fi
  fi
}

_report_delete() {
  local out="$1"
  if [[ "$out" == *"Could not delete non-existent rule"* ]]; then
    msg_fail "Правило не существует"
  else
    msg_ok "$out"
  fi
}

# ═════════════════════════════════════════════════════════════════════════════
#  Интерактивная очистка
# ═════════════════════════════════════════════════════════════════════════════

cleanup() {
  # Проверяем есть ли вообще что-то делать
  local has_work=false
  (( ${#missing_ports[@]} )) && has_work=true
  (( ${#unused_ports[@]} )) && has_work=true

  if ! $initial_active; then
    msg ""
    if [[ "$has_work" == true ]]; then
      msg_warn "UFW выключен."
      read -r -p "  Включить UFW для применения изменений? (y/n): " ans
      if [[ $ans =~ ^[Yy]$ ]]; then
        $DRY_RUN || { ufw --force enable && log "ENABLE"; }
      else
        msg_warn "Включите UFW и перезапустите."
        exit 0
      fi
    else
      msg_info "UFW выключен. Нет правил для изменения."
      msg_warn "Рекомендуется включить UFW: ${WHITE}ufw --force enable${NC}"
      return 0
    fi
  fi

  # Добавление неоткрытых портов
  if (( ${#missing_ports[@]} )); then
    mapfile -t unique_missing < <(printf "%s\n" "${missing_ports[@]}" | sort -u)
    msg ""
    msg_warn "Рекомендация: открыть порты ${GREEN}${unique_missing[*]}${NC}"
    read -r -p "  Открыть? (y/n): " ans
    if [[ $ans =~ ^[Yy]$ ]]; then
      local mp
      for mp in "${unique_missing[@]}"; do
        msg_info "Открываю ${WHITE}${mp}${NC}…"
        if $DRY_RUN; then
          msg "    ${DIM}(dry-run) ufw allow ${mp}${NC}"
        else
          local out
          out=$(ufw allow "$mp" 2>&1) || true
          msg_ok "$out"
          log "ALLOW $mp"
        fi
      done
    fi
  fi

  # Удаление неиспользуемых портов
  if (( ${#unused_ports[@]} )); then
    msg ""
    msg_warn "Рекомендация: удалить ${RED}${unused_ports[*]}${NC}"
    read -r -p "  Удалить? (y/n): " ans
    if [[ $ans =~ ^[Yy]$ ]]; then
      local r
      for r in "${unused_ports[@]}"; do
        [[ "$r" == "--" ]] && continue
        delete_ufw_rule "$r"
        log "DELETE $r"
      done
    fi
  else
    msg ""
    msg_ok "${WHITE}Все порты используются или являются блокирующими. Очистка не требуется.${NC}"
  fi
}

# ═════════════════════════════════════════════════════════════════════════════
#  MAIN
# ═════════════════════════════════════════════════════════════════════════════

main() {
  ensure_root
  load_config

  show_banner

  if $DRY_RUN; then
    msg "  ${YELLOW}${BOLD}${ICON_WARN} Режим симуляции (--dry-run) — изменения не будут применены${NC}"
  fi

  # Резервная копия
  if ! $DRY_RUN && $initial_active; then
    backup_rules
  fi

  parse_rules
  check_used
  add_ssh
  print_table
  cleanup

  msg ""
  msg "  ${GREEN}${BOLD}${ICON_OK} Готово!${NC}"
  msg ""
}

main
