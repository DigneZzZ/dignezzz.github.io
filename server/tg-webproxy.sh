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
#   bash <(wget -qO- https://raw.githubusercontent.com/DigneZzZ/tg-webproxy/main/tg-webproxy.sh)   # interactive install
#   mirror: https://dignezzz.github.io/server/tg-webproxy.sh   (same script, GitHub Pages)
#   Repository, docs, issues: https://github.com/DigneZzZ/tg-webproxy
#   ... status | watch | link | mode | logs | restart | update | adtag | version | self-update | uninstall | help
#
# Non-interactive install (env overrides): TGWP_HOSTNAME, TGWP_EMAIL,
#   TGWP_SECRET (32 hex or dd+32hex; empty = auto/keep), TGWP_ADTAG (32 hex),
#   TGWP_MODE (https|https-lanes|websocket|websocket-lanes|all),
#   TGWP_WORKERS, TGWP_MAXCONN, TGWP_SITE_DIR (own site), TGWP_REF (pin repo commit),
#   TGWP_YES=1 (auto-confirm all prompts).
# Split mode (relay and MTProxy on different hosts, joined by NetBird/WireGuard):
#   TGWP_ROLE=front   + TGWP_BACKEND=<tunnel ip[:port]>            (Caddy + relay here)
#   TGWP_ROLE=backend + TGWP_SECRETS="s1 s2" TGWP_ALLOW_FROM=<cidr,...>  (only MTProxy here)
# Networks that block core.telegram.org: put getProxySecret/getProxyConfig into
#   /opt/tgwebproxy/tg/{proxy-secret,proxy-multi.conf} or set TGWP_TG_MIRROR=https://host/path
#
# Requirements: root, x86_64, systemd, Ubuntu 22.04+/Debian 12+, public IPv4,
#               a dedicated hostname with an A record → this server.

set -euo pipefail
umask 077

TGWP_VERSION="1.3.2"   # bump on every change: `tgwebproxy version` / self-update compare it
# C.UTF-8 is built into glibc >= 2.35 (Ubuntu 22.04+/Debian 12+): keeps ${var:0:1}
# and tr multibyte-safe even when the SSH client forwards an uninstalled locale.
export LC_ALL=C.UTF-8
export NEEDRESTART_SUSPEND=1   # no "Scanning processes…" / service restarts from apt hooks

# ---------------------------------------------------------------- appearance
RED=$'\033[38;5;196m'; GREEN=$'\033[38;5;46m'; YELLOW=$'\033[38;5;214m'
BLUE=$'\033[38;5;39m'; CYAN=$'\033[38;5;51m'; BOLD=$'\033[1m'; DIM=$'\033[38;5;245m'; NC=$'\033[0m'

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
LOG="/var/log/tgwebproxy-install.log"   # full apt/make/go/installer output
# Where the published script lives. Version checks read the first 4 KB of each
# and take the HIGHEST version found (jsDelivr/Pages may lag behind raw GitHub).
SCRIPT_URLS=(
	"https://raw.githubusercontent.com/DigneZzZ/tg-webproxy/main/tg-webproxy.sh"
	"https://cdn.jsdelivr.net/gh/DigneZzZ/tg-webproxy@main/tg-webproxy.sh"
	"https://dignezzz.github.io/server/tg-webproxy.sh"
)

MTENV="/etc/mtproxy/mtproxy.env"
ADTAG_DROPIN="/etc/systemd/system/mtproxy.service.d/adtag.conf"   # legacy, removed on sight
MT_DROPIN="/etc/systemd/system/mtproxy.service.d/tgwp.conf"      # the ONLY ExecStart override
MON_NFT="/etc/tproxy-server/tgmon.nft"
MON_UNIT="/etc/systemd/system/tgmon-counters.service"
MON_TABLE="tgmon"                       # nftables table: inet tgmon (traffic counters)
BK_SOCKET="/etc/systemd/system/tgwp-backend.socket"    # front role: loopback :2398 -> remote MTProxy
BK_SERVICE="/etc/systemd/system/tgwp-backend.service"
UP_FW_NFT="/etc/tproxy-server/firewall.nft"            # backend role: our rules, applied by upstream's tproxy-firewall.service
TG_DIR="${STATE_DIR}/tg"                                # optional local copies of core.telegram.org files (see check_telegram_reach)
TG_DCS="149.154.175.50 149.154.167.51 149.154.175.100 149.154.167.91 91.108.56.130"   # DC1..DC5; MTProxy dials :8888 there

RELAY_ADMIN="http://127.0.0.1:8081"     # /healthz /readyz /metrics

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

# ---------------------------------------------------------------- versioning
ver_gt() { [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" == "$1" ]]; }
remote_version() { # -> "version url" of the newest published copy (reads 4 KB per source)
	local u v best="" best_url=""
	for u in "${SCRIPT_URLS[@]}"; do
		v="$(curl -fsSL --max-time 4 -r 0-4095 "$u" 2>/dev/null \
			| grep -m1 -E '^TGWP_VERSION="[0-9]+(\.[0-9]+)*"' | cut -d'"' -f2 || true)"
		[[ -n "$v" ]] || continue
		if [[ -z "$best" ]] || ver_gt "$v" "$best"; then best="$v"; best_url="$u"; fi
	done
	[[ -n "$best" ]] && printf '%s %s\n' "$best" "$best_url"
}
check_self_version() { # one warning if a newer script is published; never blocks the install
	[[ "${TGWP_NO_UPDATE_CHECK:-}" == "1" ]] && return 0
	local r rv; r="$(remote_version || true)"; [[ -n "$r" ]] || return 0
	rv="${r%% *}"
	if ver_gt "$rv" "$TGWP_VERSION"; then
		warn "Вы запускаете версию $TGWP_VERSION, опубликована $rv. Лучше перезапустить установщик:"
		msg  "  bash <(wget -qO- ${SCRIPT_URLS[0]})"
	fi
	return 0
}

# ---------------------------------------------------------------- split mode helpers
tunnel_iface() { local i; for i in wt0 wg0 nb0 tun0; do ip -4 -o addr show dev "$i" 2>/dev/null | grep -q inet && { printf '%s' "$i"; return 0; }; done; return 1; }
tunnel_ip()    { local i; i="$(tunnel_iface)" || return 1; ip -4 -o addr show dev "$i" | awk '{print $4; exit}' | cut -d/ -f1; }
probe_tcp()    { timeout 3 bash -c "exec 3<>/dev/tcp/${1%:*}/${1##*:}" 2>/dev/null; }   # <ip:port>
norm_backend() { [[ "${1:-}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(:[0-9]{1,5})?$ ]] || return 1; if [[ "$1" == *:* ]]; then printf '%s' "$1"; else printf '%s:2398' "$1"; fi; }
norm_cidr_list() { # "a, b/24 c" -> "a/32, b/24, c/32" (IPv4 only) ; 1 = invalid/empty
	local x out="" i; x="$(echo "${1:-}" | tr ',' ' ' | tr -s '[:space:]' ' ')"
	for i in $x; do
		[[ "$i" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]] || return 1
		[[ "$i" == */* ]] || i="$i/32"; out+="${out:+, }$i"
	done
	[[ -n "$out" ]] && printf '%s' "$out"
}
valid_secret_list() { local i; [[ -n "${1:-}" ]] || return 1; for i in $1; do [[ "$i" =~ ^([0-9a-f]{32}|dd[0-9a-f]{32})$ ]] || return 1; done; }
set_info() { [[ -f "$INFO_FILE" ]] || return 0; sed -i "/^$1=/d" "$INFO_FILE"; printf '%s="%s"\n' "$1" "$2" >> "$INFO_FILE"; }

# front role: the relay may only talk to loopback (config validation + IPAddressAllow=localhost
# in its unit), so a socket-activated systemd-socket-proxyd sits on 127.0.0.1:2398 and
# forwards into the tunnel. The local MTProxy is parked (masked), not removed: `backend local`
# brings it back without a rebuild.
write_backend_units() { # <ip:port>
	local target="$1" proxyd="" p
	for p in /usr/lib/systemd/systemd-socket-proxyd /lib/systemd/systemd-socket-proxyd; do if [[ -x "$p" ]]; then proxyd="$p"; break; fi; done
	[[ -n "$proxyd" ]] || { err "systemd-socket-proxyd не найден (пакет systemd)."; return 1; }
	cat > "$BK_SOCKET" <<EOF
[Unit]
Description=Loopback endpoint for the remote MTProxy backend (tg-webproxy)

[Socket]
ListenStream=127.0.0.1:2398
NoDelay=true
Backlog=1024

[Install]
WantedBy=sockets.target
EOF
	cat > "$BK_SERVICE" <<EOF
[Unit]
Description=Forward loopback :2398 to the remote MTProxy backend ${target} (tg-webproxy)
Requires=tgwp-backend.socket
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=${proxyd} --connections-max=8192 --exit-idle-time=10min ${target}
PrivateTmp=yes
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
EOF
	chmod 0644 "$BK_SOCKET" "$BK_SERVICE"
	systemctl daemon-reload
}
switch_backend_remote() { # <ip:port>
	local target="$1" i
	systemctl disable --now mtproxy.service refresh-mtproxy-config.timer >/dev/null 2>&1 || true
	systemctl mask mtproxy.service >/dev/null 2>&1 || true
	write_backend_units "$target" || return 1
	systemctl enable --now tgwp-backend.socket >/dev/null 2>&1 || { err "Не удалось запустить tgwp-backend.socket"; return 1; }
	systemctl restart tproxy-server.service
	for i in 1 2 3 4 5; do probe_tcp "$target" && { ok "Backend $target отвечает через туннель."; return 0; }; sleep 1; done
	warn "Backend $target пока недоступен: поднимите MTProxy на том хосте и проверьте туннель. Панель покажет, когда заработает."
	return 0
}
switch_backend_local() {
	systemctl disable --now tgwp-backend.socket tgwp-backend.service >/dev/null 2>&1 || true
	rm -f "$BK_SOCKET" "$BK_SERVICE"; systemctl daemon-reload
	systemctl unmask mtproxy.service >/dev/null 2>&1 || true
	systemctl enable --now mtproxy.service refresh-mtproxy-config.timer >/dev/null 2>&1 || warn "MTProxy не стартовал — journalctl -u mtproxy"
	systemctl restart tproxy-server.service
}
# backend role: only the tunnel may reach MTProxy. The rules live in the file upstream's
# tproxy-firewall.service already applies (same table name), so mtproxy.service's
# Requires=tproxy-firewall.service keeps working unchanged.
write_backend_firewall() { # <"cidr, cidr">
	mkdir -p /etc/tproxy-server
	cat > "$UP_FW_NFT" <<EOF
table inet tproxy_backend {
	set allow4 { type ipv4_addr; flags interval; auto-merge; elements = { $1 } }
	chain local_backend {
		type filter hook input priority -10; policy accept;
		iifname "lo" accept
		tcp dport 2398 ip saddr @allow4 accept
		tcp dport { 2398, 8888 } drop
	}
}
EOF
	chmod 0644 "$UP_FW_NFT"
	nft -c -f "$UP_FW_NFT" >/dev/null 2>&1 || return 1
	systemctl enable tproxy-firewall.service >/dev/null 2>&1 || true
	systemctl restart tproxy-firewall.service
}
backend_upstream() { # <workers> <maxconn>  (inside run_logged): build MTProxy + install upstream units
	export PATH="${STATE_DIR}/shim:${PATH}"
	cd "$REPO_DIR" && ./deploy/install-mtproxy.sh
	install -m 0644 deploy/mtproxy.service /etc/systemd/system/mtproxy.service
	install -m 0644 deploy/tproxy-firewall.service /etc/systemd/system/tproxy-firewall.service
	install -m 0644 deploy/refresh-mtproxy-config.service /etc/systemd/system/refresh-mtproxy-config.service
	install -m 0644 deploy/refresh-mtproxy-config.timer /etc/systemd/system/refresh-mtproxy-config.timer
	install -m 0755 deploy/refresh-mtproxy-config.sh /usr/local/sbin/refresh-mtproxy-config
	install -d -o root -g root -m 0755 /etc/tproxy-server
	printf 'MTPROXY_WORKERS=%s\nMTPROXY_MAX_CONNECTIONS=%s\n' "$1" "$2" > "$MTENV"
	chown root:mtproxy "$MTENV"; chmod 0640 "$MTENV"
	systemctl daemon-reload
}

do_install_backend() {
	local PREV_SECRETS PREV_ALLOW PREV_ADTAG
	PREV_SECRETS="$(prev_field SECRETS)"; PREV_ALLOW="$(prev_field ALLOW_FROM)"; PREV_ADTAG="$(prev_field ADTAG)"
	check_telegram_reach backend
	head2 "1) Подготовка"
	: > "$LOG"; chmod 0600 "$LOG"
	run_logged "Зависимости (git, curl, nftables, vnstat)" "" install_prereqs \
		|| die "apt-get не смог установить зависимости. Журнал: $LOG"
	local PUBIP TUN_IF TUN_IP; PUBIP="$(detect_ip)"; TUN_IF="$(tunnel_iface || true)"; TUN_IP="$(tunnel_ip || true)"
	if [[ -n "$TUN_IP" ]]; then ok "Туннель $TUN_IF: MTProxy будет доступен по ${GREEN}$TUN_IP:2398${NC}"
	else warn "Интерфейс туннеля (wt0/wg0) не найден — поднимите NetBird или WireGuard, иначе front не достучится."; fi

	head2 "2) Секреты — те же, что на front"
	msg "На front их печатает ${GREEN}tgwebproxy link${NC}. Несколько — через пробел."
	local SECRETS hint
	if [[ -n "$PREV_SECRETS" ]]; then hint=" [Enter = оставить текущие]"; else hint=""; fi
	while :; do
		ask SECRETS "Секреты${hint}: " "$PREV_SECRETS" "${TGWP_SECRETS:-}" || true
		SECRETS="$(echo "$SECRETS" | tr 'A-Z,' 'a-z ' | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')"
		valid_secret_list "$SECRETS" && break
		err "Каждый секрет — 32 hex (можно с префиксом dd)."
		[[ -n "${TGWP_SECRETS:-}" ]] && exit 2
		[[ -z "$HAS_TTY" ]] && die "Нет терминала — задайте TGWP_SECRETS."
	done
	ok "Секретов: $(set -- $SECRETS; echo $#)"

	head2 "3) Кому разрешено подключаться к MTProxy"
	local ALLOW def_allow=""
	[[ -n "$TUN_IF" ]] && def_allow="$(ip -4 -o addr show dev "$TUN_IF" 2>/dev/null | awk '{print $4; exit}')"
	[[ -n "$PREV_ALLOW" ]] && def_allow="$PREV_ALLOW"
	msg "IP или CIDR через запятую: IP front-хоста в туннеле или вся подсеть туннеля."
	if [[ -n "$def_allow" ]]; then hint=" [Enter = $def_allow]"; else hint=""; fi
	while :; do
		ask ALLOW "Разрешить с${hint}: " "$def_allow" "${TGWP_ALLOW_FROM:-}" || true
		ALLOW="$(norm_cidr_list "$ALLOW")" && break
		err "Нужны IPv4-адреса или CIDR, например 100.64.0.7 или 100.64.0.0/10."
		[[ -n "${TGWP_ALLOW_FROM:-}" ]] && exit 2
		[[ -z "$HAS_TTY" ]] && die "Нет терминала — задайте TGWP_ALLOW_FROM."
	done
	ok "Разрешено с: $ALLOW"

	head2 "4) Спонсорский канал (AD_TAG, необязательно)"
	msg "Тег выдаёт @MTProxybot: /newproxy → адрес ${GREEN}<домен front>:443${NC} → секрет ${GREEN}${SECRETS%% *}${NC} → тег (32 hex)"
	local ADTAG="${TGWP_ADTAG:-$PREV_ADTAG}"
	[[ -z "${TGWP_ADTAG:-}" && -n "$ADTAG" ]] && msg "AD_TAG из прошлой установки: $ADTAG"
	if [[ -z "$ADTAG" && -n "$HAS_TTY" ]] && confirm "Указать AD_TAG сейчас?"; then
		ask ADTAG "AD_TAG (32 hex): " "" "" || true
	fi
	ADTAG="$(echo "$ADTAG" | tr 'A-Z' 'a-z' | tr -d '[:space:]')"
	if [[ -n "$ADTAG" && ! "$ADTAG" =~ ^[0-9a-f]{32}$ ]]; then warn "AD_TAG не 32 hex — пропускаю."; ADTAG=""; fi
	local WORKERS MAXCONN
	WORKERS="${TGWP_WORKERS:-1}"; MAXCONN="${TGWP_MAXCONN:-4096}"
	{ [[ "$WORKERS" =~ ^[1-9][0-9]*$ ]] && (( WORKERS <= 256 )); } || WORKERS=1
	[[ "$MAXCONN" =~ ^[1-9][0-9]*$ ]] || MAXCONN=4096

	head2 "5) Установка MTProxy"
	fetch_repo
	local REPO_REF; REPO_REF="$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
	mkdir -p "$STATE_DIR"
	cat > "$INFO_FILE" <<EOF
ROLE="backend"
SECRETS="$SECRETS"
ALLOW_FROM="$ALLOW"
TUNNEL_IF="$TUN_IF"
TUNNEL_IP="$TUN_IP"
ADTAG="$ADTAG"
WORKERS="$WORKERS"
MAXCONN="$MAXCONN"
PUBIP="$PUBIP"
REPO_DIR="$REPO_DIR"
REPO_REF="$REPO_REF"
INSTALLED_AT="$(date '+%Y-%m-%d %H:%M:%S %Z')"
EOF
	chmod 0600 "$INFO_FILE"
	install_mgmt_cli
	[[ -d /opt/MTProxy/objs ]] && { chmod -R a+rX /opt/MTProxy 2>/dev/null || true; }
	make_runuser_shim; make_curl_shim
	rm -f "$ADTAG_DROPIN" "$MT_DROPIN"; systemctl daemon-reload 2>/dev/null || true
	msg "Коммит tproxy-server: ${GREEN}$REPO_REF${NC}. Сборка MTProxy занимает пару минут; полный вывод: $LOG"
	run_logged "Сборка MTProxy" install_phase backend_upstream "$WORKERS" "$MAXCONN" || { report_install_failure; exit 1; }
	write_backend_firewall "$ALLOW" || die "Правила nftables не прошли проверку (nft -c -f $UP_FW_NFT)."
	systemctl enable --now refresh-mtproxy-config.timer >/dev/null 2>&1 || true
	head2 "6) Секреты${ADTAG:+ + AD_TAG}"
	sync_mtproxy "$ADTAG" "$PUBIP" "$SECRETS" || ADTAG=""
	systemctl enable mtproxy.service >/dev/null 2>&1 || true
	verify_mtproxy_secrets "$SECRETS"
	ok "Утилита управления установлена: ${GREEN}tgwebproxy${NC}"
	print_result_backend "$TUN_IP" "$ALLOW" "$SECRETS" "$ADTAG"
}
print_result_backend() { # <tunnel_ip> <allow> <secrets> <adtag>
	head2 "🎉 Backend готов: MTProxy слушает ${1:-<IP туннеля>}:2398"
	echo -e "  Разрешено с: ${GREEN}$2${NC}"
	echo -e "  Секретов: ${GREEN}$(set -- $3; echo $#)${NC}${4:+  ·  AD_TAG задан}"
	echo
	msg "На front-хосте: ${GREEN}tgwebproxy backend set ${1:-<IP туннеля>}:2398${NC}"
	msg "или при установке front: роль front, backend ${1:-<IP туннеля>}:2398."
	msg "Сменили тип подключения на front (tgwebproxy mode)? Здесь: ${GREEN}tgwebproxy secrets set '<секреты>'${NC}"
	echo
	echo -e "${BLUE}${BOLD}Управление:${NC} ${GREEN}tgwebproxy${NC} — меню; или status | secrets | allow | adtag | update | self-update | uninstall"
}

# ---------------------------------------------------------------- logged steps
# Long/noisy commands (apt, make, go, upstream installer) write to $LOG; the
# terminal gets ONE live line: spinner, step label, detected phase, elapsed.
RUN_STDIN=""   # fed to the wrapped command's stdin (secrets never touch argv)
run_logged() { # <label> <phase-fn|""> <cmd...>
	local label="$1" phasefn="$2"; shift 2
	local start=$SECONDS rc=0 pid="" i=0 ph="" p frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
	printf '\n=== %s (%s) ===\n' "$label" "$(date '+%F %T')" >> "$LOG"
	if [[ -n "$HAS_TTY" ]]; then
		( "$@" ) <<< "$RUN_STDIN" >> "$LOG" 2>&1 &
		pid=$!
		# background jobs ignore SIGINT without job control: forward Ctrl-C ourselves
		trap 'kill "$pid" 2>/dev/null; pkill -TERM -P "$pid" 2>/dev/null; printf "\n"; exit 130' INT TERM
		while kill -0 "$pid" 2>/dev/null; do
			if [[ -n "$phasefn" ]]; then p="$("$phasefn")"; [[ -n "$p" ]] && ph="$p"; fi
			printf '\r\033[K%s %s%s %s(%ds)%s' "${frames:i%10:1}" "$label" "${ph:+: $ph}" "$DIM" "$((SECONDS - start))" "$NC"
			i=$((i + 1)); sleep 0.5
		done
		wait "$pid" || rc=$?
		trap - INT TERM
		printf '\r\033[K'
	else
		( "$@" ) <<< "$RUN_STDIN" >> "$LOG" 2>&1 || rc=$?
	fi
	if [[ $rc -eq 0 ]]; then ok "$label — $((SECONDS - start))s"
	else err "$label — ошибка (код $rc) через $((SECONDS - start))s"; fi
	return $rc
}

install_phase() { # last log line -> human phase ("" = keep the previous one)
	local l; l="$(tail -n 1 "$LOG" 2>/dev/null || true)"
	case "$l" in
		Installed\ for*)                          echo "готово" ;;
		make:*|cc\ *|ar\ rcs*|rm\ -f\ objs*)      echo "сборка MTProxy (C)" ;;
		go:\ *|ok\ *|"?"*|---\ FAIL*|FAIL*|PASS*) echo "тесты и сборка relay (Go)" ;;
		Get:*|Hit:*|Ign:*|Unpacking*|Setting\ up*|Preparing*|Selecting*|Reading*|Building\ dep*|Processing\ trig*|Fetched*|Extracting*|\(Reading*|Solving*|Need\ to\ get*|After\ this*|The\ following*|[0-9]*\ upgraded*)
			echo "пакеты apt" ;;
		*) echo "" ;;
	esac
}

# upstream install-mtproxy.sh builds MTProxy with `runuser -u mtproxy -- make`
# while install.sh holds umask 077. runuser keeps that umask, so objs/ comes out
# 0700; after upstream's `chown -R root:root` the mtproxy service user cannot
# even traverse objs/ -> systemd "203/EXEC" on every fresh install, and a
# re-install keeps the bad binary (root sees it as executable, build skipped).
# A PATH shim resets the umask for that build only; upstream files stay intact.
make_runuser_shim() {
	local real; real="$(command -v runuser 2>/dev/null || true)"
	[[ -n "$real" && "$real" != "$STATE_DIR/shim/runuser" ]] || return 0
	mkdir -p "$STATE_DIR/shim"
	printf '#!/usr/bin/env bash\n# tg-webproxy.sh shim: build MTProxy with a sane umask (see make_runuser_shim)\numask 022\nexec %q "$@"\n' \
		"$real" > "$STATE_DIR/shim/runuser"
	chmod 0755 "$STATE_DIR/shim/runuser"
}
# Runs FIRST, before any question or package: a host that cannot reach Telegram is
# the wrong host, and the operator should hear that immediately, not after a build.
# MTProxy dials the DC middle-proxies on :8888 (see getProxyConfig) and the
# installer needs proxy-secret + the DC list from core.telegram.org. Networks that
# block the domain (a 404 stub from a filter is the usual symptom) get two escape
# hatches for the files: local copies in $TG_DIR, or a mirror URL, served to
# upstream's script by a curl PATH shim. Nothing can substitute unreachable DCs.
probe_fast() { timeout 2 bash -c "exec 3<>/dev/tcp/${1%:*}/${1##*:}" 2>/dev/null; }
check_telegram_reach() { # <role>
	local role="${1:-single}" ip code ok8=0 ok443=0 total
	[[ "$role" == front ]] && return 0          # the front never talks to Telegram itself
	if [[ "${TGWP_SKIP_REACH:-}" == "1" ]]; then warn "Проверка доступности Telegram пропущена (TGWP_SKIP_REACH=1)."; return 0; fi
	head2 "Доступность Telegram с этого сервера"
	mkdir -p "$TG_DIR"
	total="$(set -- $TG_DCS; echo $#)"
	for ip in $TG_DCS; do probe_fast "$ip:8888" && ok8=$((ok8 + 1)); done
	for ip in ${TG_DCS%% *} ${TG_DCS#* }; do probe_fast "${ip%% *}:443" && ok443=$((ok443 + 1)); break; done
	code="$(curl -sS -o /dev/null --max-time 10 -w '%{http_code}' https://core.telegram.org/getProxySecret 2>/dev/null || echo 000)"
	if (( ok8 == 0 )); then
		err "Этот сервер не подходит: дата-центры Telegram недоступны — ни один из $total адресов не отвечает на :8888${ok443:+, :443 $( (( ok443 > 0 )) && echo отвечает || echo тоже молчит)}."
		err "MTProxy здесь работать не будет. Возьмите сервер в другой стране или сети (обычно так выглядит хостинг в РФ)."
		msg "Проверить вручную: ${GREEN}timeout 3 bash -c '</dev/tcp/149.154.175.50/8888' && echo ok${NC}"
		msg "Хост без доступа к Telegram годится только на роль front в split-режиме (MTProxy на другом сервере)."
		exit 3
	fi
	ok "Дата-центры Telegram доступны ($ok8 из $total на :8888)"
	if [[ "$code" == 200 ]]; then ok "core.telegram.org доступен (proxy-secret, конфигурация DC)"
	elif [[ -s "$TG_DIR/proxy-secret" && -s "$TG_DIR/proxy-multi.conf" ]]; then
		warn "core.telegram.org отвечает $code — беру локальные копии из $TG_DIR."
	elif [[ -n "${TGWP_TG_MIRROR:-}" ]]; then
		warn "core.telegram.org отвечает $code — файлы будут взяты с зеркала ${TGWP_TG_MIRROR}."
	else
		err "core.telegram.org недоступен с этого сервера (HTTP $code): установщик не получит proxy-secret и список дата-центров."
		msg "Проще взять сервер в другой сети. Если всё же здесь — скачайте на любой машине с доступом и положите на сервер:"
		msg "  curl -o proxy-secret https://core.telegram.org/getProxySecret"
		msg "  curl -o proxy-multi.conf https://core.telegram.org/getProxyConfig"
		msg "  scp proxy-secret proxy-multi.conf root@<сервер>:$TG_DIR/"
		msg "или укажите зеркало с этими двумя файлами: TGWP_TG_MIRROR=https://host/path"
		die "Без этих файлов установка невозможна — повторите после копирования."
	fi
}
make_curl_shim() {
	local real; real="$(command -v curl 2>/dev/null || true)"
	[[ -n "$real" && "$real" != "$STATE_DIR/shim/curl" ]] || return 0
	mkdir -p "$STATE_DIR/shim"
	{
		printf '#!/usr/bin/env bash\n# tg-webproxy.sh shim: serve core.telegram.org files from local copies or a mirror\n# when the network blocks the domain; every other URL goes to the real curl.\n'
		printf 'REAL=%q; LOCAL=%q; MIRROR=%q\n' "$real" "$TG_DIR" "${TGWP_TG_MIRROR:-}"
		cat <<'EOF'
url=""; out=""; args=("$@"); n=${#args[@]}
for ((i = 0; i < n; i++)); do
	case "${args[i]}" in
		-o|--output) out="${args[i+1]:-}" ;;
		https://core.telegram.org/*) url="${args[i]}" ;;
	esac
done
if [[ -n "$url" ]]; then
	name="${url##*/}"; f=""
	case "$name" in getProxySecret) f="$LOCAL/proxy-secret" ;; getProxyConfig) f="$LOCAL/proxy-multi.conf" ;; esac
	if [[ -n "$f" && -s "$f" ]]; then
		if [[ -n "$out" ]]; then cp "$f" "$out"; else cat "$f"; fi
		exit 0
	fi
	if [[ -n "$MIRROR" ]]; then
		for ((i = 0; i < n; i++)); do [[ "${args[i]}" == "$url" ]] && args[i]="${MIRROR%/}/$name"; done
	fi
fi
exec "$REAL" "${args[@]}"
EOF
	} > "$STATE_DIR/shim/curl"
	chmod 0755 "$STATE_DIR/shim/curl"
}
mtproxy_exec_failed() { # did mtproxy.service die with 203/EXEC?
	systemctl is-failed --quiet mtproxy.service 2>/dev/null \
		&& journalctl -u mtproxy.service -n 30 --no-pager 2>/dev/null | grep -q '203/EXEC'
}
repair_mtproxy_exec() { # fix the 0700 objs/ tree, restart MTProxy, wait for the relay to see it
	[[ -f /opt/MTProxy/objs/bin/mtproto-proxy ]] || return 1
	chmod -R a+rX /opt/MTProxy 2>/dev/null || true
	systemctl reset-failed mtproxy.service 2>/dev/null || true
	systemctl restart mtproxy.service 2>/dev/null || return 1
	local i; for i in 1 2 3 4 5 6 7 8 9 10; do
		curl -fsS --max-time 2 "$RELAY_ADMIN/readyz" >/dev/null 2>&1 && return 0; sleep 1
	done
	return 1
}

upstream_install() { # <host> <email> <workers> <maxconn> [--site-dir DIR]
	local h="$1" e="$2" w="$3" c="$4"; shift 4
	export PATH="${STATE_DIR}/shim:${PATH}"     # runuser shim, see make_runuser_shim
	cd "$REPO_DIR" && ./deploy/install.sh --hostname "$h" --email "$e" "$@" \
		--mtproxy-workers "$w" --mtproxy-max-connections "$c"
}

report_install_failure() {
	err "Официальный установщик завершился с ошибкой. Полный журнал: $LOG"
	if grep -q -- '--- FAIL' "$LOG"; then
		msg "Причина: упали unit-тесты апстрима (go test ./...):"
		grep -E -- '--- FAIL|_test\.go:[0-9]+:' "$LOG" | tail -n 6 | sed 's/^/    /'
	elif journalctl -u mtproxy.service -n 30 --no-pager 2>/dev/null | grep -q '203/EXEC'; then
		msg "Причина: systemd не может запустить /opt/MTProxy/objs/bin/mtproto-proxy от пользователя mtproxy (203/EXEC — нет прав)."
		msg "Исправление: chmod -R a+rX /opt/MTProxy && systemctl restart mtproxy && curl -fsS $RELAY_ADMIN/readyz"
	elif grep -q 'curl: (22)' "$LOG" && ! grep -q 'go: downloading' "$LOG"; then
		msg "Причина: не скачались proxy-secret / конфигурация DC с core.telegram.org (сеть сервера блокирует домен):"
		grep 'curl: (22)' "$LOG" | tail -n 2 | sed 's/^/    /'
		msg "Положите файлы в $TG_DIR (см. подсказку шага «Подготовка	) или задайте TGWP_TG_MIRROR, затем повторите."
	elif grep -q 'did not become ready' "$LOG"; then
		msg "Причина: relay не ответил на /readyz — не поднялся tproxy-server или MTProxy:"
		journalctl -u tproxy-server -u mtproxy --no-pager -n 12 2>/dev/null | sed 's/^/    /' || true
	elif grep -qE '^E: |dpkg: error|Could not resolve|Failed to fetch' "$LOG"; then
		msg "Причина: apt/сеть:"
		grep -E '^E: |dpkg: error|Could not resolve|Failed to fetch' "$LOG" | tail -n 5 | sed 's/^/    /'
	else
		msg "Последние строки журнала:"; tail -n 12 "$LOG" | sed 's/^/    /'
	fi
	local s st=""
	for s in caddy mtproxy tproxy-server; do st+="${st:+   }$s=$(systemctl is-active "$s" 2>/dev/null || true)"; done
	msg "Службы: $st"
	msg "Удалить частичную установку: ${GREEN}tgwebproxy uninstall${NC}"
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
	head2 "🚀 Telegram WEB Proxy v$TGWP_VERSION — установка (tproxy-server + MTProxy + Caddy)"
	require_root_arch
	probe_tty
	check_self_version

	# Everything a previous install recorded becomes the Enter-default below.
	local PREV_SECRET PREV_ADTAG PREV_HOST PREV_EMAIL PREV_MODE PREV_ROLE
	PREV_SECRET="$(prev_field SECRET)"; PREV_ADTAG="$(prev_field ADTAG)"
	PREV_HOST="$(prev_field HOSTNAME)"; PREV_EMAIL="$(prev_field EMAIL)"; PREV_MODE="$(prev_field MODE)"; PREV_ROLE="$(prev_field ROLE)"

	if [[ -f "$INFO_FILE" ]]; then
		warn "Похоже, уже установлен: роль ${PREV_ROLE:-single}${PREV_HOST:+, $PREV_HOST}, режим ${PREV_MODE:-https}, от $(prev_field INSTALLED_AT)."
		msg  "Прошлые значения подставлены по умолчанию (Enter = оставить). Переустановка перезапишет"
		msg  "config/Caddyfile, сайт в /srv/tproxy-site сохранится."
		confirm "Продолжить переустановку?" || { msg "Отменено. Управление: ${GREEN}tgwebproxy${NC}"; exit 1; }
	fi

	# --- role -----------------------------------------------------------
	head2 "0) Роль этого хоста"
	msg "single — всё на одном хосте (по умолчанию)  ·  front — Caddy + relay, MTProxy на другом хосте  ·  backend — только MTProxy"
	local ROLE
	ask ROLE "Роль [single/front/backend] (Enter = ${PREV_ROLE:-single}): " "${PREV_ROLE:-single}" "${TGWP_ROLE:-}" || true
	ROLE="$(echo "$ROLE" | tr 'A-Z' 'a-z' | tr -d '[:space:]')"
	case "$ROLE" in single|front|backend) ;; "") ROLE=single ;; *) warn "Неизвестная роль '$ROLE' — использую single."; ROLE=single ;; esac
	if [[ "$ROLE" == backend ]]; then do_install_backend; return 0; fi
	ok "Роль: $ROLE"
	check_telegram_reach "$ROLE"
	local BACKEND="" TUN_IP=""
	if [[ "$ROLE" == front ]]; then
		TUN_IP="$(tunnel_ip || true)"
		if [[ -n "$TUN_IP" ]]; then msg "IP этого хоста в туннеле: ${GREEN}$TUN_IP${NC} — его нужно разрешить на backend."
		else warn "Интерфейс туннеля (wt0/wg0) не найден — поднимите NetBird или WireGuard до backend."; fi
		local PREV_BK; PREV_BK="$(prev_field BACKEND)"
		while :; do
			ask BACKEND "MTProxy-хост в туннеле, ip[:port]${PREV_BK:+ [Enter = $PREV_BK]}: " "$PREV_BK" "${TGWP_BACKEND:-}" || true
			BACKEND="$(norm_backend "$BACKEND")" && break
			err "Нужен IPv4-адрес и порт, например 100.64.0.5:2398."
			[[ -n "${TGWP_BACKEND:-}" ]] && exit 2
			[[ -z "$HAS_TTY" ]] && die "Нет терминала — задайте TGWP_BACKEND."
		done
		ok "Backend: $BACKEND"
	fi

	# --- prereqs + public IP: needed to validate the domain right away --
	head2 "1) Подготовка"
	: > "$LOG"; chmod 0600 "$LOG"
	run_logged "Зависимости (git, curl, nftables, vnstat)" "" install_prereqs \
		|| die "apt-get не смог установить зависимости. Журнал: $LOG"
	local PUBIP; PUBIP="$(detect_ip)"
	if [[ -n "$PUBIP" ]]; then msg "Внешний IPv4 этого сервера: ${GREEN}$PUBIP${NC}"
	else warn "Не удалось определить внешний IPv4 — сверить A-запись автоматически не получится."; fi
	check_ports

	# --- inputs ---------------------------------------------------------
	head2 "2) Домен и почта"
	msg "Нужен отдельный домен с A-записью → ${PUBIP:-IP этого сервера}; он остаётся обычным сайтом."
	local HOSTNAME EMAIL hint
	if [[ -n "$PREV_HOST" ]]; then hint=" [Enter = $PREV_HOST]"; else hint=" (например proxy.example.com)"; fi
	while :; do
		ask HOSTNAME "Домен${hint}: " "$PREV_HOST" "${TGWP_HOSTNAME:-}" || true
		HOSTNAME="$(echo "$HOSTNAME" | tr 'A-Z' 'a-z' | tr -d '[:space:]')"
		if [[ "$HOSTNAME" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ && "$HOSTNAME" == *.* ]]; then
			check_dns "$HOSTNAME" "$PUBIP" && break      # A record matches (or accepted)
		else
			err "Некорректный домен. Только строчные ASCII, с точкой (домен, а не IP)."
		fi
		[[ -n "${TGWP_HOSTNAME:-}" ]] && exit 2
		[[ -z "$HAS_TTY" ]] && die "Нет терминала — задайте корректную переменную TGWP_HOSTNAME."
	done
	while :; do
		ask EMAIL "E-mail для Let's Encrypt (ACME)${PREV_EMAIL:+ [Enter = $PREV_EMAIL]}: " \
			"$PREV_EMAIL" "${TGWP_EMAIL:-}" || true
		[[ "$EMAIL" =~ ^[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] && break
		err "Нужен корректный e-mail."
		[[ -n "${TGWP_EMAIL:-}" ]] && exit 2
		[[ -z "$HAS_TTY" ]] && die "Нет терминала — задайте переменную TGWP_EMAIL."
	done

	# --- secret ---------------------------------------------------------
	head2 "3) Секрет подключения"
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

	# --- carrier mode ---------------------------------------------------
	head2 "4) Тип подключения (carrier mode)"
	msg "Транспорт выбирается НА СЕРВЕРЕ и привязан к секрету — клиент ничего не настраивает."
	echo -e "  ${BOLD}https${NC}          — один POST + один long-poll. Консервативный дефолт."
	echo -e "  ${BOLD}https-lanes${NC}    — отдельная пара запросов на каждый поток. Ниже задержки, нужен HTTP/2."
	echo -e "  ${BOLD}websocket${NC}      — один WebSocket на все потоки. Быстрее всего, общий TCP-затор."
	echo -e "  ${BOLD}websocket-lanes${NC}— отдельный WebSocket на поток. Медиа не блокирует чат, больше соединений."
	echo -e "  ${BOLD}all${NC}            — создать все четыре сразу (4 секрета, 4 ссылки — выбор на стороне юзера)."
	local MODE
	ask MODE "Режим [https/https-lanes/websocket/websocket-lanes/all] (Enter = ${PREV_MODE:-https}): " \
		"${PREV_MODE:-https}" "${TGWP_MODE:-}" || true
	MODE="$(echo "$MODE" | tr 'A-Z' 'a-z' | tr -d '[:space:]')"
	case "$MODE" in
		https|https-lanes|websocket|websocket-lanes|all) ;;
		"") MODE="https" ;;
		*) warn "Неизвестный режим '$MODE' — использую https."; MODE="https" ;;
	esac
	ok "Режим: $MODE"

	# --- ad tag ---------------------------------------------------------
	head2 "5) Спонсорский канал (AD_TAG, необязательно)"
	msg "Тег выдаёт @MTProxybot; работающий прокси для регистрации не нужен:"
	echo -e "  /newproxy → адрес ${GREEN}${HOSTNAME}:443${NC} → секрет ${GREEN}${SECRET#dd}${NC} → бот вернёт тег (32 hex)"
	warn "Для WEB-прокси показ спонсорского канала не гарантирован (подробности: tgwebproxy adtag)."
	local ADTAG="${TGWP_ADTAG:-$PREV_ADTAG}"
	[[ -z "${TGWP_ADTAG:-}" && -n "$ADTAG" ]] && msg "AD_TAG из прошлой установки: $ADTAG (сменить/убрать потом: tgwebproxy adtag)"
	if [[ "$ROLE" == front ]]; then msg "AD_TAG задаётся на backend-хосте, где работает MTProxy."; ADTAG=""
	elif [[ -z "$ADTAG" && -n "$HAS_TTY" ]]; then
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

	# --- cover website --------------------------------------------------
	head2 "6) Сайт-прикрытие"
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
		# Upstream deliberately ships no starter site: any widely reused template
		# is itself an active-probe signature. Ask for a real one first.
		msg "Лучшая маскировка — ваш настоящий сайт; сгенерированная заглушка — запасной вариант."
		local ownsite=""
		ask ownsite "Путь к каталогу вашего сайта (Enter — сгенерировать заглушку): " "" "" || true
		if [[ -n "$ownsite" ]]; then
			local od; od="$(cd "$ownsite" 2>/dev/null && pwd -P)" || die "Каталог не найден: $ownsite"
			[[ -f "$od/index.html" ]] || die "В каталоге нет index.html: $od"
			SITE_ARG=(--site-dir "$od"); ok "Использую ваш сайт: $od"
		else
			mkdir -p "$SITE_STAGE"
			generate_site "$SITE_STAGE" "$HOSTNAME"
			SITE_ARG=(--site-dir "$SITE_STAGE")
			ok "Сгенерирована уникальная заглушка (5 страниц, рандомизирована под этот сервер)."
			msg "Для серьёзной маскировки замените её настоящим сайтом: /srv/tproxy-site + systemctl restart tproxy-server"
		fi
	fi

	# --- fetch upstream repo, persist metadata + CLI, run the installer ---
	#     (info.env and the CLI go in BEFORE the build so `tgwebproxy
	#     uninstall` works even if the installer fails partway)
	head2 "7) Установка (tproxy-server + MTProxy + Caddy)"
	fetch_repo
	local REPO_REF; REPO_REF="$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
	write_info "$HOSTNAME" "$SECRET" "$EMAIL" "$ADTAG" "$WORKERS" "$MAXCONN" "$PUBIP" "$REPO_REF"
	set_info ROLE "$ROLE"; set_info BACKEND "$BACKEND"; set_info TUNNEL_IP "$TUN_IP"
	append_profiles_info "$MODE" "https:$SECRET"
	install_mgmt_cli

	# Remove BOTH our drop-ins first: upstream rewrites mtproxy.env with only
	# MTPROXY_SECRET and restarts mtproxy. A drop-in still referencing
	# ${MTPROXY_SECRET2..}/${MTPROXY_TAG} would expand them to "" (systemd treats
	# unknown ${VAR} as empty) and MTProxy exits on -S "" -> readyz never comes up
	# -> upstream install fails. sync_mtproxy rewrites the drop-in afterwards.
	if [[ -f "$ADTAG_DROPIN" || -f "$MT_DROPIN" ]]; then
		rm -f "$ADTAG_DROPIN" "$MT_DROPIN"; systemctl daemon-reload 2>/dev/null || true
	fi
	msg "Коммит tproxy-server: ${GREEN}$REPO_REF${NC}. Сборка Go и MTProxy занимает несколько минут; полный вывод: $LOG"
	# GOFLAGS: upstream install.sh runs `go test ./...` under its own umask 077,
	# which turns the 0444 fixture of TestLoadAcceptsSystemdCredentialReadPermissions
	# into 0400, so that single test fails on EVERY fresh install (tproxy-server
	# 52a5feb, 2026-08-24). Skip exactly that test; go build ignores unknown flags.
	export GOFLAGS='-skip=TestLoadAcceptsSystemdCredentialReadPermissions'
	# Re-install: a binary built by an earlier run may still be 0700 root (see make_runuser_shim)
	[[ -d /opt/MTProxy/objs ]] && { chmod -R a+rX /opt/MTProxy 2>/dev/null || true; }
	make_runuser_shim; make_curl_shim
	RUN_STDIN="$SECRET"     # the secret goes in via stdin: never in argv / ps
	if ! run_logged "Сборка и установка" install_phase \
			upstream_install "$HOSTNAME" "$EMAIL" "$WORKERS" "$MAXCONN" "${SITE_ARG[@]}"; then
		RUN_STDIN=""; unset GOFLAGS
		if mtproxy_exec_failed && repair_mtproxy_exec; then
			warn "MTProxy был собран без прав на исполнение для пользователя mtproxy (203/EXEC, баг апстрима) —"
			warn "права исправлены, служба перезапущена, relay готов. Продолжаю установку."
		else
			report_install_failure
			exit 1
		fi
	fi
	RUN_STDIN=""; unset GOFLAGS

	# --- harden Caddy's always-on error logger (capability leak) --------
	harden_caddy_log "$HOSTNAME" "$EMAIL" || true

	# --- carrier mode / profiles ----------------------------------------
	PROFILE_LIST="https:$SECRET"
	if [[ "$MODE" != "https" ]]; then
		head2 "8) Применение типа подключения ($MODE)"
		if configure_modes "$SECRET" "$MODE"; then
			ok "Профили применены: ${PROFILE_LIST// /, }"
		else
			warn "Откат на режим https."
			MODE="https"
		fi
	fi
	append_profiles_info "$MODE" "$PROFILE_LIST"

	# --- MTProxy secrets (+ optional AD_TAG) ----------------------------
	# Must run for EVERY install: MTProxy has to know every client secret,
	# and upstream install.sh has just rewritten mtproxy.env from scratch.
	head2 "9) Синхронизация MTProxy (секреты${ADTAG:+ + AD_TAG})"
	sync_mtproxy "$ADTAG" "$PUBIP" "$PROFILE_LIST" || ADTAG=""
	systemctl restart tproxy-server.service
	verify_mtproxy_secrets "$PROFILE_LIST"

	# --- monitoring counters (persistent across reboots) ---------------
	install_monitor || warn "Не удалось настроить счётчики nftables (мониторинг трафика частично недоступен)."
	if [[ "$ROLE" == front ]]; then
		head2 "10) Backend: relay → $BACKEND через туннель"
		switch_backend_remote "$BACKEND" || die "Не удалось настроить проброс к backend."
	fi

	ok "Утилита управления установлена: ${GREEN}tgwebproxy${NC}"
	print_result "$HOSTNAME" "$SECRET" "$ADTAG" "$PROFILE_LIST" "$ROLE" "$BACKEND" "$TUN_IP"
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

check_dns() { # <hostname> <pubip>  -> 0 = A record matches (or accepted), 1 = ask for another domain
	local host="$1" pubip="$2" ips=""
	ips="$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u | paste -sd, - || true)"
	if [[ -z "$ips" ]]; then
		warn "Домен $host не резолвится. Нужна A-запись: ${BOLD}$host → ${pubip:-<IP сервера>}${NC}"
		msg  "Без неё Let's Encrypt не выдаст сертификат (можно добавить запись позже и продолжить)."
		confirm "Продолжить с этим доменом всё равно?" && return 0
		return 1
	fi
	if [[ -z "$pubip" ]]; then
		warn "A-запись $host → $ips; внешний IP сервера определить не удалось, сверьте вручную."
		confirm "Это адрес ЭТОГО сервера?" && return 0
		return 1
	fi
	if [[ ",$ips," == *",$pubip,"* ]]; then
		ok "DNS: $host → $ips (совпадает с IP сервера)"
		return 0
	fi
	warn "A-запись $host → ${RED}$ips${NC}, а этот сервер — ${GREEN}$pubip${NC}: домен привязан к другому адресу."
	# A CDN in front is structurally incompatible: the relay accepts
	# X-Forwarded-For only when it parses as EXACTLY ONE address, the CDN
	# terminates TLS and therefore sees the capability and bearer tokens in
	# cleartext, and since 2025-06-09 major RU carriers throttle
	# Cloudflare-proxied traffic to the first ~16 KB.
	local hdrs=""
	hdrs="$(curl -sSI --max-time 8 "https://$host/" 2>/dev/null \
		| grep -iE 'cf-ray|cf-cache|x-cache|x-served-by|^via:|fastly|akamai' || true)"
	if [[ -n "$hdrs" ]]; then
		err "Перед доменом стоит CDN/обратный прокси (терминирует TLS, ломает X-Forwarded-For, режется операторами РФ):"
		echo "$hdrs" | sed 's/^/    /'
		msg "Отключите проксирование (серое облако в Cloudflare) или введите другой домен."
		return 1
	fi
	msg "Исправьте A-запись на $pubip или введите другой домен."
	confirm "Продолжить с этим доменом всё равно?" && return 0
	return 1
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
	[[ -z "$ref" || "$ref" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] \
		|| die "TGWP_REF должен быть коммитом/тегом/веткой (без ведущего '-')."
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

append_profiles_info() { # <mode> <profile_list>
	[[ -f "$INFO_FILE" ]] || return 0
	sed -i '/^MODE=/d; /^PROFILES=/d' "$INFO_FILE"
	printf 'MODE="%s"\nPROFILES="%s"\n' "$1" "$2" >> "$INFO_FILE"
}

# ---------------------------------------------------------------- carrier modes
# Rewrites /etc/tproxy-server/profiles.json when a non-default carrier mode (or
# all four at once) was requested. Several profiles MAY share one MTProxy
# backend: config validation (internal/config/config.go) requires a unique
# profile NAME and a unique capability (derived from hostname+secret) — it does
# NOT require a unique backend. A separate MTProxy listener is only needed when
# profiles need separate quotas or routing.
PROFILE_LIST=""      # "mode:secret mode:secret ..." — filled by configure_modes
configure_modes() {  # <secret> <mode>
	local secret="$1" mode="$2"
	local pf="/etc/tproxy-server/profiles.json"
	PROFILE_LIST="https:$secret"
	[[ "$mode" == "https" ]] && return 0     # upstream already wrote exactly this

	local json="" first=1 m s
	if [[ "$mode" == "all" ]]; then
		PROFILE_LIST=""
		for m in https https-lanes websocket websocket-lanes; do
			if [[ "$m" == "https" ]]; then s="$secret"; else s="$(gen_secret)"; fi
			PROFILE_LIST+="${PROFILE_LIST:+ }${m}:${s}"
			[[ $first -eq 1 ]] || json+=","
			first=0
			json+="{\"name\":\"${m}\",\"secret\":\"${s}\",\"backend\":\"127.0.0.1:2398\",\"carrier_mode\":\"${m}\"}"
		done
	else
		PROFILE_LIST="${mode}:${secret}"
		json="{\"name\":\"default\",\"secret\":\"${secret}\",\"backend\":\"127.0.0.1:2398\",\"carrier_mode\":\"${mode}\"}"
	fi

	printf '{"profiles":[%s]}\n' "$json" > "$pf"
	chown root:tproxy "$pf" 2>/dev/null || true
	chmod 0400 "$pf"

	if ! /usr/local/bin/tproxy-server -config /etc/tproxy-server/config.json \
			-profiles-file "$pf" -check >/dev/null 2>&1; then
		err "Конфигурация профилей не прошла проверку — откатываю на один https-профиль."
		printf '{"profiles":[{"name":"default","secret":"%s","backend":"127.0.0.1:2398"}]}\n' "$secret" > "$pf"
		chown root:tproxy "$pf" 2>/dev/null || true
		chmod 0400 "$pf"
		PROFILE_LIST="https:$secret"
		return 1
	fi
	return 0
}

# ---------------------------------------------------------------- MTProxy config
# CRITICAL: the client-facing secret IS the MTProxy secret (README: "The secret
# is the same client-facing MTProxy secret configured in the corresponding
# server profile"). The relay never decrypts the stream, so MTProxy must be
# started with EVERY secret the relay serves — otherwise those clients pass the
# bridge, open a session, and die at the obfuscated handshake with no
# diagnostics (/readyz only opens a bare TCP connection, so it still says ready).
#
# systemd does NOT word-split "${VAR}", so several secrets need several env
# variables. Everything lives in ONE drop-in: two drop-ins each doing an
# "ExecStart=" reset would clobber each other in alphabetical order.
compute_natinfo() { # <pubip> -> " --nat-info priv:pub" or empty
	local pubip="$1" localip
	localip="$(ip -4 route get 8.8.8.8 2>/dev/null \
		| awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
	[[ -n "$pubip" && -n "$localip" && "$localip" != "$pubip" ]] \
		&& printf ' --nat-info %s:%s' "$localip" "$pubip"
	return 0
}

# Post-condition: MTProxy must carry exactly one -S per served profile,
# otherwise some links silently fail at the obfuscated handshake.
verify_mtproxy_secrets() { # <profile_list>
	local want got
	want="$(set -- $1; echo $#)"
	got="$(systemctl show -p ExecStart mtproxy.service 2>/dev/null \
		| tr ' ' '\n' | grep -c -- '^-S$' || true)"
	if [[ "$got" != "$want" ]]; then
		warn "MTProxy принял $got секрет(ов), а профилей $want — часть ссылок может не подключаться."
		msg  "Проверьте: systemctl show -p ExecStart mtproxy.service"
	elif systemctl is-active --quiet mtproxy.service; then
		ok "MTProxy запущен и принял $got секрет(ов)."
	else
		warn "MTProxy сконфигурирован на $got секрет(ов), но служба не активна — journalctl -u mtproxy -n 50"
	fi
}

secrets_of() { # <profile_list "mode:secret ...">  -> "secret secret ..."
	local p out=""
	for p in $1; do out+="${out:+ }${p#*:}"; done
	printf '%s' "$out"
}

write_mtproxy_config() { # <adtag|""> <natinfo|""> <secret...>
	local tag="$1" natinfo="$2"; shift 2
	local i=0 s bs sflags="" tagflag=""

	sed -i '/^MTPROXY_SECRET[0-9]*=/d; /^MTPROXY_TAG=/d' "$MTENV" 2>/dev/null || true
	for s in "$@"; do
		i=$((i + 1)); bs="$s"
		# mirror install.sh: the dd transport marker is client-side only
		[[ "$bs" == dd* && ${#bs} -eq 34 ]] && bs="${bs:2}"
		if [[ $i -eq 1 ]]; then
			printf 'MTPROXY_SECRET=%s\n' "$bs" >> "$MTENV"
			sflags+=' -S ${MTPROXY_SECRET}'
		else
			printf 'MTPROXY_SECRET%d=%s\n' "$i" "$bs" >> "$MTENV"
			sflags+=" -S \${MTPROXY_SECRET${i}}"
		fi
	done
	if [[ -n "$tag" ]]; then
		printf 'MTPROXY_TAG=%s\n' "$tag" >> "$MTENV"
		tagflag=' -P ${MTPROXY_TAG}'
	fi
	chown root:mtproxy "$MTENV" 2>/dev/null || true
	chmod 0640 "$MTENV"

	mkdir -p /etc/systemd/system/mtproxy.service.d
	rm -f "$ADTAG_DROPIN"          # retire the old single-purpose drop-in
	cat > "$MT_DROPIN" <<EOF
[Service]
ExecStart=
ExecStart=/opt/MTProxy/objs/bin/mtproto-proxy -u mtproxy -p 8888 -H 2398${sflags}${tagflag}${natinfo} --aes-pwd /etc/mtproxy/proxy-secret /etc/mtproxy/proxy-multi.conf -M \${MTPROXY_WORKERS} -C \${MTPROXY_MAX_CONNECTIONS}
EOF
	systemctl daemon-reload
}

# Apply secrets (+ optional ad tag) to MTProxy and restart it.
# Falls back to secrets-only if MTProxy refuses to start with the tag.
sync_mtproxy() { # <adtag|""> <pubip> <profile_list>
	local tag="$1" pubip="$2" plist="$3" natinfo=""
	local -a secrets; read -r -a secrets <<< "$(secrets_of "$plist")"
	[[ -n "$tag" ]] && natinfo="$(compute_natinfo "$pubip")"
	[[ -n "$natinfo" ]] && msg "Обнаружен NAT → добавляю${natinfo}."

	write_mtproxy_config "$tag" "$natinfo" "${secrets[@]}"
	if systemctl restart mtproxy.service 2>/dev/null; then
		[[ -n "$tag" ]] && ok "AD_TAG применён (middle-proxy mode)."
		return 0
	fi
	if [[ -n "$tag" ]]; then
		warn "MTProxy не запустился с AD_TAG — откатываю тег (прокси продолжит работать без него)."
		msg  "Диагностика: journalctl -u mtproxy --no-pager -n 50"
		write_mtproxy_config "" "" "${secrets[@]}"
		systemctl restart mtproxy.service || warn "MTProxy всё ещё не стартует — проверьте журнал."
		sed -i 's|^ADTAG=.*|ADTAG=""|' "$INFO_FILE" 2>/dev/null || true
		return 1
	fi
	warn "MTProxy не запустился — проверьте: journalctl -u mtproxy --no-pager -n 50"
	return 1
}

# ---------------------------------------------------------------- Caddy log hardening
# deploy/Caddyfile has no `log` directive, so operators assume logging is off.
# It is not: Caddy's http.log.error logger stays active, and whenever
# reverse_proxy cannot reach 127.0.0.1:8080 — which happens on EVERY relay
# restart and every `tgwebproxy update` — it logs the request including
# request>uri. Those URIs contain /?bridge=<capability>, the highest-value
# secret in the deployment, which then lands in journald and in any log
# shipper or support bundle. Filter the fields out of the default logger.
harden_caddy_log() { # <hostname> <email>
	local host="$1" email="$2" cf=/etc/caddy/Caddyfile tmp
	[[ -f "$cf" ]] || return 1
	grep -q 'request>uri delete' "$cf" && return 0        # already hardened
	head -1 "$cf" | grep -qx '{' || {
		warn "Caddyfile без глобального блока — пропускаю фильтрацию логов."; return 1; }

	tmp="$(mktemp)"
	{
		echo '{'
		cat <<'CADDYLOG'
	# Added by tg-webproxy.sh: strip capability-bearing fields from the
	# always-on error logger. Do not remove.
	log default {
		output stderr
		format filter {
			wrap console
			request>uri delete
			request>headers delete
			request>remote_ip ip_mask 24 64
		}
	}
CADDYLOG
		tail -n +2 "$cf"
	} > "$tmp"

	if TPROXY_HOSTNAME="$host" TPROXY_SITE_ROOT=/srv/tproxy-site ACME_EMAIL="$email" \
			/usr/local/bin/caddy validate --config "$tmp" --adapter caddyfile >/dev/null 2>&1; then
		install -m 0644 "$tmp" "$cf"; rm -f "$tmp"
		systemctl reload caddy.service 2>/dev/null || systemctl restart caddy.service 2>/dev/null || true
		ok "Логи Caddy отфильтрованы (capability больше не попадает в journald)."
		return 0
	fi
	rm -f "$tmp"
	warn "Не удалось применить фильтр логов Caddy — проверьте /etc/caddy/Caddyfile вручную."
	return 1
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
# Produces a small, RANDOMIZED static site so two installs never share an
# active-probe fingerprint.
#
# Hard constraints from the relay (internal/server/site.go), do not violate:
#   Content-Security-Policy: default-src 'self'; style-src 'self'; img-src 'self';
#     worker-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'
#   => NO inline <style> blocks and NO inline style="" ATTRIBUTES (style-src 'self'
#      has neither 'unsafe-inline' nor 'unsafe-hashes'), no inline <script>, no
#      forms, no third-party resources.
#   /favicon.ico is answered from favicon.svg; /404.html is the not-found page;
#   extensionless /about resolves about.html. Files are read once at start-up.
# Entropy per pick, not per install. A single 16-bit seed feeding bash's LCG
# would cap the whole reachable output space at 65536 sites — enumerable.
rnd()  { echo $(( $(od -An -N4 -tu4 /dev/urandom | tr -d ' ') % $1 )); }
pick() { local -a a=("$@"); echo "${a[$(rnd ${#a[@]})]}"; }
rtok() { local n="${1:-6}"; { LC_ALL=C tr -dc 'a-z' </dev/urandom | dd bs=1 count="$n" 2>/dev/null; } || true; }

# NB: build every phrase through variables. A line continuation INSIDE a
# double-quoted echo keeps the next line's leading tabs in the output.
brand_name() {
	local a b
	case "$(rnd 3)" in
	0) a="$(pick Northwind Meridian Aster Cobalt Larkspur Vireo Halcyon Ravenna \
	             Ironwood Selene Driftwood Quantic Alder Fenwick Lowell Brightwater)"
	   b="$(pick Labs Studio Digital Works Systems Group Media Consulting Partners Collective)" ;;
	1) a="$(pick Северный Ясный Первый Точный Ровный Светлый Прямой Верный Открытый)"
	   b="$(pick Контур Вектор Формат Стандарт Профиль Сегмент Ориентир Масштаб)" ;;
	*) a="$(pick Blue Pale Deep Bright Quiet Still Amber Slate)"
	   b="$(pick Harbor Field Ridge Vale Pine Grove Point Hollow)" ;;
	esac
	printf '%s %s' "$a" "$b"
}

hero_line() {
	local a b c
	a="$(pick "Мы помогаем командам" "Наша задача — помочь командам" \
	          "Мы даём командам возможность" "Помогаем инженерным командам" \
	          "Мы работаем с командами, которые хотят" "Наши клиенты выбирают нас, чтобы")"
	b="$(pick "запускать продукты" "доводить идеи до релиза" "выпускать обновления" \
	          "развивать сервисы" "строить инфраструктуру" "выводить проекты в продакшн")"
	c="$(pick "быстрее и надёжнее." "без лишних рисков." "предсказуемо и в срок." \
	          "с меньшими затратами." "и не терять качество." "не отвлекаясь на рутину.")"
	printf '%s %s %s' "$a" "$b" "$c"
}

about_line() {
	local a b
	a="$(pick "Небольшая команда позволяет держать высокий уровень вовлечённости:" \
	          "Мы сознательно остаёмся компактными:" \
	          "Размер команды — наш осознанный выбор:" \
	          "Мы не наращиваем штат ради роста:")"
	b="$(pick "каждый проект ведёт постоянный инженер, а не сменяющаяся линия поддержки." \
	          "клиент общается с теми, кто действительно пишет код." \
	          "решения принимаются быстро, без длинных согласований." \
	          "мы берём столько проектов, сколько можем вести внимательно.")"
	printf '%s %s' "$a" "$b"
}

privacy_line() {
	local a b
	a="$(pick "Мы не передаём данные третьим лицам" "Данные не покидают наши серверы" \
	          "Мы не продаём и не передаём информацию о клиентах" \
	          "Сведения о клиентах не раскрываются третьим сторонам")"
	b="$(pick "и не используем сторонние трекеры." "и не подключаем внешнюю аналитику." \
	          "и не размещаем рекламные скрипты." "и не применяем сторонние счётчики.")"
	printf '%s %s' "$a" "$b"
}

generate_site() { # <dir> <hostname>
	local dir="$1" host="$2"

	local name tagline accent bg card fg mut font year founded cls radius
	name="$(brand_name)"
	tagline="$(pick "Проектируем цифровые продукты" "Инженерия данных и облака" \
	                "Дизайн, который работает" "Автоматизация для бизнеса" \
	                "Исследования и разработка" "Инфраструктура нового поколения" \
	                "Продуктовая аналитика и рост" "Интеграции и бэкенд-разработка" \
	                "Надёжные системы для сложных задач")"
	accent="$(pick "#2563eb" "#0891b2" "#7c3aed" "#059669" "#b91c1c" "#d97706" \
	               "#0d9488" "#4f46e5" "#be185d" "#15803d" "#0369a1" "#7e22ce" "#a16207")"
	# NB: no pure white here — cards are white and would vanish into the page
	bg="$(pick "#f7f7f9" "#fafafa" "#f5f6f8" "#f8f9fb" "#f6f7f9" "#fbfbfc")"
	card="$(pick "#ffffff" "#ffffff" "#fdfdfe")"
	fg="$(pick "#16181d" "#111827" "#1f2328" "#18181b")"
	mut="$(pick "#5c6470" "#6b7280" "#64748b" "#71717a")"
	font="$(pick "-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif" \
	             "Segoe UI,Roboto,Ubuntu,Cantarell,Helvetica,Arial,sans-serif" \
	             "system-ui,-apple-system,Helvetica Neue,Arial,sans-serif" \
	             "Georgia,Cambria,Times New Roman,serif" \
	             "Inter,system-ui,Segoe UI,Roboto,Arial,sans-serif")"
	radius="$(pick 4 6 8 10 12 14 16)"
	year="$(date +%Y)"; founded=$((2009 + $(rnd 15)))
	cls="$(pick s c u ui q lx nv kp fx mt dl)$(( $(rnd 90) + 10 ))"

	local base=$((15 + $(rnd 3)))             # 15..17px
	local lh="1.$(( 55 + $(rnd 20) ))"        # 1.55..1.74
	local maxw=$((820 + $(rnd 9) * 20))       # 820..980
	local gap=$((14 + $(rnd 8)))
	local herofs=$((32 + $(rnd 12)))
	local ncards=$((3 + $(rnd 2)))
	local layout; layout="$(pick grid flex)"
	local cardstyle; cardstyle="$(pick border shadow tint)"
	local headstyle; headstyle="$(pick line block)"
	local heroalign; heroalign="$(pick left left center)"

	local -a svc_h=("Консалтинг" "Разработка" "Поддержка" "Аналитика" "Интеграции" \
	                "Аудит" "Обучение" "Сопровождение" "Миграции" "Оптимизация")
	local -a svc_p=(\
	  "Аудит, стратегия и сопровождение проектов на всех этапах." \
	  "Веб-сервисы, интеграции и надёжная инфраструктура." \
	  "Мониторинг, обновления и оперативная помощь по будням." \
	  "Метрики, отчётность и понятные выводы для команды." \
	  "Связываем внутренние системы и внешние сервисы." \
	  "Проверяем архитектуру и находим узкие места." \
	  "Воркшопы и внутренние регламенты для ваших специалистов." \
	  "Долгосрочная поддержка и развитие работающих систем." \
	  "Переносим данные и сервисы без простоя." \
	  "Ускоряем то, что уже работает, но работает медленно.")

	# ---- pick 2..4 inner pages so the path set is not fixed ---------------
	local -a poolp=(about services pricing contacts team faq careers docs)
	local -a poolt=("О нас" "Услуги" "Цены" "Контакты" "Команда" "Вопросы" "Вакансии" "Документация")
	local npages=$((2 + $(rnd 3))) i j pages="" titles=""
	local -a idxs=()
	for ((i = 0; i < npages; i++)); do
		j=$(rnd ${#poolp[@]})
		while [[ " ${idxs[*]:-} " == *" $j "* ]]; do j=$(( (j + 1) % ${#poolp[@]} )); done
		idxs+=("$j"); pages+="${pages:+ }${poolp[$j]}"; titles+="${titles:+|}${poolt[$j]}"
	done

	# ---- stylesheet: vary structure, not only token values ----------------
	{
	echo ":root{--a:${accent};--bg:${bg};--cd:${card};--fg:${fg};--mut:${mut};--r:${radius}px}"
	echo "*{box-sizing:border-box}"
	echo "body{margin:0;font:${base}px/${lh} ${font};color:var(--fg);background:var(--bg)}"
	echo ".${cls}-wrap{max-width:${maxw}px;margin:0 auto;padding:0 20px}"
	echo ".${cls}-top{display:flex;justify-content:space-between;align-items:center;gap:16px}"
	if [[ "$headstyle" == "line" ]]; then
		echo ".${cls}-head{padding:22px 0;border-bottom:1px solid rgba(0,0,0,.08)}"
	else
		echo ".${cls}-head{padding:20px 0;background:var(--cd);box-shadow:0 1px 2px rgba(0,0,0,.06)}"
	fi
	echo ".${cls}-brand{display:flex;align-items:center;gap:9px;font-weight:700;font-size:$((base + 4))px;color:var(--a);text-decoration:none}"
	echo ".${cls}-nav a{color:var(--mut);text-decoration:none;margin-left:18px}"
	echo ".${cls}-nav a:hover{color:var(--a)}"
	if [[ "$heroalign" == "center" ]]; then
		echo ".${cls}-hero{padding:64px 0 40px;text-align:center}"
		echo ".${cls}-hero p{margin:0 auto}"
	else
		echo ".${cls}-hero{padding:60px 0 38px}"
	fi
	echo ".${cls}-hero h1{font-size:${herofs}px;line-height:1.15;margin:0 0 14px}"
	echo ".${cls}-hero p{font-size:$((base + 3))px;color:var(--mut);max-width:62ch}"
	echo ".${cls}-btn{display:inline-block;margin-top:22px;background:var(--a);color:#fff;padding:11px 21px;border-radius:var(--r);text-decoration:none}"
	if [[ "$layout" == "grid" ]]; then
		echo ".${cls}-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(230px,1fr));gap:${gap}px;padding:20px 0 56px}"
	else
		echo ".${cls}-grid{display:flex;flex-wrap:wrap;gap:${gap}px;padding:20px 0 56px}"
		echo ".${cls}-card{flex:1 1 240px}"
	fi
	case "$cardstyle" in
		border) echo ".${cls}-card{background:var(--cd);border:1px solid rgba(0,0,0,.09);border-radius:var(--r);padding:21px}" ;;
		shadow) echo ".${cls}-card{background:var(--cd);box-shadow:0 1px 3px rgba(0,0,0,.10);border-radius:var(--r);padding:22px}" ;;
		tint)   echo ".${cls}-card{background:var(--cd);border-left:3px solid var(--a);border-radius:var(--r);padding:20px}" ;;
	esac
	echo ".${cls}-card h3{margin:0 0 8px;font-size:$((base + 1))px}"
	echo ".${cls}-card p{margin:0;color:var(--mut);font-size:$((base - 1))px}"
	echo ".${cls}-prose{padding:52px 0;max-width:66ch}"
	echo ".${cls}-prose h1{font-size:$((herofs - 6))px;margin:0 0 16px}"
	echo ".${cls}-prose p{color:var(--mut)}"
	echo ".${cls}-foot{border-top:1px solid rgba(0,0,0,.08);padding:24px 0;color:var(--mut);font-size:$((base - 2))px}"
	echo ".${cls}-foot a{color:var(--mut);text-decoration:none}"
	echo ".${cls}-foot a:hover{color:var(--a)}"
	} > "$dir/styles.css"

	# ---- favicon.svg (also answers /favicon.ico) --------------------------
	local initial="${name:0:1}"
	cat > "$dir/favicon.svg" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" role="img" aria-label="${initial}">
<rect width="64" height="64" rx="$((radius + 4))" fill="${accent}"/>
<text x="32" y="43" font-family="Helvetica,Arial,sans-serif" font-size="34" font-weight="700"
 text-anchor="middle" fill="#ffffff">${initial}</text></svg>
EOF

	# ---- shared fragments -------------------------------------------------
	local nav="<nav class=\"${cls}-nav\"><a href=\"/\">Главная</a>"
	i=0
	for pg in $pages; do
		i=$((i + 1))
		nav+="<a href=\"/${pg}\">$(echo "$titles" | cut -d'|' -f$i)</a>"
	done
	nav+="</nav>"
	local brandmark="<a class=\"${cls}-brand\" href=\"/\"><svg width=\"22\" height=\"22\" viewBox=\"0 0 64 64\" aria-hidden=\"true\"><rect width=\"64\" height=\"64\" rx=\"14\" fill=\"${accent}\"/></svg>${name}</a>"
	local header="<header class=\"${cls}-head\"><div class=\"${cls}-wrap ${cls}-top\">${brandmark}${nav}</div></header>"
	local rights footer
	rights="$(pick "Все права защищены." "Все права защищены" "")"
	footer="<footer class=\"${cls}-foot\"><div class=\"${cls}-wrap ${cls}-top\"><span>© ${year} ${name}. ${rights}</span><a href=\"/privacy\">$(pick "Приватность" "Политика приватности" "Конфиденциальность")</a></div></footer>"

	local cards="" used=" "
	for ((i = 0; i < ncards; i++)); do
		j=$(rnd ${#svc_h[@]})
		while [[ "$used" == *" $j "* ]]; do j=$(( (j + 1) % ${#svc_h[@]} )); done
		used+="$j "
		cards+="<div class=\"${cls}-card\"><h3>${svc_h[$j]}</h3><p>${svc_p[$j]}</p></div>"
	done

	emit_head() { # <title> <description>
		printf '<!doctype html><html lang="ru"><head><meta charset="utf-8">\n'
		printf '<meta name="viewport" content="width=device-width,initial-scale=1">\n'
		printf '<meta name="description" content="%s">\n' "$2"
		printf '<link rel="stylesheet" href="/styles.css"><link rel="icon" href="/favicon.svg" type="image/svg+xml">\n'
		printf '<title>%s</title></head><body>\n' "$1"
	}

	# ---- index ------------------------------------------------------------
	{
	emit_head "$name" "${tagline}. $(hero_line)"
	echo "$header"
	echo "<main class=\"${cls}-wrap\">"
	echo "<section class=\"${cls}-hero\"><h1>${name}</h1><p>${tagline}. $(hero_line)</p>"
	echo "<a class=\"${cls}-btn\" href=\"/$(echo "$pages" | cut -d' ' -f1)\">$(pick "Подробнее" "Что мы делаем" "Узнать больше" "Наши услуги")</a></section>"
	echo "<section class=\"${cls}-grid\">${cards}</section>"
	echo "</main>"
	echo "$footer"
	echo "</body></html>"
	} > "$dir/index.html"

	# ---- inner pages ------------------------------------------------------
	i=0
	for pg in $pages; do
		i=$((i + 1))
		local ttl; ttl="$(echo "$titles" | cut -d'|' -f$i)"
		{
		emit_head "${ttl} — ${name}" "${ttl}: ${tagline}."
		echo "$header"
		echo "<main class=\"${cls}-wrap\"><section class=\"${cls}-prose\"><h1>${ttl}</h1>"
		echo "<p>${name} — $(pick "независимая команда специалистов" "небольшая инженерная студия" \
			"частная технологическая компания" "команда практиков"). ${tagline}. $(pick "Работаем" "На рынке" "Ведём проекты") с ${founded} года.</p>"
		echo "<p>$(about_line)</p>"
		[[ $(rnd 3) -eq 0 ]] && echo "<p>$(privacy_line)</p>"
		echo "</section>"
		[[ $(rnd 2) -eq 0 ]] && echo "<section class=\"${cls}-grid\">${cards}</section>"
		echo "</main>"
		echo "$footer"
		echo "</body></html>"
		} > "$dir/${pg}.html"
	done

	# ---- privacy is always present (linked from the footer) ---------------
	if [[ ! -f "$dir/privacy.html" ]]; then
		{
		emit_head "Политика приватности — ${name}" "Как ${name} обрабатывает данные."
		echo "$header"
		echo "<main class=\"${cls}-wrap\"><section class=\"${cls}-prose\"><h1>Политика приватности</h1>"
		echo "<p>Мы уважаем вашу конфиденциальность и обрабатываем данные только в объёме, необходимом для оказания услуг.</p>"
		echo "<p>$(privacy_line)</p></section></main>"
		echo "$footer"
		echo "</body></html>"
		} > "$dir/privacy.html"
	fi

	# ---- 404 ---------------------------------------------------------------
	{
	emit_head "$(pick "Страница не найдена" "404" "Ничего не найдено") — ${name}" "Страница не найдена."
	echo "$header"
	echo "<main class=\"${cls}-wrap\"><section class=\"${cls}-prose\"><h1>$(pick "Страница не найдена" "Ничего не найдено" "Такой страницы нет")</h1>"
	echo "<p>$(pick "Возможно, ссылка устарела." "Проверьте адрес страницы." "Похоже, страница была перемещена.") Вернитесь на <a href=\"/\">главную</a>.</p>"
	echo "</section></main>"
	echo "$footer"
	echo "</body></html>"
	} > "$dir/404.html"

	# ---- robots.txt: three shapes ------------------------------------------
	case "$(rnd 3)" in
	0) printf 'User-agent: *\nAllow: /\n' > "$dir/robots.txt" ;;
	1) printf 'User-agent: *\nDisallow:\n\nSitemap: https://%s/sitemap.xml\n' "$host" > "$dir/robots.txt"
	   { echo '<?xml version="1.0" encoding="UTF-8"?>'
	     echo '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">'
	     echo "<url><loc>https://${host}/</loc></url>"
	     for pg in $pages; do echo "<url><loc>https://${host}/${pg}</loc></url>"; done
	     echo '</urlset>'; } > "$dir/sitemap.xml" ;;
	*) printf 'User-agent: *\nCrawl-delay: %s\nDisallow: /%s\n' "$(( $(rnd 9) + 1 ))" "$(rtok 6)" > "$dir/robots.txt" ;;
	esac

	unset -f emit_head
	# Readable by the relay's unprivileged user (script umask is 077).
	chmod 0755 "$dir"
	find "$dir" -type d -exec chmod 0755 {} + 2>/dev/null || true
	find "$dir" -type f -exec chmod 0644 {} + 2>/dev/null || true
}

# ---------------------------------------------------------------- final output
print_result() { # <hostname> <secret> <adtag> <profile_list> [role] [backend] [tunnel_ip]
	local host="$1" secret="$2" adtag="$3" profiles="${4:-}" role="${5:-single}" backend="${6:-}" tun="${7:-}"
	head2 "🎉 Готово — WEB-прокси развёрнут на https://$host/"
	echo
	echo -e "${YELLOW}${BOLD}Данные для клиента:${NC}"
	echo -e "  Домен (Hostname): ${GREEN}$host${NC}"
	echo -e "  Секрет  (Secret): ${GREEN}$secret${NC}"
	echo
	echo -e "${YELLOW}${BOLD}Ссылки подключения:${NC}"
	local p m s
	for p in ${profiles:-https:$secret}; do
		m="${p%%:*}"; s="${p#*:}"
		echo -e "  ${BOLD}[$m]${NC}"
		echo -e "    ${GREEN}https://t.me/webproxy?server=$host&secret=$s${NC}"
		echo -e "    ${GREEN}tg://webproxy?server=$host&secret=$s${NC}"
	done
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
	echo -e "${YELLOW}${BOLD}Не трогайте на этом домене${NC} (иначе маскировка ломается): Caddyfile без file_server/root/redir/respond,"
	echo -e "  без path-scoped правил, request_body max_size и h3, таймауты не снижать; никакого CDN перед доменом;"
	echo -e "  не объединяйте несколько таких доменов в один сертификат (CT свяжет их публично)."
	echo
	if [[ "$role" == front ]]; then
		echo -e "${YELLOW}${BOLD}Backend:${NC} relay ходит в ${GREEN}$backend${NC} через туннель. На backend-хосте выполните:"
		echo -e "  ${GREEN}TGWP_ROLE=backend TGWP_SECRETS='$(secrets_of "${profiles:-https:$secret}")' TGWP_ALLOW_FROM=${tun:-<IP этого хоста в туннеле>} bash <(wget -qO- ${SCRIPT_URLS[0]})${NC}"
		echo
	fi
	echo -e "${BLUE}${BOLD}Управление:${NC} ${GREEN}tgwebproxy${NC} — меню с живой панелью; или status | watch | link | mode | adtag | backend | update | self-update | uninstall | help"
	msg "Проверка: ${GREEN}curl -fsS $RELAY_ADMIN/readyz${NC} → ready; ${GREEN}curl -fsS https://$host/${NC}"
}

# =====================================================================
#  MANAGEMENT CLI  (installed to /usr/local/bin/tgwebproxy)
# =====================================================================
install_mgmt_cli() {
	# Temp file + mv: bash reads scripts incrementally, so rewriting a RUNNING
	# tgwebproxy in place (self-update) would feed it garbage mid-execution.
	cat > "$MGMT.tmp" <<'UTILITY_EOF'
#!/usr/bin/env bash
set -uo pipefail
export LC_ALL=C.UTF-8   # ${#str} must count characters, not bytes (Cyrillic labels)

RED=$'\033[38;5;196m'; GREEN=$'\033[38;5;46m'; YELLOW=$'\033[38;5;214m'
BLUE=$'\033[38;5;39m'; CYAN=$'\033[38;5;51m'; BOLD=$'\033[1m'; DIM=$'\033[38;5;245m'; NC=$'\033[0m'

INFO_FILE="/opt/tgwebproxy/info.env"
TGWP_VERSION="@VERSION@"                    # substituted by the installer
SCRIPT_URLS=(@URLS@)                        # GitHub Pages, raw GitHub, jsDelivr
VER_CACHE="/opt/tgwebproxy/version-check"   # "epoch version url", refreshed daily in background
STATE_DIR="/opt/tgwebproxy"
BK_SOCKET="/etc/systemd/system/tgwp-backend.socket"
BK_SERVICE="/etc/systemd/system/tgwp-backend.service"
UP_FW_NFT="/etc/tproxy-server/firewall.nft"
MTENV="/etc/mtproxy/mtproxy.env"
ADTAG_DROPIN="/etc/systemd/system/mtproxy.service.d/adtag.conf"   # legacy, removed on sight
MT_DROPIN="/etc/systemd/system/mtproxy.service.d/tgwp.conf"      # the ONLY ExecStart override
MON_UNIT="/etc/systemd/system/tgmon-counters.service"
MON_NFT="/etc/tproxy-server/tgmon.nft"
RELAY_ADMIN="http://127.0.0.1:8081"
MTPROXY_STATS="http://127.0.0.1:8888"
MON_TABLE="tgmon"

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
	ROLE="${ROLE:-single}"
	[[ "$ROLE" == backend ]] && HOSTNAME=""   # bash's own $HOSTNAME must not leak into hints
	return 0
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
mtstat(){ curl -fsS --max-time 2 "$MTPROXY_STATS/stats" 2>/dev/null | awk -F'\t' -v n="$1" '$1==n{print $2; exit}'; }
has_tty(){ { : </dev/tty; } 2>/dev/null && [[ -t 1 ]]; }
conns(){ ss -Htn state established "( $1 = :$2 )" 2>/dev/null | wc -l | tr -d ' '; }

# The client secret IS the MTProxy secret, so MTProxy must be started with
# every secret the relay serves. One drop-in only — two ExecStart resets would
# clobber each other. systemd does not word-split ${VAR}: one var per secret.
compute_natinfo(){ local pubip="$1" localip
	localip="$(ip -4 route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
	[[ -n "$pubip" && -n "$localip" && "$localip" != "$pubip" ]] && printf ' --nat-info %s:%s' "$localip" "$pubip"
	return 0; }
secrets_of(){ local p out=""; for p in $1; do out+="${out:+ }${p#*:}"; done; printf '%s' "$out"; }
write_mtproxy_config(){ # <tag|""> <natinfo|""> <secret...>
	local tag="$1" natinfo="$2"; shift 2
	local i=0 s bs sflags="" tagflag=""
	sed -i '/^MTPROXY_SECRET[0-9]*=/d; /^MTPROXY_TAG=/d' "$MTENV" 2>/dev/null || true
	for s in "$@"; do
		i=$((i+1)); bs="$s"
		[[ "$bs" == dd* && ${#bs} -eq 34 ]] && bs="${bs:2}"
		if [[ $i -eq 1 ]]; then printf 'MTPROXY_SECRET=%s\n' "$bs" >> "$MTENV"; sflags+=' -S ${MTPROXY_SECRET}'
		else printf 'MTPROXY_SECRET%d=%s\n' "$i" "$bs" >> "$MTENV"; sflags+=" -S \${MTPROXY_SECRET${i}}"; fi
	done
	if [[ -n "$tag" ]]; then printf 'MTPROXY_TAG=%s\n' "$tag" >> "$MTENV"; tagflag=' -P ${MTPROXY_TAG}'; fi
	chown root:mtproxy "$MTENV" 2>/dev/null || true; chmod 0640 "$MTENV"
	mkdir -p /etc/systemd/system/mtproxy.service.d; rm -f "$ADTAG_DROPIN"
	cat > "$MT_DROPIN" <<EOF
[Service]
ExecStart=
ExecStart=/opt/MTProxy/objs/bin/mtproto-proxy -u mtproxy -p 8888 -H 2398${sflags}${tagflag}${natinfo} --aes-pwd /etc/mtproxy/proxy-secret /etc/mtproxy/proxy-multi.conf -M \${MTPROXY_WORKERS} -C \${MTPROXY_MAX_CONNECTIONS}
EOF
	systemctl daemon-reload; }
verify_mtproxy_secrets(){ local want got
	want="$(set -- $1; echo $#)"
	got="$(systemctl show -p ExecStart mtproxy.service 2>/dev/null | tr ' ' '\n' | grep -c -- '^-S$')"
	if [[ "$got" != "$want" ]]; then warn "MTProxy принял $got секрет(ов), профилей $want — часть ссылок может не работать."
	elif systemctl is-active --quiet mtproxy.service; then ok "MTProxy запущен и принял $got секрет(ов)."
	else warn "MTProxy сконфигурирован, но служба не активна — journalctl -u mtproxy -n 50"; fi; }


# ---------------------------------------------------------------- split mode helpers
tunnel_iface(){ local i; for i in wt0 wg0 nb0 tun0; do ip -4 -o addr show dev "$i" 2>/dev/null | grep -q inet && { printf '%s' "$i"; return 0; }; done; return 1; }
tunnel_ip(){ local i; i="$(tunnel_iface)" || return 1; ip -4 -o addr show dev "$i" | awk '{print $4; exit}' | cut -d/ -f1; }
probe_tcp(){ timeout 3 bash -c "exec 3<>/dev/tcp/${1%:*}/${1##*:}" 2>/dev/null; }
norm_backend(){ [[ "${1:-}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(:[0-9]{1,5})?$ ]] || return 1; if [[ "$1" == *:* ]]; then printf '%s' "$1"; else printf '%s:2398' "$1"; fi; }
norm_cidr_list(){ local x out="" i; x="$(echo "${1:-}" | tr ',' ' ' | tr -s '[:space:]' ' ')"
	for i in $x; do [[ "$i" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]] || return 1; [[ "$i" == */* ]] || i="$i/32"; out+="${out:+, }$i"; done
	[[ -n "$out" ]] && printf '%s' "$out"; }
valid_secret_list(){ local i; [[ -n "${1:-}" ]] || return 1; for i in $1; do [[ "$i" =~ ^([0-9a-f]{32}|dd[0-9a-f]{32})$ ]] || return 1; done; }
set_info(){ sed -i "/^$1=/d" "$INFO_FILE"; printf '%s="%s"\n' "$1" "$2" >> "$INFO_FILE"; }
secrets_list(){ if [[ "${ROLE:-single}" == backend ]]; then printf '%s' "${SECRETS:-}"; else secrets_of "${PROFILES:-https:${SECRET:-}}"; fi; }
write_backend_units(){ local target="$1" proxyd="" p
	for p in /usr/lib/systemd/systemd-socket-proxyd /lib/systemd/systemd-socket-proxyd; do if [[ -x "$p" ]]; then proxyd="$p"; break; fi; done
	[[ -n "$proxyd" ]] || { err "systemd-socket-proxyd не найден (пакет systemd)."; return 1; }
	printf '[Unit]\nDescription=Loopback endpoint for the remote MTProxy backend (tg-webproxy)\n\n[Socket]\nListenStream=127.0.0.1:2398\nNoDelay=true\nBacklog=1024\n\n[Install]\nWantedBy=sockets.target\n' > "$BK_SOCKET"
	printf '[Unit]\nDescription=Forward loopback :2398 to the remote MTProxy backend %s (tg-webproxy)\nRequires=tgwp-backend.socket\nAfter=network-online.target\nWants=network-online.target\n\n[Service]\nExecStart=%s --connections-max=8192 --exit-idle-time=10min %s\nPrivateTmp=yes\nNoNewPrivileges=yes\nProtectSystem=strict\nProtectHome=yes\n' "$target" "$proxyd" "$target" > "$BK_SERVICE"
	chmod 0644 "$BK_SOCKET" "$BK_SERVICE"; systemctl daemon-reload; }
switch_backend_remote(){ local target="$1" i
	systemctl disable --now mtproxy.service refresh-mtproxy-config.timer >/dev/null 2>&1 || true
	systemctl mask mtproxy.service >/dev/null 2>&1 || true
	write_backend_units "$target" || return 1
	systemctl enable --now tgwp-backend.socket >/dev/null 2>&1 || { err "Не удалось запустить tgwp-backend.socket"; return 1; }
	systemctl restart tproxy-server.service
	for i in 1 2 3 4 5; do probe_tcp "$target" && { ok "Backend $target отвечает через туннель."; return 0; }; sleep 1; done
	warn "Backend $target пока недоступен: поднимите MTProxy на том хосте и проверьте туннель."; return 0; }
switch_backend_local(){
	systemctl disable --now tgwp-backend.socket tgwp-backend.service >/dev/null 2>&1 || true
	rm -f "$BK_SOCKET" "$BK_SERVICE"; systemctl daemon-reload
	systemctl unmask mtproxy.service >/dev/null 2>&1 || true
	systemctl enable --now mtproxy.service refresh-mtproxy-config.timer >/dev/null 2>&1 || warn "MTProxy не стартовал — journalctl -u mtproxy"
	systemctl restart tproxy-server.service; }
write_backend_firewall(){ # <"cidr, cidr">
	mkdir -p /etc/tproxy-server
	printf 'table inet tproxy_backend {\n\tset allow4 { type ipv4_addr; flags interval; auto-merge; elements = { %s } }\n\tchain local_backend {\n\t\ttype filter hook input priority -10; policy accept;\n\t\tiifname "lo" accept\n\t\ttcp dport 2398 ip saddr @allow4 accept\n\t\ttcp dport { 2398, 8888 } drop\n\t}\n}\n' "$1" > "$UP_FW_NFT"
	chmod 0644 "$UP_FW_NFT"
	nft -c -f "$UP_FW_NFT" >/dev/null 2>&1 || return 1
	systemctl enable tproxy-firewall.service >/dev/null 2>&1 || true
	systemctl restart tproxy-firewall.service; }

# ---------------------------------------------------------------- split mode commands
do_backend(){ # front: show | set <ip[:port]> | local
	need_root backend; load_info
	title "Backend — где работает MTProxy"
	local t
	case "${1:-show}" in
		show)
			if [[ "$ROLE" == front ]]; then
				msg "Роль front  ·  relay → ${GREEN}${BACKEND:-?}${NC} через туннель  ·  IP этого хоста в туннеле: $(tunnel_ip || echo '?')"
				if probe_tcp "${BACKEND:-0.0.0.0:0}"; then ok "Backend отвечает."; else warn "Backend недоступен: проверьте MTProxy и туннель на том хосте."; fi
				msg "Вернуть MTProxy на этот хост: ${GREEN}tgwebproxy backend local${NC}"
			elif [[ "$ROLE" == backend ]]; then msg "Это backend-хост: здесь работает MTProxy. Настройки: tgwebproxy secrets | allow."
			else msg "MTProxy работает локально. Вынести на другой хост: ${GREEN}tgwebproxy backend set <ip[:port]>${NC}"; fi ;;
		set)
			[[ "$ROLE" == backend ]] && { err "Это backend-хост."; exit 1; }
			t="$(norm_backend "${2:-}")" || { err "Нужен IPv4 и порт, например 100.64.0.5:2398"; exit 1; }
			switch_backend_remote "$t" || exit 1
			set_info ROLE front; set_info BACKEND "$t"; set_info TUNNEL_IP "$(tunnel_ip || true)"
			ok "Relay теперь ходит в $t. Команда для backend-хоста: tgwebproxy link" ;;
		local)
			[[ "$ROLE" == front ]] || { msg "MTProxy и так локальный."; return 0; }
			switch_backend_local; set_info ROLE single; set_info BACKEND ""; ok "MTProxy снова работает на этом хосте." ;;
		*) err "Использование: tgwebproxy backend [show | set <ip[:port]> | local]"; exit 1 ;;
	esac
}
do_secrets(){ # backend: show | set "<s1 s2 ...>"
	need_root secrets; load_info
	[[ "$ROLE" == backend ]] || { err "Секреты задаются на backend-хосте; на front их печатает tgwebproxy link."; exit 1; }
	title "Секреты MTProxy — те же, что на front"
	msg "Сейчас: ${SECRETS:-нет}"
	local new
	if [[ "${1:-}" == show ]]; then return 0
	elif [[ $# -ge 1 ]]; then new="$*"
	elif has_tty && read -r -p "Новые секреты через пробел (Enter — оставить): " new </dev/tty; then [[ -n "$new" ]] || return 0
	else err "Нужен терминал или аргумент: tgwebproxy secrets set '<s1 s2>'"; exit 1; fi
	new="${new#set }"
	new="$(echo "$new" | tr 'A-Z,' 'a-z ' | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')"
	valid_secret_list "$new" || { err "Каждый секрет — 32 hex (можно с префиксом dd)."; exit 1; }
	local natinfo=""; [[ -n "${ADTAG:-}" ]] && natinfo="$(compute_natinfo "${PUBIP:-}")"
	local -a secs; read -r -a secs <<< "$new"
	write_mtproxy_config "${ADTAG:-}" "$natinfo" "${secs[@]}"
	systemctl restart mtproxy.service || warn "MTProxy не перезапустился — journalctl -u mtproxy"
	set_info SECRETS "$new"; verify_mtproxy_secrets "$new"
}
do_allow(){ # backend: who may reach MTProxy :2398
	need_root allow; load_info
	[[ "$ROLE" == backend ]] || { err "Только для backend-хоста."; exit 1; }
	title "Кому разрешено подключаться к MTProxy"
	msg "Сейчас: ${ALLOW_FROM:-нет}  ·  IP этого хоста в туннеле: ${TUNNEL_IP:-?}"
	local new
	if [[ $# -ge 1 ]]; then new="$*"
	elif has_tty && read -r -p "IP/CIDR через запятую (Enter — оставить): " new </dev/tty; then [[ -n "$new" ]] || return 0
	else err "Нужен терминал или аргумент: tgwebproxy allow <ip/cidr,...>"; exit 1; fi
	new="${new#set }"
	new="$(norm_cidr_list "$new")" || { err "Нужны IPv4-адреса или CIDR, например 100.64.0.7 или 100.64.0.0/10."; exit 1; }
	write_backend_firewall "$new" || { err "Правила не прошли проверку nft — ничего не изменено."; exit 1; }
	set_info ALLOW_FROM "$new"; ok "Разрешено с: $new"
}

# ---------------------------------------------------------------- versioning
ver_gt(){ [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" == "$1" ]]; }
remote_version(){ # -> "version url" of the newest published copy (reads 4 KB per source)
	local u v best="" best_url=""
	for u in "${SCRIPT_URLS[@]}"; do
		v="$(curl -fsSL --max-time 4 -r 0-4095 "$u" 2>/dev/null | grep -m1 -E '^TGWP_VERSION="[0-9]+(\.[0-9]+)*"' | cut -d'"' -f2)"
		[[ -n "$v" ]] || continue
		if [[ -z "$best" ]] || ver_gt "$v" "$best"; then best="$v"; best_url="$u"; fi
	done
	[[ -n "$best" ]] && printf '%s %s\n' "$best" "$best_url"; }
refresh_version_cache(){ # background, at most once a day, never blocks
	[[ "${TGWP_NO_UPDATE_CHECK:-}" == "1" ]] && return 0
	local now ts=""; now="$(date +%s)"
	[[ -r "$VER_CACHE" ]] && read -r ts _ < "$VER_CACHE"
	[[ "$ts" =~ ^[0-9]+$ ]] && (( now - ts <= 86400 )) && return 0
	[[ -e "$VER_CACHE.lock" ]] && (( now - $(stat -c %Y "$VER_CACHE.lock" 2>/dev/null || echo 0) < 120 )) && return 0
	: > "$VER_CACHE.lock"
	( r="$(remote_version)" && printf '%s %s\n' "$now" "$r" > "$VER_CACHE.tmp" && mv -f "$VER_CACHE.tmp" "$VER_CACHE"; rm -f "$VER_CACHE.lock" ) >/dev/null 2>&1 &
	disown 2>/dev/null || true
	return 0; }
cached_newer(){ # prints the cached published version when it is newer than this CLI
	local ts="" v="" u=""
	[[ -r "$VER_CACHE" ]] && read -r ts v u < "$VER_CACHE"
	[[ -n "$v" ]] && ver_gt "$v" "$TGWP_VERSION" && printf '%s' "$v"
	return 0; }
update_notice(){ local v; refresh_version_cache; v="$(cached_newer)"
	[[ -n "$v" ]] && warn "Доступна версия $v (у вас $TGWP_VERSION): ${GREEN}tgwebproxy self-update${NC}"; return 0; }
show_version(){
	echo "tgwebproxy $TGWP_VERSION"
	local r rv; r="$(remote_version)" || { warn "Источники обновлений недоступны (GitHub Pages, raw GitHub, jsDelivr)."; return 0; }
	rv="${r%% *}"
	if ver_gt "$rv" "$TGWP_VERSION"; then warn "Опубликована $rv (${r#* }) — обновить: ${GREEN}tgwebproxy self-update${NC}"
	else ok "Это последняя версия (опубликована $rv)."; fi; }
do_self_update(){ # re-generates this CLI from the newest published tg-webproxy.sh
	need_root self-update
	local r rv url tmp
	msg "Проверяю источники: GitHub Pages, raw GitHub, jsDelivr…"
	r="$(remote_version)" || { err "Ни один источник не ответил."; exit 1; }
	rv="${r%% *}"; url="${r#* }"
	if ! ver_gt "$rv" "$TGWP_VERSION" && [[ "${1:-}" != "--force" ]]; then
		ok "Уже последняя версия ($TGWP_VERSION, опубликована $rv). Принудительно: tgwebproxy self-update --force"; return 0
	fi
	tmp="$(mktemp)"
	curl -fsSL --max-time 60 "$url" -o "$tmp" || { err "Не удалось скачать $url"; rm -f "$tmp"; exit 1; }
	if ! grep -q '^TGWP_VERSION=' "$tmp" || ! bash -n "$tmp" 2>/dev/null; then
		err "Скачанный файл не похож на tg-webproxy.sh — ничего не меняю."; rm -f "$tmp"; exit 1
	fi
	if ! bash "$tmp" install-cli; then err "Установка новой утилиты не удалась."; rm -f "$tmp"; exit 1; fi
	rm -f "$tmp" "$VER_CACHE"
	ok "tgwebproxy обновлён: $TGWP_VERSION → $rv (источник: $url)."; }

show_link(){
	need_root link; load_info
	[[ "$ROLE" == backend ]] && { err "Ссылки печатает front-хост (там домен и relay)."; exit 1; }
	update_notice
	title "Ссылки подключения"
	local p m s
	for p in ${PROFILES:-https:$SECRET}; do
		m="${p%%:*}"; s="${p#*:}"
		echo -e "  ${BOLD}[$m]${NC}"
		echo -e "    ${GREEN}https://t.me/webproxy?server=$HOSTNAME&secret=$s${NC}"
		echo -e "    ${GREEN}tg://webproxy?server=$HOSTNAME&secret=$s${NC}"
	done
	echo
	echo -e "  Ручной ввод: Telegram → Настройки → Продвинутые → Тип соединения →"
	echo -e "  Добавить прокси → ${BOLD}WEB${NC} → Hostname: ${GREEN}$HOSTNAME${NC}, Secret: ${GREEN}$SECRET${NC}"
	echo
	warn "Нужен клиент с поддержкой WEB-прокси: Desktop ≥ 7.1.1 или Android beta 12.10.2+."
	if [[ "$ROLE" == front ]]; then
		echo; echo -e "${YELLOW}${BOLD}Backend-хост${NC} (${BACKEND:-?}) — установка или обновление секретов там:"
		echo -e "  ${GREEN}TGWP_ROLE=backend TGWP_SECRETS='$(secrets_list)' TGWP_ALLOW_FROM=${TUNNEL_IP:-<IP этого хоста в туннеле>} bash <(wget -qO- ${SCRIPT_URLS[0]})${NC}"
		echo -e "  уже установлен: ${GREEN}tgwebproxy secrets set '$(secrets_list)'${NC}"
	fi
}

# Switch the carrier mode (transport) after installation.
do_mode(){
	need_root mode; load_info
	[[ "$ROLE" == backend ]] && { err "Тип подключения меняется на front-хосте."; exit 1; }
	local pf="/etc/tproxy-server/profiles.json"
	title "Тип подключения (carrier mode)"
	msg "Текущий: ${MODE:-https}"
	echo -e "  ${BOLD}https${NC}           — один POST + long-poll, консервативный дефолт"
	echo -e "  ${BOLD}https-lanes${NC}     — своя пара запросов на поток, ниже задержки (нужен HTTP/2)"
	echo -e "  ${BOLD}websocket${NC}       — один WebSocket на всё, быстрее всего"
	echo -e "  ${BOLD}websocket-lanes${NC} — свой WebSocket на поток, медиа не блокирует чат"
	echo -e "  ${BOLD}all${NC}             — все четыре сразу (4 секрета, 4 ссылки)"
	echo
	local new
	if [[ $# -ge 1 ]]; then new="$1"
	elif [[ -e /dev/tty ]] && read -r -p "Новый режим: " new </dev/tty; then :
	else err "Нужен терминал или аргумент: tgwebproxy mode <https|https-lanes|websocket|websocket-lanes|all>"; exit 1; fi
	new="$(echo "$new" | tr 'A-Z' 'a-z' | tr -d '[:space:]')"
	case "$new" in https|https-lanes|websocket|websocket-lanes|all) ;;
		*) err "Неизвестный режим: $new"; exit 1 ;; esac

	local list="" json="" first=1 m s
	if [[ "$new" == "all" ]]; then
		for m in https https-lanes websocket websocket-lanes; do
			if [[ "$m" == "https" ]]; then s="$SECRET"
			else s="$(head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n')"; fi
			list+="${list:+ }${m}:${s}"
			[[ $first -eq 1 ]] || json+=","; first=0
			json+="{\"name\":\"${m}\",\"secret\":\"${s}\",\"backend\":\"127.0.0.1:2398\",\"carrier_mode\":\"${m}\"}"
		done
	else
		list="${new}:${SECRET}"
		json="{\"name\":\"default\",\"secret\":\"${SECRET}\",\"backend\":\"127.0.0.1:2398\",\"carrier_mode\":\"${new}\"}"
	fi

	cp -a "$pf" "$pf.bak" 2>/dev/null || true
	printf '{"profiles":[%s]}\n' "$json" > "$pf"
	chown root:tproxy "$pf" 2>/dev/null || true; chmod 0400 "$pf"
	if ! /usr/local/bin/tproxy-server -config /etc/tproxy-server/config.json \
			-profiles-file "$pf" -check >/dev/null 2>&1; then
		err "Проверка конфигурации не прошла — откатываю."
		[[ -f "$pf.bak" ]] && mv -f "$pf.bak" "$pf"
		systemctl restart tproxy-server.service 2>/dev/null || true
		exit 1
	fi
	rm -f "$pf.bak"
	# MTProxy must know every new secret, otherwise those links die silently
	local natinfo=""; [[ -n "${ADTAG:-}" ]] && natinfo="$(compute_natinfo "${PUBIP:-}")"
	local -a secs; read -r -a secs <<< "$(secrets_of "$list")"
	write_mtproxy_config "${ADTAG:-}" "$natinfo" "${secs[@]}"
	systemctl restart mtproxy.service || warn "MTProxy не перезапустился — journalctl -u mtproxy"
	systemctl restart tproxy-server.service
	verify_mtproxy_secrets "$list"
	sed -i "s|^MODE=.*|MODE=\"$new\"|; s|^PROFILES=.*|PROFILES=\"$list\"|" "$INFO_FILE"
	grep -q '^MODE=' "$INFO_FILE" || printf 'MODE="%s"\n' "$new" >> "$INFO_FILE"
	grep -q '^PROFILES=' "$INFO_FILE" || printf 'PROFILES="%s"\n' "$list" >> "$INFO_FILE"
	ok "Режим переключён на $new. Активные сессии переподключатся."
	echo; show_link
}

# ---------------------------------------------------------------- ui helpers
W=78                                    # panel width (columns)
vlen(){ local s; s="$(printf '%s' "$1" | sed 's/\x1b\[[0-9;]*m//g')"; printf '%s' "${#s}"; }   # visible length
pad(){ local n; n="$(vlen "$1")"; if (( n >= $2 )); then printf '%s' "$1"; else printf '%s%*s' "$1" "$(( $2 - n ))" ''; fi; }
lr(){ local n; n=$(( ${3:-$W} - $(vlen "$1") - $(vlen "$2") )); (( n < 1 )) && n=1; printf '%s%*s%s' "$1" "$n" '' "$2"; }
hr(){ local s; printf -v s '%*s' "${1:-$W}" ''; printf '%s' "${s// /─}"; }
box(){ local l; printf '%s╭%s╮%s\n' "$DIM" "$(hr $((W-2)))" "$NC"
	for l in "$@"; do printf '%s│%s %s %s│%s\n' "$DIM" "$NC" "$(pad "$l" $((W-4)))" "$DIM" "$NC"; done
	printf '%s╰%s╯%s\n' "$DIM" "$(hr $((W-2)))" "$NC"; }
two(){ printf '  %s%s\n' "$(pad "$1" 38)" "$2"; }
three(){ printf '  %s%s%s\n' "$(pad "$1" 26)" "$(pad "$2" 26)" "$3"; }
title(){ printf '\n  %s%s%s\n  %s%s%s\n\n' "${CYAN}${BOLD}" "$1" "$NC" "$DIM" "$(hr "$(vlen "$1")")" "$NC"; }
dot(){ local st; st="$(systemctl is-active "$1" 2>/dev/null)" || true
	if [[ "$st" == active ]]; then printf '%s' "${GREEN}●${NC} $2"; else printf '%s' "${RED}○${NC} $2 ${DIM}${st:-?}${NC}"; fi; }
short_tag(){ local t="${1:-}"; if [[ ${#t} -gt 12 ]]; then printf '%s…%s' "${t:0:8}" "${t: -4}"; else printf '%s' "$t"; fi; }
METRICS=""     # /metrics snapshot, taken once per render
metric_of(){ awk -v n="$1" '$1==n{print $2; exit}' <<< "$METRICS"; }
nprof(){ set -- ${PROFILES:-x}; echo $#; }
vshort(){ awk 'NF>=2{printf "%.0f %s", $1, $2; next}{printf "%s", $0}' <<< "${1:-}"; }   # "428.83 MiB" -> "429 MiB"

# ---------------------------------------------------------------- dashboard
dashboard(){ # one screen: header box with a verdict, then two-column sections
	if [[ "${ROLE:-single}" == backend ]]; then dashboard_backend; return 0; fi
	local hz rz bad="" u n sl st sr mtc ti to IF vn upd drx dtx mrx mtx adt
	METRICS="$(curl -fsS --max-time 2 "$RELAY_ADMIN/metrics" 2>/dev/null || true)"
	if curl -fsS --max-time 2 "$RELAY_ADMIN/healthz" >/dev/null 2>&1; then hz="${GREEN}ok${NC}"; else hz="${RED}fail${NC}"; bad+="${bad:+, }healthz"; fi
	if curl -fsS --max-time 2 "$RELAY_ADMIN/readyz"  >/dev/null 2>&1; then rz="${GREEN}ready${NC}"; else rz="${RED}503${NC}"; bad+="${bad:+, }readyz"; fi
	local units="caddy:caddy tproxy-server:relay mtproxy:mtproxy tproxy-firewall:firewall refresh-mtproxy-config.timer:refresh" mtdot bkrow=""
	if [[ "$ROLE" == front ]]; then
		units="caddy:caddy tproxy-server:relay tgwp-backend.socket:backend tproxy-firewall:firewall"
		mtdot="$(dot tgwp-backend.socket backend)"
		if probe_tcp "${BACKEND:-0.0.0.0:0}"; then bkrow="backend     ${BACKEND}  ${GREEN}● туннель ok${NC}"; else bkrow="backend     ${BACKEND:-?}  ${RED}○ недоступен${NC}"; bad+="${bad:+, }backend"; fi
	else mtdot="$(dot mtproxy mtproxy)"; fi
	for u in $units; do
		n="${u#*:}"; u="${u%%:*}"; systemctl is-active --quiet "$u" >/dev/null 2>&1 || bad+="${bad:+, }$n"
	done
	refresh_version_cache; upd="$(cached_newer)"
	local verdict; if [[ -z "$bad" ]]; then verdict="${GREEN}● работает${NC}"; else verdict="${RED}○ проблемы: ${bad}${NC}"; fi
	box "$(lr "${CYAN}${BOLD}TELEGRAM WEB PROXY${NC}" "tgwebproxy ${TGWP_VERSION}${upd:+ ${YELLOW}→ ${upd}${NC}}" $((W-4)))" \
	    "$(lr "${GREEN}${HOSTNAME:-?}${NC}" "$verdict" $((W-4)))"
	sl="$(metric_of tproxy_sessions_live)"; st="$(metric_of tproxy_streams_live)"; sr="$(metric_of tproxy_streams_rejected_total)"
	mtc="$(mtstat total_special_connections)"
	echo
	two "${BLUE}${BOLD}СЛУЖБЫ${NC}"                                                         "${BLUE}${BOLD}ПОДКЛЮЧЕНИЯ${NC}"
	two "$(dot caddy caddy)   $(dot tproxy-server relay)   $mtdot"    "клиенты → caddy      $(conns sport 443)"
	if [[ "$ROLE" == front ]]; then two "$(dot tproxy-firewall firewall)" "caddy → relay        $(conns sport 8080)"
	else two "$(dot tproxy-firewall firewall)   $(dot refresh-mtproxy-config.timer refresh)" "caddy → relay        $(conns sport 8080)"; fi
	two "relay: healthz $hz  ·  readyz $rz"                                          "relay → mtproxy      $(conns dport 2398)"
	two ""                                                                           "сессий ${sl:-?}  ·  стримов ${st:-?}  ·  отказов ${sr:-0}${mtc:+  ·  users $mtc}"
	ensure_monitor; ti="$(nft_bytes tls_in)"; to="$(nft_bytes tls_out)"
	IF="$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')"
	drx=""; dtx=""; mrx=""; mtx=""
	if [[ -n "$IF" ]] && command -v vnstat >/dev/null 2>&1; then
		vn="$(vnstat --oneline -i "$IF" 2>/dev/null || true)"
		[[ "$vn" == 1\;* ]] && IFS=';' read -r _ _ _ drx dtx _ _ _ mrx mtx _ <<< "$vn"
		drx="$(vshort "$drx")"; dtx="$(vshort "$dtx")"; mrx="$(vshort "$mrx")"; mtx="$(vshort "$mtx")"
	fi
	if [[ -n "${ADTAG:-}" ]]; then adt="$(short_tag "$ADTAG")"; else adt="${DIM}нет${NC}"; fi
	echo
	two "${BLUE}${BOLD}ТРАФИК${NC}"                                                         "${BLUE}${BOLD}НАСТРОЙКИ${NC}"
	two "relay     ↑ $(h2h "$(metric_of tproxy_bytes_up_total)")   ↓ $(h2h "$(metric_of tproxy_bytes_down_total)")" "транспорт   ${MODE:-https}  ${DIM}($(nprof) проф.)${NC}"
	two ":443      вход $(h2h "${ti:-0}")   выход $(h2h "${to:-0}")"                 "AD_TAG      $adt"
	two "$(printf '%-9s' "${IF:-net}") сегодня ${drx:-?} / ${dtx:-?}"               "relay       ${REPO_REF:-?}  ${DIM}от ${INSTALLED_AT%% *}${NC}"
	two "          месяц   ${mrx:-?} / ${mtx:-?}"                                    "$bkrow"
}

dashboard_backend(){ # backend role: MTProxy only
	local bad="" u n mtc upd adt IF vn drx dtx trx ttx verdict
	for u in mtproxy:mtproxy tproxy-firewall:firewall refresh-mtproxy-config.timer:refresh; do
		n="${u#*:}"; u="${u%%:*}"; systemctl is-active --quiet "$u" >/dev/null 2>&1 || bad+="${bad:+, }$n"
	done
	refresh_version_cache; upd="$(cached_newer)"
	if [[ -z "$bad" ]]; then verdict="${GREEN}● работает${NC}"; else verdict="${RED}○ проблемы: ${bad}${NC}"; fi
	box "$(lr "${CYAN}${BOLD}TELEGRAM WEB PROXY${NC}  ${DIM}backend${NC}" "tgwebproxy ${TGWP_VERSION}${upd:+ ${YELLOW}→ ${upd}${NC}}" $((W-4)))" \
	    "$(lr "${GREEN}MTProxy ${TUNNEL_IP:-?}:2398${NC}  ${DIM}(${TUNNEL_IF:-туннель})${NC}" "$verdict" $((W-4)))"
	mtc="$(mtstat total_special_connections)"
	if [[ -n "${ADTAG:-}" ]]; then adt="$(short_tag "$ADTAG")"; else adt="${DIM}нет${NC}"; fi
	drx=""; dtx=""; trx=""; ttx=""
	IF="$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')"
	if command -v vnstat >/dev/null 2>&1; then
		[[ -n "$IF" ]] && { vn="$(vnstat --oneline -i "$IF" 2>/dev/null || true)"; [[ "$vn" == 1\;* ]] && IFS=';' read -r _ _ _ drx dtx _ <<< "$vn"; }
		[[ -n "${TUNNEL_IF:-}" ]] && { vn="$(vnstat --oneline -i "$TUNNEL_IF" 2>/dev/null || true)"; [[ "$vn" == 1\;* ]] && IFS=';' read -r _ _ _ trx ttx _ <<< "$vn"; }
	fi
	echo
	two "${BLUE}${BOLD}СЛУЖБЫ${NC}"                                                        "${BLUE}${BOLD}ПОДКЛЮЧЕНИЯ${NC}"
	two "$(dot mtproxy mtproxy)   $(dot tproxy-firewall firewall)   $(dot refresh-mtproxy-config.timer refresh)" "front → mtproxy      $(conns sport 2398)"
	two ""                                                                          "users MTProxy        ${mtc:-?}"
	echo
	two "${BLUE}${BOLD}ТРАФИК${NC}"                                                        "${BLUE}${BOLD}НАСТРОЙКИ${NC}"
	two "$(printf '%-9s' "${TUNNEL_IF:-tun}") сегодня $(vshort "$trx") / $(vshort "$ttx")"   "секретов    $(set -- ${SECRETS:-}; echo $#)"
	two "$(printf '%-9s' "${IF:-net}") сегодня $(vshort "$drx") / $(vshort "$dtx")"          "разрешено   ${ALLOW_FROM:-?}"
	two ""                                                                          "AD_TAG      $adt"
	two ""                                                                          "MTProxy     ${REPO_REF:-?}  ${DIM}от ${INSTALLED_AT%% *}${NC}"
}

show_status(){ # [--full]
	need_root status; load_info
	dashboard
	[[ "${1:-}" == "--full" || "${1:-}" == "-f" ]] || return 0
	echo; echo -e "${YELLOW}Метрики relay:${NC}"
	{ grep -E '^tproxy_' <<< "$METRICS" || echo "(недоступны)"; } | sed 's/^/  /'
	local IF; IF="$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')"
	if [[ -n "$IF" ]] && command -v vnstat >/dev/null 2>&1; then
		echo; echo -e "${YELLOW}vnstat по месяцам ($IF):${NC}"; vnstat -m -i "$IF" 2>/dev/null | sed 's/^/  /' || true
	fi
	[[ -n "${ADTAG:-}" ]] && { echo; warn "AD_TAG $ADTAG: для WEB-прокси показ спонсорского канала не гарантирован."; }
	return 0
}

do_watch(){ # live dashboard; q or Ctrl-C returns
	need_root watch; has_tty || { err "Нужен терминал."; exit 1; }
	local key STOP=""; trap 'STOP=1' INT
	while [[ -z "$STOP" ]]; do
		printf '\033[H\033[2J'; load_info; dashboard
		printf '\n  %sq%s %s— выход · обновление каждые 2 с%s ' "$BOLD" "$NC" "$DIM" "$NC"
		key=""; read -r -n1 -t 2 key </dev/tty 2>/dev/null || true
		[[ "$key" == [qQ] ]] && break
	done
	trap - INT; echo
}

# ---------------------------------------------------------------- interactive menu
pause(){ printf '\n  %s↵ Enter — назад в меню%s ' "$DIM" "$NC"; read -r _ </dev/tty 2>/dev/null || true; }
run_sub(){ # run an action in a subshell: Ctrl-C or `exit` inside it returns to the menu
	trap ' ' INT
	( trap - INT; "$@" ) || true
	trap 'printf "\n"; exit 0' INT
}
K="${YELLOW}${BOLD}"   # hotkey colour
menu(){
	need_root menu; has_tty || { err "Нужен терминал: используйте tgwebproxy status | link | …"; exit 1; }
	local key a
	trap 'printf "\n"; exit 0' INT
	while :; do
		load_info; printf '\033[H\033[2J'; dashboard
		echo
		if [[ "$ROLE" == backend ]]; then
		three "${BLUE}${BOLD}НАСТРОЙКИ${NC}"             "${BLUE}${BOLD}ОБСЛУЖИВАНИЕ${NC}"          "${BLUE}${BOLD}УТИЛИТА${NC}"
		three "${K}1${NC}  Секреты (с front)"     "${K}4${NC}  Перезапуск MTProxy"    "${K}7${NC}  Обновить утилиту"
		three "${K}2${NC}  Кому разрешено"        "${K}5${NC}  Журналы"               "${K}8${NC}  Удалить"
		three "${K}3${NC}  AD_TAG"                "${K}6${NC}  Обновить MTProxy"      "${K}0${NC}  Выход"
		else
		three "${BLUE}${BOLD}ПОДКЛЮЧЕНИЕ${NC}"           "${BLUE}${BOLD}ОБСЛУЖИВАНИЕ${NC}"          "${BLUE}${BOLD}УТИЛИТА${NC}"
		three "${K}1${NC}  Ссылки"                "${K}4${NC}  Перезапуск служб"      "${K}7${NC}  Обновить утилиту"
		three "${K}2${NC}  Тип подключения"       "${K}5${NC}  Журналы"               "${K}8${NC}  Удалить"
		three "${K}3${NC}  AD_TAG"                "${K}6${NC}  Обновить relay"        "${K}0${NC}  Выход"
		three "${K}b${NC}  Backend-хост"          ""                                  ""
		fi
		echo
		three "${K}s${NC}  Подробный статус"      "${K}w${NC}  Живой монитор"         ""
		printf '\n  %s›%s %sклавиша · панель обновляется сама%s ' "$BOLD" "$NC" "$DIM" "$NC"
		key=""; read -r -n1 -t 5 key </dev/tty 2>/dev/null || { [[ -n "$key" ]] || continue; }
		echo
		case "$key" in
			1) if [[ "$ROLE" == backend ]]; then run_sub do_secrets; else run_sub show_link; fi; pause ;;
			2) if [[ "$ROLE" == backend ]]; then run_sub do_allow; else run_sub do_mode; fi; pause ;;
			b|B) run_sub do_backend; pause ;;
			3) run_sub do_adtag; pause ;;
			4) run_sub do_restart; pause ;;
			5) msg "Ctrl-C — вернуться в меню"; run_sub do_logs ;;
			6) run_sub do_update; pause ;;
			7) run_sub show_version
			   a=""; read -r -p "  Обновить утилиту сейчас? [y/N]: " a </dev/tty 2>/dev/null || true
			   if [[ "$a" == [yYдД]* ]]; then
				run_sub do_self_update; msg "Запустите tgwebproxy заново, чтобы работать в новой версии."; pause; exit 0
			   fi ;;
			8) run_sub do_uninstall; [[ -x /usr/local/bin/tgwebproxy ]] || exit 0; pause ;;
			s|S) run_sub show_status --full; pause ;;
			w|W) run_sub do_watch ;;
			0|q|Q) echo; exit 0 ;;
		esac
	done
}

do_logs(){ need_root logs; load_info
	case "$ROLE" in backend) journalctl -u mtproxy -u tproxy-firewall -f --no-pager ;;
		front) journalctl -u tproxy-server -u tgwp-backend -u caddy -f --no-pager ;;
		*) journalctl -u tproxy-server -u mtproxy -u caddy -f --no-pager ;; esac; }

do_restart(){
	need_root restart; load_info
	msg "Перезапуск (клиентские сессии переподключатся автоматически)…"
	case "$ROLE" in backend) systemctl restart mtproxy.service ;;
		front) systemctl restart tgwp-backend.service tproxy-server.service caddy.service ;;
		*) systemctl restart mtproxy.service tproxy-server.service caddy.service ;; esac
	ok "Перезапущено."; show_status
}

do_update(){
	need_root update; load_info
	if [[ "$ROLE" == backend ]]; then
		msg "Обновляю репозиторий и MTProxy (пересборка только при смене закреплённого коммита)…"
		git -C "$REPO_DIR" pull --ff-only 2>/dev/null || warn "git pull не удался — использую текущую версию."
		if ( export PATH="$STATE_DIR/shim:$PATH"; cd "$REPO_DIR" && ./deploy/install-mtproxy.sh ) >> /var/log/tgwebproxy-install.log 2>&1; then
			chmod -R a+rX /opt/MTProxy 2>/dev/null || true; systemctl restart mtproxy.service && ok "MTProxy обновлён." || err "MTProxy не перезапустился — journalctl -u mtproxy"
		else err "Обновление не удалось — /var/log/tgwebproxy-install.log"; fi
		return 0
	fi
	[[ -x "${REPO_DIR:-/opt/tproxy-server-src}/deploy/update-relay.sh" ]] \
		|| { err "Нет ${REPO_DIR}/deploy/update-relay.sh"; exit 1; }
	msg "Обновляю репозиторий и relay (с авто-откатом при неудаче)…"
	git -C "$REPO_DIR" pull --ff-only 2>/dev/null || warn "git pull не удался — собираю текущую версию."
	if ( cd "$REPO_DIR" && ./deploy/update-relay.sh ); then
		local ref; ref="$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
		sed -i "s|^REPO_REF=.*|REPO_REF=\"$ref\"|" "$INFO_FILE" 2>/dev/null || true
		ok "Relay обновлён (коммит $ref)."
	else err "Обновление не удалось (откат выполнен автоматически)."; fi
}

do_adtag(){
	need_root adtag; load_info
	[[ "$ROLE" == front ]] && { err "AD_TAG задаётся на backend-хосте, где работает MTProxy."; exit 1; }
	title "AD_TAG — спонсорский канал"
	warn "Для WEB-прокси показ канала не гарантирован: MTProxy видит клиентов как 127.0.0.1, атрибуция по IP теряется."
	echo
	local bsec="${SECRET:-}"; bsec="${bsec#dd}"
	msg "Как получить тег (работающий прокси не нужен): @MTProxybot → /newproxy →"
	msg "  адрес ${GREEN}${HOSTNAME:-<домен front>}:443${NC} → секрет ${GREEN}${bsec:-$(secrets_list | cut -d" " -f1)}${NC} → тег (32 hex)."
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
		local -a secs; read -r -a secs <<< "$(secrets_list)"
		write_mtproxy_config "$new" "$natinfo" "${secs[@]}"
		if systemctl restart mtproxy.service 2>/dev/null; then
			sed -i "s|^ADTAG=.*|ADTAG=\"$new\"|" "$INFO_FILE"
			ok "AD_TAG установлен: $new (middle-proxy mode)."
		else
			err "MTProxy не запустился с этим тегом — откатываю."
			write_mtproxy_config "" "" "${secs[@]}"
			systemctl restart mtproxy.service || err "MTProxy не стартует — journalctl -u mtproxy"
			sed -i 's|^ADTAG=.*|ADTAG=""|' "$INFO_FILE"; exit 1
		fi
		verify_mtproxy_secrets "$(secrets_list)"
	else
		local -a secs; read -r -a secs <<< "$(secrets_list)"
		write_mtproxy_config "" "" "${secs[@]}"
		systemctl restart mtproxy.service
		sed -i 's|^ADTAG=.*|ADTAG=""|' "$INFO_FILE"
		ok "AD_TAG убран (direct relay mode)."
	fi
}

do_uninstall(){
	need_root uninstall
	title "Удаление Telegram WEB Proxy"
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
		tgmon-counters.service tgwp-backend.socket tgwp-backend.service 2>/dev/null || true
	systemctl unmask mtproxy.service 2>/dev/null || true

	msg "Удаляю firewall-таблицы…"
	nft delete table inet tproxy_backend 2>/dev/null || true
	nft delete table inet "$MON_TABLE" 2>/dev/null || true

	msg "Удаляю systemd-юниты…"
	rm -f /etc/systemd/system/{tproxy-server,mtproxy,tproxy-firewall,refresh-mtproxy-config}.service
	rm -f /etc/systemd/system/refresh-mtproxy-config.timer "$MON_UNIT" "$BK_SOCKET" "$BK_SERVICE"
	rm -rf /etc/systemd/system/mtproxy.service.d
	rm -f /etc/caddy/Caddyfile.tproxy
	rm -rf /opt/MTProxy.before-tproxy.*
	rm -f /usr/local/bin/tproxy-server /usr/local/bin/tproxy-server.previous /usr/local/bin/tproxy-server.next
	rm -f /usr/local/sbin/refresh-mtproxy-config
	rm -rf /etc/tproxy-server /etc/mtproxy /opt/MTProxy /opt/MTProxy.before-tproxy.* /opt/tproxy-server-src

	# Caddy: restore the OLDEST pre-tproxy backup (the user's true original)
	local cbak sbak
	if [[ "${ROLE:-single}" == backend ]]; then cbak="skip"; else
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
	title "tgwebproxy $TGWP_VERSION — управление Telegram WEB Proxy"
	echo "  Без аргументов открывается меню с живой панелью. Команды (нужен sudo):"
	echo
	echo -e "  ${BOLD}Подключение${NC}"
	echo -e "    ${GREEN}link${NC}                 ссылки подключения"
	echo -e "    ${GREEN}mode [режим]${NC}         тип подключения: https | https-lanes | websocket | websocket-lanes | all"
	echo -e "    ${GREEN}adtag [32hex|off]${NC}    спонсорский канал @MTProxybot (на backend-хосте в split-режиме)"
	echo -e "  ${BOLD}Split-режим${NC} (relay и MTProxy на разных хостах)"
	echo -e "    ${GREEN}backend [show|set <ip[:port]>|local]${NC}  куда relay отправляет трафик"
	echo -e "    ${GREEN}secrets [set '<s1 s2>']${NC}   backend: секреты, те же что на front"
	echo -e "    ${GREEN}allow [<ip/cidr,...>]${NC}     backend: кому открыт порт MTProxy"
	echo -e "  ${BOLD}Обслуживание${NC}"
	echo -e "    ${GREEN}status [--full]${NC}      панель состояния (--full: все метрики relay и таблица vnstat)"
	echo -e "    ${GREEN}watch${NC}                живая панель (q — выход)"
	echo -e "    ${GREEN}logs${NC}                 журналы relay, MTProxy и Caddy (follow)"
	echo -e "    ${GREEN}restart${NC}              перезапуск служб"
	echo -e "    ${GREEN}update${NC}               обновить relay из репозитория апстрима (с откатом)"
	echo -e "  ${BOLD}Утилита${NC}"
	echo -e "    ${GREEN}version${NC}              версия и проверка обновлений"
	echo -e "    ${GREEN}self-update [--force]${NC} обновить утилиту из опубликованного скрипта"
	echo -e "    ${GREEN}uninstall [--purge]${NC}  удалить (--purge: вместе с сайтом, сертификатами и пользователями)"
	echo
}

case "${1:-}" in
	"")         if has_tty; then menu; else show_status; fi ;;
	menu)       menu ;;
	status)     shift || true; show_status "${1:-}" ;;
	watch)      do_watch ;;
	link|links) show_link ;;
	mode)       shift || true; do_mode "$@" ;;
	logs)       do_logs ;;
	restart)    do_restart ;;
	update)     do_update ;;
	adtag|tag)  shift || true; do_adtag "$@" ;;
	backend)    shift || true; do_backend "$@" ;;
	secrets)    shift || true; do_secrets "$@" ;;
	allow)      shift || true; do_allow "$@" ;;
	uninstall)  shift || true; do_uninstall "${1:-}" ;;
	version|-v|--version) show_version ;;
	self-update|selfupdate) shift || true; do_self_update "${1:-}" ;;
	help|-h|--help) show_help ;;
	*) err "Неизвестная команда: $1"; show_help; exit 1 ;;
esac
UTILITY_EOF
	sed -i "s|@VERSION@|$TGWP_VERSION|; s|@URLS@|${SCRIPT_URLS[*]}|" "$MGMT.tmp"
	chmod 0755 "$MGMT.tmp"; mv -f "$MGMT.tmp" "$MGMT"
}

# =====================================================================
#  ENTRYPOINT
# =====================================================================
main() {
	local cmd="${1:-install}"
	case "$cmd" in
		install|"") do_install ;;
		menu|status|watch|link|links|mode|logs|restart|update|adtag|tag|backend|secrets|allow|uninstall|self-update|selfupdate)
			if [[ -x "$MGMT" ]]; then exec "$MGMT" "$@"
			else die "WEB-прокси ещё не установлен. Сначала запустите установку без аргументов."; fi ;;
		version|-v|--version)
			echo "tg-webproxy.sh $TGWP_VERSION"
			local r; r="$(remote_version || true)"
			if [[ -z "$r" ]]; then warn "Источники обновлений недоступны."
			elif ver_gt "${r%% *}" "$TGWP_VERSION"; then warn "Опубликована ${r%% *} (${r#* })."
			else ok "Это последняя версия."; fi ;;
		install-cli)   # internal: (re)generate /usr/local/bin/tgwebproxy only — used by `tgwebproxy self-update`
			[[ $EUID -eq 0 ]] || die "Нужен root."
			install_mgmt_cli; ok "tgwebproxy $TGWP_VERSION записан в $MGMT" ;;
		help|-h|--help)
			echo -e "${BLUE}${BOLD}Telegram WEB Proxy v$TGWP_VERSION — установщик${NC}\n"
			echo "Использование:"
			echo -e "  ${GREEN}bash <(wget -qO- ${SCRIPT_URLS[0]})${NC}            — установка"
			echo -e "  ${GREEN}bash <(wget -qO- ${SCRIPT_URLS[0]}) uninstall${NC}  — удаление"
			echo -e "  Документация: ${GREEN}https://github.com/DigneZzZ/tg-webproxy${NC}"
			echo
			echo -e "После установки — команда ${GREEN}tgwebproxy${NC}:"
			echo -e "  status | watch | link | mode | logs | restart | update | adtag | version | self-update | uninstall | help"
			echo
			echo "Env для non-interactive установки:"
			echo "  TGWP_HOSTNAME TGWP_EMAIL TGWP_SECRET TGWP_MODE TGWP_ADTAG"
			echo "  TGWP_WORKERS TGWP_MAXCONN TGWP_SITE_DIR TGWP_REF TGWP_YES=1"
			echo "  Split: TGWP_ROLE=front TGWP_BACKEND=ip:port  |  TGWP_ROLE=backend TGWP_SECRETS='s1 s2' TGWP_ALLOW_FROM=cidr,..."
			echo "  Блокировка core.telegram.org: файлы в /opt/tgwebproxy/tg/ или TGWP_TG_MIRROR=https://host/path"
			echo "  TGWP_SKIP_REACH=1 — не проверять доступность Telegram (на свой риск)" ;;
		*) die "Неизвестная команда '$cmd'. Справка: аргумент help" ;;
	esac
}

main "$@"
