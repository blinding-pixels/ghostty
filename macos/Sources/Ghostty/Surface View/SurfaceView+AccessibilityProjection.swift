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
        guard accessibilityPipelineEnabled else { return .empty }

        if passwordInput {
            return .secureInput(changeInfo: readScreenChangeInfo())
        }

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
        // Keep an explicit VoiceOver review range across redraws. It is rebased
        // once the replacement projection is available; clearing it here makes
        // AppKit fall back to the live terminal cursor.
    }

    func clearAccessibilityReviewSelection() {
        accessibilityReviewSelectedRange = nil
    }

    func returnAccessibilityReviewToPrompt() -> Bool {
        guard accessibilityPipelineEnabled else { return false }
        guard window?.makeFirstResponder(self) == true else { return false }

        let projection = currentAccessibilityTextProjection()
        accessibilityReviewSelectedRange = projection.cursorRange
        NSAccessibility.post(
            element: self,
            notification: .selectedTextChanged,
            userInfo: accessibilitySelectedTextChangedUserInfo(
                changeType: AccessibilityTextNotification.TextStateChangeType.selectionMove,
                focusChanged: true))
        announceAccessibility("Enter terminal prompt", priority: .high)
        traceAccessibilityCue(
            "returnedToPrompt generation=\(projection.changeInfo.generation) range={\(projection.cursorRange.location),\(projection.cursorRange.length)}")
        return true
    }

    func reconcileAccessibilityReviewSelection(
        from oldProjection: AccessibilityTextProjection?,
        to newProjection: AccessibilityTextProjection
    ) {
        guard let reviewRange = accessibilityReviewSelectedRange else {
            return
        }

        let rebasedRange: NSRange
        if let oldProjection {
            rebasedRange = Self.rebasedAccessibilityRange(
                reviewRange,
                from: oldProjection.text,
                to: newProjection.text)
        } else {
            rebasedRange = reviewRange
        }

        accessibilityReviewSelectedRange = clampedAccessibilityRange(
            rebasedRange,
            length: newProjection.utf16Length)
    }

    static func rebasedAccessibilityRange(
        _ range: NSRange,
        from oldText: String,
        to newText: String
    ) -> NSRange {
        let oldUnits = Array(oldText.utf16)
        let newUnits = Array(newText.utf16)
        let oldLength = oldUnits.count
        let newLength = newUnits.count

        let oldStart = min(max(range.location, 0), oldLength)
        let oldEnd = min(
            max(range.location + max(range.length, 0), oldStart),
            oldLength)

        guard oldUnits != newUnits else {
            return NSRange(location: oldStart, length: oldEnd - oldStart)
        }

        let sharedCount = min(oldLength, newLength)
        var prefix = 0
        while prefix < sharedCount && oldUnits[prefix] == newUnits[prefix] {
            prefix += 1
        }

        var suffix = 0
        while prefix + suffix < oldLength &&
            prefix + suffix < newLength &&
            oldUnits[oldLength - suffix - 1] == newUnits[newLength - suffix - 1] {
            suffix += 1
        }

        let oldEditEnd = oldLength - suffix
        let newEditEnd = newLength - suffix
        let insertedLength = newEditEnd - prefix
        let delta = newLength - oldLength

        func mapOffset(_ offset: Int, preferAfterInsertion: Bool) -> Int {
            if offset < prefix { return offset }
            if offset > oldEditEnd { return offset + delta }
            if oldEditEnd == prefix {
                return offset + (preferAfterInsertion ? delta : 0)
            }
            if offset == oldEditEnd { return offset + delta }
            if offset == prefix { return offset }
            return prefix + min(offset - prefix, insertedLength)
        }

        let newStart = min(
            max(mapOffset(oldStart, preferAfterInsertion: true), 0),
            newLength)
        let newEnd = min(
            max(mapOffset(oldEnd, preferAfterInsertion: false), newStart),
            newLength)
        return NSRange(location: newStart, length: newEnd - newStart)
    }

    func currentAccessibilityTextProjection() -> AccessibilityTextProjection {
        guard accessibilityPipelineEnabled else { return .empty }

        let changeInfo = readScreenChangeInfo()
        _ = announceAccessibilityChange(changeInfo)

        if passwordInput {
            announceAccessibilitySecureInputIfNeeded(changeInfo, source: "projection")
            return .secureInput(changeInfo: changeInfo)
        }

        if changeInfo.generation != lastAccessibilityProjectionGeneration {
            let oldProjection = accessibilityReviewSelectedRange.map { _ in
                cachedAccessibilityTextProjection.get()
            }
            lastAccessibilityProjectionGeneration = changeInfo.generation
            invalidateAccessibilityTextProjection()
            let newProjection = cachedAccessibilityTextProjection.get()
            reconcileAccessibilityReviewSelection(
                from: oldProjection,
                to: newProjection)
        }

        return cachedAccessibilityTextProjection.get()
    }

    func accessibilityPasswordInputDidChange() {
        accessibilityTextUpdateWorkItem?.cancel()
        accessibilityTextUpdateWorkItem = nil
        accessibilityFloodSettleWorkItem?.cancel()
        accessibilityFloodSettleWorkItem = nil
        accessibilityFloodState = nil
        accessibilityIOFloodWindow = nil
        accessibilityPostFloodTextSyncPending = false
        lastAccessibilityCommandOutputSnapshot = nil
        accessibilitySecureAnnouncementPending = passwordInput
        clearAccessibilityReviewSelection()
        invalidateAccessibilityTextProjection()

        guard accessibilityPipelineEnabled else {
            lastAccessibilityProjectionGeneration = -1
            lastAccessibilityNotifiedGeneration = -1
            lastAccessibilityNotifiedProjection = nil
            traceAccessibilityCue(
                "passwordInputAX state=\(passwordInput) disabled")
            return
        }

        let projection = readAccessibilityTextProjection()
        lastAccessibilityProjectionGeneration = projection.changeInfo.generation
        lastAccessibilityNotifiedGeneration = projection.changeInfo.generation
        lastAccessibilityNotifiedProjection = projection

        if passwordInput {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.announceAccessibilitySecureInputIfNeeded(
                    self.readScreenChangeInfo(),
                    source: "passwordInput")
            }
        }

        traceAccessibilityCue(
            "passwordInputAX state=\(passwordInput) generation=\(projection.changeInfo.generation)")
    }

    func announceAccessibilitySecureInputIfNeeded(
        _ changeInfo: ScreenChangeInfo,
        source: String
    ) {
        guard passwordInput else {
            accessibilitySecureAnnouncementPending = false
            return
        }
        guard accessibilitySecureAnnouncementPending else { return }
        guard accessibilityPipelineEnabled else { return }
        guard window?.firstResponder === self else {
            traceAccessibilityCue(
                "secureInputAnnouncementDeferred source=\(source) generation=\(changeInfo.generation)")
            return
        }

        accessibilitySecureAnnouncementPending = false
        announceAccessibility(
            AccessibilityTextProjection.secureInputAnnouncement,
            priority: .high)
        traceAccessibilityCue(
            "secureInputAnnouncement source=\(source) generation=\(changeInfo.generation)")
    }

    func accessibilityProjectionLineMetrics(
        oldProjection: AccessibilityTextProjection,
        newProjection: AccessibilityTextProjection
    ) -> AccessibilityProjectionLineMetrics {
        let oldLines = oldProjection.visibleText.split(
            separator: "\n",
            omittingEmptySubsequences: false)
        let newLines = newProjection.visibleText.split(
            separator: "\n",
            omittingEmptySubsequences: false)

        let comparedLineCount = max(oldLines.count, newLines.count)
        var changedLineCount = 0
        for lineIndex in 0..<comparedLineCount {
            if lineIndex >= oldLines.count ||
                lineIndex >= newLines.count ||
                oldLines[lineIndex] != newLines[lineIndex] {
                changedLineCount += 1
            }
        }

        let diff = accessibilityTextEditDiff(
            oldText: oldProjection.visibleText,
            newText: newProjection.visibleText)

        return AccessibilityProjectionLineMetrics(
            oldVisibleLineCount: oldLines.count,
            newVisibleLineCount: newLines.count,
            changedVisibleLineCount: changedLineCount,
            insertedLineBreakCount: Self.accessibilityLineBreakCount(
                in: diff?.insertedText ?? ""),
            deletedLineBreakCount: Self.accessibilityLineBreakCount(
                in: diff?.deletedText ?? ""))
    }

    static func accessibilityLineBreakCount(in text: String) -> Int {
        text.reduce(0) { count, character in
            count + (character == "\n" ? 1 : 0)
        }
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
