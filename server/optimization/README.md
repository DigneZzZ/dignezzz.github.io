# Server Optimization

Скрипты для оптимизации производительности, настройки ядра и начальной конфигурации сервера.

| Скрипт | Описание | Установка |
|--------|----------|-----------|
| **dedic.sh** | Оптимизация ядра для высокопроизводительных выделенных серверов | `bash <(wget -qO- https://dignezzz.github.io/server/optimization/dedic.sh)` |
| **init.sh** | Начальная настройка сервера (Fail2Ban, UFW, оптимизация) | `bash <(wget -qO- https://dignezzz.github.io/server/optimization/init.sh)` |
| **mtu.sh** | Управление MTU для сетевых интерфейсов с откатом | `bash <(wget -qO- https://dignezzz.github.io/server/optimization/mtu.sh)` |
| **ssh-port.sh** | Безопасное изменение порта SSH с настройкой файрвола и SELinux | `bash <(wget -qO- https://dignezzz.github.io/server/optimization/ssh-port.sh)` |
| **swap.sh** | Автоматическое создание swap-файла оптимального размера | `bash <(wget -qO- https://dignezzz.github.io/server/optimization/swap.sh)` |
| **sysctl_opt.sh** | Оптимизация параметров ядра Ubuntu через sysctl | `bash <(wget -qO- https://dignezzz.github.io/server/optimization/sysctl_opt.sh)` |
| **unlimit_server.sh** | Снятие системных ограничений (ulimit) для ресурсоёмких приложений | `bash <(wget -qO- https://dignezzz.github.io/server/optimization/unlimit_server.sh)` |

### Файлы конфигурации

- [sysctl.conf](sysctl.conf) — пример оптимизированной конфигурации ядра

### Документация

- [Dedic README](../docs/DEDIC_README.md) — подробное описание параметров dedic.sh
