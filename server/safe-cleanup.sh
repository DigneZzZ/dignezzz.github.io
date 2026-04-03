#!/bin/bash

set -e

TEMP_FILE="/tmp/cleanup_report.txt"
FORCE_MODE=false

if [[ "$1" == "--force" ]]; then
    FORCE_MODE=true
fi

DISK_BEFORE=$(df --output=used / | tail -n1)

echo "=== 🔍 Safe System Cleanup: Предварительный анализ ==="
echo
> "$TEMP_FILE"

echo "💽 Место на диске до:" | tee -a "$TEMP_FILE"
df -h | tee -a "$TEMP_FILE"
echo | tee -a "$TEMP_FILE"

if command -v docker &>/dev/null; then
    echo "🐳 Docker:" | tee -a "$TEMP_FILE"
    docker system df | tee -a "$TEMP_FILE"
    echo | tee -a "$TEMP_FILE"
else
    echo "🐳 Docker не установлен." | tee -a "$TEMP_FILE"
fi

echo "📝 Systemd-журналы:"
if journalctl --disk-usage &>/dev/null; then
    JOURNAL_SIZE=$(LANG=C journalctl --disk-usage | grep 'take up' | awk '{print $6 $7}')
    echo " - Текущий объем логов: $JOURNAL_SIZE" | tee -a "$TEMP_FILE"
    echo " - Будет удалено всё старше 10 дней и сверх 500MB" | tee -a "$TEMP_FILE"
else
    echo " - Журналы systemd недоступны" | tee -a "$TEMP_FILE"
fi
echo | tee -a "$TEMP_FILE"

echo "📦 APT кэш:"
if [ -d /var/cache/apt ]; then
    APT_SIZE=$(du -sh /var/cache/apt 2>/dev/null | cut -f1)
    echo " - Размер: $APT_SIZE" | tee -a "$TEMP_FILE"
else
    echo " - Каталог APT не найден" | tee -a "$TEMP_FILE"
fi
echo | tee -a "$TEMP_FILE"

echo "👤 Кэш пользователя (~/.cache):"
if [ -d ~/.cache ]; then
    CACHE_SIZE=$(du -sh ~/.cache 2>/dev/null | cut -f1)
    echo " - Размер: $CACHE_SIZE" | tee -a "$TEMP_FILE"
else
    echo " - ~/.cache не существует" | tee -a "$TEMP_FILE"
fi
echo | tee -a "$TEMP_FILE"

if command -v snap &>/dev/null; then
    echo "📦 Snap старые версии:" | tee -a "$TEMP_FILE"
    SNAP_OLD=$(snap list --all | awk '/disabled/{print $1, $2, $3}')
    if [ -n "$SNAP_OLD" ]; then
        echo "$SNAP_OLD" | tee -a "$TEMP_FILE"
    else
        echo " - Нет старых Snap ревизий" | tee -a "$TEMP_FILE"
    fi
else
    echo "📦 Snap не установлен." | tee -a "$TEMP_FILE"
fi

echo
echo "🧾 Резюме записано в: $TEMP_FILE"
echo

echo "📊 Ожидаемый объём очистки:"
TOTAL_ESTIMATE=0

if command -v docker &>/dev/null; then
    DOCKER_RECLAIM=$(docker system df | grep 'Images' | awk '{print $4}')
    echo " - Docker: ~$DOCKER_RECLAIM"
fi

if [ -d /var/cache/apt ]; then
    APT_BYTES=$(du -sb /var/cache/apt | awk '{print $1}')
    APT_MB=$((APT_BYTES / 1024 / 1024))
    TOTAL_ESTIMATE=$((TOTAL_ESTIMATE + APT_MB))
    echo " - APT кэш: ~${APT_MB}MB"
fi

if [ -d ~/.cache ]; then
    CACHE_BYTES=$(du -sb ~/.cache | awk '{print $1}')
    CACHE_MB=$((CACHE_BYTES / 1024 / 1024))
    TOTAL_ESTIMATE=$((TOTAL_ESTIMATE + CACHE_MB))
    echo " - Кэш пользователя: ~${CACHE_MB}MB"
fi

if journalctl --disk-usage &>/dev/null; then
    LOG_BYTES=$(journalctl --disk-usage | grep 'take up' | awk '{print $(NF-1)}')
    LOG_MB=${LOG_BYTES%.*}
    if [[ "$LOG_MB" =~ ^[0-9]+$ ]]; then
        EST_LOG_MB=$((LOG_MB > 500 ? LOG_MB - 500 : 0))
        TOTAL_ESTIMATE=$((TOTAL_ESTIMATE + EST_LOG_MB))
        echo " - Systemd-журналы: ~${EST_LOG_MB}MB"
    fi
fi

echo " ≈ Общий предварительный объём: ~${TOTAL_ESTIMATE}MB"
echo

if ! $FORCE_MODE; then
    read -p "⚠️  Выполнить очистку? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "❌ Очистка отменена пользователем."
        exit 0
    fi
else
    echo "✅ Режим --force активен: очистка без подтверждения."
fi

echo
echo "🚀 Начинаем очистку..."

if command -v docker &>/dev/null; then
    docker system prune -af --volumes
fi

if journalctl --vacuum-time=10d &>/dev/null; then
    journalctl --vacuum-time=10d
    journalctl --vacuum-size=500M
fi

if command -v apt &>/dev/null; then
    apt clean
fi

if [ -d ~/.cache ]; then
    rm -rf ~/.cache/*
fi

if command -v snap &>/dev/null; then
    snap list --all | awk '/disabled/{print $1, $2}' | while read snapname revision; do
        if [[ "$revision" =~ ^[0-9]+$ ]]; then
            echo "Удаляю $snapname revision $revision..."
            snap remove "$snapname" --revision="$revision"
        fi
    done
fi

DISK_AFTER=$(df --output=used / | tail -n1)
FREED=$(( (DISK_BEFORE - DISK_AFTER) / 1024 ))

echo
echo "💽 Место на диске после:"
df -h

echo
echo "📊 Освобождено приблизительно: ${FREED} MB"
echo
echo "✅ Очистка завершена."
