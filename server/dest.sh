#!/bin/bash

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
CYAN="\033[36m"
RESET="\033[0m"

PING_RESULT=false
TLS_RESULT=false
CDN_RESULT=false

function check_and_install_command() {
  if ! command -v $1 &> /dev/null; then
    echo -e "${YELLOW}Utility $1 not found. Installing...${RESET}"
    sudo apt-get install -y $1 > /dev/null 2>&1
    if ! command -v $1 &> /dev/null; then
      echo -e "${RED}Error: failed to install $1. Please install it manually.${RESET}"
      exit 1
    fi
  fi
}

function check_host_port() {
  echo -e "${CYAN}Checking availability of $HOSTNAME on port $PORT...${RESET}"
  timeout 5 bash -c "</dev/tcp/$HOSTNAME/$PORT" &>/dev/null
  if [ $? -eq 0 ]; then
    echo -e "${GREEN}Host $HOSTNAME:$PORT is available${RESET}"
    HOST_PORT_AVAILABLE=true
  else
    echo -e "${YELLOW}Host $HOSTNAME:$PORT is unavailable${RESET}"
    HOST_PORT_AVAILABLE=false
  fi
}

function check_tls() {
  if [ "$PORT" == "443" ]; then
    echo -e "${CYAN}Checking TLS support for $HOSTNAME:$PORT...${RESET}"
    tls_version=$(echo | timeout 5 openssl s_client -connect $HOSTNAME:$PORT -tls1_3 2>/dev/null | grep "TLSv1.3")
    if [[ -n $tls_version ]]; then
      echo -e "${GREEN}TLS 1.3 is supported${RESET}"
      TLS_RESULT=true
    else
      tls_version=$(echo | timeout 5 openssl s_client -connect $HOSTNAME:$PORT 2>/dev/null | grep "Protocol" | awk '{print $2}')
      if [ -n "$tls_version" ]; then
        echo -e "${YELLOW}TLS 1.3 not supported. Using version: ${tls_version}${RESET}"
      else
        echo -e "${RED}Failed to detect TLS version${RESET}"
      fi
      TLS_RESULT=false
    fi
  else
    TLS_RESULT=true
  fi
}

function check_http_version() {
  echo -e "${CYAN}Checking HTTP support for $DOMAIN...${RESET}"

  HTTP2_SUPPORTED=false
  HTTP3_SUPPORTED=false

  http2_check=$(curl -I -s --max-time 5 --http2 https://$DOMAIN -H "User-Agent: Mozilla/5.0" 2>/dev/null | grep -i "^HTTP/2")
  if [[ -n $http2_check ]]; then
    echo -e "${GREEN}HTTP/2 is supported (via curl)${RESET}"
    HTTP2_SUPPORTED=true
  else
    echo -e "${YELLOW}HTTP/2 is not supported (via curl)${RESET}"
  fi

  if [ "$HTTP2_SUPPORTED" != "true" ]; then
    alpn_protocols=$(echo | timeout 5 openssl s_client -alpn h2 -connect $DOMAIN:443 2>/dev/null | grep "ALPN protocol")
    if echo "$alpn_protocols" | grep -q "protocols:.*h2"; then
      echo -e "${GREEN}HTTP/2 is supported (via openssl)${RESET}"
      HTTP2_SUPPORTED=true
    else
      echo -e "${YELLOW}HTTP/2 is not supported (via openssl)${RESET}"
    fi

    if command -v nghttp &> /dev/null; then
      nghttp_output=$(timeout 5 nghttp -nv https://$DOMAIN 2>&1)
      if echo "$nghttp_output" | grep -q "The negotiated protocol: h2"; then
        echo -e "${GREEN}HTTP/2 is supported (via nghttp)${RESET}"
        HTTP2_SUPPORTED=true
      else
        echo -e "${YELLOW}HTTP/2 is not supported (via nghttp)${RESET}"
      fi
    else
      sudo apt-get install -y nghttp2-client > /dev/null 2>&1
      if command -v nghttp &> /dev/null; then
        nghttp_output=$(timeout 5 nghttp -nv https://$DOMAIN 2>&1)
        if echo "$nghttp_output" | grep -q "The negotiated protocol: h2"; then
          echo -e "${GREEN}HTTP/2 is supported (via nghttp)${RESET}"
          HTTP2_SUPPORTED=true
        else
          echo -e "${YELLOW}HTTP/2 is not supported (via nghttp)${RESET}"
        fi
      else
        echo -e "${RED}Failed to install nghttp for HTTP/2 check${RESET}"
      fi
    fi
  fi

  alpn_protocols=$(echo | timeout 5 openssl s_client -alpn h3 -connect $DOMAIN:443 2>/dev/null | grep "ALPN protocol")
  if echo "$alpn_protocols" | grep -iq "protocols:.*h3"; then
    echo -e "${GREEN}HTTP/3 is supported (via openssl)${RESET}"
    HTTP3_SUPPORTED=true
  else
    echo -e "${YELLOW}HTTP/3 is not supported (via openssl)${RESET}"
  fi

  if [ "$HTTP2_SUPPORTED" == "true" ]; then
    echo -e "${GREEN}Conclusion: HTTP/2 is supported${RESET}"
  else
    echo -e "${RED}Conclusion: HTTP/2 is not supported${RESET}"
  fi

  if [ "$HTTP3_SUPPORTED" == "true" ]; then
    echo -e "${GREEN}Conclusion: HTTP/3 is supported${RESET}"
  else
    echo -e "${YELLOW}Conclusion: HTTP/3 is not supported or couldn't be determined${RESET}"
  fi

  if [ "$HTTP2_SUPPORTED" == "true" ]; then
    HTTP_RESULT=true
  else
    HTTP_RESULT=false
  fi
}

function calculate_average_ping() {
  echo -e "${CYAN}Calculating average ping to $HOSTNAME...${RESET}"
  ping_output=$(ping -c 5 -q $HOSTNAME)
  if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to ping $HOSTNAME${RESET}"
    PING_RESULT=false
    avg_ping=1000
  else
    avg_ping=$(echo "$ping_output" | grep "rtt" | awk -F '/' '{print $5}')
    echo -e "${GREEN}Average ping: ${avg_ping} ms${RESET}"
    PING_RESULT=true
  fi
}
function check_redirect() {
  echo -e "${CYAN}Checking for redirects for $DOMAIN...${RESET}"
  redirect_check=$(curl -s -o /dev/null -w "%{redirect_url}" --max-time 5 https://$DOMAIN)
  if [ -n "$redirect_check" ]; then
    echo -e "${YELLOW}Redirect found: $redirect_check${RESET}"
    REDIRECT_RESULT=true
  else
    echo -e "${GREEN}No redirect found${RESET}"
    REDIRECT_RESULT=false
  fi
}
function determine_rating() {
  if [ "$PING_RESULT" = true ]; then
    if (( $(echo "$avg_ping < 2" | bc -l) )); then
      RATING=5
    elif (( $(echo "$avg_ping >= 2 && $avg_ping < 3" | bc -l) )); then
      RATING=4
    elif (( $(echo "$avg_ping >= 3 && $avg_ping < 5" | bc -l) )); then
      RATING=3
    elif (( $(echo "$avg_ping >= 5 && $avg_ping < 8" | bc -l) )); then
      RATING=2
    else
      RATING=1
    fi
    echo -e "${CYAN}Ping-based rating: ${RATING}/5${RESET}"
  else
    echo -e "${YELLOW}Failed to determine ping, setting rating to 0${RESET}"
    RATING=0
  fi
}

function check_cdn_headers() {
  echo -e "${CYAN}Analyzing HTTP headers for CDN...${RESET}"
  headers=$(curl -s -I --max-time 5 https://$DOMAIN)

  if echo "$headers" | grep -iq "cloudflare"; then
    echo -e "${YELLOW}CDN detected: Cloudflare (by headers)${RESET}"
    CDN_RESULT=true
  elif echo "$headers" | grep -iq "akamai"; then
    echo -e "${YELLOW}CDN detected: Akamai (by headers)${RESET}"
    CDN_RESULT=true
  elif echo "$headers" | grep -iq "fastly"; then
    echo -e "${YELLOW}CDN detected: Fastly (by headers)${RESET}"
    CDN_RESULT=true
  elif echo "$headers" | grep -iq "incapsula"; then
    echo -e "${YELLOW}CDN detected: Imperva Incapsula (by headers)${RESET}"
    CDN_RESULT=true
  elif echo "$headers" | grep -iq "sucuri"; then
    echo -e "${YELLOW}CDN detected: Sucuri (by headers)${RESET}"
    CDN_RESULT=true
  elif echo "$headers" | grep -iq "stackpath"; then
    echo -e "${YELLOW}CDN detected: StackPath (by headers)${RESET}"
    CDN_RESULT=true
  elif echo "$headers" | grep -iq "cdn77"; then
    echo -e "${YELLOW}CDN detected: CDN77 (by headers)${RESET}"
    CDN_RESULT=true
  elif echo "$headers" | grep -iq "edgecast"; then
    echo -e "${YELLOW}CDN detected: Verizon Edgecast (by headers)${RESET}"
    CDN_RESULT=true
  elif echo "$headers" | grep -iq "keycdn"; then
    echo -e "${YELLOW}CDN detected: KeyCDN (by headers)${RESET}"
    CDN_RESULT=true
  elif echo "$headers" | grep -iq "azurecdn"; then
    echo -e "${YELLOW}CDN detected: Microsoft Azure CDN (by headers)${RESET}"
    CDN_RESULT=true
  elif echo "$headers" | grep -iq "cdn"; then
    echo -e "${YELLOW}CDN detected (by headers)${RESET}"
    CDN_RESULT=true
  else
    echo -e "${GREEN}No CDN detected by headers${RESET}"
  fi
}

function check_cdn_asn() {
  echo -e "${CYAN}Checking ASN for CDN...${RESET}"
  ip=$(dig +short $DOMAIN | head -n1)
  if [ -z "$ip" ]; then
    echo -e "${RED}Failed to retrieve domain IP address${RESET}"
    return
  fi
  asn_info=$(whois -h whois.cymru.com " -v $ip" 2>/dev/null | tail -n1)
  asn=$(echo $asn_info | awk '{print $1}')
  owner=$(echo $asn_info | awk '{$1=""; $2=""; print $0}' | sed 's/^[ \t]*//')

  if echo "$owner" | grep -iq "Cloudflare"; then
    echo -e "${YELLOW}CDN detected: Cloudflare (by ASN)${RESET}"
    CDN_RESULT=true
  elif echo "$owner" | grep -iq "Akamai"; then
    echo -e "${YELLOW}CDN detected: Akamai (by ASN)${RESET}"
    CDN_RESULT=true
  elif echo "$owner" | grep -iq "Fastly"; then
    echo -e "${YELLOW}CDN detected: Fastly (by ASN)${RESET}"
    CDN_RESULT=true
  elif echo "$owner" | grep -iq "Microsoft"; then
    echo -e "${YELLOW}CDN detected: Microsoft Azure CDN (by ASN)${RESET}"
    CDN_RESULT=true
  elif echo "$owner" | grep -iq "Incapsula"; then
    echo -e "${YELLOW}CDN detected: Imperva Incapsula (by ASN)${RESET}"
    CDN_RESULT=true
  elif echo "$owner" | grep -iq "Sucuri"; then
    echo -e "${YELLOW}CDN detected: Sucuri (by ASN)${RESET}"
    CDN_RESULT=true
  elif echo "$owner" | grep -iq "StackPath"; then
    echo -e "${YELLOW}CDN detected: StackPath (by ASN)${RESET}"
    CDN_RESULT=true
  elif echo "$owner" | grep -iq "CDN77"; then
    echo -e "${YELLOW}CDN detected: CDN77 (by ASN)${RESET}"
    CDN_RESULT=true
  elif echo "$owner" | grep -iq "Edgecast"; then
    echo -e "${YELLOW}CDN detected: Verizon Edgecast (by ASN)${RESET}"
    CDN_RESULT=true
  elif echo "$owner" | grep -iq "KeyCDN"; then
    echo -e "${YELLOW}CDN detected: KeyCDN (by ASN)${RESET}"
    CDN_RESULT=true
  elif echo "$owner" | grep -iq "Alibaba"; then
    echo -e "${YELLOW}CDN detected: Alibaba Cloud CDN (by ASN)${RESET}"
    CDN_RESULT=true
  elif echo "$owner" | grep -iq "Tencent"; then
    echo -e "${YELLOW}CDN detected: Tencent Cloud CDN (by ASN)${RESET}"
    CDN_RESULT=true
  else
    echo -e "${GREEN}No CDN detected by ASN${RESET}"
  fi
}

function check_cdn_ipinfo() {
  echo -e "${CYAN}Using ipinfo.io for CDN detection...${RESET}"
  check_and_install_command jq
  ip=$(dig +short $DOMAIN | head -n1)
  if [ -z "$ip" ]; then
    echo -e "${RED}Failed to retrieve domain IP address${RESET}"
    return
  fi
  json=$(curl -s --max-time 5 https://ipinfo.io/$ip/json)
  org=$(echo $json | jq -r '.org')

  if echo "$org" | grep -iq "Cloudflare"; then
    echo -e "${YELLOW}CDN detected: Cloudflare (via ipinfo.io)${RESET}"
    CDN_RESULT=true
  elif echo "$org" | grep -iq "Akamai"; then
    echo -e "${YELLOW}CDN detected: Akamai (via ipinfo.io)${RESET}"
    CDN_RESULT=true
  elif echo "$org" | grep -iq "Fastly"; then
    echo -e "${YELLOW}CDN detected: Fastly (via ipinfo.io)${RESET}"
    CDN_RESULT=true
  elif echo "$org" | grep -iq "Incapsula"; then
    echo -e "${YELLOW}CDN detected: Imperva Incapsula (via ipinfo.io)${RESET}"
    CDN_RESULT=true
  elif echo "$org" | grep -iq "Sucuri"; then
    echo -e "${YELLOW}CDN detected: Sucuri (via ipinfo.io)${RESET}"
    CDN_RESULT=true
  elif echo "$org" | grep -iq "Microsoft"; then
    echo -e "${YELLOW}CDN detected: Microsoft Azure CDN (via ipinfo.io)${RESET}"
    CDN_RESULT=true
  elif echo "$org" | grep -iq "StackPath"; then
    echo -e "${YELLOW}CDN detected: StackPath (via ipinfo.io)${RESET}"
    CDN_RESULT=true
  elif echo "$org" | grep -iq "CDN77"; then
    echo -e "${YELLOW}CDN detected: CDN77 (via ipinfo.io)${RESET}"
    CDN_RESULT=true
  elif echo "$org" | grep -iq "Edgecast"; then
    echo -e "${YELLOW}CDN detected: Verizon Edgecast (via ipinfo.io)${RESET}"
    CDN_RESULT=true
  elif echo "$org" | grep -iq "KeyCDN"; then
    echo -e "${YELLOW}CDN detected: KeyCDN (via ipinfo.io)${RESET}"
    CDN_RESULT=true
  elif echo "$org" | grep -iq "Alibaba"; then
    echo -e "${YELLOW}CDN detected: Alibaba Cloud CDN (via ipinfo.io)${RESET}"
    CDN_RESULT=true
  elif echo "$org" | grep -iq "Tencent"; then
    echo -e "${YELLOW}CDN detected: Tencent Cloud CDN (via ipinfo.io)${RESET}"
    CDN_RESULT=true
  else
    echo -e "${GREEN}No CDN detected via ipinfo.io${RESET}"
  fi
}

function check_cdn_certificate() {
  echo -e "${CYAN}Analyzing SSL certificate for CDN...${RESET}"
  cert_info=$(echo | timeout 5 openssl s_client -connect $DOMAIN:443 2>/dev/null | openssl x509 -noout -issuer -subject)
  
  if echo "$cert_info" | grep -iq "Cloudflare"; then
    echo -e "${YELLOW}CDN detected: Cloudflare (via SSL certificate)${RESET}"
    CDN_RESULT=true
  elif echo "$cert_info" | grep -iq "Microsoft"; then
    echo -e "${YELLOW}CDN detected: Microsoft Azure CDN (via SSL certificate)${RESET}"
    CDN_RESULT=true
  elif echo "$cert_info" | grep -iq "Akamai"; then
    echo -e "${YELLOW}CDN detected: Akamai (via SSL certificate)${RESET}"
    CDN_RESULT=true
  elif echo "$cert_info" | grep -iq "Fastly"; then
    echo -e "${YELLOW}CDN detected: Fastly (via SSL certificate)${RESET}"
    CDN_RESULT=true
  elif echo "$cert_info" | grep -iq "Incapsula"; then
    echo -e "${YELLOW}CDN detected: Imperva Incapsula (via SSL certificate)${RESET}"
    CDN_RESULT=true
  elif echo "$cert_info" | grep -iq "Sucuri"; then
    echo -e "${YELLOW}CDN detected: Sucuri (via SSL certificate)${RESET}"
    CDN_RESULT=true
  elif echo "$cert_info" | grep -iq "StackPath"; then
    echo -e "${YELLOW}CDN detected: StackPath (via SSL certificate)${RESET}"
    CDN_RESULT=true
  elif echo "$cert_info" | grep -iq "CDN77"; then
    echo -e "${YELLOW}CDN detected: CDN77 (via SSL certificate)${RESET}"
    CDN_RESULT=true
  elif echo "$cert_info" | grep -iq "Edgecast"; then
    echo -e "${YELLOW}CDN detected: Verizon Edgecast (via SSL certificate)${RESET}"
    CDN_RESULT=true
  elif echo "$cert_info" | grep -iq "KeyCDN"; then
    echo -e "${YELLOW}CDN detected: KeyCDN (via SSL certificate)${RESET}"
    CDN_RESULT=true
  elif echo "$cert_info" | grep -iq "Alibaba"; then
    echo -e "${YELLOW}CDN detected: Alibaba Cloud CDN (via SSL certificate)${RESET}"
    CDN_RESULT=true
  elif echo "$cert_info" | grep -iq "Tencent"; then
    echo -e "${YELLOW}CDN detected: Tencent Cloud CDN (via SSL certificate)${RESET}"
    CDN_RESULT=true
  else
    echo -e "${GREEN}No CDN detected via SSL certificate${RESET}"
  fi
}

function check_cdn() {
  CDN_RESULT=false
  check_cdn_headers
  if [ "$CDN_RESULT" == "true" ]; then return; fi

  check_cdn_asn
  if [ "$CDN_RESULT" == "true" ]; then return; fi

  check_cdn_ipinfo
  if [ "$CDN_RESULT" == "true" ]; then return; fi

  check_cdn_certificate
  if [ "$CDN_RESULT" == "true" ]; then return; fi

  echo -e "${GREEN}No CDN detected${RESET}"
}

function check_dest_for_reality() {
  local reasons=()
  local negatives=()
  local positives=()

  if [ "$PING_RESULT" = true ]; then
    if [ $RATING -ge 3 ]; then
      positives+=("Ping rating: ${RATING}/5")
    else
      negatives+=("Ping rating below 3 (${RATING}/5)")
    fi
  else
    negatives+=("Failed to ping the host")
  fi

  if [ "$TLS_RESULT" = true ]; then
    positives+=("TLS 1.3 is supported")
  else
    negatives+=("TLS 1.3 is not supported")
  fi
  if [ "$HTTP_RESULT" == "true" ]; then
    positives+=("HTTP/2 is supported")
  else
    negatives+=("HTTP/2 is not supported")
  fi
  if [ "$REDIRECT_RESULT" == "false" ]; then
    positives+=("No redirects found")
  else
    reasons+=("Redirect found")
  fi
  if [ "$CDN_RESULT" = false ]; then
    positives+=("CDN is not used")
  else
    negatives+=("CDN is used")
  fi

  echo -e "\n${CYAN}===== Check Results =====${RESET}"

  if [ ${#negatives[@]} -eq 0 ]; then
    echo -e "${GREEN}The site is suitable as a destination for Reality for the following reasons:${RESET}"
    for positive in "${positives[@]}"; do
      echo -e "${GREEN}- $positive${RESET}"
    done
  else
    if [ ${#negatives[@]} -eq 1 ] && [ "${negatives[0]}" == "CDN is used" ]; then
      echo -e "${YELLOW}The site is not recommended for the following reasons:${RESET}"
      for negative in "${negatives[@]}"; do
        echo -e "${YELLOW}- $negative${RESET}"
      done
    else
      echo -e "${RED}The site is NOT suitable for the following reasons:${RESET}"
      for negative in "${negatives[@]}"; do
        echo -e "${YELLOW}- $negative${RESET}"
      done
    fi

    if [ ${#positives[@]} -gt 0 ]; then
      echo -e "\n${GREEN}Positive aspects:${RESET}"
      for positive in "${positives[@]}"; do
        echo -e "${GREEN}- $positive${RESET}"
      done
    fi
  fi
}

if [ -z "$1" ]; then
  echo -e "${RED}Usage: $0 <host[:port]>${RESET}"
  exit 1
fi

INPUT="$1"
if [[ $INPUT == *":"* ]]; then
  HOSTNAME=$(echo $INPUT | cut -d':' -f1)
  PORT=$(echo $INPUT | cut -d':' -f2)
else
  HOSTNAME="$INPUT"
  PORT=""
fi

if [ -z "$PORT" ]; then
  PORTS=(443 80)
else
  PORTS=($PORT)
fi

check_and_install_command openssl
check_and_install_command ping
check_and_install_command bc

HOST_AVAILABLE=false

for PORT in "${PORTS[@]}"; do
  if [ "$PORT" == "443" ]; then
    PROTOCOL="https"
  else
    PROTOCOL="http"
  fi

  check_host_port
  if [ "$HOST_PORT_AVAILABLE" = true ]; then
    HOST_AVAILABLE=true
    check_tls
    check_redirect
    check_http_version
    check_cdn
    break
  fi
done

if [ "$HOST_AVAILABLE" = false ]; then
  echo -e "${RED}Host $HOSTNAME is unavailable on ports ${PORTS[*]}${RESET}"
  exit 1
fi

calculate_average_ping
determine_rating
check_dest_for_reality
