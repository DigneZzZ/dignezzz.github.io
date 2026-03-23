# VPN & Proxy

Скрипты для установки VPN/прокси-серверов и проверки доменов для маскировки.

| Скрипт | Описание | Установка |
|--------|----------|-----------|
| **mtproxy.sh** | Установка и управление MTProxy в Docker для Telegram | `bash <(wget -qO- https://dignezzz.github.io/server/vpn/mtproxy.sh)` |
| **reality.sh** | Проверка пригодности домена для SNI в Xray Reality | `bash <(wget -qO- https://dignezzz.github.io/server/vpn/reality.sh)` |
| **sni.sh** | Проверка домена как SNI для Xray Reality (DNS, TLS, CDN анализ) | `bash <(wget -qO- https://dignezzz.github.io/server/vpn/sni.sh)` |
| **sni2.sh** | Проверка поддержки TLS 1.3, HTTP/2, HTTP/3 для домена | `bash <(wget -qO- https://dignezzz.github.io/server/vpn/sni2.sh)` |
| **sni.py** | Проверка совместимости домена с Xray Reality (Python-версия) | `python3 <(wget -qO- https://dignezzz.github.io/server/vpn/sni.py)` |
| **netbird-egress.sh** | Маршрутизация трафика через пир NetBird для egress из определённого региона | `bash <(wget -qO- https://dignezzz.github.io/server/vpn/netbird-egress.sh)` |

### Документация

- [MTProxy README (EN)](../docs/MTPROXY_README.md)
- [MTProxy README (RU)](../docs/MTPROXY_README_RU.md)
- [MTProxy Changelog](../docs/CHANGELOG_MTPROXY.md)
- [docker-compose.example.yml](docker-compose.example.yml) — пример конфига для MTProxy
