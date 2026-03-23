# Marzban Backup

Скрипты для резервного копирования конфигурации и баз данных Marzban с отправкой в Telegram.

| Скрипт | Описание | Установка |
|--------|----------|-----------|
| **backup.sh** | Бэкап конфигурации Marzban и MySQL с отправкой в Telegram | `bash <(wget -qO- https://dignezzz.github.io/marzban/backup/backup.sh)` |
| **backup2.sh** | Бэкап с поддержкой двух баз данных и отправкой в Telegram | `bash <(wget -qO- https://dignezzz.github.io/marzban/backup/backup2.sh)` |
| **backup2e.sh** | Расширённый бэкап с исключением папок и поддержкой двух БД | `bash <(wget -qO- https://dignezzz.github.io/marzban/backup/backup2e.sh)` |

### Рекомендация

Для автоматизации добавьте в crontab:
```bash
0 3 * * * bash <(wget -qO- https://dignezzz.github.io/marzban/backup/backup.sh)
```
