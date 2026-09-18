#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${1:-$ROOT/build/Linea Lite.app}"
RUNTIME="$APP_DIR/Contents/Resources/bin/qwen-asr"
MODEL_PATH="${LINEA_MODEL_PATH:-$HOME/Library/Application Support/Linea Lite/models/qwen3-asr-0.6b-q4-k/f63771c02dfa486d9399d41ab6ab8cd2d8ca24e077cd32130ea1f67f4fd8dade/qwen3-asr-0.6b-q4_k.gguf}"
AUDIO="$ROOT/Tests/Fixtures/reference-004.wav"
REFERENCE="当前模型使用 Qwen3-ASR 0.6B 4-bit MLX balanced。"
MANIFEST="${LINEA_QUALITY_MANIFEST:-}"
RUNTIME_ARCH="${LINEA_RUNTIME_ARCH:-$(uname -m)}"
case "$RUNTIME_ARCH" in
  arm64|x86_64) ;;
  *) echo "LINEA_RUNTIME_ARCH must be arm64 or x86_64." >&2; exit 2 ;;
esac
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/linea-quality.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
CHECKER="$WORK_DIR/quality-check"
export LINEA_QWEN_RUNTIME="$RUNTIME" LINEA_MODEL_PATH="$MODEL_PATH" LINEA_RUNTIME_ARCH="$RUNTIME_ARCH"

test -x "$RUNTIME"
test -f "$AUDIO"
if [[ ! -f "$MODEL_PATH" ]]; then
  echo "Qwen model not found. Import it in Linea Lite or set LINEA_MODEL_PATH." >&2
  exit 2
fi

xcrun swiftc -O -warnings-as-errors -strict-concurrency=complete \
  -target "$(uname -m)-apple-macosx13.0" \
  -framework AVFoundation \
  "$ROOT/Sources/LineaLite/AudioSegmentation.swift" \
  "$ROOT/Sources/LineaLite/TextCleanup.swift" \
  "$ROOT/Sources/LineaLite/WorkspaceVocabulary.swift" \
  "$ROOT/Sources/LineaLite/QwenRuntime.swift" \
  "$ROOT/Tests/Quality/main.swift" \
  -o "$CHECKER"

check_audio() {
  "$CHECKER" "$@"
}

if [[ -n "$MANIFEST" ]]; then
  test -f "$MANIFEST"
  count=0
  total_cer=0
  worst_cer=0
  /usr/bin/ruby -rjson -e '
    ARGF.each_line do |line|
      row = JSON.parse(line)
      fields = [row.fetch("audio"), row.fetch("reference")]
      abort "Manifest fields must be nonempty single-line strings" unless fields.all? { |v| v.is_a?(String) && !v.empty? && v !~ /[\t\r\n]/ }
      puts fields.join("\t")
    end
  ' "$MANIFEST" >"$WORK_DIR/manifest.tsv"
  while IFS=$'\t' read -r audio reference; do
    test -f "$audio"
    count=$((count + 1))
    echo "Voice quality $count: $(basename "$audio")"
    if ! result="$(LINEA_MAX_CER=10 check_audio "$audio" "$reference" 2>&1)"; then
      printf '%s\n' "$result" >&2
      exit 1
    fi
    echo "$result"
    cer="$(awk '$1 == "CER" { print $2; exit }' <<<"$result")"
    test -n "$cer"
    total_cer="$(awk -v total="$total_cer" -v cer="$cer" 'BEGIN { print total + cer }')"
    if awk -v cer="$cer" -v worst="$worst_cer" 'BEGIN { exit !(cer > worst) }'; then
      worst_cer="$cer"
    fi
  done <"$WORK_DIR/manifest.tsv"
  test "$count" -gt 0
  average_cer="$(awk -v total="$total_cer" -v count="$count" 'BEGIN { print total / count }')"
  printf 'Voice corpus: %d recordings, average CER %.4f, worst CER %.4f\n' \
    "$count" "$average_cer" "$worst_cer"
  awk \
    -v average="$average_cer" \
    -v worst="$worst_cer" \
    -v maximum_average="${LINEA_MAX_AVERAGE_CER:-0.23}" \
    -v maximum_worst="${LINEA_MAX_WORST_CER:-0.75}" \
    'BEGIN {
      if (average > maximum_average || worst > maximum_worst) {
        printf "Voice CER gate failed (average %.4f/%.2f, worst %.4f/%.2f)\n", average, maximum_average, worst, maximum_worst > "/dev/stderr"
        exit 1
      }
    }'
else
  check_audio "$AUDIO" "$REFERENCE" Qwen3-ASR 0.6B 4-bit MLX balanced
  check_audio "$ROOT/Tests/Fixtures/spoken-decimal.wav" "数值是3.14159263" 3.14159263
  check_audio "$ROOT/Tests/Fixtures/developer-branch.wav" "分支是dev/1.1" "dev/1.1"
  check_audio "$ROOT/Tests/Fixtures/developer-list.wav" \
    $'1. 修复登录\n2. 补充测试\n3. 发布版本' $'1. 修复登录\n2. 补充测试\n3. 发布版本'
  check_audio "$ROOT/Tests/Fixtures/developer-paragraphs.wav" \
    $'接口已经修复。\n\n接下来补测试。\n\n最后发布版本。' \
    $'接口已经修复。\n\n接下来补测试。\n\n最后发布版本。'
fi

# Synthetic fixture only: three separated utterances cover beginning/middle/end without playback.
"$CHECKER" --long-fixture "$AUDIO" "$REFERENCE" Qwen3-ASR 0.6B 4-bit MLX balanced
