#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${1:-$ROOT/build/Linea Lite.app}"
BINARY="$APP_DIR/Contents/MacOS/Linea Lite"
LOG="$ROOT/build/app-smoke.log"

test -x "$BINARY"
"$BINARY" >"$LOG" 2>&1 &
PID=$!
trap 'kill "$PID" 2>/dev/null || true' EXIT
sleep 3
kill -0 "$PID"
kill -TERM "$PID"
wait "$PID" 2>/dev/null || true
trap - EXIT
echo "App launch smoke passed"
