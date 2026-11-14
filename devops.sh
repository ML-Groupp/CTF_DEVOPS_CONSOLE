#!/usr/bin/env sh
# A/D DevOps console launcher.
# Запуск: ./devops.sh [status|tail|backups|backup|restore|staging] [опции]
# Без аргументов открывает интерактивное меню.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ENTRY="$SCRIPT_DIR/devops.py"

if [ ! -f "$ENTRY" ]; then
    echo "devops.sh: не найден $ENTRY" >&2
    exit 1
fi

PY=""
for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1; then
        if "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 8) else 1)' >/dev/null 2>&1; then
            PY=$candidate
            break
        fi
    fi
done

if [ -z "$PY" ]; then
    echo "devops.sh: нужен Python 3.8+ (python3 или python) в PATH" >&2
    exit 127
fi

exec "$PY" "$ENTRY" "$@"