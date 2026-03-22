# Реорганизация Script Hub

## Проблема

Папка `server/` содержит 25+ разнородных скриптов — от 93KB Fail2Ban-менеджера до 1.6KB конфига sysctl. Некоторые скрипты выросли в полноценные проекты с версионированием и документацией, но теряются среди мелких утилит.

---

## Часть 1: Кандидаты на отдельные репозитории

### Tier 1 — Зрелые проекты (рекомендуется вынести)

| Скрипт | Размер | Версия | Документация | Почему отдельный репо |
|--------|--------|--------|-------------|----------------------|
| **multi_checker.sh** | 284KB / 5722 строки | `1.0.0` | — | Крупнейший скрипт, полноценный диагностический комбайн |
| **f2b.sh** | 93KB / 2657 строк | `3.7.5` | — | Полноценный менеджер Fail2Ban с CLI-командами |
| **dashboard.sh** | 70KB / 1855 строк | `2026.03.18.1` | VERSION_GUIDE.md | MOTD-панель с автообновлением и конфигуратором |
| **dedic.sh** | 47KB / 1386 строк | `2.0` | DEDIC_README.md | Специализированный тюнер для выделенных серверов |
| **ufw-check.sh** | 41KB / 1043 строки | `3.1` | — | Аудитор файрвола с поддержкой Docker/Podman |
| **netbird-egress.sh** | 41KB / 1127 строк | `1.1` | inline | Маршрутизация через NetBird с CLIENT/GATEWAY режимами |
| **mtproxy.sh** | 20KB / 646 строк | — | 2 README (EN+RU), CHANGELOG | Docker-менеджер MTProxy с полным lifecycle |

### Tier 2 — Потенциальные кандидаты

| Скрипт | Размер | Комментарий |
|--------|--------|-------------|
| **trafic.sh** | 30KB | Traffic limiter с автообновлением, но узкая задача |
| **security.sh** | 21KB | SSH-хардинг, двуязычный, но слишком узкий |
| **ssh-port.sh** | 17KB | Смена SSH-порта с интеграцией UFW/firewalld |

### Что оставить в Hub

Мелкие утилиты, конфиги и однозадачные скрипты:
- `dest.sh`, `dest2.sh`, `safe-cleanup.sh` — чистка сервера
- `swap.sh`, `mtu.sh`, `init.sh`, `sysctl_opt.sh` — настройка системы
- `reality.sh`, `sni.sh`, `sni2.sh` — быстрые VPN-установщики
- `stpush.sh`, `ufw-copy.sh` — мелкие утилиты
- Все скрипты из `marzban/` — тесно связаны между собой
- Конфиги из `shadowrocket/` — не являются самостоятельными проектами

### Как выносить в отдельный репо

Для каждого скрипта из Tier 1:
1. Создать репозиторий `DigneZzZ/<script-name>`
2. Добавить полноценный README.md с описанием, скриншотами, примерами
3. Настроить GitHub Releases для версий
4. В Script Hub оставить ссылку-карточку на новый репо
5. Обновить URL для `wget` — указывать на raw.githubusercontent.com нового репо

Пример структуры нового репо:
```
DigneZzZ/server-dashboard/
├── dashboard.sh
├── README.md (полное описание + скриншоты)
├── CHANGELOG.md
├── LICENSE
└── .github/
    └── workflows/
        └── release.yml
```

---

## Часть 2: Новая структура Script Hub

### Текущая структура (проблемы)
```
├── marzban/          ← OK, но все свалено в одну папку
├── server/           ← 25+ файлов без группировки!
├── shadowrocket/     ← OK
├── shm/              ← OK
├── multi_checker.sh  ← Потерян в корне
├── ru_singbox*.json  ← Потеряны в корне
└── ru_direct*.conf   ← Потеряны в корне
```

### Новая структура
```
├── marzban/
│   ├── backup/           ← Бэкапы Marzban
│   ├── firewall/         ← UFW для Marzban
│   └── tools/            ← Утилиты (core_change, migrate)
│
├── server/
│   ├── firewall/         ← f2b, ufw-check, security
│   ├── vpn/              ← mtproxy, reality, sni, netbird
│   ├── monitoring/       ← dashboard, trafic, stpush
│   ├── optimization/     ← dedic, swap, sysctl, mtu, init, unlimit
│   └── cleanup/          ← dest, dest2, safe-cleanup
│
├── shadowrocket/         ← Без изменений
│   ├── configs/          ← template-ios-* конфиги
│   └── rules/            ← proxy.list, antifilter.list и т.д.
│
├── shm/                  ← Без изменений
│
├── singbox/              ← НОВАЯ: вынести из корня
│   ├── ru_singbox.json
│   ├── ru_singbox_2.json
│   └── ru_direct*.conf
│
├── tools/                ← НОВАЯ: крупные standalone-утилиты
│   └── multi_checker.sh
│
└── docs/                 ← НОВАЯ: документация
    ├── MTPROXY_README.md
    ├── MTPROXY_README_RU.md
    ├── DEDIC_README.md
    └── VERSION_GUIDE.md
```

### Что изменится для пользователей

**URL-адреса скриптов изменятся!** Например:
- Было: `https://dignezzz.github.io/server/dashboard.sh`
- Стало: `https://dignezzz.github.io/server/monitoring/dashboard.sh`

CI/CD автоматически обновит README с новыми командами.

---

## Часть 3: Рекомендуемые названия для отдельных репозиториев

| Текущий скрипт | Название репо | Описание |
|----------------|---------------|----------|
| dashboard.sh | `server-dashboard` | Modern MOTD Dashboard for Linux |
| f2b.sh | `fail2ban-manager` | Fail2Ban Management Tool |
| ufw-check.sh | `ufw-auditor` | UFW Firewall Auditor & Cleaner |
| dedic.sh | `server-tuner` | Dedicated Server Performance Tuner |
| netbird-egress.sh | `netbird-egress` | NetBird Egress Routing Tool |
| mtproxy.sh | `mtproxy-docker` | MTProxy Docker Manager |
| multi_checker.sh | `multi-checker` | Multi-Protocol Server Diagnostic Tool |

---

## Приоритет действий

1. **Сейчас** — реорганизовать папки внутри Script Hub (эта ветка)
2. **Потом** — выносить Tier 1 скрипты в отдельные репо (по одному)
3. **Опционально** — обновить landing page с карточками-ссылками на внешние репо
