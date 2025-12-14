#!/usr/bin/env bash
# Usage: ./check_sni.sh <domain>
#
# Скрипт проверяет пригодность домена как SNI для Xray Reality:
#   1) DNS (A/AAAA), проверка приватных IP
#   2) Пинг по первому IP
#   3) TLS 1.3 и X25519
#   4) HTTP/2, HTTP/3, редиректы
#   5) Поиск CDN (заголовки + whois + ipinfo)
# В конце показывает плюсы/минусы и рекомендуемые SNI.
#
# Cтремимся к совместимости с:
#   - CentOS / RHEL
#   - Debian / Ubuntu
#   - (другие дистрибутивы, совместимые с yum или apt-get)
#
# При отсутствии нужных пакетов устанавливает их, выводя только мини-информацию.
#
# Убедитесь, что имеются права sudo, если нужно доустанавливать пакеты.

GREEN="\033[32m"
RED="\033[31m"
CYAN="\033[36m"
YELLOW="\033[33m"
RESET="\033[0m"

if [ -z "$1" ]; then
  echo -e "${RED}Usage: $0 <domain>${RESET}"
  exit 1
fi

DOMAIN="$1"
positives=()
negatives=()

#########################################################
# Определение пакетного менеджера
#########################################################
function detect_package_manager() {
  if [ -f /etc/redhat-release ] || grep -iq 'centos' /etc/os-release 2>/dev/null; then
    PKG_MGR="yum"
  else
    PKG_MGR="apt-get"
  fi
}

detect_package_manager

#########################################################
# Установка пакетов по необходимости (минимальный вывод)
#########################################################
function check_and_install_command() {
  local cmd="$1"
  if ! command -v "$cmd" &>/dev/null; then
    echo "Installing $cmd..."
    if [ "$PKG_MGR" = "yum" ]; then
      sudo yum install -y "$cmd" >/dev/null 2>&1
    else
      sudo apt-get update -y >/dev/null 2>&1
      sudo apt-get install -y "$cmd" >/dev/null 2>&1
    fi
    if ! command -v "$cmd" &>/dev/null; then
      echo -e "${RED}Failed to install '$cmd'. Please install it manually.${RESET}"
      exit 1
    else
      echo "$cmd installed successfully."
    fi
  fi
}

# Список команд, которые нужны
NEEDED_CMDS=(openssl curl dig whois ping)
for cmd in "${NEEDED_CMDS[@]}"; do
  check_and_install_command "$cmd"
done

#########################################################
# 1) Проверка DNS
#########################################################
dns_ips_v4=$(dig +short A "$DOMAIN" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
dns_ips_v6=$(dig +short AAAA "$DOMAIN" | grep -E '^[0-9A-Fa-f:]+$')

if [ -z "$dns_ips_v4" ] && [ -z "$dns_ips_v6" ]; then
  negatives+=("DNS: домен не разрешается")
else
  local_v4count=$(echo "$dns_ips_v4" | sed '/^$/d' | wc -l)
  local_v6count=$(echo "$dns_ips_v6" | sed '/^$/d' | wc -l)
  positives+=("DNS: найдено $local_v4count A-записей, $local_v6count AAAA-записей")

  # Проверка приватных IP
  for ip in $dns_ips_v4 $dns_ips_v6; do
    if [[ "$ip" =~ ^10\.|^192\.168\.|^172\.(1[6-9]|2[0-9]|3[0-1])\.|^127\.|^169\.254\. ]]; then
      negatives+=("DNS: приватный IPv4 ($ip)")
    elif [[ "$ip" =~ ^fc00:|^fd00:|^fe80:|^::1$ ]]; then
      negatives+=("DNS: приватный IPv6 ($ip)")
    fi
  done
fi

#########################################################
# 2) Пинг (берём первый доступный IP)
#########################################################
first_ip=""
if [ -n "$dns_ips_v4" ]; then
  first_ip=$(echo "$dns_ips_v4" | head -n1)
elif [ -n "$dns_ips_v6" ]; then
  first_ip=$(echo "$dns_ips_v6" | head -n1)
fi

if [ -n "$first_ip" ]; then
  if [[ "$first_ip" =~ : ]]; then
    # IPv6
    if command -v ping6 &>/dev/null; then
      ping_cmd="ping6"
    else
      ping_cmd="ping -6"
    fi
  else
    ping_cmd="ping"
  fi

  # Отправим 4 пакета, таймаут ~1с
  ping_out=$($ping_cmd -c4 -W1 "$first_ip" 2>/dev/null)
  if [ $? -eq 0 ]; then
    # Проверяем потери
    if echo "$ping_out" | grep -q " 0% packet loss"; then
      avg_rtt=$(echo "$ping_out" | awk -F'/' '/rtt/ {print $5}')
      positives+=("Ping: средний RTT ${avg_rtt} ms")
    else
      negatives+=("Ping: частичные потери (не все ответы)")
    fi
  else
    negatives+=("Ping: узел не отвечает")
  fi
else
  negatives+=("Ping: нет IP для проверки")
fi

#########################################################
# 3) Проверка TLS 1.3 и X25519
#########################################################
openssl_out=$(echo | timeout 5 openssl s_client -connect "$DOMAIN:443" -servername "$DOMAIN" -tls1_3 2>&1)
if echo "$openssl_out" | grep -q "Protocol  : TLSv1.3"; then
  positives+=("TLS 1.3: поддерживается")
  if echo "$openssl_out" | grep -q "Server Temp Key: X25519"; then
    positives+=("X25519: поддерживается")
  else
    x25519_out=$(echo | timeout 5 openssl s_client -connect "$DOMAIN:443" -servername "$DOMAIN" -tls1_3 -curves X25519 2>&1)
    if echo "$x25519_out" | grep -q "Protocol  : TLSv1.3"; then
      positives+=("X25519: поддерживается")
    else
      negatives+=("X25519: не поддерживается")
    fi
  fi
else
  negatives+=("TLS 1.3: не поддерживается")
fi

#########################################################
# 4) Проверка HTTP/2, HTTP/3, редиректов
#########################################################
curl_headers=$(curl -sIk --max-time 8 "https://${DOMAIN}")
if [ -z "$curl_headers" ]; then
  negatives+=("HTTP: нет ответа (timeout/ошибка)")
else
  first_line=$(echo "$curl_headers" | head -n1)
  if echo "$first_line" | grep -q "HTTP/2"; then
    positives+=("HTTP/2: поддерживается")
  else
    negatives+=("HTTP/2: не поддерживается")
  fi

  if echo "$curl_headers" | grep -qi "^alt-svc: .*h3"; then
    positives+=("HTTP/3: поддерживается")
  else
    negatives+=("HTTP/3: не поддерживается")
  fi

  # Проверка, не 3xx ли код
  status_code=$(echo "$first_line" | awk '{print $2}')
  if [[ "$status_code" =~ ^3[0-9]{2}$ ]]; then
    loc=$(echo "$curl_headers" | grep -i '^Location:' | sed 's/Location: //i')
    if [ -n "$loc" ]; then
      negatives+=("Редирект: есть -> $loc")
    else
      negatives+=("Редирект: есть")
    fi
  else
    positives+=("Редиректов нет")
  fi
fi

#########################################################
# 5) Проверка CDN
#########################################################
combined_info="$curl_headers"$'\n'"$openssl_out"

if [ -n "$first_ip" ]; then
  whois_out=$(timeout 5 whois "$first_ip" 2>/dev/null || true)
  combined_info+=$'\n'"$whois_out"
  ipinfo_org=$(curl -s --max-time 5 "https://ipinfo.io/$first_ip/org" || true)
  combined_info+=$'\n'"$ipinfo_org"
fi

combined_lc=$(echo "$combined_info" | tr '[:upper:]' '[:lower:]')

cdns=(
  "\\bcloudflare\\b"
  "\\bakamai\\b"
  "\\bfastly\\b"
  "\\bincapsula\\b"
  "\\bimperva\\b"
  "\\bsucuri\\b"
  "\\bstackpath\\b"
  "\\bcdn77\\b"
  "\\bedgecast\\b"
  "\\bkeycdn\\b"
  "\\bazure\\b"
  "\\btencent\\b"
  "\\balibaba\\b"
  "\\baliyun\\b"
  "bunnycdn"
  "\\barvan\\b"
  "\\bg-core\\b"
  "\\bmail\\.ru\\b"
  "\\bmailru\\b"
  "\\bvk\\.com\\b"
  "\\bvk\\b"
  "\\blimelight\\b"
  "\\blumen\\b"
  "\\blevel[[:space:]]?3\\b"
  "\\bcenturylink\\b"
  "\\bcloudfront\\b"
  "\\bverizon\\b"
)

cdn_detected=""
cdn_name=""
for pattern in "${cdns[@]}"; do
  if echo "$combined_lc" | grep -Eq "$pattern"; then
    cdn_detected="$pattern"
    case "$pattern" in
      *cloudflare*) cdn_name="Cloudflare" ;;
      *akamai*) cdn_name="Akamai" ;;
      *fastly*) cdn_name="Fastly" ;;
      *incapsula*|*imperva*) cdn_name="Imperva Incapsula" ;;
      *sucuri*) cdn_name="Sucuri" ;;
      *stackpath*) cdn_name="StackPath" ;;
      *cdn77*) cdn_name="CDN77" ;;
      *edgecast*|*verizon*) cdn_name="Verizon EdgeCast" ;;
      *keycdn*) cdn_name="KeyCDN" ;;
      *azure*) cdn_name="Azure CDN" ;;
      *tencent*) cdn_name="Tencent CDN" ;;
      *alibaba*|*aliyun*) cdn_name="Alibaba CDN" ;;
      *bunnycdn*) cdn_name="BunnyCDN" ;;
      *arvan*) cdn_name="ArvanCloud" ;;
      *g-core*) cdn_name="G-Core Labs" ;;
      *mail\.ru*|*mailru*) cdn_name="Mail.ru (VK) CDN" ;;
      *vk\.com*) cdn_name="VK CDN" ;;
      *vk*) cdn_name="VK CDN" ;;
      *limelight*) cdn_name="Limelight" ;;
      *lumen*) cdn_name="Lumen (CenturyLink)" ;;
      *level[[:space:]]?3*) cdn_name="Level3/CenturyLink" ;;
      *centurylink*) cdn_name="CenturyLink" ;;
      *cloudfront*) cdn_name="Amazon CloudFront" ;;
      *) cdn_name="$pattern" ;;
    esac
    break
  fi
done

if [ -n "$cdn_detected" ]; then
  negatives+=("CDN: обнаружена ($cdn_name)")
else
  positives+=("CDN: не обнаружена")
fi

#########################################################
# 6) Вывод результатов
#########################################################
echo -e "\n${CYAN}===== РЕЗУЛЬТАТЫ ПРОВЕРКИ SNI =====${RESET}"

if [ ${#positives[@]} -eq 0 ]; then
  echo -e "${GREEN}Положительные аспекты: нет${RESET}"
else
  echo -e "${GREEN}Положительные аспекты:${RESET}"
  for p in "${positives[@]}"; do
    echo -e "  - $p"
  done
fi

if [ ${#negatives[@]} -eq 0 ]; then
  echo -e "${GREEN}\nНедостатки: нет${RESET}"
else
  echo -e "${RED}\nНедостатки:${RESET}"
  for n in "${negatives[@]}"; do
    echo -e "  - $n"
  done
fi

echo -e "\n${CYAN}===== ВОЗМОЖНЫЕ ПУБЛИЧНЫЕ SNI (без Microsoft/Amazon/WhatsApp) =====${RESET}"
echo -e "${GREEN}- gateway.icloud.com${RESET} (Apple iCloud, узлы в Европе)"
echo -e "${GREEN}- www.dropbox.com${RESET} (Dropbox, безопасный и популярный)"
echo -e "${GREEN}- www.wikipedia.org${RESET} (Wikipedia, нейтральный, с HTTP/2/3, но может быть высокий пинг)"
exit 0
