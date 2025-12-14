# ⚡ Quick Start - SHM Backup v2.1

## Установка одной командой

```bash
bash <(wget -qO- https://dignezzz.github.io/shm/backup/backup.sh)
```

## Что произойдёт?

### 1️⃣ Автоматическая проверка системы

```text
✔ OS Check: Ubuntu 22.04 LTS
```

### 2️⃣ Установка зависимостей (при необходимости)

```text
✖ Missing required dependencies:
  - docker
  - curl

Do you want to install missing dependencies automatically? (Y/n): [Enter]
```

**Нажмите Enter** - всё установится автоматически!

### 3️⃣ Выбор пути к SHM

```text
📍 Specify the path to docker-compose.yml for SHM:
  1) /root/shm
  2) /opt/shm  ← рекомендуется
  3) Enter manually
Choose an option (1-3) [2]: [Enter]
```

### 4️⃣ Режим резервного копирования

```text
📁 Do you want to backup the entire folder?
  1) Yes, backup all files  ← рекомендуется
  2) No, backup only specific files
Choose an option (1-2) [1]: [Enter]
```

### 5️⃣ Telegram настройки

```text
📡 Telegram Settings:
  Bot Token: 1234567890:ABCdefGHIjklMNOpqrsTUVwxyz
  Chat ID: -1001234567890
```

**Как получить:**
- **Bot Token**: [@BotFather](https://t.me/BotFather) → `/newbot`
- **Chat ID**: Добавьте бота в чат → `https://api.telegram.org/bot<TOKEN>/getUpdates`

### 6️⃣ Автоматическое расписание

```text
====================================================
   Automatic Backup Schedule Setup
====================================================
Would you like to set up automatic backups?

  1) Every 1 hour
  2) Every 2 hours
  3) Every 3 hours
  4) Every 4 hours
  5) Every 6 hours
  6) Every 12 hours
  7) Once a day (at 03:00)  ← рекомендуется
  8) Twice a day (at 03:00 and 15:00)
  9) Skip (configure manually later)

Choose an option (1-9) [7]: [Enter]
```

### 7️⃣ Готово!

```text
✔ Backup script created successfully at /opt/shm/backup.sh
✔ Cron job added successfully

Your backups will run daily at 03:00
```

## Ручной запуск

```bash
/opt/shm/backup.sh
```

## Проверка crontab

```bash
crontab -l
# 0 3 * * * /opt/shm/backup.sh
```

## После установки Docker (если был установлен)

```bash
# Вариант 1: Перезайти
exit

# Вариант 2: Активировать группу
newgrp docker
```

## Что включается в бэкап?

✅ MySQL база данных (`db_backup.sql`)  
✅ WebDAV volume (если существует)  
✅ Файлы конфигурации (docker-compose.yml, .env)  
✅ Опционально: вся папка SHM целиком

## Telegram уведомление

```text
✅ SHM Backup Complete

🖥 Server: your-server
📅 Date: 2025-11-06 14:30:15 UTC
⏱ Duration: 02:15
📁 Files: 142
🗃 Tables: 12
📊 Archive: 23.5M

📦 Contents:
📁 Entire SHM folder
📋 db_backup.sql (MySQL)
💾 webdav-volume.tar.gz

💾 Database: shm (145.67 MB)
```

## Полезные команды

```bash
# Просмотр логов бэкапа (если через cron)
grep backup /var/log/syslog

# Редактирование расписания
crontab -e

# Проверка Docker
docker ps | grep shm

# Список volume'ов
docker volume ls | grep shm
```

## Поддержка

📖 **Документация:**
- [README.md](README.md) - Полная документация
- [AUTO_INSTALL.md](AUTO_INSTALL.md) - Автоустановка зависимостей
- [FEATURES.md](FEATURES.md) - Все возможности v2.x
- [RELEASE_NOTES_v2.1.md](RELEASE_NOTES_v2.1.md) - Что нового?

🐛 **Проблемы:**
- [Устранение неполадок](README.md#устранение-проблем)

---

**Время установки: ~5 минут** ⏱  
**Сложность: для новичков** 🟢

---

🎉 **Сделано с ❤️ для SHM Community**
