#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

if [[ "$EUID" -ne 0 ]]; then
  echo -e "${RED}This script must be run as root or with sudo privileges. Exiting...${RESET}"
  exit 1
fi

if ! command -v sudo &> /dev/null; then
  echo -e "${YELLOW}Warning: 'sudo' is not installed. Commands will run as root.${RESET}"
  SUDO=""
else
  SUDO="sudo"
fi

if command -v nginx &> /dev/null; then
  echo -e "${RED}Nginx is already installed on this system.${RESET}"
  echo -e "${CYAN}This script supports only fresh installations on servers with unoccupied ports 80 and 8443.${RESET}"
  echo -e "${YELLOW}Please remove Nginx first and run this script again.${RESET}"
  echo -e "You can uninstall Nginx using the following command:"
  echo -e "${GREEN}  sudo apt-get remove --purge -y nginx && sudo apt-get autoremove -y${RESET}"
  exit 1
fi

if ss -tlnp | grep -qE ":80\b|:8443\b"; then
  echo -e "${RED}Ports 80 or 8443 are already in use.${RESET}"
  echo -e "${CYAN}This script requires these ports to be free.${RESET}"
  echo -e "${YELLOW}Please stop any processes using these ports and run the script again.${RESET}"
  exit 1
fi

read -p "Please enter your domain (e.g., example.com): " DOMAIN
if [[ -z "$DOMAIN" ]]; then
  echo -e "${RED}No domain provided. Exiting...${RESET}"
  exit 1
fi

if command -v ufw &> /dev/null && ufw status | grep -qw active; then
  echo -e "${CYAN}UFW is active. Ensuring port 80 is open...${RESET}"
  ufw allow 80/tcp
  ufw reload
else
  echo -e "${YELLOW}UFW is not active. Checking iptables rules...${RESET}"
  
  if ! iptables -C INPUT -p tcp --dport 80 -j ACCEPT &> /dev/null; then
    echo -e "${CYAN}Port 80 is not open in iptables. Adding rule...${RESET}"
    iptables -I INPUT -p tcp --dport 80 -j ACCEPT
  else
    echo -e "${GREEN}Port 80 is already open in iptables.${RESET}"
  fi
fi


generate_random_email() {
  echo "$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c35)@gmail.com"
}

read -p "Please enter your email for certificate registration (leave blank to auto-generate): " EMAIL
if [[ -z "$EMAIL" ]]; then
  EMAIL=$(generate_random_email)
  echo -e "${YELLOW}No email provided. Generated email: ${EMAIL}${RESET}"
fi

DOMAIN_FILE="/etc/nginx/current_domain.txt"
$SUDO mkdir -p /etc/nginx
echo "$DOMAIN" | $SUDO tee "$DOMAIN_FILE" > /dev/null

if ! command -v logrotate &> /dev/null; then
  echo -e "${RED}Logrotate is not installed. Installing it now...${RESET}"
  $SUDO apt-get install -y -qq logrotate > /dev/null 2>&1
  if [[ $? -ne 0 ]]; then
    echo -e "${RED}Failed to install logrotate. Ensure your system is updated and retry.${RESET}"
    exit 1
  else
    echo -e "${GREEN}Logrotate installed successfully.${RESET}"
  fi
else
  echo -e "${GREEN}Logrotate is already installed.${RESET}"
fi

log_rotation_config() {
  echo "Adding log rotation configuration for Nginx..."
  $SUDO bash -c "cat <<EOF > /etc/logrotate.d/nginx
/var/log/nginx/*.log {
    size 100M
    rotate 2
    missingok
    compress
    delaycompress
    notifempty
    create 0640 www-data adm
    sharedscripts
    postrotate
        if [ -f /var/run/nginx.pid ]; then
            kill -USR1 \$(cat /var/run/nginx.pid)
        fi
    endscript
}
EOF"
}



echo -e "${CYAN}Installing Nginx, Certbot, and python3-certbot-nginx...${RESET}"
$SUDO apt-get update -qq
$SUDO apt-get install -y -qq nginx certbot python3-certbot-nginx 
if [[ $? -ne 0 ]]; then
  echo -e "${RED}Failed to install required packages. Ensure your system is updated and retry.${RESET}"
  exit 1
else
  echo -e "${GREEN}Required packages installed successfully.${RESET}"
fi

CERTBOT_CONF="/etc/nginx/sites-available/letsencrypt.conf"
$SUDO bash -c "cat <<EOF > \"$CERTBOT_CONF\"
server {
    listen 80;
    server_name $DOMAIN;

    location /.well-known/acme-challenge/ {
    }

    location / {
        return 301 https://\$host:8443\$request_uri;
    }
}
EOF"

$SUDO ln -sf "$CERTBOT_CONF" /etc/nginx/sites-enabled/letsencrypt.conf

$SUDO systemctl enable nginx
$SUDO systemctl restart nginx
log_rotation_config

  echo -e "${CYAN}Obtaining Let's Encrypt certificate using web server for ${DOMAIN}...${RESET}"
  $SUDO certbot --nginx -d "$DOMAIN" --email "$EMAIL" --agree-tos --no-eff-email

if [[ $? -ne 0 ]]; then
  echo -e "${RED}Certbot failed to obtain a certificate. Check the error messages above.${RESET}"
  exit 1
fi

CONF_FILE="/etc/nginx/sites-available/sni.conf"
$SUDO bash -c "cat <<'EOF' > \"$CONF_FILE\"
server {
    listen 127.0.0.1:8443 ssl http2 proxy_protocol;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_trusted_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305';

    ssl_session_cache shared:SSL:1m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    ssl_stapling on;
    ssl_stapling_verify on;
    resolver 1.1.1.1 valid=60s;
    resolver_timeout 2s;

    real_ip_header proxy_protocol;
    set_real_ip_from 127.0.0.1;
    set_real_ip_from ::1;

    add_header Strict-Transport-Security 'max-age=31536000; includeSubDomains' always;
    add_header X-Content-Type-Options 'nosniff' always;
    add_header X-Frame-Options 'DENY' always;
    add_header Referrer-Policy 'no-referrer' always;

    root /var/www/html/site;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }

    error_page 403 404 500 502 503 504 /error.html;
    location = /error.html {
        root /usr/share/nginx/html;
    }
}
EOF"

ln -sf "$CONF_FILE" /etc/nginx/sites-enabled/

$SUDO nginx -t && $SUDO systemctl reload nginx

$SUDO rm -f /etc/nginx/sites-enabled/letsencrypt.conf
$SUDO rm -f /etc/nginx/sites-available/letsencrypt.conf

SELF_PATH="/usr/local/bin/self"
$SUDO bash -c "cat << 'EOF' > \"$SELF_PATH\"
#!/bin/bash

# Цвета для выделения
RED='\\033[0;31m'
GREEN='\\033[0;32m'
YELLOW='\\033[0;33m'
CYAN='\\033[0;36m'
BOLD='\\033[1m'
RESET='\\033[0m'

CERT_DIR=\"/etc/letsencrypt/live\"
DOMAIN_FILE=\"/etc/nginx/current_domain.txt\"
DOMAIN=\"\"

if [[ -f \$DOMAIN_FILE ]]; then
  DOMAIN=\$(cat \$DOMAIN_FILE)
else
  echo -e \"\${RED}Domain file not found. Set DOMAIN manually.\${RESET}\"
  DOMAIN=\"example.com\"
fi

help_menu() {
  echo -e \"\"
  echo -e \"\${CYAN}=========================================\${RESET}\"
  echo -e \"\${BOLD}          Nginx Management Utility        \${RESET}\"
  echo -e \"\${CYAN}=========================================\${RESET}\"
  echo -e \"\"
  echo -e \"\${BOLD}Available Commands:\${RESET}\"
  echo -e \"  \${GREEN}e\${RESET}             \${YELLOW}Edit /etc/nginx/nginx.conf\${RESET}\"
  echo -e \"  \${GREEN}r\${RESET}             \${YELLOW}Restart Nginx\${RESET}\"
  echo -e \"  \${GREEN}logs\${RESET}          \${YELLOW}Show Nginx logs\${RESET}\"
  echo -e \"  \${GREEN}s | status\${RESET}    \${YELLOW}Show 'systemctl status nginx'\${RESET}\"
  echo -e \"  \${GREEN}renew\${RESET}         \${YELLOW}Renew SSL certificates\${RESET}\"
  echo -e \"  \${GREEN}cert-status\${RESET}   \${YELLOW}Check SSL certificate expiration\${RESET}\"
  echo -e \"  \${GREEN}reinstall\${RESET}     \${YELLOW}Reload Nginx\${RESET}\"
  echo -e \"  \${GREEN}uninstall\${RESET}     \${YELLOW}Remove Nginx, Certbot, and configurations\${RESET}\"
  echo -e \"\"
  echo -e \"\${BOLD}Current Configuration Info:\${RESET}\"
  echo -e \"  \${CYAN}Domain SNI:\${RESET} \$DOMAIN\"
  echo -e \"  \${CYAN}Destination:\${RESET}  127.0.0.1:8443\"
  echo -e \"  \${CYAN}Cert Path:\${RESET}    \$CERT_DIR/\$DOMAIN/\"
  echo -e \"\"
}

cert_status() {
  if [[ -d \$CERT_DIR/\$DOMAIN ]]; then
    EXPIRY_DATE=\$(openssl x509 -enddate -noout -in \$CERT_DIR/\$DOMAIN/fullchain.pem | cut -d= -f2)
    echo -e \"\${GREEN}Certificate for \$DOMAIN expires on: \${BOLD}\$EXPIRY_DATE\${RESET}\"
  else
    echo -e \"\${RED}Certificate files not found for domain \$DOMAIN in \$CERT_DIR.\${RESET}\"
  fi
}

renew_certs() {
  echo -e \"\${YELLOW}Renewing SSL certificates for \$DOMAIN...\${RESET}\"
  certbot renew --nginx
  if [[ \$? -eq 0 ]]; then
    echo -e \"\${GREEN}Certificates successfully renewed.\${RESET}\"
  else
    echo -e \"\${RED}Failed to renew certificates. Check Certbot logs for details.\${RESET}\"
  fi
}

case \"\$1\" in
  e)
    echo -e \"\${CYAN}Opening /etc/nginx/nginx.conf...\${RESET}\"
    nano /etc/nginx/nginx.conf
    ;;
  r)
    echo -e \"\${CYAN}Restarting Nginx...\${RESET}\"
    systemctl restart nginx
    ;;
  logs)
    echo -e \"\${CYAN}Showing Nginx logs (Ctrl+C to exit)...\${RESET}\"
    journalctl -u nginx -n 50 -f
    ;;
  s|status)
    echo -e \"\${CYAN}-- systemctl status nginx --\${RESET}\"
    systemctl status nginx
    ;;
  renew)
    renew_certs
    ;;
  cert-status)
    cert_status
    ;;
  reinstall)
    echo -e \"\${CYAN}Reloading Nginx configuration...\${RESET}\"
    systemctl reload nginx || systemctl restart nginx
    ;;
  uninstall)
    echo -e \"\${YELLOW}Stopping and removing Nginx and Certbot...\${RESET}\"
    systemctl stop nginx
    apt-get remove --purge -y nginx certbot python3-certbot-nginx
    apt-get autoremove -y
    rm -rf /etc/letsencrypt
    rm -rf /etc/nginx
    rm -f /usr/local/bin/self
    echo -e \"\${RED}All components removed.\${RESET}\"
    ;;
  help)
    help_menu
    ;;
  *)
    echo -e \"\${RED}Invalid command.\${RESET}\"
    help_menu
    ;;
esac
EOF"


$SUDO chmod +x "$SELF_PATH"

if [[ ":$PATH:" != *":/usr/local/bin:"* ]]; then
 export PATH=$PATH:/usr/local/bin
fi

if command -v ufw &> /dev/null && ufw status | grep -qw active; then
  echo -e "${CYAN}Closing ports 80 and 8443 in UFW...${RESET}"
  ufw delete allow 80/tcp
  ufw delete allow 8443/tcp
  ufw reload
else
  echo -e "${CYAN}Applying iptables rules to block external access to ports 80 and 8443...${RESET}"
  iptables -I INPUT -p tcp --dport 8443 ! -s 127.0.0.1 -j DROP
  iptables -I INPUT -p tcp --dport 80 ! -s 127.0.0.1 -j DROP
fi
mkdir -p /var/lib/marzban/certs
ln -s /etc/letsencrypt/live/${DOMAIN}/fullchain.pem /var/lib/marzban/certs/fullchain.pem
ln -s /etc/letsencrypt/live/${DOMAIN}/privkey.pem /var/lib/marzban/certs/key.pem

echo "Installation complete!"
echo "You can manage Nginx using the 'self' utility."
