# Captions — macOS live caption overlay

A menu-bar-only (no Dock icon) Mac app that captions your Mac's microphone and
system audio live, in a floating always-on-top panel. Captions are generated
on-device whenever Apple's on-device speech model is available for your
language (the app requests it explicitly); without it, macOS falls back to
Apple's speech servers. There's no app server, no relay, and no transcript
history.

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
- **Speech recognition** — `AppleSpeechEngine.swift` wraps `SFSpeechRecognizer`
  as a `CaptionEngine` (from the `caption-core` package): `start()` asks for
  speech-recognition permission and emits `.ready`; `send(_:)` takes
  interleaved stereo PCM (mic + system audio) and feeds one recognizer per
  channel. It requests on-device recognition when the recognizer reports
  `supportsOnDeviceRecognition`; otherwise the audio is recognized via
  Apple's speech servers.
- **Global hotkey** — a menu-bar-independent shortcut (default ⌃⌥⌘C,
  configurable) toggles the caption overlay without needing to click the menu
  bar icon. `GlobalHotkey.swift` registers it with Carbon so it fires from any
  app; `HotkeyBinding.swift` is the persisted key/modifier value; the menu's
  native shortcut hint and the in-Settings recorder
  (`HotkeyRecorderField.swift`) both stay in sync with it.
- **Launch at login** — a toggle in Settings (`SettingsStore.swift`, backed by
  `SMAppService.mainApp`) registers Captions as a login item, since the
  global hotkey only works while the app is running.
- **Settings** — a text-size slider and the launch-at-login toggle for the
  caption overlay (`SettingsStore.swift`, backed by `UserDefaults` and
  `SMAppService`).

## Layout
- `MacCaptions/` — the app: `AppModel` (state, capture + recognition
  wiring), `DualCapture` + `SystemAudioSource` + `MicSource` + `Interleaver`
  + `AudioHub` (mic and system-audio capture), `AppleSpeechEngine` (on-device
  speech recognition), `CaptionPanel.swift` (the floating overlay),
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
   macOS doesn't apply it to an already-running process.

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
