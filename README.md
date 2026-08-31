# Linea Desktop Lite

Minimal macOS menu bar dictation app extracted from the Linea idea for open source.

## Scope

Included:

- Native macOS microphone capture.
- Ten-minute recording safety limit and stale temporary-audio cleanup.
- Silence-aware segmentation around 40 seconds with overlap and an eight-second minimum tail.
- Rejection of pathological repeated ASR output before cursor insertion or history storage.
- Qwen3-ASR 0.6B Q4_K local speech recognition for zh-CN.
- Native automatic punctuation and local format-only paragraph/list formatting.
- Choose right `Option`, right `Control`, or right `Command`; tap to start/stop or hold for push-to-talk.
- Linea-style floating waveform while recording and processing.
- Paste into the current cursor location.
- Restore the previous clipboard after automatic paste without overwriting newer clipboard changes.
- Searchable local transcript history, copy actions, and a 16-week activity graph in the menu bar.
- One active workspace vocabulary for local product and technical terms.
- Local diagnostics for timings, permissions, architecture, and model status without transcript or audio data.

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

macOS will ask for microphone permission on first use. Linea shows a first-run prompt to choose the
separately supplied `qwen3-asr-0.6b-q4_k.gguf` model (about 602 MiB). The app verifies its exact size
and SHA-256 before moving it to `~/Library/Application Support/Linea Lite/models/`; an invalid model
is rejected without removing the selected file. The app and DMG do not contain the model.
Recognition remains local and uses Qwen only.
Accessibility permission is needed for shortcut detection and automatic paste. Once it is enabled, Linea starts listening without a restart.
Transcript text, time, duration, and target-app name are stored locally in `~/Library/Application Support/Linea Lite/history.json`.
Unreadable history is moved to a private `history-corrupt-*.json` backup before new entries are saved.

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
make test-quality
make test-quality-corpus
```

`make test` runs optimized Swift checks with compiler warnings and complete concurrency violations treated as errors. `make coverage`
enforces at least 70% line coverage across the testable core. `make test-quality`
silently replays the included short WAV through the installed local model and enforces CER and required
developer terms; it never plays the audio. The model must already be installed, or supplied through
`LINEA_MODEL_PATH`.

`make test-quality-corpus` additionally replays the previous Linea installation's local human voice
corpus when it exists, enforcing average and worst-case CER regression limits. Those personal recordings
remain outside this repository and are never packaged.

Run the complete local gate when both architecture runtimes and the model are available:

```bash
make verify
```

This cleans the build, runs tests, creates and verifies the Universal DMG, launches the built app as a
smoke test, and runs the real-model quality check natively and through x86_64/Rosetta. Pull requests run optimized tests and compile checks
on Apple Silicon and Intel through GitHub Actions.

## Package

```bash
make runtimes
make package
```

This creates one Universal DMG in `build/` for Apple Silicon and Intel, without the ASR model.
Packaging is blocked when the test suite fails.
Intel uses Accelerate instead of Metal and is expected to transcribe more slowly.
The default package is locally signed. Internal distribution without a Gatekeeper warning requires
the company's Developer ID Application certificate and Apple notarization.

After storing notarytool credentials in a keychain profile, create the hardened, notarized release with:

```bash
make release \
  SIGN_IDENTITY="Developer ID Application: Company Name (TEAMID)" \
  NOTARY_PROFILE="linea-notary"
```

## License

Apache-2.0.
