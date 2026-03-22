# VM Host Tuning Script - Documentation

## Описание

Скрипт `dedic.sh` v2.0 - продвинутый инструмент для оптимизации выделенных серверов под запуск большого количества виртуальных машин.

## Целевая конфигурация

- **CPU**: AMD Ryzen 9950X (16 cores / 32 threads)
- **RAM**: 250GB DDR5
- **Нагрузка**: Множественные VM/VPS/контейнеры
- **Network**: Высокая сетевая нагрузка (тысячи соединений)

## Оптимизации

### 1. Network Stack
- **Connection Tracking**: 16M соединений (vs 4M в старой версии)
- **TCP Buffers**: 128MB для каждого направления
- **BBR Congestion Control**: Современный алгоритм управления перегрузками
- **RPS/RFS**: Распределение пакетов по всем 32 потокам
- **Queue Sizes**: Увеличены для обработки burst traffic

### 2. Memory Management
- **Huge Pages**: 20% RAM для VM (опционально)
- **Transparent Huge Pages**: madvise режим
- **Overcommit**: Агрессивный для плотности VM
- **Dirty Ratios**: Оптимизированы для быстрой записи

### 3. CPU Optimization
- **IRQ Affinity**: Распределение прерываний по ядрам
- **RPS/RFS**: Multi-queue packet steering
- **Process Limits**: 4M потоков и процессов

### 4. I/O Optimization
- **Schedulers**: none для NVMe, mq-deadline для SSD
- **Queue Depth**: 4096 requests
- **Readahead**: 4MB для последовательного чтения

### 5. System Limits
- **File Descriptors**: 1M (vs стандартных 1024)
- **Processes**: 1M одновременных процессов
- **Memlock**: unlimited для VM

## Использование

### Базовый запуск
```bash
sudo bash dedic.sh
```

### С автоисправлением конфликтов
```bash
sudo AUTO_FIX=1 bash dedic.sh
```

### Отключение отдельных оптимизаций
```bash
# Без Huge Pages
sudo ENABLE_HUGEPAGES=0 bash dedic.sh

# Без RPS/RFS
sudo ENABLE_RPS=0 bash dedic.sh

# Комбинация
sudo ENABLE_HUGEPAGES=0 ENABLE_RPS=0 AUTO_FIX=1 bash dedic.sh
```

## Параметры окружения

| Параметр | Значение по умолчанию | Описание |
|----------|----------------------|----------|
| `AUTO_FIX` | 0 | Автоматическое исправление конфликтов в `/etc/sysctl.conf` |
| `ENABLE_HUGEPAGES` | 1 | Включить Transparent Huge Pages |
| `ENABLE_RPS` | 1 | Включить RPS/RFS для multi-queue |

## Ключевые параметры

### Connection Tracking
```bash
net.netfilter.nf_conntrack_max = 16777216  # 16M соединений
net.netfilter.nf_conntrack_buckets = 4194304  # 4M buckets
```

### TCP Buffers (для 250GB RAM)
```bash
net.core.rmem_max = 134217728  # 128MB
net.core.wmem_max = 134217728  # 128MB
net.ipv4.tcp_mem = 786432 1048576 26777216  # ~25GB
```

### Memory Management
```bash
vm.swappiness = 1  # Минимальный swap
vm.overcommit_memory = 1  # Разрешить overcommit
vm.overcommit_ratio = 80  # 80% RAM для overcommit
```

### File Descriptors
```bash
fs.file-max = 26234859  # ~26M файлов
```

## Что делает скрипт

1. **Анализ системы**: Определяет CPU, RAM, NUMA
2. **Проверка модулей**: Загружает tcp_bbr, nf_conntrack
3. **Конфликты**: Находит и исправляет конфликты в sysctl
4. **Запись конфига**: Создает `/etc/sysctl.d/99-vm-host-tuning.conf`
5. **Применение**: Применяет все параметры через `sysctl --system`
6. **Huge Pages**: Выделяет 20% RAM (опционально)
7. **RPS/RFS**: Настраивает multi-queue processing
8. **IRQ Affinity**: Распределяет прерывания по CPU
9. **I/O Schedulers**: Оптимизирует для NVMe/SSD
10. **System Limits**: Настраивает `/etc/security/limits.d/`
11. **Верификация**: Проверяет применение всех параметров

## Мониторинг после применения

### Conntrack
```bash
watch -n1 'cat /proc/sys/net/netfilter/nf_conntrack_count'
```

### Network stats
```bash
ss -s  # Сводка сокетов
netstat -s | grep -i tcp  # TCP статистика
```

### Memory
```bash
free -h
cat /proc/meminfo | grep -i huge
```

### File descriptors
```bash
cat /proc/sys/fs/file-nr
lsof | wc -l
```

### CPU performance
```bash
htop
mpstat -P ALL 1
```

## Рекомендации после применения

1. **Reboot**: Рекомендуется перезагрузка для полного применения
2. **Huge Pages**: Могут потребовать reboot для выделения
3. **Monitoring**: Установите мониторинг (Prometheus/Grafana)
4. **VM Density**: Постепенно увеличивайте количество VM

## Совместимость

- **OS**: Ubuntu 20.04+, Debian 11+, RHEL 8+, Rocky Linux 8+
- **Kernel**: 5.4+
- **Virtualization**: KVM/QEMU, LXC, Docker
- **Network**: Работает с любыми сетевыми картами

## Безопасность

- Создает backup перед изменением `/etc/sysctl.conf`
- Все изменения логируются
- Можно откатить через `sysctl.conf.bak.*`

## Troubleshooting

### Conntrack не увеличился
```bash
# Проверить модуль
lsmod | grep nf_conntrack

# Вручную установить
echo 16777216 > /proc/sys/net/netfilter/nf_conntrack_max
```

### BBR не активирован
```bash
# Проверить поддержку
modprobe tcp_bbr
sysctl net.ipv4.tcp_congestion_control=bbr
```

### Huge Pages не выделяются
```bash
# Требуется больше свободной памяти
# Перезагрузить или освободить память
echo 3 > /proc/sys/vm/drop_caches
```

## Performance Impact

### До оптимизации (типичный сервер)
- Conntrack limit: 65K соединений
- File descriptors: 1K
- TCP buffers: 4MB
- VM плотность: 10-20 VM

### После оптимизации
- Conntrack limit: 16M соединений
- File descriptors: 26M
- TCP buffers: 128MB
- VM плотность: 100+ VM

## Дополнительные рекомендации

### Для KVM/QEMU
```bash
# Включить nested virtualization
echo "options kvm_amd nested=1" > /etc/modprobe.d/kvm.conf

# CPU pinning для VM
# Использовать в libvirt XML
```

### Для Docker
```bash
# Увеличить docker daemon limits
cat > /etc/docker/daemon.json <<EOF
{
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Hard": 1048576,
      "Soft": 1048576
    }
  }
}
EOF
systemctl restart docker
```

### Для LXC
```bash
# В /etc/lxc/default.conf
lxc.net.0.type = veth
lxc.net.0.flags = up
lxc.cgroup2.memory.max = unlimited
```

## Версионирование

- **v1.0**: Базовая оптимизация (4 параметра)
- **v2.0**: Полная переработка для high-end серверов
  - 50+ параметров
  - RPS/RFS support
  - Huge Pages
  - IRQ affinity
  - I/O optimization

## Автор

DigneZzZ - https://github.com/DigneZzZ

## License

MIT License
