# Server Cleanup

Скрипты для безопасной очистки системы, удаления неиспользуемых Docker-образов и освобождения дискового пространства.

| Скрипт | Описание | Установка |
|--------|----------|-----------|
| **dest.sh** | Безопасная очистка с предварительным анализом и отчётом об освобождённом месте | `bash <(wget -qO- https://dignezzz.github.io/server/cleanup/dest.sh)` |
| **dest2.sh** | Очистка Docker-образов и контейнеров с отправкой отчёта в Telegram | `bash <(wget -qO- https://dignezzz.github.io/server/cleanup/dest2.sh)` |
| **dest.py** | Очистка системы с визуализацией через Python Rich | `python3 <(wget -qO- https://dignezzz.github.io/server/cleanup/dest.py)` |
| **safe-cleanup.sh** | Безопасная очистка с опцией dry-run и логированием | `bash <(wget -qO- https://dignezzz.github.io/server/cleanup/safe-cleanup.sh)` |
