# GIG MOTD Dashboard - Полный список функций

Версия: 2025.10.05.2

## 📊 Системная информация

### Базовые метрики

- **System Uptime** - время работы системы без перезагрузки
- **Load Average** - средняя нагрузка (1, 5, 15 минут) + количество ядер
- **Kernel** - версия ядра Linux

### CPU

- Использование CPU с прогресс-баром и цветовой индикацией
- Температура CPU (если доступна в `/sys/class/thermal/thermal_zone0/temp`)
- Автоматическое определение количества ядер

### Память

- **RAM Usage** - использование оперативной памяти с прогресс-баром
- **SWAP Usage** - использование SWAP с прогресс-баром
- Цветовая индикация: 🟢 (0-69%), 🟡 (70-89%), 🔴 (90-100%)

### Диски

- **Основной диск (/)** - использование с прогресс-баром
- **Дополнительные диски** - автоматическое определение `/home`, `/var`, `/data`, `/mnt`, `/opt`, `/backup`
- **Inode Usage** - мониторинг inodes (отображается только при > 80%)

### Процессы

- **Общее количество** процессов
- **Running** процессы
- **Zombie** процессы (с предупреждением если > 0)
- **Top CPU** - топ-3 процесса по нагрузке на CPU
- **Top RAM** - топ-3 процесса по использованию памяти

### Производительность

- **I/O Wait** - время ожидания операций ввода/вывода
  - 🟢 Low (< 10%)
  - 🟡 Moderate (10-20%)
  - 🔴 High (> 20%)
- **Open Files** - количество открытых файлов vs лимит с прогресс-баром

---

## 🌐 Сетевая информация

### IP адреса

- **Local IPv4** - локальный IP адрес
- **Public IPv4** - внешний IP адрес (через ifconfig.me)
- **IPv6** - глобальный IPv6 адрес (если настроен)

### Сетевой трафик

- **Traffic Stats** - общая статистика через vnstat
- Отображение входящего и исходящего трафика

### Соединения

- **Total Connections** - общее количество сетевых соединений
- **ESTABLISHED** - активные установленные соединения

---

## 🔒 Безопасность и доступ

### Аутентификация

- **Last Login** - последний успешный вход (пользователь, IP, время)
- **Failed Logins (24h)** - количество неудачных попыток входа за последние 24 часа

### SSH

- **SSH Sessions** - количество активных SSH сессий
- **SSH IPs** - IP адреса активных SSH подключений
- **SSH Port** - порт SSH (с предупреждением если используется 22)
- **Root Login** - статус разрешения входа под root
- **Password Auth** - статус парольной аутентификации

### Защита

- **Fail2ban** - статус сервиса + количество заблокированных IP
- **CrowdSec** - статус агента CrowdSec
- **UFW Firewall** - статус файрвола

### Синхронизация времени

- **NTP Status** - статус синхронизации времени
- Определение NTP сервера (systemd-timesyncd, ntpq)

---

## 🐳 Docker

### Контейнеры

- **Running** - количество запущенных контейнеров
- **Stopped** - количество остановленных контейнеров
- **Problem Containers** - контейнеры в статусе exited/restarting (с деталями)

### Volumes

- **Docker Volumes** - количество volumes и занимаемое место
- Информация из `docker system df -v`

---

## ⚙️ Сервисы

### Мониторинг сервисов

Автоматическая проверка статуса настраиваемого списка сервисов:

- nginx
- mysql
- postgresql
- redis
- docker
- fail2ban

**Настройка:**

```bash
# В /etc/motdrc или ~/.motdrc
MONITORED_SERVICES=nginx,mysql,postgresql,redis,custom-service
```

Отображение:

- ✅ Сервис запущен
- ❌ Сервис остановлен

---

## 🔐 SSL Сертификаты

### Автоматическая проверка

- Сканирование директории с сертификатами (по умолчанию `/etc/letsencrypt/live`)
- Определение срока действия каждого сертификата
- Предупреждения о приближающемся истечении

**Индикация:**

- ✅ Все сертификаты валидны (> 30 дней)
- ⚠️ Сертификат истекает через 7-30 дней
- ❌ Критично: < 7 дней до истечения

**Настройка:**

```bash
# В /etc/motdrc или ~/.motdrc
SSL_CERT_PATHS=/etc/letsencrypt/live
SSL_WARN_DAYS=30  # Порог предупреждения
```

---

## 📦 Обновления

### Apt Updates

- Количество доступных обновлений пакетов
- Команда для обновления: `apt update && apt upgrade`

### Auto Updates

- **Status** - статус unattended-upgrades
- **Diagnostics** - автоматические подсказки при проблемах:
  - Не установлен → команда установки
  - Timers отключены → команда включения
  - Config неправильный → команда исправления

---

## ⚙️ Настройка

### Конфигурация через motd-config

```bash
motd-config
```

Интерактивное меню для включения/отключения любого из 28 блоков.

### Файлы конфигурации

**Global (root):**

```bash
/etc/motdrc
```

**User mode:**

```bash
~/.motdrc
```

### Структура конфига

```bash
# === System Information ===
SHOW_UPTIME=true
SHOW_LOAD=true
SHOW_CPU=true
SHOW_RAM=true
SHOW_SWAP=true
SHOW_DISK=true
SHOW_ADDITIONAL_DISKS=true
SHOW_INODES=true
SHOW_PROCESSES=true
SHOW_TOP_PROCESSES=true
SHOW_IO_WAIT=true
SHOW_OPEN_FILES=true
SHOW_TEMP=true

# === Network Information ===
SHOW_NET=true
SHOW_IP=true
SHOW_CONNECTIONS=true

# === Security & Access ===
SHOW_LAST_LOGIN=true
SHOW_FAILED_LOGINS=true
SHOW_NTP=true
SHOW_SSH=true
SHOW_SECURITY=true
SHOW_FAIL2BAN_STATS=true

# === Services & Docker ===
SHOW_DOCKER=true
SHOW_DOCKER_VOLUMES=true
SHOW_SERVICES=true
SHOW_SSL_CERTS=true

# === Updates ===
SHOW_UPDATES=true
SHOW_AUTOUPDATES=true

# === Advanced Settings ===
MONITORED_SERVICES=nginx,mysql,postgresql,redis,docker,fail2ban
SSL_CERT_PATHS=/etc/letsencrypt/live
SSL_WARN_DAYS=30
```

---

## 🎨 Цветовая индикация

### Прогресс-бары

- 🟢 **Зеленый** (0-69%) - нормальная нагрузка
- 🟡 **Желтый** (70-89%) - высокая нагрузка
- 🔴 **Красный** (90-100%) - критическая нагрузка

### Статусы

- ✅ **OK** - всё в порядке
- ⚠️ **Warning** - предупреждение
- ❌ **Failed** - ошибка или проблема

---

## 🚀 Команды

### Просмотр дашборда

```bash
motd
```

### Обновление

```bash
motd --update         # Обновить до последней версии
motd --check-update   # Проверить наличие обновлений
```

### Настройка

```bash
motd-config
```

### Установка

```bash
# Root установка
sudo bash <(wget -qO- https://dignezzz.github.io/server/dashboard.sh) --force

# User-mode установка
bash <(wget -qO- https://dignezzz.github.io/server/dashboard.sh) --not-root --force
```

---

## 📈 Пример вывода

```
─~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
 MOTD Dashboard — powered by https://gig.ovh
─~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
 System Uptime        : up 15 weeks, 3 hours, 44 minutes
 Load Average         : 0.85 0.57 0.45 (cores: 4)
 CPU Usage            : [████████████░░░░░░░░░░░░░░░░░░]  40% | 55°C
 Kernel               : 6.8.0-36-generic
 RAM Usage            : [████████████████████░░░░░░░░░░]  66% 2600MB / 3916MB
 SWAP Usage           : [█████████████████████░░░░░░░░░]  73% 1200MB / 1636MB
 Disk Usage /         : [████████████████░░░░░░░░░░░░░░]  55% 19G / 35G
 Disk /var            : [████████████░░░░░░░░░░░░░░░░░░]  42% 85G / 200G
 Processes            : 225 total, 2 running, 0 zombie
 Top CPU              : dockerd, xray, prometheus
 Top RAM              : mysql, redis, nginx
 I/O Wait             : 0.5% (low)
 Open Files           : [██░░░░░░░░░░░░░░░░░░░░░░░░░░░░]  1% 1250 / 1048576
 Net Traffic          : 245.67 GiB ↓ / 89.23 GiB ↑
 IPv4/IPv6            : Local: 45.144.51.155 / Public: 2a05:fc1:40:17c::3 / IPv6: 2a05:fc1:40:17c::3
 Connections          : 156 total, 23 ESTABLISHED
 Last Login           : dignezzz from 178.170.198.95 at Oct 5 16:30
 Time Sync            : ✅ synchronized (systemd-timesyncd)
 Docker               : ✅ 12 running / 0 stopped
 Docker Volumes       : 8 volumes (2.5GB)
 Services             : ✅ nginx ✅ mysql ✅ redis ✅ docker ✅ fail2ban
 SSL Certificates     : ✅ all certificates valid
 ~~~~~~ ↓↓↓ Security Block ↓↓↓ ~~~~~~
 Fail2ban             : ✅ active
   Banned IPs         : 45
 CrowdSec             : ❌ not running
 UFW Firewall         : ✅ enabled
 SSH Port             : ✅ non-standard port (5322)
 Root Login           : ❌ enabled
 Password Auth        : ✅ disabled
 SSH Sessions         : 1
 SSH IPs              : 178.170.198.95
 ~~~~~~ ↑↑↑ Security Block ↑↑↑ ~~~~~~
 Apt Updates          : 25 package(s) can be updated
 Auto Updates         : ✅ enabled

 Dashboard Ver        : 2025.10.05.2
─~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
 Config tool          : motd-config
```

---

**Автор**: DigneZzZ - https://gig.ovh  
**Лицензия**: MIT  
**GitHub**: https://github.com/DigneZzZ/dignezzz.github.io
