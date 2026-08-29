# Linea Desktop Lite

Minimal macOS menu bar dictation app extracted from the Linea idea for open source.

## Scope

Included:

- Native macOS microphone capture.
- Native macOS on-device speech recognition for zh-CN.
- Push-to-talk dictation by holding the right `Option` key.
- Linea-style floating waveform while recording and processing.
- Paste into the current cursor location.
- Session stats in the menu bar.

Not included:

- Accounts, activation codes, payments, telemetry, updater, or server APIs.
- Bundled ASR models, Python sidecars, benchmarks, history database, or agents.
- Remote mic, cloud correction, vocabulary packs, windows, editors, or insight pages.

## Requirements

- macOS 13 or newer.
- Xcode command line tools.

## Build

```bash
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

macOS will ask for microphone and speech-recognition permission on first use.
The app intentionally does not fall back to cloud recognition.
Accessibility permission is needed for right-Option detection and automatic paste. Once it is enabled, Linea starts listening without a restart.

## Test

```bash
make test
```

## License

Apache-2.0.
