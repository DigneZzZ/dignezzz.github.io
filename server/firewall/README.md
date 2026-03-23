# Firewall & Security

Скрипты для настройки файрвола, защиты от брутфорса и безопасности SSH.

| Скрипт | Описание | Установка |
|--------|----------|-----------|
| **f2b.sh** | Управление и настройка Fail2Ban для защиты от атак перебора | `bash <(wget -qO- https://dignezzz.github.io/server/firewall/f2b.sh)` |
| **f2b-e.sh** | Fail2Ban с динамическими временами блокировки для SSH и веб-сервисов | `bash <(wget -qO- https://dignezzz.github.io/server/firewall/f2b-e.sh)` |
| **security.sh** | Конфигурация параметров безопасности SSH | `bash <(wget -qO- https://dignezzz.github.io/server/firewall/security.sh)` |
| **ufw-check.sh** | Аудит и очистка правил UFW с поддержкой Docker и логирования | `bash <(wget -qO- https://dignezzz.github.io/server/firewall/ufw-check.sh)` |
| **ufw-copy.sh** | Экспорт и копирование правил UFW на другой сервер | `bash <(wget -qO- https://dignezzz.github.io/server/firewall/ufw-copy.sh)` |
