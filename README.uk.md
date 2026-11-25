# Мультисайтовий reverse proxy на Docker Compose із самовідновленням

[English version](README.md)

Три сайти (два статичні, один PHP) за одним Nginx reverse proxy на одному VPS. Кожен сервіс має healthcheck, watchdog перестворює несправні контейнери, а фаєрвол відкриває тільки SSH і HTTP.

## Архітектура

```
                     [ Клієнт ]
                         │
                     порт 80 (HTTP)
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
          усі сервіси в ізольованій Docker-мережі "web"
```

- **proxy** (`nginx:alpine`): єдина публічна точка входу. Маршрутизує `/site1/`, `/site2/`, `/site3/` і передає бекендам заголовки `Host`, `X-Real-IP`, `X-Forwarded-For`, `X-Forwarded-Proto`.
- **site1, site2**: статичні сайти на Nginx.
- **site3**: PHP 8.3 на вбудованому сервері, порт 8083.
- **Healthchecks**: кожен сервіс, включно з proxy, віддає `/healthz`. Proxy стартує тільки після того, як усі бекенди стали healthy.
- **Watchdog** (`all-services-check.sh`): працює як systemd-сервіс і перестворює контейнер, який unhealthy або зупинений. `restart: unless-stopped` у Docker реагує лише на завершення контейнера, а не на провалений healthcheck. Після перестворення бекенду скрипт перезавантажує proxy, щоб Nginx підхопив нову IP-адресу контейнера.

## Структура репозиторію

```
.
├── docker-compose.yml      # сервіси, healthchecks, мережа
├── all-services-check.sh   # watchdog з автоперезапуском
├── proxy/nginx.conf        # конфіг reverse proxy
├── site1/                  # Dockerfile, nginx.conf, index.html
├── site2/                  # Dockerfile, nginx.conf, index.html
└── site3/                  # Dockerfile, index.php (+ /healthz)
```

## Розгортання на чистому сервері

Перевірено на Ubuntu 22.04 / 24.04 та Debian 12.

### 1. Системні пакети

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y git ufw
```

### 2. Фаєрвол

Дозвольте SSH **до** увімкнення фаєрвола, інакше втратите доступ до сервера.

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp comment 'SSH'
sudo ufw allow 80/tcp comment 'HTTP'
sudo ufw --force enable
sudo ufw status verbose
```

> Docker публікує порти через власні правила iptables в обхід UFW. Порт публікує тільки proxy (80), тож бекенди назовні не доступні.

### 3. Docker Engine і Compose plugin

```bash
sudo apt install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
. /etc/os-release   # задає $ID (ubuntu або debian) і $VERSION_CODENAME
sudo curl -fsSL "https://download.docker.com/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# docker без sudo (після цього перелогіньтесь)
sudo usermod -aG docker "$USER"
```

### 4. Клонування і запуск

```bash
git clone https://github.com/88susan00/TechTask_2.git
cd TechTask_2
docker compose up -d --build
docker compose ps
```

Приблизно за хвилину всі чотири сервіси мають показати `Up (healthy)`.

## Перевірка

```bash
curl -I http://<IP_СЕРВЕРА>/site1/
curl -I http://<IP_СЕРВЕРА>/site2/
curl    http://<IP_СЕРВЕРА>/site3/

# Healthchecks: очікується HTTP 200 і тіло "OK"
curl -i http://<IP_СЕРВЕРА>/healthz
for s in site1 site2 site3; do curl -s "http://<IP_СЕРВЕРА>/$s/healthz"; echo " <- $s"; done
```

## Watchdog як systemd-сервіс

Створіть `/etc/systemd/system/techtask-watchdog.service` (замініть `<USER>` на свого користувача):

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

Скрипт сам переходить у свою директорію, тому знаходить `docker-compose.yml` незалежно від того, звідки його запустили. Користувач має бути в групі `docker` (крок 3).

```bash
chmod +x all-services-check.sh
sudo systemctl daemon-reload
sudo systemctl enable --now techtask-watchdog.service
journalctl -u techtask-watchdog.service -f
```

### Перевірка самовідновлення

Зламайте healthcheck бекенду зсередини контейнера і подивіться, як watchdog це виправить:

```bash
docker compose exec site1 sh -c "sed -i 's/return 200/return 500/' /etc/nginx/conf.d/default.conf && nginx -s reload"
journalctl -u techtask-watchdog.service -f   # "site1: unhealthy, recreating" приблизно за 90 с
```

Watchdog перестворює контейнер з образу, тож зламаний конфіг зникає і `site1` знову стає healthy. Звичайний `docker restart` тут не допоміг би: він зберігає файлову систему контейнера разом зі зламаним файлом.

Інтервал перевірки за замовчуванням 30 секунд, його можна змінити через `CHECK_INTERVAL` (наприклад, `Environment=CHECK_INTERVAL=15` у юніті).
