# Captions — macOS live caption overlay

A menu-bar-only (no Dock icon) Mac app that captions your Mac's microphone and
system audio live, in a floating always-on-top panel. System audio is
captured from the apps themselves, so calls and videos are captioned even
through headphones. On macOS 26 and later captions are generated on-device
with Apple's SpeechAnalyzer and work with Siri & Dictation turned off (the
speech model for your language downloads once on first start). There's no app
server and no relay, and nothing is kept unless you turn on **Save Transcripts**.

## Features
- **Menu bar controls** — Start/Stop, and independent Microphone / System
  Audio toggles (`MacCaptionsApp.swift`, `AppModel`). The menu also shows a
  small status line (Connecting… / Listening… / the current error) driven by
  the caption store's state.
- **Floating caption panel** — translucent, always-on-top, non-activating
  panel (`CaptionPanel.swift`) showing live captions from both mic and system
  audio as flowing text, with pause/resume and stop controls that fade in on
  hover. Double-click the panel to zoom it to fill the screen; double-click
  again to restore. If the session hits an error, the panel shows the error
  message instead.
- **Speech recognition** — `AppModel.makeSpeechEngine()` picks the engine.
  Both are `CaptionEngine`s (from the `caption-core` package) whose `send(_:)`
  takes interleaved stereo PCM (mic + system audio, split by `StereoPCM`) and
  runs one recognizer per channel.
  - macOS 26+: `AnalyzerSpeechEngine.swift` streams each channel into its own
    `SpeechAnalyzer` + `SpeechTranscriber`, reporting in-progress text as
    partial captions and finished text as final ones. It does not need Siri &
    Dictation enabled. `start()` downloads the on-device model for your
    language if needed, then emits `.ready`; an unsupported language or failed
    download is shown as an error.
  - Earlier macOS: `AppleSpeechEngine.swift` wraps `SFSpeechRecognizer`, which
    refuses to run while Siri & Dictation are off; the panel says so and
    points to System Settings › Keyboard.
- **Global hotkey** — a menu-bar-independent shortcut (default ⌃⌥⌘C,
  configurable) toggles the caption overlay without needing to click the menu
  bar icon. `GlobalHotkey.swift` registers it with Carbon so it fires from any
  app; `HotkeyBinding.swift` is the persisted key/modifier value; the menu's
  native shortcut hint and the in-Settings recorder
  (`HotkeyRecorderField.swift`) both stay in sync with it.
- **Launch at login** — a toggle in Settings (`SettingsStore.swift`, backed by
  `SMAppService.mainApp`) registers Captions as a login item, since the
  global hotkey only works while the app is running.
- **Transcripts (opt-in)** — with **Save Transcripts** on (menu bar or
  Settings), each captioning session is written to a Markdown file in
  `~/Documents/Captions Transcripts` (folder configurable), named by start
  time, e.g. `2026-09-16 11.00.05 Captions.md`. Only finished utterances are
  logged, one per line with arrival time and speaker: microphone is `Me`,
  system audio (everyone else on a call) is `Them`. Pausing from the overlay
  and resuming continues the same file with a `Resumed at` marker; Stop ends
  it. Nothing is created for a session where nobody spoke, each line is
  written immediately, and a failed write shows in the menu without stopping
  captions. `TranscriptLog` writes the file, `TranscriptLoggingEngine`
  forwards finished captions from the speech engine, and `TranscriptRecorder`
  decides which file a session writes to. Let people know when you're saving
  a conversation; some places require everyone's consent.
- **Settings** — a text-size slider, the launch-at-login toggle, and the
  transcript toggle and folder (`SettingsStore.swift`, backed by
  `UserDefaults` and `SMAppService`).

## Layout
- `MacCaptions/` — the app: `AppModel` (state, capture + recognition
  wiring), `DualCapture` + `SystemAudioSource` + `MicSource` + `Interleaver`
  + `AudioHub` (mic and system-audio capture), `AnalyzerSpeechEngine` /
  `AppleSpeechEngine` (on-device speech recognition), `TranscriptLog` + `TranscriptLoggingEngine` +
  `TranscriptRecorder` (opt-in transcript files), `CaptionPanel.swift` (the
  floating overlay),
  `SettingsStore` (overlay preferences), `MacPermissions` (mic authorization),
  and the `@main` app (`MenuBarExtra` scene, `LSUIElement` so there's no Dock
  icon or main window).
- `MacCaptionsTests/` — unit test target.
- `project.yml` — XcodeGen project definition. `Captions.xcodeproj` is
  generated from this and is gitignored.
- Depends on the remote Swift package
  [`jonyen/caption-core`](https://github.com/jonyen/caption-core) for the
  shared `CaptionEngine` protocol, `CaptionEvent`, and `CaptionStore`/
  `SessionController` logic.

## Setup
1. `xcodegen generate && open Captions.xcodeproj`
2. Select your signing team in Xcode if `DEVELOPMENT_TEAM` in `project.yml`
   doesn't match.
3. Run. The app lives in the menu bar (look for the captions icon) — no Dock
   icon, no window until you start captioning.
4. On first capture, macOS will prompt for **Microphone** access, **Speech
   Recognition** access, and separately for **Screen Recording** access
   (required for system-audio capture via ScreenCaptureKit) — grant all three
   in System Settings → Privacy & Security if you miss the prompts. A fresh
   Screen Recording grant only takes effect after relaunching the app —
   macOS doesn't apply it to an already-running process. With Save
   Transcripts on and the default folder, macOS also asks once for access to
   **Documents**.

## Build
```bash
xcodegen generate
xcodebuild build -project Captions.xcodeproj -scheme Captions \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```
(If you have a Development cert for team 7PZN69YDL4, omit `CODE_SIGNING_ALLOWED=NO`.)

## Test
```bash
xcodebuild test -project Captions.xcodeproj -scheme Captions \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```
10 tests (HotkeyBinding parsing/persistence + Interleaver PCM mixing + a build
smoke test).
(If you have a Development cert for team 7PZN69YDL4, omit `CODE_SIGNING_ALLOWED=NO`.)
