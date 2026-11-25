# Multi-Site Reverse Proxy with Docker Compose and Self-Healing

[Українська версія](README.uk.md)

Three websites (two static, one PHP) behind a single Nginx reverse proxy on one VPS. Every service has a healthcheck, a watchdog restarts unhealthy containers, and the firewall exposes only SSH and HTTP.

## Architecture

```
                     [ Client ]
                         │
                     port 80 (HTTP)
                         ▼
             ┌───────────────────────┐
             │  Nginx reverse proxy  │
             │   /healthz            │
             └───────────┬───────────┘
     ┌───────────────────┼───────────────────┐
     │ /site1/           │ /site2/           │ /site3/
     ▼                   ▼                   ▼
┌─────────────┐    ┌─────────────┐    ┌──────────────────┐
│   site1     │    │   site2     │    │      site3       │
│ static HTML │    │ static HTML │    │ PHP 8.3, :8083   │
└─────────────┘    └─────────────┘    └──────────────────┘
        all services share the isolated Docker network "web"
```

- **proxy** (`nginx:alpine`): the only public entry point. Routes `/site1/`, `/site2/`, `/site3/` to the backends and forwards `Host`, `X-Real-IP`, `X-Forwarded-For`, `X-Forwarded-Proto`.
- **site1, site2**: static sites on Nginx.
- **site3**: PHP 8.3 app on the built-in server, port 8083.
- **Healthchecks**: every service, the proxy included, exposes `/healthz`. The proxy starts only after all backends are healthy.
- **Watchdog** (`all-services-check.sh`): runs as a systemd service and recreates any container that is unhealthy or stopped. Docker's `restart: unless-stopped` only reacts to a container exiting, not to a failed healthcheck. After recreating a backend it reloads the proxy, so Nginx picks up the new container IP.

## Repository layout

```
.
├── docker-compose.yml      # services, healthchecks, network
├── all-services-check.sh   # watchdog with auto-restart
├── proxy/nginx.conf        # reverse proxy config
├── site1/                  # Dockerfile, nginx.conf, index.html
├── site2/                  # Dockerfile, nginx.conf, index.html
└── site3/                  # Dockerfile, index.php (+ /healthz)
```

## Deploy on a clean server

Tested on Ubuntu 22.04 / 24.04 and Debian 12.

### 1. System packages

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y git ufw
```

### 2. Firewall

Allow SSH **before** enabling the firewall, otherwise you lock yourself out of the server.

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp comment 'SSH'
sudo ufw allow 80/tcp comment 'HTTP'
sudo ufw --force enable
sudo ufw status verbose
```

> Docker publishes ports through its own iptables rules, which bypass UFW. Only the proxy publishes a port (80), so no backend is exposed.

### 3. Docker Engine and Compose plugin

```bash
sudo apt install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
. /etc/os-release   # sets $ID (ubuntu or debian) and $VERSION_CODENAME
sudo curl -fsSL "https://download.docker.com/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Run docker without sudo (log out and back in afterwards)
sudo usermod -aG docker "$USER"
```

### 4. Clone and start

```bash
git clone https://github.com/88susan00/TechTask_2.git
cd TechTask_2
docker compose up -d --build
docker compose ps
```

All four services should show `Up (healthy)` within about a minute.

## Verify

```bash
curl -I http://<SERVER_IP>/site1/
curl -I http://<SERVER_IP>/site2/
curl    http://<SERVER_IP>/site3/

# Healthchecks: expect HTTP 200 and body "OK"
curl -i http://<SERVER_IP>/healthz
for s in site1 site2 site3; do curl -s "http://<SERVER_IP>/$s/healthz"; echo " <- $s"; done
```

## Watchdog as a systemd service

Create `/etc/systemd/system/techtask-watchdog.service` (replace `<USER>` with your user name):

```ini
[Unit]
Description=TechTask watchdog: recreates unhealthy containers
After=docker.service network-online.target
Requires=docker.service

[Service]
User=<USER>
ExecStart=/home/<USER>/TechTask_2/all-services-check.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

The script changes to its own directory, so it finds `docker-compose.yml` no matter where it is started from. The user must be in the `docker` group (step 3).

```bash
chmod +x all-services-check.sh
sudo systemctl daemon-reload
sudo systemctl enable --now techtask-watchdog.service
journalctl -u techtask-watchdog.service -f
```

### Test self-healing

Break a backend's healthcheck from inside the container and watch the watchdog fix it:

```bash
docker compose exec site1 sh -c "sed -i 's/return 200/return 500/' /etc/nginx/conf.d/default.conf && nginx -s reload"
journalctl -u techtask-watchdog.service -f   # "site1: unhealthy, recreating" after ~90 s
```

The watchdog recreates the container from its image, so the broken config is gone and `site1` becomes healthy again. A plain `docker restart` would not help here: it keeps the container's filesystem, broken file included.

The check interval defaults to 30 seconds; override it with `CHECK_INTERVAL` (e.g. `Environment=CHECK_INTERVAL=15` in the unit).
