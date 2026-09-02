#!/usr/bin/env bash
#
# tg-webproxy.sh — one-click installer for the NEW Telegram WEB proxy
# (masks MTProxy traffic inside ordinary HTTPS/WebSocket to a real domain).
#
# It wraps the official proof-of-concept server telegramdesktop/tproxy-server:
#   Internet :443 (Caddy + Let's Encrypt) -> tproxy-server (Go relay, loopback)
#   -> stock official MTProxy (loopback). Only :443/:80 are public.
#
# Adds on top of upstream: pre-flight checks, secret generation, a randomized
# "cover" website, optional @MTProxybot AD_TAG (sponsored channel), live
# connection/traffic monitoring, and a management CLI.
#
# Usage:
#   bash <(wget -qO- https://dignezzz.github.io/server/tg-webproxy.sh)          # interactive install
#   bash <(wget -qO- https://dignezzz.github.io/server/tg-webproxy.sh) status   # requires prior install
#   ... status | watch | link | logs | restart | update | adtag | uninstall | help
#
# Non-interactive install (env overrides): TGWP_HOSTNAME, TGWP_EMAIL,
#   TGWP_SECRET (32 hex or dd+32hex; empty = auto/keep), TGWP_ADTAG (32 hex),
#   TGWP_WORKERS, TGWP_MAXCONN, TGWP_SITE_DIR (own site), TGWP_REF (pin repo commit),
#   TGWP_YES=1 (auto-confirm all prompts).
#
# Requirements: root, x86_64, systemd, Ubuntu 22.04+/Debian 12+, public IPv4,
#               a dedicated hostname with an A record → this server.

set -euo pipefail
umask 077

# ---------------------------------------------------------------- appearance
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

msg()  { echo -e "${CYAN}$*${NC}"; }
ok()   { echo -e "${GREEN}✅ $*${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $*${NC}"; }
err()  { echo -e "${RED}❌ $*${NC}" >&2; }
head2(){ echo -e "\n${BLUE}${BOLD}$*${NC}"; }
die()  { err "$*"; exit 1; }

# ---------------------------------------------------------------- constants
REPO_URL="https://github.com/telegramdesktop/tproxy-server"
REPO_DIR="/opt/tproxy-server-src"
STATE_DIR="/opt/tgwebproxy"
INFO_FILE="${STATE_DIR}/info.env"
SITE_STAGE="${STATE_DIR}/site"
MGMT="/usr/local/bin/tgwebproxy"

MTENV="/etc/mtproxy/mtproxy.env"
ADTAG_DROPIN="/etc/systemd/system/mtproxy.service.d/adtag.conf"
MON_NFT="/etc/tproxy-server/tgmon.nft"
MON_UNIT="/etc/systemd/system/tgmon-counters.service"
MON_TABLE="tgmon"                       # nftables table: inet tgmon (traffic counters)

RELAY_ADMIN="http://127.0.0.1:8081"     # /healthz /readyz /metrics

SELF="$0"
HAS_TTY=""   # set by probe_tty()

# ---------------------------------------------------------------- tty helpers
# Probe ONCE whether /dev/tty can actually be opened. The node exists even
# without a controlling terminal (cron/CI/ssh-without-t), so -e is not enough.
probe_tty() { if { : </dev/tty; } 2>/dev/null; then HAS_TTY=1; else HAS_TTY=""; fi; }

# ask <var> <prompt> <default> <env_override>
# Returns 0 when a value was obtained (env or interactive), 1 when it could
# only fall back to the default because there is no usable terminal.
ask() {
	local __var="$1" __prompt="$2" __default="${3:-}" __env="${4:-}" __ans=""
	if [[ -n "$__env" ]]; then printf -v "$__var" '%s' "$__env"; return 0; fi
	if [[ -n "$HAS_TTY" ]]; then
		if read -r -p "$__prompt" __ans </dev/tty; then
			printf -v "$__var" '%s' "${__ans:-$__default}"; return 0
		fi
	fi
	printf -v "$__var" '%s' "$__default"; return 1
}
ask_secret() { # ask_secret <var> <prompt>  (returns 1 if no tty)
	local __var="$1" __prompt="$2" __ans=""
	if [[ -n "$HAS_TTY" ]] && read -r -s -p "$__prompt" __ans </dev/tty; then
		echo >/dev/tty; printf -v "$__var" '%s' "$__ans"; return 0
	fi
	printf -v "$__var" '%s' ""; return 1
}
confirm() { # confirm <prompt>  -> 0 if yes
	[[ "${TGWP_YES:-}" == "1" ]] && return 0
	local a; ask a "$1 [y/N]: " "n" "" || true
	[[ "$a" =~ ^([yY]|[yY][eE][sS]|[дД]|[дД][аА])$ ]]
}

# ---------------------------------------------------------------- utilities
gen_secret() { head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n'; }  # 32 lowercase hex, no openssl

detect_ip() {
	local ip=""
	for s in "https://ipv4.icanhazip.com" "https://ipv4.ident.me" \
	         "https://ifconfig.me/ip" "https://api.ipify.org"; do
		ip="$(curl -4 -fsS --connect-timeout 8 "$s" 2>/dev/null | tr -d '[:space:]')" || ip=""
		[[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && { echo "$ip"; return; }
	done
	echo ""
}

prev_field() { # prev_field <KEY>  — read a value from an existing info.env
	[[ -f "$INFO_FILE" ]] || return 0
	sed -n "s/^$1=//p" "$INFO_FILE" 2>/dev/null | head -1 | sed 's/^"//; s/"$//'
}

require_root_arch() {
	[[ $EUID -eq 0 ]] || die "Запустите от root (sudo)."
	[[ "$(uname -m)" == "x86_64" ]] || die "Официальная сборка MTProxy требует x86_64."
	command -v systemctl >/dev/null 2>&1 || die "Нужен systemd."
	command -v apt-get   >/dev/null 2>&1 || die "Поддерживаются только apt-дистрибутивы (Ubuntu 22.04+/Debian 12+)."
}

# =====================================================================
#  INSTALL
# =====================================================================
do_install() {
	head2 "🚀 Telegram WEB Proxy — установка (tproxy-server + MTProxy + Caddy)"
	require_root_arch
	probe_tty

	local PREV_SECRET PREV_ADTAG
	PREV_SECRET="$(prev_field SECRET)"; PREV_ADTAG="$(prev_field ADTAG)"

	if [[ -f "$INFO_FILE" ]]; then
		warn "Похоже, WEB-прокси уже установлен ($INFO_FILE)."
		msg  "Переустановка перезапишет config/Caddyfile (сайт в /srv/tproxy-site сохранится)."
		confirm "Продолжить переустановку?" || { msg "Отменено. Управление: ${GREEN}tgwebproxy${NC}"; exit 1; }
	fi

	# --- inputs ---------------------------------------------------------
	head2 "1) Домен и почта"
	msg "Нужен ОТДЕЛЬНЫЙ домен, чьи A-запись указывает на этот сервер."
	msg "Он остаётся обычным сайтом; Telegram-трафик прячется в HTTPS к нему."
	local HOSTNAME EMAIL
	while :; do
		ask HOSTNAME "Домен (например proxy.example.com): " "" "${TGWP_HOSTNAME:-}" || true
		HOSTNAME="$(echo "$HOSTNAME" | tr 'A-Z' 'a-z' | tr -d '[:space:]')"
		[[ "$HOSTNAME" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ && "$HOSTNAME" == *.* ]] && break
		err "Некорректный домен. Только строчные ASCII, с точкой (домен, а не IP)."
		[[ -n "${TGWP_HOSTNAME:-}" ]] && exit 2
		[[ -z "$HAS_TTY" ]] && die "Нет терминала — задайте переменную TGWP_HOSTNAME."
	done
	while :; do
		ask EMAIL "E-mail для Let's Encrypt (ACME): " "" "${TGWP_EMAIL:-}" || true
		[[ "$EMAIL" =~ ^[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] && break
		err "Нужен корректный e-mail."
		[[ -n "${TGWP_EMAIL:-}" ]] && exit 2
		[[ -z "$HAS_TTY" ]] && die "Нет терминала — задайте переменную TGWP_EMAIL."
	done

	# --- secret ---------------------------------------------------------
	head2 "2) Секрет подключения"
	local SECRET="${TGWP_SECRET:-}"
	if [[ -z "$SECRET" && -n "$PREV_SECRET" ]]; then
		local keep; ask keep "Оставить текущий секрет $PREV_SECRET? [Y/n]: " "y" "" || true
		[[ ! "$keep" =~ ^[nNнН] ]] && SECRET="$PREV_SECRET"
	fi
	if [[ -z "$SECRET" ]]; then
		if [[ -n "$HAS_TTY" ]] && confirm "Ввести свой секрет вручную? (нет — сгенерирую)"; then
			ask_secret SECRET "Секрет (32 hex, можно с префиксом dd): " || true
		fi
	fi
	[[ -z "$SECRET" ]] && { SECRET="$(gen_secret)"; ok "Сгенерирован секрет: ${BOLD}$SECRET${NC}"; }
	SECRET="$(echo "$SECRET" | tr 'A-Z' 'a-z' | tr -d '[:space:]')"
	[[ "$SECRET" =~ ^([0-9a-f]{32}|dd[0-9a-f]{32})$ ]] \
		|| die "Секрет должен быть 32 hex-символа (опционально с префиксом dd). Префикс ee для WEB-прокси не поддерживается."

	# --- ad tag ---------------------------------------------------------
	head2 "3) Спонсорский канал (AD_TAG, необязательно)"
	msg "Тег от @MTProxybot показывает рекламный канал подключившимся."
	warn "Для WEB-прокси это НЕ проверено и не документировано (подробности после установки)."
	local ADTAG="${TGWP_ADTAG:-$PREV_ADTAG}"
	if [[ -z "$ADTAG" && -n "$HAS_TTY" ]]; then
		if confirm "Указать AD_TAG сейчас?"; then
			ask ADTAG "AD_TAG (32 hex, /newproxy у @MTProxybot): " "" "" || true
		fi
	fi
	ADTAG="$(echo "$ADTAG" | tr 'A-Z' 'a-z' | tr -d '[:space:]')"
	if [[ -n "$ADTAG" && ! "$ADTAG" =~ ^[0-9a-f]{32}$ ]]; then
		warn "AD_TAG не 32 hex — пропускаю."; ADTAG=""
	fi

	local WORKERS MAXCONN
	WORKERS="${TGWP_WORKERS:-1}"; MAXCONN="${TGWP_MAXCONN:-4096}"
	{ [[ "$WORKERS" =~ ^[1-9][0-9]*$ ]] && (( WORKERS <= 256 )); } || WORKERS=1
	[[ "$MAXCONN" =~ ^[1-9][0-9]*$ ]] || MAXCONN=4096

	# --- pre-flight -----------------------------------------------------
	head2 "4) Предварительные проверки"
	install_prereqs
	local PUBIP; PUBIP="$(detect_ip)"
	[[ -n "$PUBIP" ]] && msg "Внешний IPv4: ${GREEN}$PUBIP${NC}" || warn "Не удалось определить внешний IPv4."
	check_dns "$HOSTNAME" "$PUBIP"
	check_ports

	# --- cover website --------------------------------------------------
	head2 "5) Сайт-прикрытие"
	local SITE_ARG=()
	if [[ -n "${TGWP_SITE_DIR:-}" ]]; then
		local sd; sd="$(cd "${TGWP_SITE_DIR}" 2>/dev/null && pwd -P)" || die "TGWP_SITE_DIR не существует: ${TGWP_SITE_DIR}"
		[[ -f "${sd}/index.html" ]] || die "В TGWP_SITE_DIR нет index.html."
		if find "$sd" -type f ! -perm -o+r -print -quit 2>/dev/null | grep -q .; then
			warn "В вашем сайте есть файлы без права чтения для всех (o+r) — relay (пользователь tproxy) их не прочитает."
			warn "Исправьте: chmod -R o+r '$sd' (и o+x на подкаталоги)."
		fi
		SITE_ARG=(--site-dir "$sd"); ok "Использую ваш сайт: $sd"
	elif [[ -f /srv/tproxy-site/index.html ]]; then
		ok "Обнаружен существующий /srv/tproxy-site — он будет сохранён."
		SITE_ARG=()
	else
		if [[ -d /srv/tproxy-site && -n "$(find /srv/tproxy-site -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
			die "/srv/tproxy-site не пуст, но без index.html. Уберите каталог или добавьте index.html."
		fi
		mkdir -p "$SITE_STAGE"
		generate_site "$SITE_STAGE" "$HOSTNAME"
		SITE_ARG=(--site-dir "$SITE_STAGE")
		ok "Сгенерирован уникальный стартовый сайт (рандомизирован под этот сервер)."
		warn "Это ЗАГЛУШКА. Для реальной маскировки замените её своим настоящим сайтом:"
		msg  "  отредактируйте файлы в /srv/tproxy-site и выполните: systemctl restart tproxy-server"
	fi

	# --- fetch upstream repo -------------------------------------------
	head2 "6) Загрузка официального сервера tproxy-server"
	fetch_repo
	local REPO_REF; REPO_REF="$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
	msg "Коммит tproxy-server: ${GREEN}$REPO_REF${NC}"

	# --- persist metadata + management CLI (BEFORE install, so uninstall
	#     works even if the build fails partway) ------------------------
	write_info "$HOSTNAME" "$SECRET" "$EMAIL" "$ADTAG" "$WORKERS" "$MAXCONN" "$PUBIP" "$REPO_REF"
	install_mgmt_cli

	# --- run upstream installer ----------------------------------------
	head2 "7) Сборка и установка (Caddy, MTProxy, relay, systemd)"
	# Remove any stale AD_TAG drop-in first: upstream rewrites mtproxy.env
	# without MTPROXY_TAG and restarts mtproxy, which would break on a
	# drop-in that still references the now-unset ${MTPROXY_TAG}.
	if [[ -f "$ADTAG_DROPIN" ]]; then rm -f "$ADTAG_DROPIN"; systemctl daemon-reload 2>/dev/null || true; fi
	msg "Запускаю официальный deploy/install.sh — сборка Go и MTProxy, это займёт пару минут…"
	# Feed the secret via stdin so it never lands in the process list / ps.
	if ! ( cd "$REPO_DIR" && ./deploy/install.sh \
			--hostname "$HOSTNAME" --email "$EMAIL" \
			"${SITE_ARG[@]}" \
			--mtproxy-workers "$WORKERS" --mtproxy-max-connections "$MAXCONN" ) <<< "$SECRET"; then
		err "Официальный установщик завершился с ошибкой."
		msg "Журнал: journalctl -u caddy -u mtproxy -u tproxy-server --no-pager"
		msg "Удалить частичную установку: ${GREEN}tgwebproxy uninstall${NC}"
		exit 1
	fi

	# --- optional AD_TAG ------------------------------------------------
	if [[ -n "$ADTAG" ]]; then
		head2 "8) Применение AD_TAG"
		apply_adtag "$ADTAG" "$PUBIP" || ADTAG=""   # rolled back on failure
	fi

	# --- monitoring counters (persistent across reboots) ---------------
	install_monitor || warn "Не удалось настроить счётчики nftables (мониторинг трафика частично недоступен)."

	ok "Утилита управления установлена: ${GREEN}tgwebproxy${NC}"
	print_result "$HOSTNAME" "$SECRET" "$ADTAG"
}

# ---------------------------------------------------------------- prereqs
install_prereqs() {
	export DEBIAN_FRONTEND=noninteractive
	msg "Устанавливаю зависимости (git, curl, nftables, vnstat)…"
	apt-get update -qq
	apt-get install -y -qq --no-install-recommends \
		ca-certificates curl git nftables vnstat >/dev/null
	systemctl enable --now vnstat >/dev/null 2>&1 || true
}

check_dns() { # <hostname> <pubip>
	local host="$1" pubip="$2" resolved=""
	resolved="$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1{print $1}' || true)"
	if [[ -z "$resolved" ]]; then
		warn "Домен $host сейчас не резолвится. ACME (Let's Encrypt) не сможет выдать сертификат."
		confirm "Продолжить всё равно (A-запись добавите/подождёте)?" || die "Добавьте A-запись $host → ${pubip:-<IP сервера>} и повторите."
	elif [[ -n "$pubip" && "$resolved" != "$pubip" ]]; then
		warn "A-запись $host → $resolved, но внешний IP сервера $pubip. Проверьте DNS (без CDN/прокси)."
		confirm "Продолжить?" || die "Исправьте A-запись и повторите."
	else
		ok "DNS: $host → ${resolved:-?}"
	fi
}

check_ports() {
	local busy; busy="$(ss -Htlnp '( sport = :80 or sport = :443 )' 2>/dev/null || true)"
	if [[ -n "$busy" ]] && ! grep -qi 'caddy' <<< "$busy"; then
		warn "Порты 80/443 заняты не Caddy:"; echo "$busy"
		confirm "Установщик заменит владельца портов на Caddy. Продолжить?" \
			|| die "Освободите 80/443 (или используйте ручную интеграцию из README tproxy-server)."
	fi
}

fetch_repo() {
	local ref="${TGWP_REF:-}"
	if [[ -d "$REPO_DIR/.git" ]]; then
		git -C "$REPO_DIR" fetch --depth 1 origin >/dev/null 2>&1 || true
		git -C "$REPO_DIR" reset --hard origin/HEAD >/dev/null 2>&1 \
			|| git -C "$REPO_DIR" pull --ff-only >/dev/null 2>&1 || true
	else
		rm -rf "$REPO_DIR"
		git clone --depth 1 "$REPO_URL" "$REPO_DIR" >/dev/null 2>&1 \
			|| die "Не удалось клонировать $REPO_URL"
	fi
	if [[ -n "$ref" ]]; then
		git -C "$REPO_DIR" fetch --depth 1 origin "$ref" >/dev/null 2>&1 || true
		git -C "$REPO_DIR" checkout -q "$ref" 2>/dev/null || warn "Коммит $ref не найден — использую HEAD."
	fi
	[[ -x "$REPO_DIR/deploy/install.sh" ]] || die "В репозитории нет deploy/install.sh — структура изменилась."
}

write_info() { # <host> <secret> <email> <adtag> <workers> <maxconn> <pubip> <ref>
	mkdir -p "$STATE_DIR"
	# NB: every value is quoted so the file is safe to `source` (INSTALLED_AT has spaces).
	cat > "$INFO_FILE" <<EOF
HOSTNAME="$1"
SECRET="$2"
EMAIL="$3"
ADTAG="$4"
WORKERS="$5"
MAXCONN="$6"
PUBIP="$7"
REPO_DIR="$REPO_DIR"
REPO_REF="$8"
INSTALLED_AT="$(date '+%Y-%m-%d %H:%M:%S %Z')"
EOF
	chmod 0600 "$INFO_FILE"
}

# ---------------------------------------------------------------- AD_TAG
# Applies -P <tag> to the stock MTProxy via a systemd drop-in that survives
# upstream re-installs of the base unit. Switches MTProxy to middle-proxy
# mode; behind NAT that needs --nat-info <private>:<public>.
apply_adtag() { # <tag> <pubip>
	local tag="$1" pubip="$2" localip natinfo=""
	localip="$(ip -4 route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
	if [[ -n "$pubip" && -n "$localip" && "$localip" != "$pubip" ]]; then
		natinfo=" --nat-info ${localip}:${pubip}"
		msg "Обнаружен NAT ($localip за $pubip) → добавляю --nat-info."
	fi
	if grep -q '^MTPROXY_TAG=' "$MTENV" 2>/dev/null; then
		sed -i "s/^MTPROXY_TAG=.*/MTPROXY_TAG=$tag/" "$MTENV"
	else
		echo "MTPROXY_TAG=$tag" >> "$MTENV"
	fi
	mkdir -p "$(dirname "$ADTAG_DROPIN")"
	cat > "$ADTAG_DROPIN" <<EOF
[Service]
ExecStart=
ExecStart=/opt/MTProxy/objs/bin/mtproto-proxy -u mtproxy -p 8888 -H 2398 -S \${MTPROXY_SECRET} -P \${MTPROXY_TAG}${natinfo} --aes-pwd /etc/mtproxy/proxy-secret /etc/mtproxy/proxy-multi.conf -M \${MTPROXY_WORKERS} -C \${MTPROXY_MAX_CONNECTIONS}
EOF
	systemctl daemon-reload
	# If MTProxy refuses to start with the tag, roll back instead of aborting
	# the whole install — the proxy itself works fine without a tag.
	if systemctl restart mtproxy.service 2>/dev/null; then
		ok "AD_TAG применён (middle-proxy mode)."
	else
		warn "MTProxy не запустился с AD_TAG — откатываю тег (прокси продолжит работать без него)."
		msg  "Диагностика: journalctl -u mtproxy --no-pager -n 50"
		rm -f "$ADTAG_DROPIN"
		sed -i '/^MTPROXY_TAG=/d' "$MTENV" 2>/dev/null || true
		systemctl daemon-reload
		systemctl restart mtproxy.service || warn "MTProxy всё ещё не стартует — проверьте журнал."
		sed -i 's|^ADTAG=.*|ADTAG=""|' "$INFO_FILE" 2>/dev/null || true
		return 1
	fi
}

# ---------------------------------------------------------------- monitoring
# A DISTINCT nft table so it never clashes with the installer's inet
# tproxy_backend. A tiny oneshot unit (like tproxy-firewall) re-applies it
# after every reboot / nftables reload so counting survives.
install_monitor() {
	command -v nft >/dev/null 2>&1 || return 1
	mkdir -p /etc/tproxy-server
	cat > "$MON_NFT" <<EOF
add table inet $MON_TABLE
delete table inet $MON_TABLE
table inet $MON_TABLE {
	counter tls_in  { }
	counter tls_out { }
	chain input  { type filter hook input  priority filter; policy accept; tcp dport 443 counter name tls_in;  }
	chain output { type filter hook output priority filter; policy accept; tcp sport 443 counter name tls_out; }
}
EOF
	cat > "$MON_UNIT" <<EOF
[Unit]
Description=Traffic counters for Telegram WEB proxy (:443)
After=nftables.service
PartOf=nftables.service

[Service]
Type=oneshot
RemainAfterExit=true
ExecStart=/usr/sbin/nft -f $MON_NFT
ExecReload=/usr/sbin/nft -f $MON_NFT
ExecStop=-/usr/sbin/nft delete table inet $MON_TABLE

[Install]
WantedBy=multi-user.target
EOF
	systemctl daemon-reload
	systemctl enable --now tgmon-counters.service >/dev/null 2>&1 || return 1
	return 0
}

# ---------------------------------------------------------------- cover site generator
# Produces a small, RANDOMIZED static site so two installs never share a
# fingerprint. Files are made world-readable (relay runs as user `tproxy`).
generate_site() { # <dir> <hostname>
	local dir="$1" host="$2"
	local names=("Northwind Labs" "Meridian Studio" "Aster Digital" "Blue Harbor" \
	             "Quantic Works" "Larkspur Media" "Vireo Systems" "Orchard & Pine" \
	             "Cobalt Field" "Selene Consulting" "Driftwood Co" "Halcyon Group")
	local taglines=("Проектируем цифровые продукты" "Инженерия данных и облака" \
	                "Дизайн, который работает" "Автоматизация для бизнеса" \
	                "Исследования и разработка" "Инфраструктура нового поколения")
	local accents=("#2563eb" "#0891b2" "#7c3aed" "#059669" "#dc2626" "#d97706" "#0d9488" "#4f46e5")
	local rand; rand="$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')"
	local name="${names[$((rand % ${#names[@]}))]}"
	local tag="${taglines[$(( (rand/7) % ${#taglines[@]}))]}"
	local accent="${accents[$(( (rand/13) % ${#accents[@]}))]}"
	local year; year="$(date +%Y)"

	cat > "$dir/styles.css" <<EOF
:root{--a:${accent};--bg:#f7f7f9;--fg:#16181d;--mut:#5c6470}
*{box-sizing:border-box}body{margin:0;font:16px/1.6 -apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;color:var(--fg);background:var(--bg)}
.wrap{max-width:880px;margin:0 auto;padding:0 20px}
header{padding:22px 0;border-bottom:1px solid #e6e8ec}
.brand{font-weight:700;font-size:20px;color:var(--a);text-decoration:none}
nav a{color:var(--mut);text-decoration:none;margin-left:18px}nav a:hover{color:var(--a)}
.hero{padding:64px 0 40px}.hero h1{font-size:40px;margin:0 0 12px}.hero p{font-size:19px;color:var(--mut);max-width:60ch}
.btn{display:inline-block;margin-top:20px;background:var(--a);color:#fff;padding:11px 20px;border-radius:8px;text-decoration:none}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:18px;padding:24px 0 56px}
.card{background:#fff;border:1px solid #e6e8ec;border-radius:12px;padding:20px}
.card h3{margin:0 0 8px}footer{border-top:1px solid #e6e8ec;padding:24px 0;color:var(--mut);font-size:14px}
EOF

	cat > "$dir/index.html" <<EOF
<!doctype html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${name}</title><link rel="stylesheet" href="/styles.css"></head><body>
<header><div class="wrap" style="display:flex;justify-content:space-between;align-items:center">
<a class="brand" href="/">${name}</a>
<nav><a href="/">Главная</a><a href="/about">О нас</a><a href="/privacy">Приватность</a></nav>
</div></header>
<main class="wrap">
<section class="hero"><h1>${name}</h1><p>${tag}. Мы помогаем командам запускать продукты быстрее и надёжнее.</p>
<a class="btn" href="/about">Узнать больше</a></section>
<section class="grid">
<div class="card"><h3>Консалтинг</h3><p>Аудит, стратегия и сопровождение проектов на всех этапах.</p></div>
<div class="card"><h3>Разработка</h3><p>Веб-сервисы, интеграции и надёжная инфраструктура.</p></div>
<div class="card"><h3>Поддержка</h3><p>Мониторинг, обновления и оперативная помощь 24/7.</p></div>
</section></main>
<footer><div class="wrap">© ${year} ${name}. Все права защищены.</div></footer>
</body></html>
EOF

	cat > "$dir/about.html" <<EOF
<!doctype html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>О нас — ${name}</title><link rel="stylesheet" href="/styles.css"></head><body>
<header><div class="wrap"><a class="brand" href="/">${name}</a></div></header>
<main class="wrap"><section class="hero"><h1>О компании</h1>
<p>${name} — независимая команда специалистов. ${tag}. Работаем с 2019 года,
ценим прозрачность, качество и долгосрочные отношения с клиентами.</p></section></main>
<footer><div class="wrap">© ${year} ${name}.</div></footer></body></html>
EOF

	cat > "$dir/privacy.html" <<EOF
<!doctype html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Политика приватности — ${name}</title><link rel="stylesheet" href="/styles.css"></head><body>
<header><div class="wrap"><a class="brand" href="/">${name}</a></div></header>
<main class="wrap"><section class="hero"><h1>Политика приватности</h1>
<p>Мы уважаем вашу конфиденциальность и обрабатываем данные только в объёме,
необходимом для оказания услуг. Свяжитесь с нами по вопросам обработки данных.</p></section></main>
<footer><div class="wrap">© ${year} ${name}.</div></footer></body></html>
EOF

	cat > "$dir/404.html" <<EOF
<!doctype html><html lang="ru"><head><meta charset="utf-8">
<title>404 — ${name}</title><link rel="stylesheet" href="/styles.css"></head><body>
<main class="wrap"><section class="hero"><h1>Страница не найдена</h1>
<p>Вернитесь на <a href="/">главную</a>.</p></section></main></body></html>
EOF

	printf 'User-agent: *\nAllow: /\n' > "$dir/robots.txt"

	# Make everything readable by the relay's unprivileged user (umask is 077).
	chmod 0755 "$dir"
	find "$dir" -type f -exec chmod 0644 {} + 2>/dev/null || true
}

# ---------------------------------------------------------------- final output
print_result() { # <hostname> <secret> <adtag>
	local host="$1" secret="$2" adtag="$3"
	head2 "🎉 Готово — WEB-прокси развёрнут на https://$host/"
	echo
	echo -e "${YELLOW}${BOLD}Данные для клиента:${NC}"
	echo -e "  Домен (Hostname): ${GREEN}$host${NC}"
	echo -e "  Секрет  (Secret): ${GREEN}$secret${NC}"
	echo
	echo -e "${YELLOW}${BOLD}Ссылки подключения:${NC}"
	echo -e "  ${GREEN}https://t.me/webproxy?server=$host&secret=$secret${NC}"
	echo -e "  ${GREEN}tg://webproxy?server=$host&secret=$secret${NC}"
	echo
	echo -e "${YELLOW}Как добавить вручную (самый надёжный способ):${NC}"
	echo -e "  Telegram → Настройки → Продвинутые → Тип соединения →"
	echo -e "  Добавить прокси → ${BOLD}WEB${NC} → Hostname: ${GREEN}$host${NC}, Secret: ${GREEN}$secret${NC}"
	echo
	warn "Клиент должен поддерживать WEB-прокси: Telegram Desktop ≥ 7.1.1 (авг 2026)"
	warn "или Android beta 12.10.2+. На iOS/macOS-native пока нет."
	warn "Публичный t.me пока НЕ регистрирует маршрут /webproxy — для теста"
	warn "используйте ссылку tg:// или ручной ввод."
	if [[ -n "$adtag" ]]; then
		echo; warn "AD_TAG включён, но для WEB-прокси показ спонсорского канала НЕ гарантирован."
		msg  "Подробности и ограничения: tgwebproxy adtag"
	fi
	echo
	echo -e "${BLUE}${BOLD}Управление:${NC}"
	echo -e "  ${GREEN}tgwebproxy status${NC}   — статус, подключения, трафик"
	echo -e "  ${GREEN}tgwebproxy watch${NC}    — живой мониторинг"
	echo -e "  ${GREEN}tgwebproxy link${NC}     — снова показать ссылки"
	echo -e "  ${GREEN}tgwebproxy adtag${NC}    — включить/сменить/убрать AD_TAG"
	echo -e "  ${GREEN}tgwebproxy update${NC}   — обновить relay из репозитория"
	echo -e "  ${GREEN}tgwebproxy uninstall${NC}— полностью удалить"
	echo
	msg "Проверка: ${GREEN}curl -fsS $RELAY_ADMIN/readyz${NC} → ready; ${GREEN}curl -fsS https://$host/${NC}"
}

# =====================================================================
#  MANAGEMENT CLI  (installed to /usr/local/bin/tgwebproxy)
# =====================================================================
install_mgmt_cli() {
	cat > "$MGMT" <<'UTILITY_EOF'
#!/usr/bin/env bash
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

INFO_FILE="/opt/tgwebproxy/info.env"
MTENV="/etc/mtproxy/mtproxy.env"
ADTAG_DROPIN="/etc/systemd/system/mtproxy.service.d/adtag.conf"
MON_UNIT="/etc/systemd/system/tgmon-counters.service"
MON_NFT="/etc/tproxy-server/tgmon.nft"
RELAY_ADMIN="http://127.0.0.1:8081"
MTPROXY_STATS="http://127.0.0.1:8888"
MON_TABLE="tgmon"
SERVICES=(caddy tproxy-server mtproxy tproxy-firewall refresh-mtproxy-config.timer)

msg(){ echo -e "${CYAN}$*${NC}"; }
ok(){ echo -e "${GREEN}✅ $*${NC}"; }
warn(){ echo -e "${YELLOW}⚠️  $*${NC}"; }
err(){ echo -e "${RED}❌ $*${NC}" >&2; }

need_root(){ [[ $EUID -eq 0 ]] || { err "Нужен root (sudo tgwebproxy $*)."; exit 1; }; }
load_info(){
	if [[ ! -r "$INFO_FILE" ]]; then
		[[ $EUID -ne 0 ]] && { err "Запустите через sudo."; exit 1; }
		err "WEB-прокси не установлен ($INFO_FILE не найден)."; exit 1
	fi
	# shellcheck disable=SC1090
	source "$INFO_FILE"
}

h2h(){ local b="${1:-0}"
	if command -v numfmt >/dev/null 2>&1 && [[ "$b" =~ ^[0-9]+$ ]]; then numfmt --to=iec --suffix=B "$b"; else echo "${b} B"; fi; }

nft_bytes(){ nft list counter inet "$MON_TABLE" "$1" 2>/dev/null \
	| awk '{for(i=1;i<=NF;i++) if($i=="bytes"){print $(i+1); exit}}'; }
ensure_monitor(){
	command -v nft >/dev/null 2>&1 || return 1
	nft list table inet "$MON_TABLE" >/dev/null 2>&1 && return 0
	[[ -f "$MON_NFT" ]] && nft -f "$MON_NFT" >/dev/null 2>&1
}
metric(){ curl -fsS --max-time 4 "$RELAY_ADMIN/metrics" 2>/dev/null | awk -v n="$1" '$1==n{print $2; exit}'; }
mtstat(){ curl -fsS --max-time 4 "$MTPROXY_STATS/stats" 2>/dev/null | awk -F'\t' -v n="$1" '$1==n{print $2; exit}'; }
conns(){ ss -Htn state established "( $1 = :$2 )" 2>/dev/null | wc -l | tr -d ' '; }

show_link(){
	need_root link; load_info
	echo -e "${YELLOW}${BOLD}Ссылки подключения:${NC}"
	echo -e "  ${GREEN}https://t.me/webproxy?server=$HOSTNAME&secret=$SECRET${NC}"
	echo -e "  ${GREEN}tg://webproxy?server=$HOSTNAME&secret=$SECRET${NC}"
	echo
	echo -e "  Ручной ввод: Telegram → Настройки → Продвинутые → Тип соединения →"
	echo -e "  Добавить прокси → ${BOLD}WEB${NC} → Hostname: ${GREEN}$HOSTNAME${NC}, Secret: ${GREEN}$SECRET${NC}"
	echo
	warn "Нужен клиент с поддержкой WEB-прокси: Desktop ≥ 7.1.1 или Android beta 12.10.2+."
}

show_status(){
	need_root status; load_info
	echo -e "${BLUE}${BOLD}=== Telegram WEB Proxy — статус ===${NC}\n"
	echo -e "Домен: ${GREEN}${HOSTNAME:-?}${NC}   Установлен: ${INSTALLED_AT:-?}   Коммит: ${REPO_REF:-?}"

	echo -e "\n${YELLOW}Службы:${NC}"
	local s state
	for s in "${SERVICES[@]}"; do
		state="$(systemctl is-active "$s" 2>/dev/null)" || true
		state="${state:-unknown}"
		if [[ "$state" == active ]]; then echo -e "  ${GREEN}●${NC} $s"
		else echo -e "  ${RED}○${NC} $s ($state)"; fi
	done

	echo -e "\n${YELLOW}Здоровье relay:${NC}"
	if curl -fsS --max-time 4 "$RELAY_ADMIN/healthz" >/dev/null 2>&1; then echo -e "  healthz: ${GREEN}ok${NC}"
	else echo -e "  healthz: ${RED}fail${NC}"; fi
	if curl -fsS --max-time 4 "$RELAY_ADMIN/readyz" >/dev/null 2>&1; then echo -e "  readyz:  ${GREEN}ready${NC} (MTProxy-бэкенд доступен)"
	else echo -e "  readyz:  ${RED}503${NC} (MTProxy-бэкенд недоступен — journalctl -u mtproxy)"; fi

	echo -e "\n${YELLOW}Подключения (live):${NC}"
	echo -e "  Клиенты → Caddy (:443):     ${GREEN}$(conns sport 443)${NC}"
	echo -e "  Caddy → relay (:8080):      ${GREEN}$(conns sport 8080)${NC}"
	echo -e "  relay → MTProxy (:2398):    ${GREEN}$(conns dport 2398)${NC}"
	local mtc; mtc="$(mtstat total_special_connections)"
	[[ -n "$mtc" ]] && echo -e "  MTProxy proxied users:      ${GREEN}$mtc${NC}"

	echo -e "\n${YELLOW}Relay-метрики:${NC}"
	local sl st bu bd sc sr df
	sl="$(metric tproxy_sessions_live)"; st="$(metric tproxy_streams_live)"
	sc="$(metric tproxy_sessions_created_total)"; sr="$(metric tproxy_streams_rejected_total)"
	df="$(metric tproxy_backend_dial_failures_total)"
	bu="$(metric tproxy_bytes_up_total)"; bd="$(metric tproxy_bytes_down_total)"
	echo -e "  Живые сессии/стримы:        ${GREEN}${sl:-?}${NC} / ${GREEN}${st:-?}${NC}"
	echo -e "  Всего сессий создано:       ${GREEN}${sc:-?}${NC}   отклонено стримов: ${GREEN}${sr:-0}${NC}"
	echo -e "  Ошибки dial к бэкенду:      ${GREEN}${df:-0}${NC}"
	[[ -n "$bu$bd" ]] && echo -e "  Трафик relay ↑/↓:           ${GREEN}$(h2h "${bu:-0}")${NC} / ${GREEN}$(h2h "${bd:-0}")${NC}"

	echo -e "\n${YELLOW}Трафик HTTPS (:443, nftables-счётчики):${NC}"
	ensure_monitor
	local ti to; ti="$(nft_bytes tls_in)"; to="$(nft_bytes tls_out)"
	if [[ -n "$ti$to" ]]; then
		echo -e "  Входящий:  ${GREEN}$(h2h "${ti:-0}")${NC}   Исходящий: ${GREEN}$(h2h "${to:-0}")${NC}"
		echo -e "  ${CYAN}(с момента создания счётчика; сбрасывается при перезагрузке/reload nftables)${NC}"
	else warn "  Счётчики nftables недоступны."; fi

	if command -v vnstat >/dev/null 2>&1; then
		local IF; IF="$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')"
		if [[ -n "$IF" ]]; then
			echo -e "\n${YELLOW}Трафик интерфейса $IF (vnstat, persistent):${NC}"
			vnstat -i "$IF" 2>/dev/null | sed 's/^/  /' | grep -E 'today|month|rx|tx|estimated' | head -8 || true
		fi
	fi

	if [[ -n "${ADTAG:-}" ]]; then
		echo -e "\n${YELLOW}AD_TAG:${NC} ${GREEN}$ADTAG${NC} (middle-proxy). Для WEB-прокси показ канала не гарантирован."
	else echo -e "\n${YELLOW}AD_TAG:${NC} не задан. Включить: ${GREEN}tgwebproxy adtag${NC}"; fi
}

do_watch(){
	need_root watch
	command -v watch >/dev/null 2>&1 || { err "Утилита 'watch' не найдена (apt install procps)."; exit 1; }
	exec watch -c -n 2 "tgwebproxy status"
}

do_logs(){ need_root logs; journalctl -u tproxy-server -u mtproxy -u caddy -f --no-pager; }

do_restart(){
	need_root restart
	msg "Перезапуск (клиентские сессии переподключатся автоматически)…"
	systemctl restart mtproxy.service tproxy-server.service caddy.service
	ok "Перезапущено."; show_status
}

do_update(){
	need_root update; load_info
	[[ -x "${REPO_DIR:-/opt/tproxy-server-src}/deploy/update-relay.sh" ]] \
		|| { err "Нет ${REPO_DIR}/deploy/update-relay.sh"; exit 1; }
	msg "Обновляю репозиторий и relay (с авто-откатом при неудаче)…"
	git -C "$REPO_DIR" pull --ff-only 2>/dev/null || warn "git pull не удался — собираю текущую версию."
	( cd "$REPO_DIR" && ./deploy/update-relay.sh ) && ok "Relay обновлён." || err "Обновление не удалось (откат выполнен автоматически)."
}

do_adtag(){
	need_root adtag; load_info
	echo -e "${YELLOW}${BOLD}AD_TAG — спонсорский канал${NC}\n"
	warn "Стек WEB-прокси не тестирует и не документирует показ спонсорского канала."
	warn "MTProxy видит все подключения с 127.0.0.1 (relay) — атрибуция по IP теряется."
	warn "Зарегистрировать WEB-домен у @MTProxybot НЕЛЬЗЯ: он проверяет публичный host:port"
	warn "сырого MTProto, а здесь :2398 закрыт фаерволом. Тег применяется 'вслепую'."
	echo
	msg "Как получить тег: @MTProxybot → /newproxy → (host:port, secret) → тег (32 hex)."
	echo
	local cur="${ADTAG:-}"; [[ -n "$cur" ]] && msg "Текущий AD_TAG: $cur"

	# A new tag can be passed as an argument (non-interactive). Interactive
	# empty line removes the tag; a FAILED prompt (no tty) must NOT remove it.
	local new
	if [[ $# -ge 1 ]]; then new="$1"
	elif [[ -e /dev/tty ]] && read -r -p "Новый AD_TAG (32 hex; пусто = убрать): " new </dev/tty; then :
	else err "Нужен интерактивный терминал или аргумент: tgwebproxy adtag <32hex|off>"; exit 1; fi

	new="$(echo "$new" | tr 'A-Z' 'a-z' | tr -d '[:space:]')"
	[[ "$new" == "off" || "$new" == "none" ]] && new=""
	local pubip="${PUBIP:-}" localip natinfo=""
	if [[ -n "$new" ]]; then
		[[ "$new" =~ ^[0-9a-f]{32}$ ]] || { err "AD_TAG должен быть 32 hex (или 'off' для удаления)."; exit 1; }
		localip="$(ip -4 route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
		[[ -n "$pubip" && -n "$localip" && "$localip" != "$pubip" ]] && natinfo=" --nat-info ${localip}:${pubip}"
		if grep -q '^MTPROXY_TAG=' "$MTENV" 2>/dev/null; then sed -i "s/^MTPROXY_TAG=.*/MTPROXY_TAG=$new/" "$MTENV"
		else echo "MTPROXY_TAG=$new" >> "$MTENV"; fi
		mkdir -p "$(dirname "$ADTAG_DROPIN")"
		cat > "$ADTAG_DROPIN" <<EOF
[Service]
ExecStart=
ExecStart=/opt/MTProxy/objs/bin/mtproto-proxy -u mtproxy -p 8888 -H 2398 -S \${MTPROXY_SECRET} -P \${MTPROXY_TAG}${natinfo} --aes-pwd /etc/mtproxy/proxy-secret /etc/mtproxy/proxy-multi.conf -M \${MTPROXY_WORKERS} -C \${MTPROXY_MAX_CONNECTIONS}
EOF
		systemctl daemon-reload; systemctl restart mtproxy.service
		sed -i "s|^ADTAG=.*|ADTAG=\"$new\"|" "$INFO_FILE"
		ok "AD_TAG установлен: $new (middle-proxy mode)."
	else
		rm -f "$ADTAG_DROPIN"; sed -i '/^MTPROXY_TAG=/d' "$MTENV" 2>/dev/null || true
		systemctl daemon-reload; systemctl restart mtproxy.service
		sed -i 's|^ADTAG=.*|ADTAG=""|' "$INFO_FILE"
		ok "AD_TAG убран (direct relay mode)."
	fi
}

do_uninstall(){
	need_root uninstall
	echo -e "${YELLOW}${BOLD}Удаление Telegram WEB Proxy${NC}\n"
	if [[ -r "$INFO_FILE" ]]; then # shellcheck disable=SC1090
		source "$INFO_FILE"
		msg "Перед удалением — ваши данные (сохраните, если нужны):"
		echo -e "  ${GREEN}tg://webproxy?server=${HOSTNAME:-?}&secret=${SECRET:-?}${NC}\n"
	fi
	local purge="no"
	if [[ "${1:-}" == "--purge" ]]; then purge="yes"
	elif [[ -e /dev/tty ]] && read -r -p "Удалить также сертификаты, сайт и системных пользователей? (--purge) [y/N]: " a </dev/tty; then
		[[ "$a" =~ ^[yYдД] ]] && purge="yes"
	fi
	local c=""
	[[ -e /dev/tty ]] && read -r -p "Введите YES для подтверждения удаления: " c </dev/tty || c="${TGWP_YES:+YES}"
	[[ "$c" == "YES" ]] || { msg "Отменено."; exit 0; }

	msg "Останавливаю службы…"
	systemctl disable --now caddy.service tproxy-server.service mtproxy.service \
		refresh-mtproxy-config.timer refresh-mtproxy-config.service tproxy-firewall.service \
		tgmon-counters.service 2>/dev/null || true

	msg "Удаляю firewall-таблицы…"
	nft delete table inet tproxy_backend 2>/dev/null || true
	nft delete table inet "$MON_TABLE" 2>/dev/null || true

	msg "Удаляю systemd-юниты…"
	rm -f /etc/systemd/system/{tproxy-server,mtproxy,tproxy-firewall,refresh-mtproxy-config}.service
	rm -f /etc/systemd/system/refresh-mtproxy-config.timer "$MON_UNIT"
	rm -rf /etc/systemd/system/mtproxy.service.d
	rm -f /usr/local/bin/tproxy-server /usr/local/bin/tproxy-server.previous /usr/local/bin/tproxy-server.next
	rm -f /usr/local/sbin/refresh-mtproxy-config
	rm -rf /etc/tproxy-server /etc/mtproxy /opt/MTProxy /opt/MTProxy.before-tproxy.* /opt/tproxy-server-src

	# Caddy: restore the OLDEST pre-tproxy backup (the user's true original)
	local cbak sbak
	cbak="$(ls -1 /etc/caddy/Caddyfile.before-tproxy.* 2>/dev/null | sort | head -1 || true)"
	sbak="$(ls -1 /etc/systemd/system/caddy.service.before-tproxy.* 2>/dev/null | sort | head -1 || true)"
	if [[ -n "$cbak" ]]; then
		mv -f "$cbak" /etc/caddy/Caddyfile
		rm -f /etc/caddy/Caddyfile.tproxy /etc/caddy/Caddyfile.before-tproxy.* /etc/systemd/system/caddy.service.d/tproxy.conf
		[[ -n "$sbak" ]] && mv -f "$sbak" /etc/systemd/system/caddy.service
		rm -f /etc/systemd/system/caddy.service.before-tproxy.*
		systemctl daemon-reload 2>/dev/null || true
		systemctl enable --now caddy.service 2>/dev/null || true
		msg "Восстановлен и перезапущен предыдущий Caddy."
	else
		systemctl disable --now caddy.service 2>/dev/null || true
		rm -f /etc/systemd/system/caddy.service /etc/systemd/system/caddy.service.before-tproxy.*
		rm -rf /etc/systemd/system/caddy.service.d /etc/caddy /usr/local/bin/caddy
	fi
	systemctl daemon-reload 2>/dev/null || true

	if [[ "$purge" == "yes" ]]; then
		msg "Purge: удаляю сайт, сертификаты, Go-тулчейн и пользователей…"
		rm -rf /srv/tproxy-site /var/lib/caddy /opt/go1.*
		userdel caddy 2>/dev/null || true
		userdel mtproxy 2>/dev/null || true
		userdel tproxy 2>/dev/null || true
	else
		warn "Сохранены: /srv/tproxy-site, сертификаты (/var/lib/caddy), /opt/go*. Удалите вручную при желании."
	fi
	rm -rf /opt/tgwebproxy
	rm -f /usr/local/bin/tgwebproxy
	ok "Telegram WEB Proxy удалён."
}

show_help(){
	echo -e "${BLUE}${BOLD}tgwebproxy — управление Telegram WEB Proxy${NC}\n"
	echo "Команды (нужен sudo):"
	echo -e "  ${GREEN}status${NC}         — статус служб, подключения, трафик, метрики"
	echo -e "  ${GREEN}watch${NC}          — живой мониторинг (обновление каждые 2с)"
	echo -e "  ${GREEN}link${NC}           — показать ссылки подключения"
	echo -e "  ${GREEN}logs${NC}           — журналы relay/MTProxy/Caddy (follow)"
	echo -e "  ${GREEN}restart${NC}        — перезапустить службы"
	echo -e "  ${GREEN}update${NC}         — обновить relay из репозитория (с откатом)"
	echo -e "  ${GREEN}adtag [32hex|off]${NC} — включить/сменить/убрать AD_TAG (@MTProxybot)"
	echo -e "  ${GREEN}uninstall${NC}      — полностью удалить (--purge — с сайтом и сертификатами)"
	echo -e "  ${GREEN}help${NC}           — эта справка"
}

case "${1:-status}" in
	status)     show_status ;;
	watch)      do_watch ;;
	link|links) show_link ;;
	logs)       do_logs ;;
	restart)    do_restart ;;
	update)     do_update ;;
	adtag|tag)  shift || true; do_adtag "$@" ;;
	uninstall)  shift || true; do_uninstall "${1:-}" ;;
	help|-h|--help) show_help ;;
	*) err "Неизвестная команда: $1"; show_help; exit 1 ;;
esac
UTILITY_EOF
	chmod 0755 "$MGMT"
}

# =====================================================================
#  ENTRYPOINT
# =====================================================================
main() {
	local cmd="${1:-install}"
	case "$cmd" in
		install|"") do_install ;;
		status|watch|link|links|logs|restart|update|adtag|tag|uninstall)
			if [[ -x "$MGMT" ]]; then exec "$MGMT" "$@"
			else die "WEB-прокси ещё не установлен. Сначала запустите установку без аргументов."; fi ;;
		help|-h|--help)
			echo -e "${BLUE}${BOLD}Telegram WEB Proxy — установщик${NC}\n"
			echo "Использование:"
			echo -e "  ${GREEN}bash <(wget -qO- https://dignezzz.github.io/server/tg-webproxy.sh)${NC}            — установка"
			echo -e "  ${GREEN}bash <(wget -qO- https://dignezzz.github.io/server/tg-webproxy.sh) uninstall${NC}  — удаление"
			echo
			echo -e "После установки — команда ${GREEN}tgwebproxy${NC}:"
			echo -e "  status | watch | link | logs | restart | update | adtag | uninstall | help"
			echo
			echo "Env для non-interactive установки:"
			echo "  TGWP_HOSTNAME TGWP_EMAIL TGWP_SECRET TGWP_ADTAG TGWP_WORKERS TGWP_MAXCONN TGWP_SITE_DIR TGWP_REF TGWP_YES=1" ;;
		*) die "Неизвестная команда '$cmd'. Справка: $SELF help" ;;
	esac
}

main "$@"
