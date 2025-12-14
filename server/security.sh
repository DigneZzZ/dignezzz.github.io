#!/bin/bash

# SSH Security Configuration Script
# Created by GIG.ovh Community
# https://gig.ovh
# Version: 2.0.0

set -euo pipefail

# ==================== Константы ====================
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[1;34m'
readonly CYAN='\033[1;36m'
readonly NC='\033[0m'

readonly SSHD_CONFIG="/etc/ssh/sshd_config"

# Глобальные переменные для версии SSH (инициализируются позже)
SSH_VERSION=""
SSH_MAJOR=0
SSH_MINOR=0

# Переменная для резервной копии (для trap)
CONFIG_BACKUP=""

# Язык по умолчанию
LANG_RU=false

# ==================== Утилиты ====================
log_info() { echo -e "${CYAN}$1${NC}"; }
log_success() { echo -e "${GREEN}$1${NC}"; }
log_warning() { echo -e "${YELLOW}$1${NC}"; }
log_error() { echo -e "${RED}$1${NC}"; }

# Универсальная функция для локализованных сообщений
msg() {
  local key="$1"
  shift
  local args=("$@")
  
  case "$key" in
    error_key)
      [[ "$LANG_RU" == true ]] && echo -e "${RED}Ошибка:${NC} файл authorized_keys пуст или отсутствует. Добавьте публичный ключ перед продолжением." \
        || echo -e "${RED}Error:${NC} authorized_keys file is empty or missing. Please add a public key before continuing." ;;
    backup_created)
      [[ "$LANG_RU" == true ]] && echo -e "${GREEN}Создана резервная копия конфигурации SSH:${NC}" \
        || echo -e "${GREEN}Backup of SSH configuration created:${NC}" ;;
    ssh_restart_success)
      [[ "$LANG_RU" == true ]] && log_success "SSH успешно перезапущен." \
        || log_success "SSH successfully restarted." ;;
    ssh_restart_fail)
      [[ "$LANG_RU" == true ]] && echo -e "${RED}Ошибка:${NC} Не удалось перезапустить SSH. Восстанавливаю исходный конфиг..." \
        || echo -e "${RED}Error:${NC} Could not restart SSH. Restoring original config..." ;;
    done)
      [[ "$LANG_RU" == true ]] && log_success "Настройки SSH успешно обновлены." \
        || log_success "SSH settings successfully updated." ;;
    ssh_version)
      [[ "$LANG_RU" == true ]] && echo -e "${BLUE}Обнаружена версия OpenSSH:${NC}" \
        || echo -e "${BLUE}Detected OpenSSH version:${NC}" ;;
    final_warning)
      [[ "$LANG_RU" == true ]] && log_warning "ВАЖНО: Убедитесь, что можете подключиться по SSH с новыми настройками!" \
        || log_warning "IMPORTANT: Make sure you can connect via SSH with the new settings!" ;;
    keys_path)
      [[ "$LANG_RU" == true ]] && echo -e "${YELLOW}Путь к файлу ключей: ${BLUE}${args[0]}${NC}" \
        || echo -e "${YELLOW}Keys file path: ${BLUE}${args[0]}${NC}" ;;
    os_name)
      [[ "$LANG_RU" == true ]] && echo -e "${CYAN}Операционная система: ${BLUE}${args[0]}${NC}" \
        || echo -e "${CYAN}Operating System: ${BLUE}${args[0]}${NC}" ;;
    cancelled)
      [[ "$LANG_RU" == true ]] && log_error "Операция отменена пользователем." \
        || log_error "Operation cancelled by user." ;;
    invalid_config)
      [[ "$LANG_RU" == true ]] && echo -e "${RED}Ошибка:${NC} Некорректная конфигурация SSH. Восстанавливаю исходный файл..." \
        || echo -e "${RED}Error:${NC} Invalid SSH configuration. Restoring original file..." ;;
    service_warning)
      [[ "$LANG_RU" == true ]] && log_warning "Предупреждение: SSH сервис перезапущен, но может работать некорректно. Проверьте подключение." \
        || log_warning "Warning: SSH service restarted but may not be working correctly. Check connection." ;;
    invalid_keys)
      [[ "$LANG_RU" == true ]] && echo -e "${RED}Ошибка:${NC} В файле authorized_keys не найдено валидных SSH-ключей." \
        || echo -e "${RED}Error:${NC} No valid SSH keys found in authorized_keys file." ;;
    keys_found)
      [[ "$LANG_RU" == true ]] && echo -e "${GREEN}Найдено валидных SSH-ключей:${NC} ${args[0]}" \
        || echo -e "${GREEN}Valid SSH keys found:${NC} ${args[0]}" ;;
    include_warning)
      [[ "$LANG_RU" == true ]] && log_warning "Обнаружены Include директивы! Конфиги из включённых файлов могут перезаписать настройки." \
        || log_warning "Include directives detected! Configs from included files may override settings." ;;
    include_fixed)
      [[ "$LANG_RU" == true ]] && echo -e "${GREEN}Настройки безопасности применены ко всем включённым конфигам.${NC}" \
        || echo -e "${GREEN}Security settings applied to all included configs.${NC}" ;;
  esac
}

# ==================== Очистка при прерывании ====================
cleanup() {
  local exit_code=$?
  if [[ -n "$CONFIG_BACKUP" && -f "$CONFIG_BACKUP" && $exit_code -ne 0 ]]; then
    if [[ "$LANG_RU" == true ]]; then
      log_warning "Прерывание! Восстанавливаю исходный конфиг..."
    else
      log_warning "Interrupted! Restoring original config..."
    fi
    cp "$CONFIG_BACKUP" "$SSHD_CONFIG" 2>/dev/null || true
  fi
  exit $exit_code
}

trap cleanup INT TERM

# ==================== Проверки ====================
check_root() {
  if [[ "$EUID" -ne 0 ]]; then
    # До выбора языка выводим на обоих языках
    log_error "Please run script as root or via sudo."
    log_error "Пожалуйста, запустите скрипт от root или через sudo."
    exit 1
  fi
}

check_sshd_config_exists() {
  if [[ ! -f "$SSHD_CONFIG" ]]; then
    if [[ "$LANG_RU" == true ]]; then
      log_error "Файл конфигурации SSH не найден: $SSHD_CONFIG"
    else
      log_error "SSH configuration file not found: $SSHD_CONFIG"
    fi
    exit 1
  fi
}

check_ssh_installed() {
  if ! command -v sshd >/dev/null 2>&1; then
    if [[ "$LANG_RU" == true ]]; then
      log_error "SSH сервер (sshd) не установлен в системе."
    else
      log_error "SSH server (sshd) is not installed on the system."
    fi
    exit 1
  fi
}

# ==================== Выбор языка ====================
select_language() {
  log_info "Choose language / Выберите язык:"
  echo "1) English"
  echo "2) Русский"
  read -r -p "[1/2] (default 1): " lang_choice
  lang_choice=${lang_choice:-1}
  
  [[ "$lang_choice" == "2" ]] && LANG_RU=true || LANG_RU=false
}

# ==================== Подтверждение ====================
confirm_changes() {
  if [[ "$LANG_RU" == true ]]; then
    log_warning "Будут выполнены следующие изменения:"
    echo -e "- ${RED}Отключение авторизации по паролю${NC}"
    echo -e "- ${RED}Ограничение входа по SSH${NC}"
    echo -e "- ${RED}Установка строгих прав на SSH${NC}"
    echo
    log_success "Продолжить? [Y/n]"
  else
    log_warning "The following changes will be applied:"
    echo -e "- ${RED}Disable password authentication${NC}"
    echo -e "- ${RED}SSH access restriction${NC}"
    echo -e "- ${RED}Set strict permissions on SSH${NC}"
    echo
    log_success "Continue? [Y/n]"
  fi

  read -r answer
  answer=${answer:-Y}
  if [[ ! "$answer" =~ ^[Yy]$ ]]; then
    msg cancelled
    exit 0
  fi
}

# ==================== Определение путей ====================
get_authorized_keys_path() {
  if [[ "$EUID" -eq 0 ]]; then
    echo "/root/.ssh/authorized_keys"
  else
    echo "$HOME/.ssh/authorized_keys"
  fi
}

# ==================== Валидация SSH ключей ====================
# Проверяет, что в authorized_keys есть хотя бы один валидный ключ
validate_ssh_keys() {
  local authorized_keys="$1"
  local valid_key_count=0
  
  # Допустимые типы ключей
  local key_types="ssh-rsa|ssh-dss|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519|sk-ecdsa-sha2-nistp256"
  
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Пропускаем пустые строки и комментарии
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    
    # Проверяем, начинается ли строка с валидного типа ключа
    if echo "$line" | grep -qE "^($key_types)[[:space:]]"; then
      ((valid_key_count++))
    fi
  done < "$authorized_keys"
  
  echo "$valid_key_count"
}

# ==================== Обработка Include директив ====================
# Находит все включённые конфиги и применяет к ним те же настройки
get_included_configs() {
  local includes=()
  
  # Ищем Include директивы в основном конфиге
  while IFS= read -r line; do
    # Извлекаем путь из Include директивы
    local include_path
    include_path=$(echo "$line" | sed -E 's/^[[:space:]]*Include[[:space:]]+//' | tr -d '"')
    
    # Разворачиваем glob-паттерны
    for file in $include_path; do
      [[ -f "$file" ]] && includes+=("$file")
    done
  done < <(grep -iE '^[[:space:]]*Include[[:space:]]' "$SSHD_CONFIG" 2>/dev/null || true)
  
  printf '%s\n' "${includes[@]}"
}

# Применяет критичные настройки безопасности к включённому конфигу
apply_security_to_included() {
  local config_file="$1"
  
  # Критичные настройки, которые должны быть одинаковыми везде
  local critical_settings=(
    "PasswordAuthentication no"
    "PermitEmptyPasswords no"
    "PubkeyAuthentication yes"
  )
  
  for setting in "${critical_settings[@]}"; do
    local param_name="${setting%% *}"
    
    # Если параметр есть в файле — обновляем, если нет — не добавляем (чтобы не засорять)
    if grep -qE "^[#[:space:]]*${param_name}[[:space:]]" "$config_file" 2>/dev/null; then
      sed -i '' "s|^[#[:space:]]*${param_name}[[:space:]].*|${setting}|" "$config_file" 2>/dev/null || \
      sed -i "s|^[#[:space:]]*${param_name}[[:space:]].*|${setting}|" "$config_file"
    fi
  done
}

# ==================== Работа с конфигурацией ====================
add_or_update_config() {
  local param_value="$1"
  local param_name="${param_value%% *}"
  
  if grep -qE "^[#[:space:]]*${param_name}[[:space:]]" "$SSHD_CONFIG"; then
    sed -i '' "s|^[#[:space:]]*${param_name}[[:space:]].*|${param_value}|" "$SSHD_CONFIG" 2>/dev/null || \
    sed -i "s|^[#[:space:]]*${param_name}[[:space:]].*|${param_value}|" "$SSHD_CONFIG"
  else
    echo "$param_value" >> "$SSHD_CONFIG"
  fi
}

test_sshd_config() {
  if ! command -v sshd >/dev/null 2>&1; then
    log_error "sshd not found"
    return 1
  fi
  sshd -t -f "$SSHD_CONFIG" 2>/dev/null
}

# ==================== Версия SSH ====================
get_ssh_version() {
  ssh -V 2>&1 | grep -oE '[0-9]+\.[0-9]+' | head -1
}

ssh_version_ge() {
  local required_major="$1"
  local required_minor="$2"
  
  [[ "$SSH_MAJOR" -gt "$required_major" ]] || \
  [[ "$SSH_MAJOR" -eq "$required_major" && "$SSH_MINOR" -ge "$required_minor" ]]
}

ssh_version_lt() {
  local required_major="$1"
  local required_minor="$2"
  
  [[ "$SSH_MAJOR" -lt "$required_major" ]] || \
  [[ "$SSH_MAJOR" -eq "$required_major" && "$SSH_MINOR" -lt "$required_minor" ]]
}

# ==================== Определение SSH сервиса ====================
get_ssh_service() {
  if systemctl is-enabled sshd.service >/dev/null 2>&1; then
    echo "sshd.service"
  elif systemctl is-enabled ssh.service >/dev/null 2>&1; then
    echo "ssh.service"
  elif [[ -f /etc/systemd/system/sshd.service ]] || [[ -f /usr/lib/systemd/system/sshd.service ]]; then
    echo "sshd.service"
  else
    echo "ssh.service"
  fi
}

# ==================== Применение настроек безопасности ====================
apply_security_settings() {
  # Основные настройки безопасности
  local base_settings=(
    "PubkeyAuthentication yes"
    "AuthorizedKeysFile %h/.ssh/authorized_keys"
    "HostbasedAuthentication no"
    "PermitEmptyPasswords no"
    "PasswordAuthentication no"
    "PermitRootLogin prohibit-password"
    "StrictModes yes"
  )
  
  for setting in "${base_settings[@]}"; do
    add_or_update_config "$setting"
  done

  # Настройки в зависимости от версии OpenSSH
  if ssh_version_ge 8 7; then
    add_or_update_config "KbdInteractiveAuthentication no"
  else
    add_or_update_config "ChallengeResponseAuthentication no"
  fi

  # Только для OpenSSH < 7.4
  if ssh_version_lt 7 4; then
    add_or_update_config "RhostsRSAAuthentication no"
  fi

  # PubkeyAcceptedAlgorithms доступен с OpenSSH 8.5+
  if ssh_version_ge 8 5; then
    add_or_update_config "PubkeyAcceptedAlgorithms rsa-sha2-512,rsa-sha2-256,ssh-rsa,ecdsa-sha2-nistp256,ecdsa-sha2-nistp384,ecdsa-sha2-nistp521,ssh-ed25519"
  fi

  # Дополнительные настройки безопасности
  local additional_settings=(
    "LoginGraceTime 30s"
    "MaxAuthTries 3"
    "MaxSessions 5"
    "MaxStartups 10:30:60"
    "AllowTcpForwarding local"
    "X11Forwarding no"
    "ClientAliveInterval 300"
    "ClientAliveCountMax 3"
    "Compression no"
    "TCPKeepAlive yes"
    "UseDNS no"
  )
  
  for setting in "${additional_settings[@]}"; do
    add_or_update_config "$setting"
  done
}

# ==================== Установка прав доступа ====================
set_permissions() {
  local authorized_keys="$1"
  chmod 700 "$(dirname "$authorized_keys")" 2>/dev/null || true
  chmod 600 "$authorized_keys" 2>/dev/null || true
  chmod 600 "$SSHD_CONFIG"
}

# ==================== Перезапуск SSH ====================
restart_ssh_service() {
  local ssh_service="$1"
  local config_backup="$2"
  
  if systemctl restart "$ssh_service"; then
    msg ssh_restart_success
    
    # Проверяем, что SSH сервис действительно работает
    sleep 2
    if ! systemctl is-active "$ssh_service" >/dev/null 2>&1; then
      msg service_warning
    fi
    return 0
  else
    msg ssh_restart_fail
    cp "$config_backup" "$SSHD_CONFIG"
    systemctl restart "$ssh_service"
    return 1
  fi
}

# ==================== Главная функция ====================
main() {
  check_root
  select_language
  
  # Проверяем наличие SSH сервера и конфига
  check_ssh_installed
  check_sshd_config_exists
  
  confirm_changes
  
  # Инициализация переменных
  local authorized_keys
  authorized_keys=$(get_authorized_keys_path)
  CONFIG_BACKUP="${SSHD_CONFIG}.bak_$(date +%Y%m%d_%H%M%S)"
  
  # Проверяем наличие файла ключей
  if [[ ! -s "$authorized_keys" ]]; then
    msg error_key
    msg keys_path "$authorized_keys"
    exit 1
  fi
  
  # Валидируем SSH ключи
  local valid_keys
  valid_keys=$(validate_ssh_keys "$authorized_keys")
  
  if [[ "$valid_keys" -eq 0 ]]; then
    msg invalid_keys
    msg keys_path "$authorized_keys"
    exit 1
  fi
  
  msg keys_found "$valid_keys"
  msg keys_path "$authorized_keys"
  
  # Создаём резервную копию
  cp "$SSHD_CONFIG" "$CONFIG_BACKUP"
  msg backup_created
  echo -e "${BLUE}$CONFIG_BACKUP${NC}"
  
  # Определяем ОС
  if [[ -f /etc/os-release ]]; then
    local os_name
    os_name=$(grep '^NAME=' /etc/os-release | cut -d'"' -f2)
    msg os_name "$os_name"
  fi
  
  # Получаем и выводим версию SSH
  SSH_VERSION=$(get_ssh_version)
  SSH_MAJOR="${SSH_VERSION%%.*}"
  SSH_MINOR="${SSH_VERSION#*.}"
  
  if command -v ssh >/dev/null 2>&1; then
    msg ssh_version
    echo -e "${BLUE}$SSH_VERSION${NC}"
  fi
  
  # Проверяем Include директивы и обрабатываем вложенные конфиги
  local included_configs
  mapfile -t included_configs < <(get_included_configs)
  
  if [[ ${#included_configs[@]} -gt 0 ]]; then
    msg include_warning
    echo -e "${YELLOW}Include files:${NC}"
    for inc_config in "${included_configs[@]}"; do
      echo -e "  ${BLUE}$inc_config${NC}"
      # Создаём резервную копию включённого конфига
      cp "$inc_config" "${inc_config}.bak_$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
      # Применяем критические настройки
      apply_security_to_included "$inc_config"
    done
    msg include_fixed
  fi
  
  # Применяем настройки безопасности к основному конфигу
  apply_security_settings
  
  # Устанавливаем права доступа
  set_permissions "$authorized_keys"
  
  # Проверяем корректность конфигурации
  if ! test_sshd_config; then
    msg invalid_config
    cp "$CONFIG_BACKUP" "$SSHD_CONFIG"
    exit 1
  fi
  
  # Перезапускаем SSH
  local ssh_service
  ssh_service=$(get_ssh_service)
  
  if ! restart_ssh_service "$ssh_service" "$CONFIG_BACKUP"; then
    exit 1
  fi
  
  # Финальные сообщения
  msg done
  echo
  msg final_warning
  
  local ssh_port
  ssh_port=$(grep -E '^Port' "$SSHD_CONFIG" | awk '{print $2}')
  echo -e "${CYAN}SSH порт / SSH port: ${NC}${ssh_port:-22}"
  echo
  echo -e "${CYAN}© GIG.ovh Community - https://gig.ovh${NC}"
}

# Запуск скрипта
main "$@"
