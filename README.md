# Linea Desktop Lite

Minimal macOS menu bar dictation app extracted from the Linea idea for open source.

## Scope

Included:

- Native macOS microphone capture.
- Qwen3-ASR 0.6B Q4_K local speech recognition for zh-CN.
- Native automatic punctuation and local format-only paragraph/list formatting.
- Tap right `Option` to start/stop, or hold it for push-to-talk dictation.
- Linea-style floating waveform while recording and processing.
- Paste into the current cursor location.
- Local transcript history and a 16-week activity graph in the menu bar.
- One active workspace vocabulary for local product and technical terms.

Not included:

- Accounts, activation codes, payments, telemetry, updater, or server APIs.
- Bundled ASR model, Python sidecars, benchmarks, audio archive, or agents.
- Remote mic, cloud correction, windows, editors, or insight pages.

## Requirements

- macOS 13.5 or newer on Apple Silicon or Intel.
- Xcode command line tools and CMake to build the pinned [CrispASR](https://github.com/CrispStrobe/CrispASR) runtime.

## Build

```bash
make runtime-$(uname -m)
make build
```

The app bundle is written to:

```text
build/Linea Lite.app
```

## Run

```bash
make run
```

macOS will ask for microphone permission on first use. Linea shows a first-run prompt to download the
SHA-256-pinned Qwen3-ASR model (about 602 MiB) to `~/Library/Application Support/Linea Lite/models/`,
with progress in its menu; the app and DMG do not contain the model.
Recognition remains local and uses Qwen only.
Accessibility permission is needed for right-Option detection and automatic paste. Once it is enabled, Linea starts listening without a restart.
Transcript text, time, duration, and target-app name are stored locally in `~/Library/Application Support/Linea Lite/history.json`.

Choose a workspace from the menu to preserve its folder name, npm package name, and direct dependency names. For explicit recognition corrections, add `.linea-vocabulary.json` at the workspace root:

```json
{
  "terms": [
    { "canonical": "Typeless", "aliases": ["Tablas"] },
    { "canonical": "Qwen3-ASR", "aliases": ["千问三 ASR"] }
  ]
}
```

Only the listed aliases and canonical capitalization are corrected; audio and workspace files remain local.

## Test

```bash
make test
```

## Package

```bash
make runtimes
make package
```

This creates one Universal DMG in `build/` for Apple Silicon and Intel, without the ASR model.
Intel uses Accelerate instead of Metal and is expected to transcribe more slowly.
The default package is locally signed. Internal distribution without a Gatekeeper warning requires
the company's Developer ID Application certificate and Apple notarization.

## License

Apache-2.0.
