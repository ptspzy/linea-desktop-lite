# Linea Desktop Lite

Minimal macOS desktop dictation app extracted from the Linea idea for open source.

## Scope

Included:

- Native macOS microphone capture.
- Native macOS on-device speech recognition for zh-CN.
- Transcript editing.
- Copy to clipboard.

Not included:

- Accounts, activation codes, payments, telemetry, updater, or server APIs.
- Bundled ASR models, Python sidecars, benchmarks, history database, or agents.
- Global shortcuts, remote mic, cloud correction, vocabulary packs, or insight pages.

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

## Test

```bash
make test
```

## License

Apache-2.0.
