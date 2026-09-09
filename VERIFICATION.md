# 0.2.1 Loading Indicator

Local run: 2026-09-09. The previous timed, autoreversing fill did not measure recognition
progress. It is replaced with the native AppKit indeterminate spinner and a short status
label, preserving the 118 x 30 point HUD. No percentage or time estimate is invented.
Microphone startup and model import use the same indicator with their own labels.

`make test-hud` passed: processing remains a spinner beyond the old 2.4-second turning
point, all three labels fit, recording/completion/error remove the spinner, hidden HUDs
stop animation, and stale completion/error timers cannot hide a new recognition session.
This narrow UI change does not alter the ASR model or recognition pipeline. The 0.2.0
quality numbers below are the previous run, not a new 0.2.1 speech-quality measurement.
`make lint package smoke` also passed, including the core regression suite, Universal
build/signature checks, and DMG validation. Normal 0.2.1 is installed and running locally;
the existing history checksum is unchanged. No playback or volume changes were made.

# 0.2.0 Verification

Local run: 2026-09-09. Goal: reliable, lightweight, local menu-bar dictation for developers.
Keep the model separate, retain existing user data, and keep low-frequency controls in Settings.
No cloud recognition, automatic installation, or additional framework was added.

## Passed Locally

```sh
make lint coverage package smoke test-quality test-quality-corpus test-quality-x86 test-menu
```

- Optimized Swift tests with warnings-as-errors and complete concurrency checking.
- Core line coverage: 83.70%. This excludes the app coordinator, HUD, and history menu view;
  it is not whole-application or end-to-end coverage.
- Text cases: single sentences, three paragraphs, flat/nested lists, versions, decimals,
  paths, repeated prefixes, and explicit personal vocabulary corrections.
- Recognition cases: partial file reads, segment boundaries, repeated utterances,
  incomplete-segment failure, cancellation, private retry expiry, and safe model replacement.
- History: non-destructive migration, write-failure recovery, correction, search, retention,
  and complete copying. AppKit light/dark snapshots at 320/380/392/400 points check bounds
  and overlap. Menu tests now run in local verification and CI.
- Update transport: offline protocol tests for validation, redirects, cancellation,
  size/checksum failures, and manifest generation. No public feed has been configured or tested.
- Universal app and runtime contain arm64/x86_64 slices targeting macOS 13.0; signatures
  and the model-free DMG checksum verify. Launch smoke test passes.
- Short audio CER: 0.0976 on both runtimes. Controlled long audio preserves all three
  beginning/middle/end utterances: CER 0.1220 arm64, 0.0813 x86_64/Rosetta.
- Production-pipeline timings in this run: short 1.340 s / 6.522 s, controlled long
  1.833 s / 13.374 s (arm64 / Rosetta). These are fixture results, not general latency promises.
- Existing full-Linea synthetic professional corpus: 40 samples, mean CER 0.1307,
  worst CER 0.7333. The existing 0.23 mean / 0.75 worst gates were unchanged.
  Some terminology remains wrong; passing this gate does not mean error-free recognition.
- Computer-driven isolated app: menu start/stop, injected failure followed by a successful
  real-model retry, history creation, focus-uncertain copy fallback, and Escape cancellation.
- Latest isolated build with no injected audio: actual microphone entered recording state;
  Escape stopped capture without adding history. No audio playback or volume changes.
- Normal 0.2.0 installed into Applications and launched; isolated test app exited. Existing
  history SHA-256 remained unchanged, and the installed binary contains no test-only markers.
  Previous 0.1.11 app bundle is retained under `build/rollback` for local rollback.

Package: `Linea-Lite-0.2.0-macos-universal.dmg`, 14,696,623 bytes (about 14.0 MiB).
SHA-256: `5af7b8b56899f3d9159ec44f41973cc565b7063fb02deb02195a7cdad02d27af`.
Separate model: 631,026,336 bytes (about 601.8 MiB), SHA-256
`f63771c02dfa486d9399d41ab6ab8cd2d8ca24e077cd32130ea1f67f4fd8dade`.

## Still Needs Verification

- The expected private human-labeled corpus is absent; that optional target explicitly
  skipped. Synthetic results must not be reported as real-user accuracy.
- Physical hold/tap keyboard shortcuts and end-to-end insertion into real target apps
  need manual acceptance. Computer's targeted events do not reliably exercise global
  Carbon hotkeys or modifier-only hardware events. State tests are not a substitute.
- No physical Intel machine or macOS 13 installation was available. Rosetta execution
  and deployment-target checks do not prove compatibility on those machines.
- No Developer ID, Apple notarization, or hosted update feed was used. Distribution is
  locally signed; this does not remove Gatekeeper prompts on another user's Mac.

## Manual Acceptance

In a disposable text field, hold the configured key, speak, and release; then tap once to
start and again to stop. Verify beginning and ending words, one insertion only, and no
clipboard loss. Repeat after switching target fields and while holding modifiers: the
app should copy instead of pasting into an unverified target. Press Escape during capture
and processing and confirm no later insertion. Test the same sequence in the team's actual
editor, browser, and chat client before broad distribution.

Quality logs and synthetic menu screenshots are local build outputs and are not packaged.
Test-only windows, injected audio, and the artificial test delay are compile-time gated
out of the normal app. The isolated test app must be exited before everyday use.
