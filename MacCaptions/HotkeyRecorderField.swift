import SwiftUI
import AppKit
import Carbon.HIToolbox

/// A click-to-record hotkey field. Click it, press a combo, done.
/// Escape drops focus without recording; Delete clears the binding.
struct HotkeyRecorderField: NSViewRepresentable {
    @Binding var hotkey: HotkeyBinding?

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onCapture = { hotkey = $0 }
        view.onClear = { hotkey = nil }
        view.display = { hotkey?.display }
        return view
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.needsDisplay = true
    }

    final class RecorderView: NSView {
        var onCapture: ((HotkeyBinding) -> Void)?
        var onClear: (() -> Void)?
        var display: (() -> String?)?

        override var acceptsFirstResponder: Bool { true }
        override var intrinsicContentSize: NSSize { NSSize(width: 120, height: 24) }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
        }

        override func keyDown(with event: NSEvent) {
            switch Int(event.keyCode) {
            case kVK_Escape:
                window?.makeFirstResponder(nil)
            case kVK_Delete, kVK_ForwardDelete:
                onClear?()
                window?.makeFirstResponder(nil)
            default:
                var carbon: UInt32 = 0
                let mods = event.modifierFlags
                if mods.contains(.command) { carbon |= UInt32(cmdKey) }
                if mods.contains(.option) { carbon |= UInt32(optionKey) }
                if mods.contains(.control) { carbon |= UInt32(controlKey) }
                if mods.contains(.shift) { carbon |= UInt32(shiftKey) }
                // A bare key makes a terrible global hotkey — it would fire
                // while typing. Require at least one modifier.
                guard carbon != 0 else { NSSound.beep(); return }
                let label = event.charactersIgnoringModifiers?.uppercased() ?? "?"
                onCapture?(HotkeyBinding(
                    keyCode: UInt32(event.keyCode), modifiers: carbon, keyLabel: label))
                window?.makeFirstResponder(nil)
            }
        }

        override func draw(_ dirtyRect: NSRect) {
            let recording = window?.firstResponder === self
            let text = recording ? "Press keys…" : (display?() ?? "None")
            let color: NSColor = recording ? .secondaryLabelColor : .labelColor
            NSColor.controlBackgroundColor.setFill()
            let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
            box.fill()
            (recording ? NSColor.keyboardFocusIndicatorColor : .separatorColor).setStroke()
            box.stroke()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: color]
            let size = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                                  y: (bounds.height - size.height) / 2), withAttributes: attrs)
        }

        override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
        override func resignFirstResponder() -> Bool { needsDisplay = true; return super.resignFirstResponder() }
    }
}
