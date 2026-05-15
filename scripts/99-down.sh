#!/usr/bin/env bash
# Полная очистка стенда.
set -euo pipefail
cd "$(dirname "$0")/.."
docker compose down -v --remove-orphans
echo "Стенд остановлен и volume'ы удалены."
