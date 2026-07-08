import AppKit
import GhosttyKit

extension Ghostty.SurfaceView {
    static func string(from pointer: UnsafePointer<CChar>?, count: Int) -> String? {
        guard let pointer else { return nil }
        let bytes = UnsafeBufferPointer(
            start: UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self),
            count: count)
        return String(bytes: bytes, encoding: .utf8)
    }

    func readAccessibilityTextProjection() -> AccessibilityTextProjection {
        guard let surface else { return .empty }
        guard let context = ghostty_surface_accessibility_context_new(surface) else { return .empty }
        defer { ghostty_surface_accessibility_context_free(context) }

        var text = ghostty_accessibility_text_s()
        guard ghostty_accessibility_context_text(context, &text),
              let value = Self.string(from: text.text, count: Int(text.text_len)) else {
            return .empty
        }

        return AccessibilityTextProjection(
            text: value,
            viewportStart: Int(text.viewport_start),
            viewportEnd: Int(text.viewport_end),
            cursorOffset: Int(text.cursor_offset),
            selectionStart: Int(text.selection_start),
            selectionEnd: Int(text.selection_end),
            selectionPresent: text.selection_present != 0,
            changeInfo: ScreenChangeInfo(text))
    }

    func readScreenChangeInfo() -> ScreenChangeInfo {
        guard let surface else { return .empty }

        var change = ghostty_accessibility_change_s()
        guard ghostty_surface_accessibility_change(surface, &change) else { return .empty }

        return ScreenChangeInfo(change)
    }
}
