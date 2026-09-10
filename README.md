# Linea Desktop Lite

Minimal macOS menu bar dictation app extracted from the Linea idea for open source.

## Scope

Included:

- Native macOS microphone capture.
- Ten-minute recording safety limit and stale temporary-audio cleanup.
- Failed recordings can be retried locally for ten minutes, then are deleted; successful recordings are removed immediately.
- Silence-aware segmentation around 40 seconds with overlap and an eight-second minimum tail.
- Rejection of pathological repeated ASR output before cursor insertion or history storage.
- Qwen3-ASR 0.6B Q4_K local speech recognition for zh-CN.
- Native automatic punctuation and local format-only paragraph/list formatting.
- Exact spoken Chinese decimals and clear coding-number contexts use Arabic numerals; ambiguous prose,
  idioms, time expressions, and detected code/paths are preserved. Fractional zeros are not rounded away.
- Choose right `Option`, right `Control`, right `Command`, or an exclusive custom modifier/key combination; tap to start/stop or hold for push-to-talk. Escape cancels recording or pending output.
- Linea-style floating waveform while recording and processing.
- Paste completed dictation at the current keyboard cursor, even when the editor does not expose AX focus metadata or the cursor moved during recording. Accessibility permission, released modifiers, and secure-input/password-field checks still apply. Retrying an older failed recording remains copy-only. A dispatched paste is not claimed as confirmed insertion.
- Restore the previous clipboard after automatic paste without overwriting newer clipboard changes.
- Searchable local transcript history, full-text preview, copy/correction/delete actions, and a compact 16-week activity graph. Counts describe retained records, not lifetime usage; the menu bar shows today's retained count.
- History retention of up to 500 records by default, with explicit 7/30/90-day options. Shortening retention or clearing history requires confirmation.
- One active workspace vocabulary and explicit personal mistake-to-correction pairs for local product and technical terms. No training or cloud correction is performed.
- Local diagnostics for capture readiness, model readiness, segmentation, retries, timings, permissions, OS and architecture without transcript or audio data.
- Opt-in manual HTTPS version checks and verified installer downloads; models remain separate.

Not included:

- Accounts, activation codes, payments, telemetry, automatic installation, or remote speech APIs.
- Bundled ASR model, Python sidecars, benchmarks, audio archive, or agents.
- Remote mic, cloud correction, windows, editors, or insight pages.

## Requirements

- macOS 13.0 or newer on Apple Silicon or Intel.
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

Linea guides first-run setup in order: choose the separately supplied
`qwen3-asr-0.6b-q4_k.gguf` model (about 602 MiB), allow microphone access, then allow Accessibility.
The app verifies the model's exact size
and SHA-256 before moving it to `~/Library/Application Support/Linea Lite/models/`; an invalid model
is rejected without removing the selected file. The app and DMG do not contain the model.
Recognition remains local and uses Qwen only.
Accessibility permission is needed for shortcut detection and automatic paste. Once it is enabled, Linea starts listening without a restart.
Transcript text, time, duration, and target-app name are stored locally in `~/Library/Application Support/Linea Lite/history.json`.
Unreadable history is moved to a private `history-corrupt-*.json` backup before new entries are saved.
Existing array-format history is migrated without dropping entries. New history writes include the retention policy.
Explicitly clearing all history also deletes its corrupt-file backups. Personal vocabulary is stored separately in
`~/Library/Application Support/Linea Lite/personal-vocabulary.json` with owner-only file permissions.
Failed audio is held only in private temporary files; quitting deletes held retries. After a crash, stale files
are removed on the next launch. History and vocabulary are local plaintext, not an encrypted vault.

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
make test-menu
make test-hud
```

`make test` runs optimized Swift checks with compiler warnings and complete concurrency violations treated as errors,
including failure recovery, history migration, numbered text, shortcut states, and offline update transport tests. `make coverage`
enforces at least 70% line coverage across the testable core. `make test-quality`
silently replays the included short WAV and controlled long audio through the production segmentation/recognition/merge pipeline and enforces CER and required
developer terms; it never plays the audio. The model must already be installed, or supplied through
`LINEA_MODEL_PATH`.

`make test-quality-corpus` additionally replays the previous Linea installation's local human voice
corpus when it exists, enforcing average and worst-case CER regression limits. Those personal recordings
remain outside this repository and are never packaged.

`make test-menu` verifies native AppKit layout and interactions in light/dark appearances at multiple widths,
and writes synthetic screenshots to `build/menu-snapshots`. No personal history is loaded by these checks.
`make test-hud` checks the one-way waiting fill, recording marker spacing, state transitions, and cancellation
of stale hide timers; its synthetic screenshot is written to `build/hud-snapshots`.
For interactive tests, `make ui-test-build` builds a separate, compile-time-instrumented app. Launch it with
`--ui-test-directory /absolute/test-folder --ui-test-audio /absolute/synthetic.wav` to isolate history/preferences
and exercise the normal recognition/output flow without playing audio. Omit the audio argument to test the
real microphone. The test controls, injected audio and artificial delay are absent from release builds.

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

## Manual Updates

Updates are opt-in: configure the trusted team's HTTPS manifest address, then explicitly check
for a newer version. No release endpoint is bundled. The helper downloads only on request and
returns a verified DMG for manual installation; it never opens, mounts, or installs it, removes
quarantine, or bypasses Gatekeeper. The ASR model remains a separate download/import.

The configured feed operator is the trust point. HTTPS uses the system's certificate trust,
including company-installed trusted certificates. Enterprise DNS names (including `.internal`
and single-label names) and HTTPS ports such as 8443 are supported. URLs must have no credentials,
fragment, or traversal path. IP literals, localhost, and `.local` hosts are rejected. This is URL
validation, not a DNS/IP firewall: a trusted company hostname may resolve to a private address.
Manifest redirects must retain the original HTTPS host and port. DMG URLs and their redirects may
use a different HTTPS CDN host under the same URL rules; at most five redirects are accepted.
Cookies and stored HTTP credentials are not sent.

The JSON manifest uses `schemaVersion: 1`, required string fields `version`, `minimumSystemVersion`,
`downloadURL`, and `sha256`, plus an optional integer `byteCount`. Unknown fields and unsupported
schemas are rejected. Versions contain one to three numeric components without leading zeros or
prerelease/build suffixes; `1.10` is newer than `1.9`, and `1` equals `1.0.0`. `downloadURL` must end
in `.dmg` before any query, and `sha256` must be exactly 64 lowercase hexadecimal characters.

Checks accept at most 64 KiB of manifest data. Installers are limited to 1 GiB and require matching
SHA-256, matching `byteCount` when supplied, and a UDIF DMG trailer. Transfers use a 30-second idle
timeout, a 30-second manifest deadline, and a 15-minute installer deadline. Downloads stay in a
private staging folder until verification succeeds, then move to the chosen new `.dmg` path or a
unique filename in Downloads, with quarantine metadata. Existing files are never replaced; failed
or cancelled transfers remove staging files. Progress reports downloaded bytes, not verification
completion; only a successful return from `AppUpdate.downloadVerified` means the file is ready.

SHA-256 detects a mismatched or tampered download, **not an untrusted publisher**: authenticity here
depends on the trusted HTTPS feed. It does not replace Developer ID signing or Apple notarization.
Generate the manifest from the final DMG **after** signing/notarization/stapling, using your actual
artifact path, release version, and hosted DMG URL:

```bash
./scripts/create-update-manifest.sh "$DMG_PATH" "$RELEASE_VERSION" "$HTTPS_DMG_URL" 13.0 > update-manifest.json
```

The script requires the build tools' Python 3 standard library and writes JSON to stdout; it does
not upload anything. Host the DMG and manifest yourself, then configure that manifest's HTTPS URL.
The UI calls `AppUpdate.validatedHTTPSURL`, `AppUpdate.fetchNewer(from:currentVersion:)`, and
`AppUpdate.downloadVerified(_:to:progress:)`. Both network operations are async, propagate task
cancellation, and have no MainActor/UI dependency. `runUpdateRegressionTests()` is an async throwing
offline check using an isolated URLProtocol, including the manifest generator round trip.

## License

Apache-2.0.
