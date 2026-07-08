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
    func invalidateAccessibilityTextProjection() {
        cachedAccessibilityTextProjection.invalidate()
        cachedScreenContents.invalidate()
        cachedVisibleContents.invalidate()
        accessibilityReviewSelectedRange = nil
    }

    func currentAccessibilityTextProjection() -> AccessibilityTextProjection {
        let changeInfo = readScreenChangeInfo()
        _ = announceAccessibilityChange(changeInfo)

        if changeInfo.generation != lastAccessibilityProjectionGeneration {
            lastAccessibilityProjectionGeneration = changeInfo.generation
            invalidateAccessibilityTextProjection()
        }

        return cachedAccessibilityTextProjection.get()
    }
    static func accessibilityEffectiveSelectedRange(
        in projection: AccessibilityTextProjection
    ) -> NSRange {
        projection.selectionRange ?? projection.cursorRange
    }

    static func accessibilityRangeEqual(_ lhs: NSRange, _ rhs: NSRange) -> Bool {
        lhs.location == rhs.location && lhs.length == rhs.length
    }
    func accessibilityTextEditDiff(
        oldText: String,
        newText: String
    ) -> AccessibilityTextEditDiff? {
        let oldUnits = Array(oldText.utf16)
        let newUnits = Array(newText.utf16)
        guard oldUnits != newUnits else { return nil }

        let sharedCount = min(oldUnits.count, newUnits.count)
        var prefix = 0
        while prefix < sharedCount &&
            accessibilityUTF16UnitsEqual(oldUnits[prefix], newUnits[prefix]) {
            prefix += 1
        }

        var suffix = 0
        while prefix + suffix < oldUnits.count &&
            prefix + suffix < newUnits.count &&
            accessibilityUTF16UnitsEqual(
                oldUnits[oldUnits.count - suffix - 1],
                newUnits[newUnits.count - suffix - 1]) {
            suffix += 1
        }

        let deletedRange = NSRange(
            location: prefix,
            length: oldUnits.count - prefix - suffix)
        let insertedRange = NSRange(
            location: prefix,
            length: newUnits.count - prefix - suffix)

        return AccessibilityTextEditDiff(
            deletedText: deletedRange.length > 0
                ? (oldText as NSString).substring(with: deletedRange)
                : "",
            insertedText: insertedRange.length > 0
                ? (newText as NSString).substring(with: insertedRange)
                : "")
    }

    func accessibilityUTF16UnitsEqual(_ lhs: UInt16, _ rhs: UInt16) -> Bool {
        if lhs == rhs { return true }
        guard let lhsScalar = UnicodeScalar(Int(lhs)),
              let rhsScalar = UnicodeScalar(Int(rhs)) else { return false }

        let whitespace = CharacterSet.whitespacesAndNewlines
        return whitespace.contains(lhsScalar) && whitespace.contains(rhsScalar)
    }
}
