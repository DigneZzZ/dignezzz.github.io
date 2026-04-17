# node-tune.sh — Design Document

**Версия:** 1.0.0
**Дата:** 2026-04-17
**Скрипт:** `server/node-tune.sh`
**Целевая платформа:** Ubuntu 20.04+ / Debian 11+ на Ryzen 7/9 dedicated
**Назначение:** оптимизация VPN/Proxy-нод (Xray/Reality + WireGuard/AmneziaWG)

---

## Мотивация

Существующий `dedic.sh` оптимизирован под VM-хост (250 GB RAM, 16M conntrack, hugepages 20% для KVM). Для **VPN/Proxy-нод** требования принципиально другие:

- множество **коротких TCP-соединений** (Reality/Xray) → быстрый TIME_WAIT reuse, короткий `fin_timeout`
- большой объём **UDP-трафика с forwarding** (WireGuard) → большие `udp_mem`, UDP GRO, loose rp_filter
- **низкая и предсказуемая latency** важнее throughput → THP=never, swappiness низкий
- **экономия памяти** (ноды не обязательно 250 GB) → conntrack в районе 512K–1M, буферы 64 MB max

Поэтому `node-tune.sh` — отдельный скрипт с профилями под реальные сценарии.

---

## Профили

| Профиль | Сценарий | Особенности |
|---|---|---|
| **reality** | Xray/Reality/VLESS/Trojan, TCP-heavy | агрессивный TIME_WAIT, fin_timeout=10, mtu_probing=1, tw_buckets=2M, THP=madvise |
| **wireguard** | WG/AmneziaWG, UDP forwarding | `udp_mem` большой, `rp_filter=2`, conntrack timeouts↓, THP=never, netdev_max_backlog=250K |
| **mixed** | 3x-ui/Marzban (Xray+WG+SS) | UDP-буферы WG + TCP-агрессивность Reality, `rp_filter=1` (strict), THP=never |

Активный профиль сохраняется в `/etc/node-tune/profile` для статуса и реапплая.

---

## Auto-detection (универсальность Ubuntu/Debian)

| Фича | Метод | Действие |
|---|---|---|
| OS | `/etc/os-release` | поддержка Ubuntu 20.04+ / Debian 11+; иначе — warning и продолжение |
| Kernel | `uname -r` | feature-gate по major.minor |
| XanMod | `grep -i xanmod /proc/version` | BBRv3 + cake из коробки |
| Congestion | `/proc/sys/net/ipv4/tcp_available_congestion_control` | приоритет: `bbr3 > bbr2 > bbr > cubic` |
| Qdisc | dry-probe: `tc qdisc add dev lo root cake` | приоритет: `cake > fq` |
| Ryzen | `/proc/cpuinfo` → AMD | проверка `amd_pstate` active (info only) |
| IPv6 | `/proc/net/if_inet6` | forwarding применяется только если IPv6 включён |
| NIC | `ip -br link`, `ethtool -g/-k` | RPS/RFS, IRQ affinity, offloads |

---

## Файловая структура

```
/etc/sysctl.d/99-node-tune.conf             # основные параметры ядра
/etc/security/limits.d/99-node-tune.conf    # PAM-лимиты (nofile, nproc, memlock)
/etc/systemd/system.conf.d/99-node-tune.conf # systemd DefaultLimit*
/etc/systemd/user.conf.d/99-node-tune.conf   # systemd user-session лимиты
/etc/modprobe.d/99-node-tune.conf            # options nf_conntrack hashsize
/etc/udev/rules.d/99-node-tune.rules         # I/O scheduler + txqueuelen (persistent)
/etc/node-tune/profile                       # активный профиль
/etc/node-tune/version                       # версия скрипта
/var/backups/node-tune/rollback_YYYYMMDD_HHMMSS.sh  # автобэкап с rollback
```

---

## Ключевые параметры

### Общие (все профили)

```
# BBR + qdisc (auto-selected)
net.ipv4.tcp_congestion_control = bbr3|bbr2|bbr
net.core.default_qdisc = cake|fq

# TCP core
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_sack = 1

# Security
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 32768
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65536 (wg: 250000)

# Buffers — 64 MB max (не 128, экономим)
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 262144 67108864
net.ipv4.tcp_wmem = 4096 262144 67108864

# Conntrack — масштабируется от RAM, clamp(131072, 1048576)
net.netfilter.nf_conntrack_max = calc

# Memory
vm.swappiness = 10
vm.dirty_ratio = 10
vm.dirty_background_ratio = 3
vm.min_free_kbytes = clamp(RAM_KB/100, 65536, 1048576)

# Limits
fs.file-max = 4194304
kernel.pid_max = 4194304
```

### Reality (TCP-heavy overrides)

```
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_max_tw_buckets = 2000000
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 15
# THP = madvise (не never — Xray benefits от huge pages в reality TLS)
```

### WireGuard (UDP-heavy overrides)

```
net.ipv4.udp_mem = 8x больше базового
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.core.netdev_max_backlog = 250000
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.netfilter.nf_conntrack_tcp_timeout_established = 3600
# THP = never (WG forwarding + low-latency критичнее)
```

### Mixed (компромисс)

```
# UDP-буферы как у WG + TCP-оптимизации как у Reality
# rp_filter = 1 (strict, безопасность на первом месте для смешанной ноды)
# THP = never
```

---

## NIC Tuning

1. **Ring buffers**: `ethtool -G $iface rx max tx max` (читаем max из `ethtool -g`)
2. **Offloads**: `ethtool -K $iface gro on gso on tso on rx-gro-list on` (UDP GRO на kernel ≥ 6.2 критично для WG)
3. **Queue length**: `ip link set $iface txqueuelen 10000` + persist через udev
4. **RPS**: маска всех CPU кроме CPU0 в `/sys/class/net/$iface/queues/rx-*/rps_cpus`
5. **RFS**: `net.core.rps_sock_flow_entries = 32768` + per-queue `rps_flow_cnt = 4096`
6. **IRQ affinity**: распределение network IRQs по `smp_affinity_list`, CPU0 оставлен для OS

## CPU Tuning

- `cpupower frequency-set -g performance` (или systemd-unit `node-tune-governor.service`)
- Для AMD Ryzen: info-сообщение о рекомендуемом `amd_pstate=active` в GRUB (не применяется автоматом)
- **НЕ отключаем**: CPU mitigations, C-states, SMT (безопасность > 1–2% perf)

## I/O Scheduler

udev rule, применяется при загрузке:
- NVMe → `none`
- SSD (rotational=0, не NVMe) → `mq-deadline`
- HDD (rotational=1) → `bfq`

---

## CLI

```
node-tune                      # interactive menu
node-tune apply [profile]      # reality|wireguard|mixed
node-tune profile <name>       # смена профиля без полного реапплая
node-tune status               # текущий профиль, BBR/qdisc/FD/conntrack stats
node-tune bench                # iperf3 + latency test (если установлены)
node-tune rollback             # восстановление
node-tune install / remove     # установка в /usr/local/bin/node-tune
node-tune update               # проверка/загрузка обновления
node-tune help / version
```

Интерактивное меню — стиль `dedic.sh` (цветные заголовки, подтверждения).

---

## Безопасность и безопасный откат

1. **Автобэкап** перед применением: `sysctl -a` → `backup_YYYYMMDD_HHMMSS.conf` + генерируемый `rollback_*.sh`
2. **Detect conflicts**: сканируем `/etc/sysctl.conf` и `/etc/sysctl.d/*.conf` на дубли — предупреждение или AUTO_FIX
3. **Не трогаем**: firewall, UFW, nft-правила, пакеты, mitigations, MTU, GRUB, сервисы
4. **Не рестартим** xray/wg-quick — пользователь сам решает, когда применить новые лимиты
5. **Опциональные действия** (никогда не автоматом, только печать команды): отключение IPv6, NOTRACK-правила для WG, установка `amd_pstate=active`

---

## Что `node-tune.sh` **не** делает (явно)

- ❌ mitigations=off
- ❌ iptables/nft/UFW манипуляции
- ❌ отключение IPv6
- ❌ hugepages (VPN-ноде без KVM они не нужны)
- ❌ изменение MTU (есть отдельный `mtu.sh`)
- ❌ установка сторонних пакетов без согласия
- ❌ reboot
- ❌ перезапуск VPN/proxy-сервисов

---

## Отличия от `dedic.sh`

| Параметр | `dedic.sh` (VM-host) | `node-tune.sh` (VPN-node) |
|---|---|---|
| conntrack_max | 16 777 216 | clamp(131072, 1048576) от RAM |
| rmem/wmem max | 128 MB | 64 MB |
| hugepages | 20% RAM | не используются |
| THP | madvise + defer | never (wg/mixed) или madvise (reality) |
| ip_forward | всегда on | по выбранному профилю |
| Профили | один | reality / wireguard / mixed |
| UDP-оптимизации | минимальные | основная часть для wireguard |
| KSM | не трогается | disable (экономия CPU) |

---

## Roadmap (v1.1+)

- eBPF/XDP detection и рекомендации для WG bypass conntrack
- Авто-генерация NOTRACK-правил под UFW/nftables (с подтверждением)
- Профиль `gaming-proxy` — extreme low-latency
- Web-dashboard hook для `dashboard.sh`
