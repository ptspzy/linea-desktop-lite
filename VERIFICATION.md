# 0.2.6 Omitted Branch Separator

Local run: 2026-09-18. The reported `在DEV一点一分支` now becomes
`在dev/1.1分支`. Known branch prefixes may omit the slash only when the version
is immediately followed by `分支` (horizontal spaces allowed). Existing explicit
`DEV/1.1`, quoted text, paths and ordinary version descriptions remain unchanged.

- The exact user text failed before the fix and passes afterward, including terminal
  single-line formatting. Multiple components and two branches in one utterance are covered.
- `make lint coverage package smoke test-quality test-quality-x86
  BUILD_DIR=build/branch-context` passed. Core line coverage: 86.53%; formatter: 97.60%.
  The existing branch/list/paragraph synthetic fixtures and long-audio gates pass on
  native arm64 and x86_64/Rosetta. This is not physical Intel/macOS 13 verification.
- An additional silent Tingting sample saying `在 DEV 一点一分支` failed exact audio
  acceptance: Qwen produced `在Dev一点一分之` (CER 0.6000). Adding `分支` to CLI
  hotwords did not resolve it and was not shipped. This homophone error remains open;
  the formatter does not globally rewrite `分之` or guess arbitrary recognition errors.
  Logs: `build/branch-context-{red,green,verification,audio,hotword}.log`.
- The signed Universal model-free 0.2.6 bundle is installed and running, matches the
  verified binary, and the standard build copy is updated. 0.2.5 is backed up under
  `build/rollback`; the production history checksum is unchanged across installation.
  No audio was played and no volume settings were changed. Computer launched the app
  but its windowless accessibility inspection timed out, so physical microphone/cursor
  delivery is not claimed as revalidated.

# 0.2.5 Developer Dictation and Structure

Local run: 2026-09-18. Scope: developer identifiers, explicit lists and paragraph breaks,
keeping the existing local Qwen model, lightweight app, single-sentence punctuation preference,
and terminal single-line safety. No cloud rewriting, new model, or runtime dependency was added.

References reviewed (behavioral comparison, not copied implementation):

- [Handy transcription pipeline](https://github.com/cjpais/Handy/blob/ba10ce1943ef34e93c09494027fc0b9ced2e8a44/src-tauri/src/managers/transcription.rs):
  vocabulary at decode time where supported, separate post-correction otherwise.
- [Handy cleanup prompt](https://github.com/cjpais/Handy/blob/ba10ce1943ef34e93c09494027fc0b9ced2e8a44/src-tauri/src/settings.rs):
  numeric/symbol normalization with meaning and order preservation.
- [Wispr Flow smart formatting](https://docs.wisprflow.ai/articles/5373093536-how-do-i-use-smart-formatting-and-backtrack):
  ordinal lists and explicit line/paragraph commands.

Changes and acceptance:

- Existing personal/workspace canonical terms now reach local Qwen HTTP requests and CLI retries.
  Deduplication, 64-term/1,024-byte limits and literal form encoding are tested. Recognition-only
  hints do not lowercase ordinary English prose or modify personal vocabulary files.
- `dev/一点一`, spoken slash variants and multi-component versions normalize locally.
  Paths, quoted literals, dates/rankings, missing list items and existing numeric identifiers
  have negative regression cases. Ambiguous omitted separators are not guessed.
- Consecutive `第一/第二/第三` and `第一点/第一步` work without an announced total.
  Distinct `换行/换段` between phrases preserve structure. Existing newlines and fenced code
  survive; paragraph cues inside ordinary words no longer split prose.
- Red/green logs are under `build/*-red.log` and `build/*-green.log`.
- Final `make lint coverage package smoke test-quality test-quality-x86
  BUILD_DIR=build/developer-format` passed. Core line coverage: 86.49%; formatter: 97.58%.
  Coverage excludes the app coordinator and native UI, not whole-app coverage.
- All three new synthetic audio fixtures produce exact expected branch/list/paragraph results
  (CER 0.0000) on native arm64 and x86_64/Rosetta. Decimal and three-segment completeness gates pass.
- Universal model-free DMG verifies. Installed `/Applications/Linea Lite.app` and the normal
  build bundle match the verified 0.2.5 binary; the application is running. 0.2.4 is backed up
  under `build/rollback`. The production history checksum is unchanged.

Limits: these are reproducible synthetic integration tests, not a head-to-head accuracy benchmark
against commercial products. Early combined utterances still exposed model-dependent word/separator
errors; arbitrary phonetic mistakes are not safely recoverable by formatting alone. The private
human-reference corpus is unavailable. Physical microphone/cursor delivery and physical Intel/macOS
13 hardware were not revalidated in this change; Computer could launch the accessory app but could
not inspect its windowless UI. No audio playback or volume changes occurred.

# 0.2.4 Straight-Edge Progress

Local run: 2026-09-10. The moving fill now has a vertical leading edge, including the
completion animation; rounding belongs only to the fixed outer track. The waiting fill
continues left-to-right and stays below full width until the success callback completes
the final animation. It remains a waiting affordance, not a measured ASR percentage.

The new straight-edge assertion failed on the old implementation. `make test-hud` now
passes, including pixel samples at the top/middle/bottom of the rendered leading edge,
nondecreasing animation widths beyond eight seconds, success-only full width, and state
cleanup. The midpoint screenshot was visually checked. Recognition and insertion logic
are unchanged; no audio playback or volume changes were used for this UI test.
`make lint package smoke` also passed. Normal 0.2.4 is installed and running, its binary
matches the verified Universal build, and the existing history checksum is unchanged.
The prior 0.2.3 app is retained under `build/rollback`.

# 0.2.3 Current-Cursor Delivery

Local run: 2026-09-10. Two subsequent user captures reported
`capture-focus-unavailable(-25212)`: the editor returned `kAXErrorNoValue` for its focus
attribute. Recognition succeeded, but the original-target check prevented Cmd+V.

The user explicitly requested insertion at the current cursor. The earlier original-field
matching policy is therefore replaced: normal dictation sends Cmd+V to the live keyboard
focus, without requiring AX focus/selection metadata from the editor. Accessibility
permission, held modifiers, secure event input and detectable password fields still block
automatic delivery. Cancellation and copy-only retry of an older recording are preserved.
Copy-only fallback has a distinct HUD hint and fixed diagnostic reason codes.

The regression for missing AX focus failed against the old policy, then passed with the
new policy. `make lint test`, `make coverage test-hud package`, and `make smoke` passed.
Core line coverage is 85.36%; this is not whole-app or end-to-end coverage. The Universal
model-free DMG verifies, and both architecture slices still target macOS 13.0.

The existing Cmd+V transport is unchanged from the pre-focus-guard implementation.
A temporary AppKit recipient was exercised through Computer, but empty/duplicated field
observations were inconsistent; it was not accepted as end-to-end proof, and the temporary
recipient/activation scaffolding was removed. The actual ChatGPT app remains inaccessible
to Computer. Real-editor insertion is not claimed as verified by these automated checks.
No speech-model or formatter change was made, and no audio was played.
The final normal 0.2.3 app is installed and running; its binary matches the verified
Universal build, no test controls are included, and the production history checksum
remains unchanged. The previous normal and diagnostic bundles are kept in `build/rollback`.

The diagnostic checkpoint below is historical, not the final 0.2.3 behavior.

# Cursor Delivery Diagnostic Checkpoint

Local run: 2026-09-10. The goal is reliable cursor insertion without pasting into a
different field or deleting existing history. Four of the last five production summaries
reported successful recognition followed by `Copied only`, all targeting ChatGPT.
The old summaries do not identify which focus/permission check blocked delivery, so the
precise root cause is not established. No focus protection has been removed.

The installed local diagnostic build adds fixed, text-free reason codes for unavailable
capture/delivery focus, changed application/element/selection, missing accessibility
permission, held modifiers and event creation failure. Copy-only results now show a
distinct paste hint instead of the completion animation. `make test` and `make test-hud
build` passed; the copy-only hint fits the unchanged HUD and its timer cannot dismiss a
subsequent recording. The installed binary matches the tested build; the production
history checksum is unchanged. No audio playback or volume change was made.

Computer access to the target ChatGPT app was refused by the tool, so no alternate API
was used to inspect or control that app. A physical shortcut test by the user is needed
to collect the specific failure reason. Automatic cursor delivery is **not yet verified
as fixed**. This diagnostic build is not a new distribution package; the prior 0.2.2
bundle is retained under `build/rollback/Linea Lite 0.2.2.app`.

# 0.2.2 Feedback and Number Formatting

The user prefers the original left-to-right visual feedback over the 0.2.1 spinner.
The HUD now uses a one-way waiting fill, no visible label, and a subtle left-to-right sheen.
The fill stops short of the edge until real completion; it is not a measured percentage.
Recording uses a smaller red center with a fine outline and a separate waveform area.
The frame remains 118 x 30 points. `make test-hud` passed, including sampled nondecreasing
fill widths beyond the original reversal point, completion, marker spacing, and cleanup.

Spoken Chinese decimals are normalized as strings, preserving every digit and trailing zero.
Standalone numbers and clear numeric contexts (including ports, versions, line numbers,
percentages, and the user's example phrasing) prefer Arabic numerals. Ambiguous prose,
time expressions, quoted content, and detected code/paths are guarded; this is not a general
Chinese-language rewriting engine. Canonical unit-form integers are capped at 15 digits.

Final local gates passed:

```sh
make lint test-hud coverage package smoke test-quality test-quality-x86
```

- Core line coverage: 84.55%, excluding the coordinator and UI as described below.
- The exact spoken decimal fixture yields `数值是3.14159263`, CER 0.0000 on arm64 and
  x86_64/Rosetta through the production recognition/formatting pipeline.
- Controlled long-audio completeness passes on both runtimes; CER 0.1220 / 0.0813.
- Full-Linea synthetic corpus: 40 samples, mean CER 0.1357, worst 0.7333, below unchanged
  gates of 0.23 / 0.75. These are literal comparisons, not proof of overall ASR accuracy
  improvement. The recognition model is unchanged; formatting has its own exact-output tests.
- Universal signatures, model-free DMG verification and launch smoke pass. Normal 0.2.2
  is installed and running, with the original history checksum unchanged.
- No audio playback or volume change. The private human corpus and physical macOS 13/Intel
  machines remain unavailable; those earlier verification limits still apply.

The entries below describe historical runs, not validation of every later release.

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
