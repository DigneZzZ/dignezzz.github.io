# MTProxy Docker Installation Guide

This script installs and manages MTProxy using the official Telegram Docker image (`telegrammessenger/proxy:latest`).

## Features

- ✅ Official Telegram MTProxy Docker image
- ✅ Automatic SECRET generation
- ✅ Configurable port (default 443, but any port can be used)
- ✅ Optional TAG for channel branding via @MTProxybot
- ✅ Docker Compose based deployment
- ✅ Easy management with `mtproxy` utility
- ✅ Complete uninstall functionality

## Requirements

- Linux server (Ubuntu/Debian recommended)
- Root access (sudo)
- Docker and Docker Compose will be installed automatically if not present

## Installation

### 1. Download and Install

```bash
# Make the script executable
chmod +x mtproxy.sh

# Install MTProxy
sudo ./mtproxy.sh install
```

During installation, you'll be prompted to:
- Enter the port (default: 443)
- Optionally enter a TAG from @MTProxybot (can be added later)

### 2. Get TAG for Channel Branding (Optional)

TAG is used to promote your Telegram channel to users connecting through your proxy.

**To get your TAG:**

1. Open Telegram and find [@MTProxybot](https://t.me/MTProxybot)
2. Send `/newproxy` command
3. Register your proxy with the bot
4. Bot will provide you with a TAG (32 hexadecimal characters)

**To add/update TAG:**

```bash
sudo ./mtproxy.sh update-tag
```

## Usage

### Installation Commands

```bash
# Install MTProxy
sudo ./mtproxy.sh install

# Update TAG from @MTProxybot
sudo ./mtproxy.sh update-tag

# Uninstall MTProxy completely
sudo ./mtproxy.sh uninstall

# Show help
./mtproxy.sh help
```

### Management Commands (After Installation)

After installation, use the `mtproxy` utility to manage the service:

```bash
# Show status and connection links
mtproxy status

# Start MTProxy container
mtproxy start

# Stop MTProxy container
mtproxy stop

# Restart MTProxy container
mtproxy restart

# View container logs
mtproxy logs

# Update TAG
mtproxy update-tag

# Show detailed information
mtproxy info

# Show help
mtproxy help
```

## Configuration

### Docker Compose Configuration

The script creates a `docker-compose.yml` file at `/opt/MTProxy/docker-compose.yml`:

```yaml
version: '3.8'

services:
  mtproto-proxy:
    image: telegrammessenger/proxy:latest
    container_name: mtproto-proxy
    restart: always
    ports:
      - "${PORT}:443"
    environment:
      SECRET: "${SECRET}"
      TAG: "${TAG}"
    volumes:
      - proxy-config:/data
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

volumes:
  proxy-config:
```

### Environment Variables

Environment variables are stored in `/opt/MTProxy/.env`:

```
SECRET=<your-generated-secret>
PORT=<your-port>
TAG=<your-tag-from-mtproxybot>  # Optional
```

### Changing Port

If port 443 is already in use, you can:

1. **During installation**: Enter a different port when prompted
2. **After installation**: 
   - Edit `/opt/MTProxy/.env` and change the PORT value
   - Restart the container: `mtproxy restart`

**Example ports to try:**
- 443 (HTTPS - default)
- 8443
- 9443

## Connection Links

After installation, you'll receive connection links:

**Telegram Link:**
```
tg://proxy?server=YOUR_IP&port=PORT&secret=SECRET
```

**Web Browser Link:**
```
https://t.me/proxy?server=YOUR_IP&port=PORT&secret=SECRET
```

Share these links with users who want to use your proxy.

## Files and Directories

- `/opt/MTProxy/` - Installation directory
- `/opt/MTProxy/docker-compose.yml` - Docker Compose configuration
- `/opt/MTProxy/.env` - Environment variables (SECRET, PORT, TAG)
- `/opt/MTProxy/info.txt` - Configuration information
- `/usr/local/bin/mtproxy` - Management utility

## Troubleshooting

### Check Container Status

```bash
docker ps | grep mtproto-proxy
```

### View Container Logs

```bash
mtproxy logs
# or
docker-compose -f /opt/MTProxy/docker-compose.yml logs -f
```

### Check Port Availability

```bash
# Check if port is already in use
sudo ss -tlnp | grep :443

# Check firewall
sudo ufw status
```

### Restart Container

```bash
mtproxy restart
```

### Reinstall

```bash
# Uninstall first
sudo ./mtproxy.sh uninstall

# Then install again
sudo ./mtproxy.sh install
```

## Comparison with Previous Version

| Feature | Old (Python MTProxy) | New (Docker MTProxy) |
|---------|---------------------|---------------------|
| Installation | Python dependencies | Docker image |
| Management | systemd service | Docker Compose |
| Updates | Manual | Docker pull |
| Port Config | During install | Flexible |
| TAG Support | Manual setup | @MTProxybot integration |
| Rollback | systemctl | docker-compose |
| Logs | journalctl | docker logs |

## Security Notes

- Keep your SECRET private
- Use firewall rules to protect your server
- TAG from @MTProxybot enables channel promotion (optional)
- The container runs with restart policy to ensure high availability

## Support

For issues or questions:
- Check Docker status: `docker ps`
- Check logs: `mtproxy logs`
- Verify configuration: `mtproxy info`

## License

This script uses the official Telegram MTProxy Docker image.
