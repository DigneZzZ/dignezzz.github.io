# Monitoring & Dashboard

Скрипты для мониторинга сервера, дашбордов и отправки статусов.

| Скрипт | Описание | Установка |
|--------|----------|-----------|
| **dashboard.sh** | Современный MOTD-дашборд с информацией о сервере при входе | `bash <(wget -qO- https://dignezzz.github.io/server/monitoring/dashboard.sh)` |
| **trafic.sh** | Управление ограничением пропускной способности через tc (traffic control) | `bash <(wget -qO- https://dignezzz.github.io/server/monitoring/trafic.sh)` |
| **stpush.sh** | Отправка статуса сервера на внешний URL с информацией о Docker-контейнерах | `bash <(wget -qO- https://dignezzz.github.io/server/monitoring/stpush.sh)` |

### Документация

- [Version Guide (dashboard.sh)](../docs/VERSION_GUIDE.md)
