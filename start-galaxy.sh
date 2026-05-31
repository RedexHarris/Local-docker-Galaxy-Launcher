#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

if [[ ! -f .env && -f .env.example ]]; then
  cp .env.example .env
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker CLI was not found. Install Docker first."
  exit 1
fi

if docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE=(docker-compose)
else
  echo "Docker Compose was not found. Install the Docker Compose plugin."
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "Docker is installed, but the Docker daemon is not running."
  exit 1
fi

if [[ ! -f tool_list.yml ]]; then
  echo "tool_list.yml is missing. Run scripts/Update-ToolList.ps1 or restore the file."
  exit 1
fi

PORT="${GALAXY_PORT:-8080}"
IMAGE="${GALAXY_IMAGE:-local-usegalaxy:latest}"
if [[ -f .env ]]; then
  PORT="$(grep -E '^GALAXY_PORT=' .env | tail -n 1 | cut -d= -f2- || true)"
  PORT="${PORT:-8080}"
  IMAGE="$(grep -E '^GALAXY_IMAGE=' .env | tail -n 1 | cut -d= -f2- || true)"
  IMAGE="${IMAGE:-local-usegalaxy:latest}"
fi

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "Galaxy image is missing. Building it once..."
  "${COMPOSE[@]}" build
fi

"${COMPOSE[@]}" up -d --no-build

URL="http://localhost:${PORT}"
echo "Waiting for Galaxy at ${URL} ..."
for _ in $(seq 1 180); do
  if curl -fsS "${URL}/api/version" >/dev/null 2>&1; then
    echo "Galaxy is ready: ${URL}"
    if command -v pwsh >/dev/null 2>&1; then
      pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/Sync-GalaxyTools.ps1 -GalaxyUrl "$URL" || true
    elif command -v powershell.exe >/dev/null 2>&1; then
      powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/Sync-GalaxyTools.ps1 -GalaxyUrl "$URL" || true
    fi
    if command -v xdg-open >/dev/null 2>&1; then
      xdg-open "${URL}/login/start?redirect=%2F" >/dev/null 2>&1 || true
    elif command -v open >/dev/null 2>&1; then
      open "${URL}/login/start?redirect=%2F" >/dev/null 2>&1 || true
    fi
    exit 0
  fi
  sleep 5
done

echo "Galaxy did not become ready in time. Recent logs:"
"${COMPOSE[@]}" logs --tail 80 galaxy
exit 1
