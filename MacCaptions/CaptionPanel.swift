import SwiftUI
import CaptionCore

/// Floating, non-activating, always-on-top translucent caption panel.
@MainActor
final class CaptionPanelController {
    private var panel: NSPanel?
    private var savedFrame: NSRect?
    private var dragOrigin: NSPoint?

    func show(model: AppModel) {
        if panel != nil { return }
        let view = NSHostingView(rootView: CaptionPanelView(
            model: model,
            store: model.store,
            settings: model.settings,
            onDoubleTap: { [weak self] in self?.toggleZoom() },
            onDrag: { [weak self] in self?.drag(by: $0) },
            onDragEnd: { [weak self] in self?.dragOrigin = nil }))
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 120, width: 560, height: 260),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
            backing: .buffered, defer: false)
        p.level = .floating
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.backgroundColor = .clear
        p.isOpaque = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        // The overlay's own controls are the affordances; the system
        // traffic lights don't belong on a floating caption panel.
        for b: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            p.standardWindowButton(b)?.isHidden = true
        }
        p.contentView = view
        p.center()
        // The transcript is never trimmed, so the panel's height decides how
        // much history is visible at once; remember the user's resize.
        p.setFrameAutosaveName("CaptionPanel")
        p.orderFrontRegardless()
        panel = p
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        savedFrame = nil
    }

    /// The panel's whole surface drags it. `isMovableByWindowBackground`
    /// can't do this on its own: the content is an NSScrollView, which
    /// swallows the mouse-down the window drag needs. A SwiftUI gesture
    /// does get the mouse down, so it hands the live event to AppKit's
    /// `performDrag`, which runs the drag in the window server — the window
    /// then tracks the cursor exactly, with no per-event repaint of the
    /// panel's translucent material. `performDrag` blocks until mouse-up,
    /// so the gesture's remaining updates never arrive, and `onDragEnd`
    /// clears the fallback's state.
    private func drag(by translation: CGSize) {
        guard let p = panel else { return }
        if let event = NSApp.currentEvent, event.type == .leftMouseDragged || event.type == .leftMouseDown {
            p.performDrag(with: event)
            dragOrigin = nil
            return
        }
        // No live event to hand over (synthetic drags in tests, say): move
        // the window by hand from where the drag started.
        let origin = dragOrigin ?? p.frame.origin
        dragOrigin = origin
        p.setFrameOrigin(Self.draggedOrigin(from: origin, translation: translation))
    }

    /// AppKit origins grow upward, SwiftUI translations downward.
    nonisolated static func draggedOrigin(from start: NSPoint, translation: CGSize) -> NSPoint {
        NSPoint(x: start.x + translation.width, y: start.y - translation.height)
    }

    /// Double-click: grow the panel to fill the screen's visible area;
    /// double-click again to restore the previous frame.
    private func toggleZoom() {
        guard let p = panel, let screen = p.screen ?? NSScreen.main else { return }
        if let saved = savedFrame {
            p.setFrame(saved, display: true, animate: true)
            savedFrame = nil
        } else {
            savedFrame = p.frame
            p.setFrame(screen.visibleFrame, display: true, animate: true)
        }
    }
}

struct CaptionPanelView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: CaptionStore
    @ObservedObject var settings: SettingsStore
    let onDoubleTap: () -> Void
    let onDrag: (CGSize) -> Void
    let onDragEnd: () -> Void
    @State private var hovering = false

    var body: some View {
        Group {
            CaptionFlow(store: store, fontSize: settings.fontSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture(count: 2) { onDoubleTap() }
        // A click that never moves stays a click, so the overlay's buttons
        // and the double-click zoom still work. The threshold is small so
        // AppKit takes the drag over almost immediately.
        .simultaneousGesture(
            DragGesture(minimumDistance: 2)
                .onChanged { onDrag($0.translation) }
                .onEnded { _ in onDragEnd() })
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 10) {
                Button { model.pauseResume() } label: {
                    Image(systemName: model.capturing ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(model.capturing ? "Pause captions" : "Start captions")
                Button { model.stop() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Stop captions and close")
            }
            .padding(8)
            // Keep controls discoverable while idle; fade them out mid-caption.
            .opacity(hovering || !model.capturing ? 1 : 0)
        }
        .onHover { hovering = $0 }
        .padding(8)
    }
}

/// One provider's transcript as flowing text: all finals from the session and
/// the gray in-progress partial share a single wrapping Text, so lines re-wrap
/// whenever the panel is resized. The scroll view stays pinned to the newest
/// caption until the user scrolls up to read history.
private struct CaptionFlow: View {
    @ObservedObject var store: CaptionStore
    let fontSize: Double

    // The panel is a single flowing line of text by design, so paragraph
    // breaks are joined away here rather than shown.
    private var finals: String {
        store.paragraphs.map(\.text).joined(separator: " ")
    }
    private var partial: String {
        store.partials.sorted { $0.key < $1.key }
            .map(\.value)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if case .error(let message) = store.state {
                    Text(message)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                if !finals.isEmpty || !partial.isEmpty {
                    (Text(finals + (finals.isEmpty || partial.isEmpty ? "" : " "))
                        + Text(partial).foregroundColor(.secondary))
                        .font(.system(size: fontSize, weight: .medium))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .defaultScrollAnchor(.bottom)
    }
}
