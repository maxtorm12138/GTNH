#!/usr/bin/env bash
set -euo pipefail

WATCH_DIR="/mnt/server/gtnh-backups"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SYNC_SCRIPT="$SCRIPT_DIR/sync-backups.sh"
COOLDOWN=30

if [ ! -d "$WATCH_DIR" ]; then
    echo "[ERROR] Watch directory not found: $WATCH_DIR"
    exit 1
fi

last_run=0

echo "[INFO] Watching $WATCH_DIR for new backup files..."

inotifywait -m -r -e close_write -e moved_to --format '%w%f' "$WATCH_DIR" | while read -r filepath; do
    filename=$(basename "$filepath")

    case "$filename" in
        *-full.zip|*-partial.zip) ;;
        *) continue ;;
    esac

    if [[ "$filename" == *incomplete* ]]; then
        echo "[SKIP] Incomplete file: $filename"
        continue
    fi

    now=$(date +%s)
    if (( now - last_run < COOLDOWN )); then
        echo "[SKIP] Cooldown active, ignoring: $filename"
        continue
    fi
    last_run=$now

    echo "[TRIGGER] New backup detected: $filename"
    echo "[INFO] Running sync script..."
    if bash "$SYNC_SCRIPT"; then
        echo "[DONE] Sync completed successfully"
    else
        echo "[ERROR] Sync script failed with exit code $?"
    fi
done
