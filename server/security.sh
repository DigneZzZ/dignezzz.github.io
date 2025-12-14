#!/bin/bash

# SSH Security Configuration Script
# Created by GIG.ovh Community
# https://gig.ovh

set -euo pipefail

# ==================== Константы ====================
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[1;34m'
readonly CYAN='\033[1;36m'
readonly NC='\033[0m'

readonly SSHD_CONFIG="/etc/ssh/sshd_config"

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
  esac
}

# ==================== Проверки ====================
check_root() {
  if [[ "$EUID" -ne 0 ]]; then
    log_error "Пожалуйста, запустите скрипт от root или через sudo."
    log_error "Please run script as root or via sudo."
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
  command -v sshd >/dev/null 2>&1 && sshd -t -f "$SSHD_CONFIG" 2>/dev/null
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
    "MaxSessions 2"
    "MaxStartups 10:30:60"
    "AllowTcpForwarding local"
    "X11Forwarding no"
    "ClientAliveInterval 300"
    "ClientAliveCountMax 0"
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
  confirm_changes
  
  # Инициализация переменных
  local authorized_keys
  authorized_keys=$(get_authorized_keys_path)
  local config_backup="${SSHD_CONFIG}.bak_$(date +%Y%m%d_%H%M%S)"
  
  # Проверяем наличие публичных ключей
  if [[ ! -s "$authorized_keys" ]]; then
    msg error_key
    msg keys_path "$authorized_keys"
    exit 1
  fi
  
  # Создаём резервную копию
  cp "$SSHD_CONFIG" "$config_backup"
  msg backup_created
  echo -e "${BLUE}$config_backup${NC}"
  
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
  
  # Применяем настройки безопасности
  apply_security_settings
  
  # Устанавливаем права доступа
  set_permissions "$authorized_keys"
  
  # Проверяем корректность конфигурации
  if ! test_sshd_config; then
    msg invalid_config
    cp "$config_backup" "$SSHD_CONFIG"
    exit 1
  fi
  
  # Перезапускаем SSH
  local ssh_service
  ssh_service=$(get_ssh_service)
  
  if ! restart_ssh_service "$ssh_service" "$config_backup"; then
    exit 1
  fi
  
  # Финальные сообщения
  msg done
  echo
  msg final_warning
  
  local ssh_port
  ssh_port=$(grep -E '^Port' "$SSHD_CONFIG" | awk '{print $2}')
  echo -e "${CYAN}SSH порт: ${NC}${ssh_port:-22}"
  echo
  echo -e "${CYAN}© GIG.ovh Community - https://gig.ovh${NC}"
}

# Запуск скрипта
main "$@"
