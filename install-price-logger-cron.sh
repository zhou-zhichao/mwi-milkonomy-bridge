#!/usr/bin/env bash
# Install a cron entry to run the price logger every hour at :37
# (non-round minute, offset from keep-alive at :07).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGGER="$SCRIPT_DIR/mwi-price-logger.py"
LOG_FILE="$SCRIPT_DIR/logs/mwi-price-logger.log"
PYTHON_BIN="$(command -v python3)"
ENTRY="37 * * * * $PYTHON_BIN $LOGGER >> $LOG_FILE 2>&1"

if [[ ! -x "$LOGGER" && ! -f "$LOGGER" ]]; then
    echo "ERROR: $LOGGER not found" >&2
    exit 1
fi

mkdir -p "$SCRIPT_DIR/logs" "$SCRIPT_DIR/data"

CURRENT="$(crontab -l 2>/dev/null || true)"
if echo "$CURRENT" | grep -Fq "$LOGGER"; then
    echo "cron entry for $LOGGER already present; skipping."
    exit 0
fi

{ echo "$CURRENT"; echo "$ENTRY"; } | crontab -
echo "installed: $ENTRY"
