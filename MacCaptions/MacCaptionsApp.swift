import SwiftUI
import CaptionCore

/// Reopen events (Spotlight/Finder launching the already-running app) have no
/// SwiftUI hook, so a minimal delegate forwards them to the model.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var onReopen: (() -> Void)?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        Task { @MainActor in AppDelegate.onReopen?() }
        return false
    }
}

@main
struct MacCaptionsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    @Environment(\.openSettings) private var openSettings

    var body: some Scene {
        MenuBarExtra("Captions", systemImage: model.capturing ? "captions.bubble.fill" : "captions.bubble") {
            StatusLine(store: model.store, capturing: model.capturing)
            // The global trigger is Carbon (GlobalHotkey), registered from
            // AppModel; this just shows the current combo as the menu's
            // native shortcut hint and gives it a local, in-menu shortcut too.
            if let (key, mods) = model.settings.hotkey?.keyEquivalent {
                Button(model.capturing ? "Stop Captions" : "Start Captions") { model.toggle() }
                    .keyboardShortcut(key, modifiers: mods)
            } else {
                Button(model.capturing ? "Stop Captions" : "Start Captions") { model.toggle() }
            }
            Toggle("Microphone", isOn: $model.micOn)
            Toggle("System Audio", isOn: $model.systemOn)
            Divider()
            TranscriptMenuItems(settings: model.settings, transcripts: model.transcripts,
                                reveal: model.revealTranscriptsFolder)
            Divider()
            // SettingsLink doesn't activate an LSUIElement app, so the
            // Settings window opens behind every other window; activate first.
            Button("Settings…") {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        Settings {
            SettingsView(settings: model.settings, reveal: model.revealTranscriptsFolder)
        }
    }
}

/// The store's connection state lives on `model.store`, not on `AppModel`
/// itself, so MenuBarExtra's content needs its own `@ObservedObject` on the
/// store to re-render when it changes (e.g. session error) — observing only
/// `model.capturing` here would leave the menu showing stale status text.
/// Status is shown only when capturing or displaying an error; fresh launches
/// hide the default .connecting state since the Mac app doesn't auto-start.
private struct StatusLine: View {
    @ObservedObject var store: CaptionStore
    let capturing: Bool

    var isError: Bool {
        if case .error = store.state {
            return true
        }
        return false
    }

    var body: some View {
        Group {
            if capturing || isError {
                switch store.state {
                case .connecting:
                    Text("Connecting…")
                case .listening:
                    Text("Listening…")
                case .error(let message):
                    Text(message).foregroundStyle(.red)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// Same reason as StatusLine: the menu must observe the nested objects
/// directly, or the toggle and error line would render stale.
private struct TranscriptMenuItems: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var transcripts: TranscriptRecorder
    let reveal: () -> Void

    var body: some View {
        Toggle("Save Transcripts", isOn: $settings.saveTranscripts)
        Button("Open Transcripts Folder", action: reveal)
        if let error = transcripts.lastError {
            Text("Transcript not saved: \(error)")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    let reveal: () -> Void

    var body: some View {
        Form {
            Section("Captions") {
                LabeledContent("Global shortcut") {
                    HotkeyRecorderField(hotkey: $settings.hotkey)
                        .fixedSize()
                }
                Text("Toggles captions from any app. Delete clears it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Slider(value: $settings.fontSize, in: 12...48, step: 1) {
                        Text("Text size")
                    }
                    Text("\(Int(settings.fontSize)) pt")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
            }
            Section("Audio") {
                Toggle("Echo cancellation", isOn: $settings.echoCancellation)
                Text("Stops speaker sound from being captioned twice, but macOS lowers other apps' audio while captions run. Leave off with headphones. Applies from the next Start.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Transcripts") {
                Toggle("Save transcripts", isOn: $settings.saveTranscripts)
                LabeledContent("Folder") {
                    HStack {
                        Text(abbreviatedPath(settings.transcriptsFolder))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…", action: chooseFolder)
                        Button("Show", action: reveal)
                    }
                }
                Text("One Markdown file per session. Your microphone is labeled Me and other audio Them. Changes apply from the next Start. Let people know when you're saving a conversation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("General") {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                Text("Keeps the global shortcut working after a restart.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }

    private func abbreviatedPath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.directoryURL = settings.transcriptsFolder.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url {
            settings.transcriptsFolder = url
        }
    }
}
