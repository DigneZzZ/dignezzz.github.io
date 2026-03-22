#!/usr/bin/env bash
# Usage: ./check_reality_domain.sh <domain:port>
# This script checks if the given domain is suitable for use as an Xray Reality target.
# It verifies:
#   - Availability and average ping
#   - TLS1.3 support (with optional check for X25519)
#   - HTTP/2 and HTTP/3 support
#   - Redirect presence
#   - CDN usage (via headers, ASN, ssl certificate)
# Outputs a final verdict: "Suitable" or "Not suitable"

# Exit on unset variables or errors in pipeline
set -o nounset
set -o pipefail

# --- 1) Check arguments ---
if [ $# -lt 1 ]; then
  echo "Usage: $0 <domain:port>"
  exit 1
fi

# --- 2) Parse domain and port from argument ---
if [[ "$1" == *:* ]]; then
  host="${1%%:*}"
  port="${1##*:}"
else
  host="$1"
  port="443"
fi

if ! [[ "$port" =~ ^[0-9]+$ ]]; then
  echo "Error: Port must be numeric."
  exit 1
fi

echo "Target: $host:$port"

# --- 3) Resolve the domain to an IP ---
ip=""
if command -v getent >/dev/null 2>&1; then
  ip="$(getent hosts "$host" | awk '{ print $1; exit }')"
fi

if [ -z "$ip" ]; then
  if command -v dig >/dev/null 2>&1; then
    ip="$(dig +short "$host" | head -n1)"
  elif command -v host >/dev/null 2>&1; then
    ip="$(host -t A "$host" 2>/dev/null | awk '/has address/ {print $NF; exit}')"
    if [ -z "$ip" ]; then
      ip="$(host -t AAAA "$host" 2>/dev/null | awk '/has IPv6 address/ {print $NF; exit}')"
    fi
  fi
fi

if [ -z "$ip" ]; then
  ip="$(ping -c1 -W1 "$host" 2>/dev/null | head -n1 | awk -F'[()]' '{print $2}')"
fi

if [ -n "$ip" ]; then
  echo "Resolved IP: $ip"
else
  echo "Error: Unable to resolve domain $host."
  exit 1
fi

# --- 4) Ping check (availability + average latency) ---
avg_ping="N/A"
if [[ "$ip" == *:* ]]; then
  # IPv6 address
  if command -v ping6 >/dev/null 2>&1; then
    ping_cmd="ping6"
  else
    ping_cmd="ping -6"
  fi
else
  ping_cmd="ping"
fi

ping_output="$($ping_cmd -c4 -W2 "$ip" 2>/dev/null)"
if [ -n "$ping_output" ]; then
  if echo "$ping_output" | grep -q "0 received"; then
    echo "Ping: No response (100% packet loss)"
  else
    # Extract average round-trip time
    avg_ping=$(echo "$ping_output" | tail -1 | awk -F'/' '{print $5}')
    # Round the average ping to integer
    avg_ping=$(printf "%.0f" "${avg_ping}")
    echo "Ping: ${avg_ping} ms (average)"
  fi
else
  echo "Ping: Unable to ping host (no output)"
fi

# --- 5) Check TLS 1.3 support (forcing TLS1.3 handshake) ---
tls13_supported="No"
if echo | openssl s_client -connect "${host}:${port}" -tls1_3 -brief 2>/dev/null | grep -q "TLSv1.3"; then
  tls13_supported="Yes"
fi
echo "TLS 1.3 Supported: $tls13_supported"

# Optional: check X25519 usage
if [ "$tls13_supported" == "Yes" ]; then
  x25519_supported="No"
  if echo | openssl s_client -connect "${host}:${port}" -tls1_3 -curves X25519 -brief 2>/dev/null | grep -q "TLSv1.3"; then
    x25519_supported="Yes"
  fi
  echo "TLS 1.3 Key Exchange (X25519): $x25519_supported"
else
  echo "TLS 1.3 Key Exchange (X25519): N/A"
fi

# --- 6) Check HTTP/2, HTTP/3, Redirects ---
headers="$(curl -s -I --connect-timeout 5 --max-time 10 "https://$host:$port")"
if [ -z "$headers" ]; then
  echo "HTTP request: No response (unable to connect or fetch headers)"
  http2_supported="No"
  http3_supported="No"
  redirect="No"
else
  # HTTP/2 detection
  http2_supported="No"
  if echo "$headers" | head -1 | grep -q '^HTTP/2'; then
    http2_supported="Yes"
  fi
  echo "HTTP/2 Supported: $http2_supported"

  # HTTP/3 detection via Alt-Svc
  http3_supported="No"
  if echo "$headers" | grep -qi 'alt-svc: .*h3'; then
    http3_supported="Yes"
  fi
  echo "HTTP/3 Supported (Alt-Svc): $http3_supported"

  # Redirect detection (looking for 3xx status + Location header)
  redirect="No"
  if echo "$headers" | head -1 | grep -qE 'HTTP/.* 30[1-7]'; then
    redirect="Yes"
    # Extract Location header if any
    location_header=$(echo "$headers" | awk 'tolower($1) == "location:" { $1=""; print substr($0,2)}' | tr -d '\r')
    if [ -z "$location_header" ]; then
      location_header="(No Location header found)"
    fi
    echo "Redirect: Yes -> $location_header"
  else
    echo "Redirect: No"
  fi
fi

# --- 7) CDN detection ---
cdn_detected="No"
cdn_provider=""

headers_lc="$(echo "$headers" | tr '[:upper:]' '[:lower:]')"
org_info=""
if command -v curl >/dev/null 2>&1; then
  org_info="$(curl -s --connect-timeout 5 --max-time 8 "https://ipinfo.io/${ip}/org" || true)"
fi
org_info_lc="$(echo "$org_info" | tr '[:upper:]' '[:lower:]')"

cert_info="$(echo | openssl s_client -connect "${host}:${port}" -servername "$host" 2>/dev/null | openssl x509 -noout -issuer -subject 2>/dev/null)"
cert_info_lc="$(echo "$cert_info" | tr '[:upper:]' '[:lower:]')"

# Объединим все строки в один блок (headers + org_info + cert_info)
combined_info="$headers_lc $org_info_lc $cert_info_lc"

if echo "$combined_info" | grep -qE "cloudflare|cf-ray"; then
  cdn_detected="Yes"
  cdn_provider="Cloudflare"
elif echo "$combined_info" | grep -qE "akamai|akamai.?technologies"; then
  cdn_detected="Yes"
  cdn_provider="Akamai"
elif echo "$combined_info" | grep -q "fastly"; then
  cdn_detected="Yes"
  cdn_provider="Fastly"
elif echo "$combined_info" | grep -qE "incapsula|imperva"; then
  cdn_detected="Yes"
  cdn_provider="Imperva Incapsula"
elif echo "$combined_info" | grep -q "sucuri"; then
  cdn_detected="Yes"
  cdn_provider="Sucuri"
elif echo "$combined_info" | grep -qE "stackpath|highwinds"; then
  cdn_detected="Yes"
  cdn_provider="StackPath/Highwinds"
elif echo "$combined_info" | grep -q "cdn77"; then
  cdn_detected="Yes"
  cdn_provider="CDN77"
elif echo "$combined_info" | grep -q "edgecast"; then
  cdn_detected="Yes"
  cdn_provider="Verizon Edgecast"
elif echo "$combined_info" | grep -q "keycdn"; then
  cdn_detected="Yes"
  cdn_provider="KeyCDN"
elif echo "$combined_info" | grep -qE "microsoft|azure"; then
  cdn_detected="Yes"
  cdn_provider="Microsoft Azure CDN"
elif echo "$combined_info" | grep -q "alibaba"; then
  cdn_detected="Yes"
  cdn_provider="Alibaba Cloud CDN"
elif echo "$combined_info" | grep -q "tencent"; then
  cdn_detected="Yes"
  cdn_provider="Tencent Cloud CDN"
elif echo "$combined_info" | grep -qE "vk|vkontakte|mail\\.ru"; then
  cdn_detected="Yes"
  cdn_provider="VK (Mail.ru)"
elif echo "$combined_info" | grep -q "bunnycdn"; then
  cdn_detected="Yes"
  cdn_provider="BunnyCDN"
elif echo "$combined_info" | grep -q "gcorelabs"; then
  cdn_detected="Yes"
  cdn_provider="G-Core Labs"
elif echo "$combined_info" | grep -qE "arvancloud"; then
  cdn_detected="Yes"
  cdn_provider="ArvanCloud"
elif echo "$combined_info" | grep -qE "verizon|level3|centurylink|limelight|lumen"; then
  cdn_detected="Yes"
  cdn_provider="Verizon/Level3/Limelight (Lumen)"
fi

if [ "$cdn_detected" == "Yes" ]; then
  echo "CDN Detected: $cdn_provider"
else
  echo "CDN Detected: No"
fi


# --- 8) Final verdict ---
# Reality typically requires:
#   - TLS 1.3
#   - HTTP/2
#   - No CDN
verdict="Suitable"
if [ "$tls13_supported" != "Yes" ] || [ "$http2_supported" != "Yes" ] || [ "$cdn_detected" == "Yes" ]; then
  verdict="Not suitable"
fi

echo "Final Verdict: $verdict for Xray Reality"
