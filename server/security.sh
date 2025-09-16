#!/bin/bash

# SSH Security Configuration Script
# Created by GIG.ovh Community
# https://gig.ovh

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Пожалуйста, запустите скрипт от root или через sudo.${NC}"
  exit 1
fi

echo -e "${CYAN}Choose language / Выберите язык:${NC}"
echo "1) English"
echo "2) Русский"
read -r -p "[1/2] (default 1): " lang_choice
lang_choice=${lang_choice:-1}

if [ "$lang_choice" = "2" ]; then
  MSG_ERROR_KEY="${RED}Ошибка:${NC} файл authorized_keys пуст или отсутствует. Добавьте публичный ключ перед продолжением."
  MSG_BACKUP_CREATED="${GREEN}Создана резервная копия конфигурации SSH:${NC}"
  MSG_SSH_RESTART_SUCCESS="${GREEN}SSH успешно перезапущен.${NC}"
  MSG_SSH_RESTART_FAIL="${RED}Ошибка:${NC} Не удалось перезапустить SSH. Восстанавливаю исходный конфиг..."
  MSG_DONE="${GREEN}Настройки SSH успешно обновлены.${NC}"
  MSG_SSH_VERSION="${BLUE}Обнаружена версия OpenSSH:${NC}"
  MSG_FINAL_WARNING="${YELLOW}ВАЖНО:${NC} Убедитесь, что можете подключиться по SSH с новыми настройками!"
else
  MSG_ERROR_KEY="${RED}Error:${NC} authorized_keys file is empty or missing. Please add a public key before continuing."
  MSG_BACKUP_CREATED="${GREEN}Backup of SSH configuration created:${NC}"
  MSG_SSH_RESTART_SUCCESS="${GREEN}SSH successfully restarted.${NC}"
  MSG_SSH_RESTART_FAIL="${RED}Error:${NC} Could not restart SSH. Restoring original config..."
  MSG_DONE="${GREEN}SSH settings successfully updated.${NC}"
  MSG_SSH_VERSION="${BLUE}Detected OpenSSH version:${NC}"
  MSG_FINAL_WARNING="${YELLOW}IMPORTANT:${NC} Make sure you can connect via SSH with the new settings!"
fi

if [ "$lang_choice" = "2" ]; then
  echo -e "${YELLOW}Будут выполнены следующие изменения:${NC}"
  echo -e "- ${RED}Отключение авторизации по паролю${NC}"
  echo -e "- ${RED}Ограничение входа по SSH${NC}"
  echo -e "- ${RED}Установка строгих прав на SSH${NC}"
  echo
  echo -e "${GREEN}Продолжить?${NC} [Y/n]"
else
  echo -e "${YELLOW}The following changes will be applied:${NC}"
  echo -e "- ${RED}Disable password authentication${NC}"
  echo -e "- ${RED}SSH access restriction${NC}"
  echo -e "- ${RED}Set strict permissions on SSH${NC}"
  echo
  echo -e "${GREEN}Continue?${NC} [Y/n]"
fi

read -r answer
answer=${answer:-Y}
if [[ ! "$answer" =~ ^[Yy]$ ]]; then
  if [ "$lang_choice" = "2" ]; then
    echo -e "${RED}Операция отменена пользователем.${NC}"
  else
    echo -e "${RED}Operation cancelled by user.${NC}"
  fi
  exit 0
fi

SSHD_CONFIG="/etc/ssh/sshd_config"
# Правильно определяем путь к authorized_keys для root
if [ "$USER" = "root" ] || [ "$EUID" -eq 0 ]; then
  AUTHORIZED_KEYS="/root/.ssh/authorized_keys"
else
  AUTHORIZED_KEYS="$HOME/.ssh/authorized_keys"
fi
SSHD_CONFIG_BACKUP="${SSHD_CONFIG}.bak_$(date +%Y%m%d_%H%M%S)"

# Проверяем наличие публичных ключей
if [ ! -s "$AUTHORIZED_KEYS" ]; then
  echo -e "$MSG_ERROR_KEY"
  if [ "$lang_choice" = "2" ]; then
    echo -e "${YELLOW}Путь к файлу ключей: ${BLUE}$AUTHORIZED_KEYS${NC}"
  else
    echo -e "${YELLOW}Keys file path: ${BLUE}$AUTHORIZED_KEYS${NC}"
  fi
  exit 1
fi

cp "$SSHD_CONFIG" "$SSHD_CONFIG_BACKUP"
echo -e "$MSG_BACKUP_CREATED ${BLUE}$SSHD_CONFIG_BACKUP${NC}"

# Определяем ОС для информации
if [ -f /etc/os-release ]; then
  OS_NAME=$(grep '^NAME=' /etc/os-release | cut -d'"' -f2)
  if [ "$lang_choice" = "2" ]; then
    echo -e "${CYAN}Операционная система: ${BLUE}$OS_NAME${NC}"
  else
    echo -e "${CYAN}Operating System: ${BLUE}$OS_NAME${NC}"
  fi
fi

# Получаем версию OpenSSH
SSH_VERSION=$(ssh -V 2>&1 | grep -oE '[0-9]+\.[0-9]+' | head -1)

# Показываем версию OpenSSH для информации
if command -v ssh >/dev/null 2>&1; then
  echo -e "$MSG_SSH_VERSION ${BLUE}$SSH_VERSION${NC}"
fi
SSH_MAJOR=$(echo "$SSH_VERSION" | cut -d. -f1)
SSH_MINOR=$(echo "$SSH_VERSION" | cut -d. -f2)

add_config_if_missing() {
  PARAM_NAME=$(echo "$1" | awk '{print $1}')
  if grep -qE "^[#\\s]*${PARAM_NAME}\\s" "$SSHD_CONFIG"; then
    sed -i "s|^[#\\s]*${PARAM_NAME}\\s.*|$1|" "$SSHD_CONFIG"
  else
    echo "$1" >> "$SSHD_CONFIG"
  fi
}

# Проверка синтаксиса конфигурации
test_sshd_config() {
  if command -v sshd >/dev/null 2>&1; then
    sshd -t -f "$SSHD_CONFIG" 2>/dev/null
  else
    return 0  # Если sshd недоступен, предполагаем, что конфиг корректен
  fi
}

# Основные настройки безопасности
add_config_if_missing "PubkeyAuthentication yes"
add_config_if_missing "AuthorizedKeysFile %h/.ssh/authorized_keys"
add_config_if_missing "HostbasedAuthentication no"
add_config_if_missing "PermitEmptyPasswords no"
add_config_if_missing "PasswordAuthentication no"
add_config_if_missing "PermitRootLogin prohibit-password"

# Настройки в зависимости от версии OpenSSH
if [ "$SSH_MAJOR" -gt 8 ] || ([ "$SSH_MAJOR" -eq 8 ] && [ "$SSH_MINOR" -ge 7 ]); then
  # OpenSSH 8.7+ использует KbdInteractiveAuthentication вместо ChallengeResponseAuthentication
  add_config_if_missing "KbdInteractiveAuthentication no"
else
  add_config_if_missing "ChallengeResponseAuthentication no"
fi

# Только для OpenSSH 7.4 и ранее
if [ "$SSH_MAJOR" -lt 8 ] && [ "$SSH_MINOR" -lt 4 ]; then
  add_config_if_missing "RhostsRSAAuthentication no"
fi

# PubkeyAcceptedAlgorithms доступен с OpenSSH 8.5+
if [ "$SSH_MAJOR" -gt 8 ] || ([ "$SSH_MAJOR" -eq 8 ] && [ "$SSH_MINOR" -ge 5 ]); then
  add_config_if_missing "PubkeyAcceptedAlgorithms rsa-sha2-512,rsa-sha2-256,ssh-rsa,ecdsa-sha2-nistp256,ecdsa-sha2-nistp384,ecdsa-sha2-nistp521,ssh-ed25519"
fi

# Дополнительные настройки безопасности
add_config_if_missing "LoginGraceTime 30s"
add_config_if_missing "MaxAuthTries 3"
add_config_if_missing "MaxSessions 2"
add_config_if_missing "MaxStartups 10:30:60"
add_config_if_missing "AllowTcpForwarding local"
add_config_if_missing "X11Forwarding no"
add_config_if_missing "ClientAliveInterval 300"
add_config_if_missing "ClientAliveCountMax 0"
add_config_if_missing "Compression no"
add_config_if_missing "TCPKeepAlive yes"
add_config_if_missing "UseDNS no"

chmod 700 "$(dirname "$AUTHORIZED_KEYS")" 2>/dev/null
chmod 600 "$AUTHORIZED_KEYS" 2>/dev/null
chmod 600 "$SSHD_CONFIG"

# Проверяем корректность конфигурации
if ! test_sshd_config; then
  if [ "$lang_choice" = "2" ]; then
    echo -e "${RED}Ошибка:${NC} Некорректная конфигурация SSH. Восстанавливаю исходный файл..."
  else
    echo -e "${RED}Error:${NC} Invalid SSH configuration. Restoring original file..."
  fi
  cp "$SSHD_CONFIG_BACKUP" "$SSHD_CONFIG"
  exit 1
fi

# Определяем имя SSH сервиса
SSH_SERVICE=""
if systemctl is-enabled sshd.service >/dev/null 2>&1; then
  SSH_SERVICE="sshd.service"
elif systemctl is-enabled ssh.service >/dev/null 2>&1; then
  SSH_SERVICE="ssh.service"
elif [ -f /etc/systemd/system/sshd.service ] || [ -f /usr/lib/systemd/system/sshd.service ]; then
  SSH_SERVICE="sshd.service"
else
  SSH_SERVICE="ssh.service"
fi

# Перезапускаем SSH сервис
if systemctl restart "$SSH_SERVICE"; then
  echo -e "$MSG_SSH_RESTART_SUCCESS"
  
  # Проверяем, что SSH сервис действительно работает
  sleep 2
  if ! systemctl is-active "$SSH_SERVICE" >/dev/null 2>&1; then
    if [ "$lang_choice" = "2" ]; then
      echo -e "${YELLOW}Предупреждение:${NC} SSH сервис перезапущен, но может работать некорректно. Проверьте подключение."
    else
      echo -e "${YELLOW}Warning:${NC} SSH service restarted but may not be working correctly. Check connection."
    fi
  fi
else
  echo -e "$MSG_SSH_RESTART_FAIL"
  cp "$SSHD_CONFIG_BACKUP" "$SSHD_CONFIG"
  systemctl restart "$SSH_SERVICE"
  exit 1
fi

echo -e "$MSG_DONE"
echo
echo -e "$MSG_FINAL_WARNING"
echo -e "${CYAN}SSH порт: ${NC}$(grep -E '^Port' $SSHD_CONFIG | awk '{print $2}' || echo '22')"
echo
echo -e "${CYAN}© GIG.ovh Community - https://gig.ovh${NC}"
