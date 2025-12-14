#!/bin/bash 

GREEN="\033[32m"
RED="\033[31m"
CYAN="\033[36m"
YELLOW="\033[33m"
RESET="\033[0m"

TLS_RESULT=false
HTTP_RESULT=false
CDN_RESULT=false
REDIRECT_RESULT=false

function check_and_install_command() {
  if ! command -v $1 &> /dev/null; then
    echo -e "${YELLOW}Utility $1 not found. Installing...${RESET}"
    sudo apt-get install -y $1 > /dev/null
    if ! command -v $1 &> /dev/null; then
      echo -e "${RED}Error: Failed to install $1. Install it manually.${RESET}"
      exit 1
    fi
  fi
}

function check_tls() {
  echo -e "${CYAN}Checking TLS support for $DOMAIN...${RESET}"
  tls_version=$(echo | timeout 5 openssl s_client -connect $DOMAIN:443 -tls1_3 2>&1)
  if echo "$tls_version" | grep -q "TLSv1.3"; then
    echo -e "${GREEN}TLS 1.3 is supported${RESET}"
    TLS_RESULT=true
  else
    tls_output=$(echo | timeout 5 openssl s_client -connect $DOMAIN:443 2>&1)
    protocol_line=$(echo "$tls_output" | grep -E "Protocol *:")
    if [[ -n $protocol_line ]]; then
      tls_used=$(echo "$protocol_line" | awk -F ': ' '{print $2}')
      echo -e "${YELLOW}TLS 1.3 is not supported. Current version: ${tls_used}${RESET}"
    else
      echo -e "${RED}Failed to determine the TLS version${RESET}"
    fi
  fi
}

function check_http_version() {
  echo -e "${CYAN}Checking HTTP support for $DOMAIN...${RESET}"

  HTTP2_SUPPORTED=false
  HTTP3_SUPPORTED=false

  http2_check=$(curl -I -s --max-time 5 --http2 https://$DOMAIN 2>/dev/null | grep -i "^HTTP/2")
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

function check_sni_for_reality() {
  local reasons=()
  local positives=()

  if [ "$TLS_RESULT" == "true" ]; then
    positives+=("TLS 1.3 is supported")
  else
    reasons+=("TLS 1.3 is not supported")
  fi

  if [ "$HTTP_RESULT" == "true" ]; then
    positives+=("HTTP/2 is supported")
  else
    reasons+=("HTTP/2 is not supported")
  fi

  if [ "$CDN_RESULT" == "true" ]; then
    reasons+=("CDN is used")
  else
    positives+=("No CDN is used")
  fi

  if [ "$REDIRECT_RESULT" == "false" ]; then
    positives+=("No redirects found")
  else
    reasons+=("Redirect found")
  fi

  echo -e "\n${CYAN}===== Test Results =====${RESET}"

  if [ ${#reasons[@]} -eq 0 ]; then
    echo -e "${GREEN}The site is suitable as SNI for Reality for the following reasons:${RESET}"
    for positive in "${positives[@]}"; do
      echo -e "${GREEN}- $positive${RESET}"
    done
  else
    echo -e "${RED}The site is not suitable as SNI for Reality for the following reasons:${RESET}"
    for reason in "${reasons[@]}"; do
      echo -e "${YELLOW}- $reason${RESET}"
    done
    if [ ${#positives[@]} -gt 0 ]; then
      echo -e "\n${GREEN}Positive points:${RESET}"
      for positive in "${positives[@]}"; do
        echo -e "${GREEN}- $positive${RESET}"
      done
    fi
  fi
}

if [ -z "$1" ]; then
  echo -e "${RED}Usage: $0 <domain>${RESET}"
  exit 1
fi

DOMAIN=$1

check_and_install_command openssl
check_and_install_command curl
check_and_install_command dig
check_and_install_command whois

check_tls
check_http_version
check_redirect
check_cdn

check_sni_for_reality
