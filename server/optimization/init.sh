#!/bin/bash
set -euo pipefail

SSH_PORT=5322
SWAPFILE="/swapfile"
DASHBOARD_FILE="/etc/update-motd.d/99-dashboard"

# ------------------------------
# 1. Проверки и базовые пакеты
# ------------------------------
apt update && apt upgrade -y
apt install -y curl wget ufw fail2ban vnstat net-tools htop unzip jq vim gnupg software-properties-common tput

# ------------------------------
# 2. Fail2Ban — динамическая защита
# ------------------------------
if ! command -v fail2ban-server &>/dev/null; then
  apt install -y fail2ban
fi

cat >/etc/fail2ban/jail.local <<EOF
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
port = $SSH_PORT
filter = sshd
logpath = /var/log/auth.log
EOF

systemctl enable --now fail2ban

# ------------------------------
# 3. SSH — безопасная конфигурация
# ------------------------------
SSHD_CONFIG="/etc/ssh/sshd_config"
AUTHORIZED_KEYS="/root/.ssh/authorized_keys"

cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak_$(date +%Y%m%d_%H%M%S)"

sed -i "s/^#\?Port .*/Port $SSH_PORT/" "$SSHD_CONFIG"

declare -a ssh_settings=(
  "PubkeyAuthentication yes"
  "AuthorizedKeysFile %h/.ssh/authorized_keys"
  "RhostsRSAAuthentication no"
  "HostbasedAuthentication no"
  "PermitEmptyPasswords no"
  "PasswordAuthentication no"
  "ChallengeResponseAuthentication no"
  "PubkeyAcceptedAlgorithms +ssh-rsa"
  "Protocol 2"
  "LoginGraceTime 30s"
  "MaxAuthTries 3"
  "MaxSessions 2"
  "AllowTcpForwarding no"
  "X11Forwarding no"
  "ClientAliveInterval 300"
  "ClientAliveCountMax 0"
)

for setting in "${ssh_settings[@]}"; do
  key=$(echo "$setting" | awk '{print $1}')
  grep -qE "^\s*#?\s*${key}\s" "$SSHD_CONFIG" && sed -i "s|^\s*#\?\s*${key}\s.*|$setting|" "$SSHD_CONFIG" || echo "$setting" >> "$SSHD_CONFIG"
done

chmod 700 /root/.ssh
chmod 600 "$AUTHORIZED_KEYS"
chmod 600 "$SSHD_CONFIG"

systemctl restart ssh || systemctl restart sshd

# ------------------------------
# 4. UFW
# ------------------------------
ufw default deny incoming
ufw default allow outgoing
ufw allow "$SSH_PORT"/tcp
ufw --force enable

# ------------------------------
# 5. Swap — адаптивно к памяти и диску
# ------------------------------
if ! grep -q '^/swapfile ' /etc/fstab; then
  MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  DISK_BYTES=$(df --output=avail -B1 / | tail -n1)
  if (( DISK_BYTES < 10*1024*1024*1024 )); then
    SWAPSIZE=1073741824
  else
    SWAPSIZE=$((MEM_KB * 1024 + 2147483648))
  fi
  swapoff -a || true
  rm -f "$SWAPFILE"
  fallocate -l "$SWAPSIZE" "$SWAPFILE" || dd if=/dev/zero of="$SWAPFILE" bs=1M count=$((SWAPSIZE / 1024 / 1024))
  chmod 600 "$SWAPFILE"
  mkswap "$SWAPFILE"
  swapon "$SWAPFILE"
  cp /etc/fstab /etc/fstab.bak
  echo "$SWAPFILE none swap sw 0 0" >> /etc/fstab
fi

# ------------------------------
# 6. Сетевые настройки
# ------------------------------
cat >/etc/sysctl.d/99-security.conf <<EOF
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.tcp_syncookies = 1
EOF

sysctl --system

# ------------------------------
# 7. MOTD Dashboard
# ------------------------------
if ! command -v vnstat &>/dev/null; then
  apt install -y vnstat
  systemctl enable --now vnstat
fi

curl -fsSL https://dignezzz.github.io/server/dashboard.sh | sed '/read -p/d;/^if \[\[.*confirm.*\]\]; then/,/^fi$/d' > "$DASHBOARD_FILE"
chmod +x "$DASHBOARD_FILE"
find /etc/update-motd.d/ -type f -not -name "99-dashboard" -exec chmod -x {} \;

# ------------------------------
# 8. Финализация
# ------------------------------
systemctl disable --now apt-daily.timer apt-daily-upgrade.timer || true
apt autoremove -y && apt clean

echo "✅ Сервер готов. Используйте порт SSH: $SSH_PORT"
