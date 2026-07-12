import AppKit
import CoreText
import GhosttyKit

// MARK: Accessibility

extension Ghostty.SurfaceView {
    override func isAccessibilityElement() -> Bool {
        return true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        return .textArea
    }

    override func accessibilityRoleDescription() -> String {
        return "interactive terminal text area"
    }

    override func accessibilityLabel() -> String? {
        return "Terminal"
    }

    override func accessibilityIdentifier() -> String {
        return "GhosttyTerminalTextArea"
    }

    override func accessibilityHelp() -> String? {
        return "Interactive terminal content area"
    }

    override func isAccessibilityFocused() -> Bool {
        return window?.firstResponder === self
    }

    override func setAccessibilityFocused(_ accessibilityFocused: Bool) {
        guard accessibilityFocused else { return }
        focusTerminalForAccessibility()
    }

    override func accessibilityPerformPress() -> Bool {
        focusTerminalForAccessibility()
        return true
    }

    override func accessibilityValue() -> Any? {
        return currentAccessibilityTextProjection().text
    }

    override func accessibilitySelectedTextRange() -> NSRange {
        let projection = currentAccessibilityTextProjection()
        return projection.selectionRange ??
            clampedAccessibilityRange(accessibilityReviewSelectedRange, length: projection.utf16Length) ??
            projection.cursorRange
    }

    override func setAccessibilitySelectedTextRange(_ accessibilitySelectedTextRange: NSRange) {
        let projection = currentAccessibilityTextProjection()
        accessibilityReviewSelectedRange = clampedAccessibilityRange(
            accessibilitySelectedTextRange,
            length: projection.utf16Length
        )
        NSAccessibility.post(
            element: self,
            notification: .selectedTextChanged,
            userInfo: accessibilitySelectedTextChangedUserInfo(
                changeType: AccessibilityTextNotification.TextStateChangeType.selectionMove,
                focusChanged: false))
    }

    override func accessibilitySelectedText() -> String? {
        let projection = currentAccessibilityTextProjection()
        guard let range = projection.selectionRange ??
            clampedAccessibilityRange(accessibilityReviewSelectedRange, length: projection.utf16Length),
            range.length > 0 else { return nil }

        guard let swiftRange = Range(range, in: projection.text) else { return nil }
        let str = String(projection.text[swiftRange])
        return str.isEmpty ? nil : str
    }

    override func accessibilityNumberOfCharacters() -> Int {
        return currentAccessibilityTextProjection().utf16Length
    }

    override func accessibilityVisibleCharacterRange() -> NSRange {
        let info = currentAccessibilityTextProjection()
        return NSRange(info.viewportRange, in: info.text)
    }

    override func accessibilityLine(for index: Int) -> Int {
        let string = currentAccessibilityTextProjection().text as NSString
        let location = min(max(index, 0), string.length)

        var line = 0
        var cursor = 0
        while cursor < location {
            let range = string.lineRange(for: NSRange(location: cursor, length: 0))
            let next = NSMaxRange(range)
            if next > location || next <= cursor { break }

            cursor = next
            line += 1
        }

        return line
    }

    override func accessibilityRange(forLine line: Int) -> NSRange {
        guard line >= 0 else { return NSRange(location: NSNotFound, length: 0) }

        let string = currentAccessibilityTextProjection().text as NSString
        var currentLine = 0
        var cursor = 0

        while cursor < string.length {
            let range = string.lineRange(for: NSRange(location: cursor, length: 0))
            if currentLine == line { return range }

            let next = NSMaxRange(range)
            if next <= cursor { break }

            cursor = next
            currentLine += 1
        }

        if currentLine == line {
            return NSRange(location: string.length, length: 0)
        }

        return NSRange(location: NSNotFound, length: 0)
    }

    override func accessibilityInsertionPointLineNumber() -> Int {
        return accessibilityLine(for: accessibilitySelectedTextRange().location)
    }

    override func accessibilityRange(for index: Int) -> NSRange {
        let string = currentAccessibilityTextProjection().text as NSString
        guard string.length > 0 else { return NSRange(location: 0, length: 0) }

        let location = min(max(index, 0), string.length)
        guard location < string.length else {
            return NSRange(location: string.length, length: 0)
        }

        return string.rangeOfComposedCharacterSequence(at: location)
    }

    override func accessibilityRange(for point: NSPoint) -> NSRange {
        let projection = currentAccessibilityTextProjection()
        let string = projection.text as NSString
        guard string.length > 0, cellSize.width > 0, cellSize.height > 0 else {
            return NSRange(location: 0, length: 0)
        }
        guard let window else { return NSRange(location: NSNotFound, length: 0) }

        let windowRect = window.convertFromScreen(NSRect(origin: point, size: .zero))
        let localPoint = convert(windowRect.origin, from: nil)
        let visibleRange = NSRange(projection.viewportRange, in: projection.text)
        let visibleStartLine = accessibilityLine(for: visibleRange.location)
        let row = max(Int((bounds.height - localPoint.y) / cellSize.height), 0)
        let col = max(Int(localPoint.x / cellSize.width), 0)
        let lineRange = accessibilityRange(forLine: visibleStartLine + row)

        guard lineRange.location != NSNotFound else {
            return NSRange(location: NSNotFound, length: 0)
        }

        let index = min(lineRange.location + col, NSMaxRange(lineRange))
        return accessibilityRange(for: index)
    }

    override func accessibilityFrame(for range: NSRange) -> NSRect {
        let projection = currentAccessibilityTextProjection()
        let string = projection.text as NSString
        guard string.length > 0, cellSize.width > 0, cellSize.height > 0 else {
            return NSRect(x: 0, y: 0, width: 0, height: 0)
        }

        let visibleRange = NSRange(projection.viewportRange, in: projection.text)
        let clampedRange = intersection(range, visibleRange)
        guard clampedRange.location != NSNotFound else {
            return NSRect(x: 0, y: 0, width: 0, height: 0)
        }

        let visibleStartLine = accessibilityLine(for: visibleRange.location)
        let startLine = accessibilityLine(for: clampedRange.location)
        let endLocation = min(NSMaxRange(clampedRange), string.length)
        let endLine = accessibilityLine(for: max(endLocation - 1, clampedRange.location))
        let lineRange = accessibilityRange(forLine: startLine)
        guard lineRange.location != NSNotFound else {
            return NSRect(x: 0, y: 0, width: 0, height: 0)
        }
        let startColumn = max(clampedRange.location - lineRange.location, 0)
        let row = max(startLine - visibleStartLine, 0)
        let lineCount = max(endLine - startLine + 1, 1)
        let width: CGFloat

        if lineCount == 1 {
            width = max(CGFloat(max(clampedRange.length, 1)) * cellSize.width, cellSize.width)
        } else {
            width = bounds.width
        }

        let height = CGFloat(lineCount) * cellSize.height
        let viewRect = NSRect(
            x: CGFloat(startColumn) * cellSize.width,
            y: bounds.height - (CGFloat(row) * cellSize.height) - height,
            width: width,
            height: height
        )
        let windowRect = convert(viewRect, to: nil)
        return window?.convertToScreen(windowRect) ?? windowRect
    }

    override func accessibilityString(for range: NSRange) -> String? {
        let content = currentAccessibilityTextProjection().text
        guard let swiftRange = Range(range, in: content) else { return nil }
        return String(content[swiftRange])
    }

    /// Returns an attributed string for the given range.
    ///
    /// Note: right now this only applies font information. One day it'd be nice to extend
    /// this to copy styling information as well but we need to augment Ghostty core to
    /// expose that.
    ///
    /// This provides styling information to assistive technologies.
    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        guard let surface = self.surface else { return nil }
        guard let plainString = accessibilityString(for: range) else { return nil }

        var attributes: [NSAttributedString.Key: Any] = [:]

        // Try to get the font from the surface
        if let fontRaw = ghostty_surface_quicklook_font(surface) {
            let font = Unmanaged<CTFont>.fromOpaque(fontRaw)
            attributes[.font] = font.takeUnretainedValue()
            font.release()
        }

        return NSAttributedString(string: plainString, attributes: attributes)
    }

    func clampedAccessibilityRange(_ range: NSRange?, length: Int) -> NSRange? {
        guard let range else { return nil }
        guard range.location != NSNotFound else { return nil }

        let location = min(max(range.location, 0), length)
        let requestedEnd = range.length < 0 ? location : range.location + range.length
        let end = min(max(requestedEnd, location), length)
        return NSRange(location: location, length: end - location)
    }

    private func intersection(_ lhs: NSRange, _ rhs: NSRange) -> NSRange {
        guard lhs.location != NSNotFound, rhs.location != NSNotFound else {
            return NSRange(location: NSNotFound, length: 0)
        }

        let start = max(lhs.location, rhs.location)
        let end = min(NSMaxRange(lhs), NSMaxRange(rhs))
        guard end >= start else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: start, length: end - start)
    }

    private func focusTerminalForAccessibility() {
        guard window?.makeFirstResponder(self) == true else { return }
        NSAccessibility.post(element: self, notification: .focusedUIElementChanged)
    }

}
