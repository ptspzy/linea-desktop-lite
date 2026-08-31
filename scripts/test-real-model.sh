#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${1:-$ROOT/build/Linea Lite.app}"
RUNTIME="$APP_DIR/Contents/Resources/bin/qwen-asr"
MODEL_PATH="${LINEA_MODEL_PATH:-$HOME/Library/Application Support/Linea Lite/models/qwen3-asr-0.6b-q4-k/f63771c02dfa486d9399d41ab6ab8cd2d8ca24e077cd32130ea1f67f4fd8dade/qwen3-asr-0.6b-q4_k.gguf}"
AUDIO="$ROOT/Tests/Fixtures/reference-004.wav"
REFERENCE="当前模型使用 Qwen3-ASR 0.6B 4-bit MLX balanced。"
MANIFEST="${LINEA_QUALITY_MANIFEST:-}"
CHECKER="$ROOT/build/quality-check"
LOG="$ROOT/build/quality-runtime.log"
PORT=$((40000 + $$ % 20000))
while /usr/sbin/lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; do
  PORT=$((PORT + 1))
done
SERVER_PID=""
RUNTIME_ARCH="${LINEA_RUNTIME_ARCH:-$(uname -m)}"

run_runtime() {
  if [[ "$RUNTIME_ARCH" == "$(uname -m)" ]]; then
    exec "$RUNTIME" "$@"
  else
    exec /usr/bin/arch "-$RUNTIME_ARCH" "$RUNTIME" "$@"
  fi
}

cleanup() {
  local status=$?
  trap - EXIT
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  exit "$status"
}
trap cleanup EXIT

test -x "$RUNTIME"
test -f "$AUDIO"
if [[ ! -f "$MODEL_PATH" ]]; then
  echo "Qwen model not found. Download it in Linea Lite or set LINEA_MODEL_PATH." >&2
  exit 2
fi

xcrun swiftc -O -warnings-as-errors -strict-concurrency=complete \
  -framework AVFoundation \
  "$ROOT/Sources/LineaLite/AudioSegmentation.swift" \
  "$ROOT/Sources/LineaLite/TextCleanup.swift" \
  "$ROOT/Sources/LineaLite/WorkspaceVocabulary.swift" \
  "$ROOT/Sources/LineaLite/QwenRuntime.swift" \
  "$ROOT/Tests/Quality/main.swift" \
  -o "$CHECKER"

run_runtime --server --host 127.0.0.1 --port "$PORT" \
  --backend qwen3 -m "$MODEL_PATH" -np -nt -l auto --lid-backend off \
  --ws-port -1 --wyoming-port -1 >"$LOG" 2>&1 &
SERVER_PID=$!
for _ in {1..300}; do
  if curl --fail --silent "http://127.0.0.1:$PORT/health" >/dev/null; then break; fi
  kill -0 "$SERVER_PID"
  sleep 0.05
done
curl --fail --silent "http://127.0.0.1:$PORT/health" >/dev/null

check_audio() {
  local audio="$1"
  local reference="$2"
  shift 2
  local response
  response="$(curl --fail --silent --show-error --max-time 180 \
    --form "file=@$audio" \
    --form language=auto \
    --form lid_backend=off \
    --form no_timestamps=true \
    "http://127.0.0.1:$PORT/inference")"
  test -n "$response"
  "$CHECKER" "$response" "$reference" "$@"
}

if [[ -n "$MANIFEST" ]]; then
  test -f "$MANIFEST"
  count=0
  total_cer=0
  worst_cer=0
  while IFS=$'\t' read -r audio reference; do
    test -f "$audio"
    count=$((count + 1))
    echo "Human voice quality $count: $(basename "$audio")"
    result="$(LINEA_MAX_CER=10 check_audio "$audio" "$reference" 2>&1)"
    echo "$result"
    cer="$(awk '$1 == "CER" { print $2; exit }' <<<"$result")"
    test -n "$cer"
    total_cer="$(awk -v total="$total_cer" -v cer="$cer" 'BEGIN { print total + cer }')"
    if awk -v cer="$cer" -v worst="$worst_cer" 'BEGIN { exit !(cer > worst) }'; then
      worst_cer="$cer"
    fi
  done < <(/usr/bin/ruby -rjson -e \
    'ARGF.each_line { |line| row = JSON.parse(line); puts [row.fetch("audio"), row.fetch("reference")].join("\t") }' \
    "$MANIFEST")
  test "$count" -gt 0
  average_cer="$(awk -v total="$total_cer" -v count="$count" 'BEGIN { print total / count }')"
  printf 'Human voice corpus: %d recordings, average CER %.4f, worst CER %.4f\n' \
    "$count" "$average_cer" "$worst_cer"
  awk \
    -v average="$average_cer" \
    -v worst="$worst_cer" \
    -v maximum_average="${LINEA_MAX_AVERAGE_CER:-0.23}" \
    -v maximum_worst="${LINEA_MAX_WORST_CER:-0.75}" \
    'BEGIN {
      if (average > maximum_average || worst > maximum_worst) {
        printf "Human voice CER gate failed (average %.4f/%.2f, worst %.4f/%.2f)\n", average, maximum_average, worst, maximum_worst > "/dev/stderr"
        exit 1
      }
    }'
else
  check_audio "$AUDIO" "$REFERENCE" Qwen3-ASR 0.6B 4-bit MLX balanced
fi
