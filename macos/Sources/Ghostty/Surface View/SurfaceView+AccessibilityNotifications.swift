import AppKit
import GhosttyKit

extension Ghostty.SurfaceView {
    static func isVoiceOverProcessRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { application in
            application.bundleIdentifier == "com.apple.VoiceOver" ||
                application.executableURL?.path == "/System/Library/CoreServices/VoiceOver.app/Contents/MacOS/VoiceOver"
        }
    }

    static func shouldEnableAccessibilityPipeline() -> Bool {
        NSWorkspace.shared.isVoiceOverEnabled && isVoiceOverProcessRunning()
    }

    func updateAccessibilityEnabledState() {
        guard let surface else { return }

        let enabled = Self.shouldEnableAccessibilityPipeline()
        let wasEnabled = accessibilityPipelineEnabled
        accessibilityPipelineEnabled = enabled
        ghostty_surface_set_accessibility_enabled(surface, enabled)
        guard enabled != wasEnabled else { return }

        accessibilityTextUpdateWorkItem?.cancel()
        accessibilityFloodSettleWorkItem?.cancel()
        lastAccessibilityNotifiedProjection = nil
        lastAccessibilityScreenChangedTraceTime = nil
        accessibilityFloodState = nil
        accessibilityIOFloodWindow = nil
        accessibilityPostFloodTextSyncPending = false
        lastAccessibilityCommandStatus = nil
        lastAccessibilityCommandOutputSnapshot = nil
        accessibilitySecureAnnouncementPending = enabled && passwordInput
        accessibilityBurstSuppressionEnabled = true
        clearAccessibilityReviewSelection()
        invalidateAccessibilityTextProjection()

        if enabled {
            let projection = readAccessibilityTextProjection()
            lastAccessibilityNotifiedGeneration = projection.changeInfo.generation
            lastAccessibilityProjectionGeneration = projection.changeInfo.generation
            lastAccessibilityNotifiedProjection = projection
        } else {
            lastAccessibilityNotifiedGeneration = -1
            lastAccessibilityProjectionGeneration = -1
        }
    }

    func accessibilityScreenChanged(_ change: Ghostty.Action.ScreenChanged) {
        guard accessibilityPipelineEnabled else { return }

        let changeInfo = ScreenChangeInfo(change)
        let now = ProcessInfo.processInfo.systemUptime
        let sinceLastMsValue = lastAccessibilityScreenChangedTraceTime.map {
            (now - $0) * 1000
        }
        let sinceLastMs = sinceLastMsValue.map {
            String(format: "%.1f", $0)
        } ?? "nil"
        lastAccessibilityScreenChangedTraceTime = now
        noteAccessibilityFloodSignal(
            changeInfo,
            now: now,
            sinceLastMs: sinceLastMsValue)
        traceAccessibilityCue(
            "screenChanged generation=\(changeInfo.generation) dirtyRows=\(changeInfo.dirtyRowCount) dirtyRange=\(Self.traceRange(changeInfo.dirtyRowRange)) sinceLastMs=\(sinceLastMs) outputBytes=\(changeInfo.outputBytes) outputNewlines=\(changeInfo.outputNewlines) outputScrollLines=\(changeInfo.outputScrollLines) cursor=\(changeInfo.cursorRow),\(changeInfo.cursorColumn) alternate=\(changeInfo.usesAlternateScreen)")
        scheduleAccessibilityTextUpdate(changeInfo)
    }

    func accessibilityCommandFinished(exitCode: Int?) {
        let status = AccessibilityCommandStatus(
            exitCode: exitCode,
            finishedAt: ProcessInfo.processInfo.systemUptime)
        lastAccessibilityCommandStatus = status

        if var floodState = accessibilityFloodState {
            floodState.commandStatus = status
            accessibilityFloodState = floodState
            scheduleAccessibilityFloodSummary()
        }

        traceAccessibilityCue(
            "commandFinished exitCode=\(exitCode.map(String.init) ?? "nil")")
    }

    static func traceRange(_ range: ClosedRange<Int>?) -> String {
        guard let range else { return "nil" }
        return "\(range.lowerBound)...\(range.upperBound)"
    }

    static func traceLineMetrics(_ metrics: AccessibilityProjectionLineMetrics?) -> String {
        guard let metrics else { return "nil" }

        return [
            "class=\(metrics.classification)",
            "oldLines=\(metrics.oldVisibleLineCount)",
            "newLines=\(metrics.newVisibleLineCount)",
            "changedLines=\(metrics.changedVisibleLineCount)",
            "insertedLineBreaks=\(metrics.insertedLineBreakCount)",
            "deletedLineBreaks=\(metrics.deletedLineBreakCount)",
        ].joined(separator: ",")
    }

    static func shouldPostAccessibilityVisibleTextNotification(
        change: ScreenChangeInfo,
        lineMetrics: AccessibilityProjectionLineMetrics?,
        diff: AccessibilityTextEditDiff?
    ) -> Bool {
        guard let lineMetrics,
              let diff,
              diff.hasChange else { return true }

        if isAccessibilityInlineTextEdit(
            lineMetrics: lineMetrics,
            diff: diff) {
            return true
        }

        return isAccessibilityMeaningfulTextOutputFrame(change)
    }

    static func isAccessibilityInlineTextEdit(
        lineMetrics: AccessibilityProjectionLineMetrics?,
        diff: AccessibilityTextEditDiff?
    ) -> Bool {
        guard let lineMetrics,
              let diff,
              diff.hasChange else { return false }

        return isAccessibilityInlineTextEdit(
            lineMetrics: lineMetrics,
            diff: diff)
    }

    static func isAccessibilityInlineTextEdit(
        lineMetrics: AccessibilityProjectionLineMetrics,
        diff: AccessibilityTextEditDiff
    ) -> Bool {
        guard lineMetrics.classification == "singleLine" else {
            return false
        }

        return accessibilityLineBreakCount(in: diff.insertedText) == 0 &&
            accessibilityLineBreakCount(in: diff.deletedText) == 0
    }

    static func isAccessibilityMeaningfulTextOutputFrame(
        _ change: ScreenChangeInfo
    ) -> Bool {
        change.outputNewlines > accessibilityTypingMaxNewlines ||
            change.outputBytes >= accessibilityTypingMaxBytes
    }

    static func shouldSuppressPostFloodInlineInsertNotification(
        lineMetrics: AccessibilityProjectionLineMetrics?,
        diff: AccessibilityTextEditDiff?
    ) -> Bool {
        guard let diff,
              isAccessibilityInlineTextEdit(
                lineMetrics: lineMetrics,
                diff: diff) else { return false }

        let insertedLength = diff.insertedText.utf16.count
        guard insertedLength > 1 else { return false }
        return insertedLength >= diff.deletedText.utf16.count
    }

    func announceAccessibilityPostFloodInlineInsert(
        _ diff: AccessibilityTextEditDiff
    ) {
        let text = Self.accessibilitySummaryLine(diff.insertedText)
        guard !text.isEmpty else { return }
        announceAccessibility(text, priority: .medium)
    }

    func scheduleAccessibilityTextUpdate(_ changeInfo: ScreenChangeInfo? = nil) {
        guard accessibilityPipelineEnabled else { return }
        guard window?.firstResponder === self else { return }

        accessibilityTextUpdateWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.accessibilityPipelineEnabled,
                  self.window?.firstResponder === self else { return }

            let resolvedChangeInfo = changeInfo ?? self.readScreenChangeInfo()
            self.accessibilityTextUpdateWorkItem = nil
            self.traceAccessibilityCue("flushFast generation=\(resolvedChangeInfo.generation)")
            _ = self.announceAccessibilityChange(resolvedChangeInfo)
            self.notifyAccessibilityProjectionIfNeeded(resolvedChangeInfo)
        }
        accessibilityTextUpdateWorkItem = workItem

        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.accessibilityTextUpdateDelay,
            execute: workItem)
    }

    func notifyAccessibilityProjectionIfNeeded(_ change: ScreenChangeInfo) {
        guard accessibilityPipelineEnabled else { return }

        if passwordInput {
            announceAccessibilitySecureInputIfNeeded(change, source: "notification")
            let projection = AccessibilityTextProjection.secureInput(changeInfo: change)
            lastAccessibilityNotifiedGeneration = change.generation
            lastAccessibilityProjectionGeneration = change.generation
            lastAccessibilityNotifiedProjection = projection
            accessibilityFloodState = nil
            accessibilityPostFloodTextSyncPending = false
            traceAccessibilityCue(
                "suppressedPasswordNotification requestedGeneration=\(change.generation)")
            return
        }

        guard change.generation != lastAccessibilityNotifiedGeneration else { return }

        if accessibilityFloodState != nil {
            lastAccessibilityNotifiedGeneration = change.generation
            traceAccessibilityCue(
                "suppressedFloodNotificationCheap requestedGeneration=\(change.generation) outputBytes=\(change.outputBytes) outputNewlines=\(change.outputNewlines) outputScrollLines=\(change.outputScrollLines) dirtyRows=\(change.dirtyRowCount) dirtyRange=\(Self.traceRange(change.dirtyRowRange))")
            return
        }

        let oldProjection = lastAccessibilityNotifiedProjection
        lastAccessibilityNotifiedGeneration = change.generation
        lastAccessibilityProjectionGeneration = change.generation

        let oldReviewProjection = accessibilityReviewSelectedRange.map { _ in
            cachedAccessibilityTextProjection.get()
        }
        invalidateAccessibilityTextProjection()
        let newProjection = cachedAccessibilityTextProjection.get()
        reconcileAccessibilityReviewSelection(
            from: oldReviewProjection,
            to: newProjection)
        lastAccessibilityNotifiedProjection = newProjection
        let lineMetrics = oldProjection.map {
            accessibilityProjectionLineMetrics(
                oldProjection: $0,
                newProjection: newProjection)
        }
        let textDiff = oldProjection.flatMap {
            accessibilityTextEditDiff(
                oldText: $0.visibleText,
                newText: newProjection.visibleText)
        }

        if !Self.shouldPostAccessibilityVisibleTextNotification(
            change: change,
            lineMetrics: lineMetrics,
            diff: textDiff) {
            traceAccessibilityCue(
                "suppressedUnconfirmedVisibleTextNotification requestedGeneration=\(change.generation) notifiedGeneration=\(newProjection.changeInfo.generation) outputBytes=\(change.outputBytes) outputNewlines=\(change.outputNewlines) outputScrollLines=\(change.outputScrollLines) dirtyRows=\(change.dirtyRowCount) lineDelta=\(Self.traceLineMetrics(lineMetrics))")
            return
        }

        if accessibilityPostFloodTextSyncPending,
           Self.shouldSuppressPostFloodInlineInsertNotification(
                lineMetrics: lineMetrics,
                diff: textDiff) {
            if let textDiff {
                announceAccessibilityPostFloodInlineInsert(textDiff)
            }
            traceAccessibilityCue(
                "suppressedPostFloodInlineInsertNotification requestedGeneration=\(change.generation) notifiedGeneration=\(newProjection.changeInfo.generation) insertedUTF16=\(textDiff?.insertedText.utf16.count ?? 0) deletedUTF16=\(textDiff?.deletedText.utf16.count ?? 0) lineDelta=\(Self.traceLineMetrics(lineMetrics))")
            return
        }

        var postedValueChanged = false
        if let oldProjection,
           let userInfo = accessibilityValueChangedUserInfo(
                oldProjection: oldProjection,
                newProjection: newProjection) {
            NSAccessibility.post(
                element: self,
                notification: .valueChanged,
                userInfo: userInfo)
            postedValueChanged = true
        }

        let selectedTextChanged = oldProjection.map {
            !Self.accessibilityRangeEqual(
                Self.accessibilityEffectiveSelectedRange(in: $0),
                Self.accessibilityEffectiveSelectedRange(in: newProjection))
        } ?? false

        var postedSelectedTextChanged = false
        if selectedTextChanged && !postedValueChanged {
            NSAccessibility.post(
                element: self,
                notification: .selectedTextChanged,
                userInfo: accessibilitySelectedTextChangedUserInfo(
                    changeType: AccessibilityTextNotification.TextStateChangeType.unknown,
                    focusChanged: false))
            postedSelectedTextChanged = true
        }

        if accessibilityPostFloodTextSyncPending,
           postedValueChanged,
           !Self.isAccessibilityInlineTextEdit(
                lineMetrics: lineMetrics,
                diff: textDiff) {
            accessibilityPostFloodTextSyncPending = false
            traceAccessibilityCue(
                "clearedPostFloodTextSync requestedGeneration=\(change.generation)")
        }

        traceAccessibilityCue(
            "postedNotification requestedGeneration=\(change.generation) notifiedGeneration=\(newProjection.changeInfo.generation) valueChanged=\(postedValueChanged) selectedTextChanged=\(postedSelectedTextChanged) lineDelta=\(Self.traceLineMetrics(lineMetrics))")
    }

    func accessibilityValueChangedUserInfo(
        oldProjection: AccessibilityTextProjection,
        newProjection: AccessibilityTextProjection
    ) -> [NSAccessibility.NotificationUserInfoKey: Any]? {
        guard !passwordInput else { return nil }
        guard let diff = accessibilityTextEditDiff(
            oldText: oldProjection.visibleText,
            newText: newProjection.visibleText),
              diff.hasChange else { return nil }

        var changes: [[NSAccessibility.NotificationUserInfoKey: Any]] = []
        if Self.shouldAnnounceAccessibilityDeletedText(diff) {
            changes.append([
                AccessibilityTextNotification.textEditType: AccessibilityTextNotification.TextEditType.delete,
                AccessibilityTextNotification.textChangeValueLength: diff.deletedText.utf16.count,
                AccessibilityTextNotification.textChangeValue: diff.deletedText,
            ])
        }
        if !diff.insertedText.isEmpty {
            let editType = diff.insertedText.utf16.count > 1
                ? AccessibilityTextNotification.TextEditType.insert
                : AccessibilityTextNotification.TextEditType.typing
            changes.append([
                AccessibilityTextNotification.textEditType: editType,
                AccessibilityTextNotification.textChangeValueLength: diff.insertedText.utf16.count,
                AccessibilityTextNotification.textChangeValue: diff.insertedText,
            ])
        }
        guard !changes.isEmpty else { return nil }

        return [
            AccessibilityTextNotification.textStateSync: true,
            AccessibilityTextNotification.textStateChangeType: AccessibilityTextNotification.TextStateChangeType.edit,
            AccessibilityTextNotification.textChangeValues: changes,
            AccessibilityTextNotification.textChangeElement: self,
        ]
    }

    func accessibilitySelectedTextChangedUserInfo(
        changeType: Int,
        focusChanged: Bool
    ) -> [NSAccessibility.NotificationUserInfoKey: Any] {
        return [
            AccessibilityTextNotification.textStateSync: true,
            AccessibilityTextNotification.textSelectionDirection: 0,
            AccessibilityTextNotification.textSelectionGranularity: 0,
            AccessibilityTextNotification.textSelectionChangedFocus: focusChanged,
            AccessibilityTextNotification.textStateChangeType: changeType,
            AccessibilityTextNotification.textChangeElement: self,
        ]
    }
    @discardableResult
    func announceAccessibilityChange(_ change: ScreenChangeInfo) -> Bool {
        let screenChanged = change.usesAlternateScreen != lastAccessibilityAlternateScreen

        lastAccessibilityAlternateScreen = change.usesAlternateScreen

        if screenChanged {
            announceAccessibility(
                change.usesAlternateScreen
                    ? "Full-screen terminal application"
                    : "Returned to terminal scrollback",
                priority: .high)
            return true
        }

        return false
    }

    func announceAccessibility(
        _ announcement: String,
        priority: NSAccessibilityPriorityLevel
    ) {
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: announcement,
                .priority: priority.rawValue,
            ])
    }
}
