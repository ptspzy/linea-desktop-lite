# Linea Desktop Lite

Minimal macOS menu bar dictation app extracted from the Linea idea for open source.

## Scope

Included:

- Native macOS microphone capture.
- Qwen3-ASR 0.6B Q4_K local speech recognition for zh-CN.
- Native automatic punctuation and local format-only paragraph/list formatting.
- Push-to-talk dictation by holding the right `Option` key.
- Linea-style floating waveform while recording and processing.
- Paste into the current cursor location.
- Local transcript history and a 16-week activity graph in the menu bar.

Not included:

- Accounts, activation codes, payments, telemetry, updater, or server APIs.
- Bundled ASR model, Python sidecars, benchmarks, audio archive, or agents.
- Remote mic, cloud correction, vocabulary packs, windows, editors, or insight pages.

## Requirements

- macOS 13 or newer.
- Xcode command line tools.
- A `qwen-asr` runtime built from [CrispASR](https://github.com/CrispStrobe/CrispASR).

## Build

```bash
QWEN_ASR_BIN=/path/to/qwen-asr make build
```

The app bundle is written to:

```text
build/Linea Lite.app
```

## Run

```bash
make run
```

macOS will ask for microphone permission on first use. The first transcription downloads the
SHA-256-pinned Qwen3-ASR model (about 602 MiB) to `~/Library/Application Support/Linea Lite/models/`.
Recognition remains local and uses Qwen only.
Accessibility permission is needed for right-Option detection and automatic paste. Once it is enabled, Linea starts listening without a restart.
Transcript text, time, duration, and target-app name are stored locally in `~/Library/Application Support/Linea Lite/history.json`.

## Test

```bash
make test
```

## License

Apache-2.0.
