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
        lastAccessibilityCommandStatus = nil
        suppressPostFloodInputEdits = false
        accessibilitySecureAnnouncementPending = enabled && passwordInput
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
            "screenChanged generation=\(changeInfo.generation) dirtyRows=\(changeInfo.dirtyRowCount) dirtyRange=\(Self.traceRange(changeInfo.dirtyRowRange)) sinceLastMs=\(sinceLastMs) cursor=\(changeInfo.cursorRow),\(changeInfo.cursorColumn) alternate=\(changeInfo.usesAlternateScreen)")
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
            suppressPostFloodInputEdits = false
            traceAccessibilityCue(
                "suppressedPasswordNotification requestedGeneration=\(change.generation)")
            return
        }

        guard change.generation != lastAccessibilityNotifiedGeneration else { return }
        let oldProjection = lastAccessibilityNotifiedProjection
        lastAccessibilityNotifiedGeneration = change.generation
        lastAccessibilityProjectionGeneration = change.generation

        invalidateAccessibilityTextProjection()
        let newProjection = cachedAccessibilityTextProjection.get()
        lastAccessibilityNotifiedProjection = newProjection
        let lineMetrics = oldProjection.map {
            accessibilityProjectionLineMetrics(
                oldProjection: $0,
                newProjection: newProjection)
        }
        let textDiff = oldProjection.flatMap {
            accessibilityTextEditDiff(
                oldText: $0.text,
                newText: newProjection.text)
        }

        if let floodState = accessibilityFloodState {
            if !floodState.sawMeaningfulOutput &&
                !Self.isAccessibilityFloodOutput(lineMetrics) {
                accessibilityFloodState = nil
                if lineMetrics?.classification == "unchanged" {
                    traceAccessibilityCue(
                        "discardedFloodCandidate requestedGeneration=\(change.generation) notifiedGeneration=\(newProjection.changeInfo.generation) lineDelta=\(Self.traceLineMetrics(lineMetrics))")
                    return
                }
            } else {
                updateAccessibilityFloodState(
                    lineMetrics: lineMetrics,
                    latestProjection: newProjection)
                traceAccessibilityCue(
                    "suppressedFloodNotification requestedGeneration=\(change.generation) notifiedGeneration=\(newProjection.changeInfo.generation) lineDelta=\(Self.traceLineMetrics(lineMetrics))")
                return
            }
        }

        if suppressPostFloodInputEdits &&
            Self.isAccessibilityInputOnlyEdit(
                lineMetrics: lineMetrics,
                diff: textDiff) {
            if let textDiff {
                announceAccessibilityPostFloodInputEdit(textDiff)
            }
            traceAccessibilityCue(
                "suppressedPostFloodInputNotification requestedGeneration=\(change.generation) notifiedGeneration=\(newProjection.changeInfo.generation) insertedUTF16=\(textDiff?.insertedText.utf16.count ?? 0) deletedUTF16=\(textDiff?.deletedText.utf16.count ?? 0) lineDelta=\(Self.traceLineMetrics(lineMetrics))")
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

        traceAccessibilityCue(
            "postedNotification requestedGeneration=\(change.generation) notifiedGeneration=\(newProjection.changeInfo.generation) valueChanged=\(postedValueChanged) selectedTextChanged=\(postedSelectedTextChanged) lineDelta=\(Self.traceLineMetrics(lineMetrics))")
    }

    func accessibilityValueChangedUserInfo(
        oldProjection: AccessibilityTextProjection,
        newProjection: AccessibilityTextProjection
    ) -> [NSAccessibility.NotificationUserInfoKey: Any]? {
        guard !passwordInput else { return nil }
        guard let diff = accessibilityTextEditDiff(
            oldText: oldProjection.text,
            newText: newProjection.text),
              diff.hasChange else { return nil }

        var changes: [[NSAccessibility.NotificationUserInfoKey: Any]] = []
        if !diff.deletedText.isEmpty {
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
