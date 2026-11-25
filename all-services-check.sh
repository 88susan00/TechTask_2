#!/usr/bin/env bash
# Watchdog: checks every Compose service and restarts the ones that are unhealthy.
# Docker's `restart: unless-stopped` only restarts containers that EXIT,
# not ones that keep running but fail their healthcheck. This script covers that gap.
set -uo pipefail

# Run from the project directory, wherever the script is called from (e.g. systemd).
cd "$(dirname "$(readlink -f "$0")")" || exit 1

SERVICES=(proxy site1 site2 site3)
INTERVAL="${CHECK_INTERVAL:-30}"

log() { echo "$(date '+%F %T') $*"; }

while true; do
  for service in "${SERVICES[@]}"; do
    # Ask Compose for the container ID instead of guessing the container name.
    id=$(docker compose ps -q "$service" 2>/dev/null)

    if [[ -z "$id" ]]; then
      log "$service: not running, starting"
      docker compose up -d "$service"
      continue
    fi

    status=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$id")

    case "$status" in
      healthy | starting)
        log "$service: $status"
        ;;
      *)
        # Recreate from the image instead of a plain restart: a restart keeps the
        # container's filesystem, so a broken file inside it would survive.
        log "$service: $status, recreating"
        docker compose up -d --force-recreate --no-deps "$service"

        # A recreated backend gets a new IP, but Nginx resolves upstream names only at
        # (re)load. Reload the proxy so it does not keep sending traffic to the old IP.
        if [[ "$service" != "proxy" ]]; then
          docker compose exec -T proxy nginx -s reload
        fi
        ;;
    esac
  done
  sleep "$INTERVAL"
done
