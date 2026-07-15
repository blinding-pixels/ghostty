import AppKit
import GhosttyKit

extension Ghostty.SurfaceView {
    func readAccessibilityCommandOutputText() -> String? {
        guard let surface else {
            return nil
        }

        var text = ghostty_text_s()
        guard ghostty_surface_accessibility_command_output(surface, &text) else {
            return nil
        }
        defer { ghostty_surface_free_text(surface, &text) }

        return Self.string(from: text.text, count: Int(text.text_len))
    }

    func readAccessibilityCommandOutputSnapshot() -> AccessibilityCommandOutputSnapshot? {
        if let text = readAccessibilityCommandOutputText(),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return AccessibilityCommandOutputSnapshot(
                text: text,
                source: "semantic",
                generation: lastAccessibilityNotifiedGeneration)
        }

        guard let snapshot = lastAccessibilityCommandOutputSnapshot,
              !snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return snapshot
    }

    func readAccessibilityCommandOutputSummary(
        fallback: AccessibilityCommandOutputSummary
    ) -> AccessibilityCommandOutputSummary {
        guard let value = readAccessibilityCommandOutputText() else {
            return fallback
        }

        var lines = value.split(
            separator: "\n",
            omittingEmptySubsequences: false)
            .map(String.init)
        while let last = lines.last,
              last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.removeLast()
        }
        guard !lines.isEmpty else { return fallback }

        let lastMeaningfulLine = lines.last
            .map { Self.accessibilitySummaryLine($0) }
            .flatMap { $0.isEmpty ? nil : $0 }

        return AccessibilityCommandOutputSummary(
            lineCount: lines.count,
            lastMeaningfulLine: lastMeaningfulLine,
            semanticOutput: true,
            source: "semantic",
            commandOutputText: value)
    }

    static func accessibilitySummaryLine(_ line: String) -> String {
        let collapsed = line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard collapsed.count > accessibilitySummaryLineLimit else { return collapsed }

        let end = collapsed.index(
            collapsed.startIndex,
            offsetBy: accessibilitySummaryLineLimit)
        return String(collapsed[..<end])
    }

    static func accessibilityLineLabel(_ count: Int) -> String {
        count == 1 ? "1 line" : "\(count) lines"
    }

    static func accessibilityVisibleLineLabel(_ count: Int) -> String {
        count == 1 ? "1 visible line" : "\(count) visible lines"
    }

    static func accessibilityCommandOutputAnchorTarget(
        commandOutput: String,
        in projection: AccessibilityTextProjection,
        anchor: AccessibilityCommandOutputAnchor
    ) -> AccessibilityCommandOutputAnchorTarget? {
        let projectionText = projection.text as NSString
        guard projectionText.length > 0 else { return nil }

        let searchCandidates = accessibilityCommandOutputSearchCandidates(
            commandOutput,
            anchor: anchor)
        for candidate in searchCandidates {
            let outputRange = projectionText.range(
                of: candidate,
                options: [.backwards])
            guard outputRange.location != NSNotFound else { continue }

            if let lineRange = accessibilityMeaningfulCommandOutputLineRange(
                in: projectionText,
                outputRange: outputRange,
                anchor: anchor) {
                let line = projectionText.substring(with: lineRange)
                return AccessibilityCommandOutputAnchorTarget(
                    range: NSRange(location: lineRange.location, length: 0),
                    spokenLine: accessibilitySummaryLine(line))
            }
        }

        return nil
    }

    static func accessibilityCommandOutputSearchCandidates(
        _ commandOutput: String,
        anchor: AccessibilityCommandOutputAnchor
    ) -> [String] {
        var candidates: [String] = []

        func append(_ value: String) {
            guard !value.isEmpty, !candidates.contains(value) else { return }
            candidates.append(value)
        }

        append(commandOutput)
        append(commandOutput.trimmingCharacters(in: .whitespacesAndNewlines))

        let meaningfulLines = commandOutput.split(
            separator: "\n",
            omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !accessibilitySummaryLine($0).isEmpty }

        if anchor == .end,
           let last = meaningfulLines.last {
            append(last)
        }

        return candidates
    }

    static func accessibilityMeaningfulCommandOutputLineRange(
        in projectionText: NSString,
        outputRange: NSRange,
        anchor: AccessibilityCommandOutputAnchor
    ) -> NSRange? {
        guard outputRange.location != NSNotFound,
              outputRange.length > 0 else { return nil }

        var cursor = outputRange.location
        let end = min(NSMaxRange(outputRange), projectionText.length)
        let boundedOutputRange = NSRange(
            location: outputRange.location,
            length: end - outputRange.location)
        var ranges: [NSRange] = []

        while cursor < end {
            var lineRange = projectionText.lineRange(
                for: NSRange(location: cursor, length: 0))
            lineRange = NSIntersectionRange(lineRange, boundedOutputRange)
            let contentRange = accessibilityLineContentRange(
                in: projectionText,
                lineRange: lineRange)

            if contentRange.length > 0 {
                let line = projectionText.substring(with: contentRange)
                if !accessibilitySummaryLine(line).isEmpty {
                    ranges.append(contentRange)
                }
            }

            cursor = max(NSMaxRange(lineRange), cursor + 1)
        }

        switch anchor {
        case .start:
            return ranges.first
        case .end:
            return ranges.last
        }
    }

    static func accessibilityLineContentRange(
        in text: NSString,
        lineRange: NSRange
    ) -> NSRange {
        guard lineRange.location != NSNotFound else { return lineRange }

        var range = NSIntersectionRange(
            lineRange,
            NSRange(location: 0, length: text.length))
        while range.length > 0 {
            let lastIndex = NSMaxRange(range) - 1
            let character = text.character(at: lastIndex)
            if character == 10 || character == 13 {
                range.length -= 1
            } else {
                break
            }
        }
        return range
    }

    func returnAccessibilityReviewToLastCommandOutput(
        anchor: AccessibilityCommandOutputAnchor
    ) -> Bool {
        guard accessibilityPipelineEnabled else { return false }
        guard window?.makeFirstResponder(self) == true else { return false }

        guard let commandOutputSnapshot = readAccessibilityCommandOutputSnapshot() else {
            _ = returnAccessibilityReviewToPrompt()
            announceAccessibility("No output for last command", priority: .high)
            traceAccessibilityCue("commandOutputAnchor missingOutput anchor=\(anchor)")
            return true
        }

        let projection = currentAccessibilityTextProjection()
        guard let target = Self.accessibilityCommandOutputAnchorTarget(
            commandOutput: commandOutputSnapshot.text,
            in: projection,
            anchor: anchor) else {
            announceAccessibility(
                "Last command output is outside the review window",
                priority: .high)
            traceAccessibilityCue(
                "commandOutputAnchor missingRange anchor=\(anchor) source=\(commandOutputSnapshot.source) outputGeneration=\(commandOutputSnapshot.generation) outputUTF16=\(commandOutputSnapshot.text.utf16.count) projectionUTF16=\(projection.utf16Length)")
            return true
        }

        accessibilityReviewSelectedRange = clampedAccessibilityRange(
            target.range,
            length: projection.utf16Length)
        NSAccessibility.post(
            element: self,
            notification: .selectedTextChanged,
            userInfo: accessibilitySelectedTextChangedUserInfo(
                changeType: AccessibilityTextNotification.TextStateChangeType.selectionMove,
                focusChanged: true))

        let prefix = anchor == .start
            ? "Start of last command output"
            : "End of last command output"
        announceAccessibility(
            "\(prefix): \(target.spokenLine)",
            priority: .high)
        traceAccessibilityCue(
            "commandOutputAnchor anchor=\(anchor) source=\(commandOutputSnapshot.source) outputGeneration=\(commandOutputSnapshot.generation) range={\(target.range.location),\(target.range.length)} line=\(Self.traceString(target.spokenLine))")
        return true
    }

    static func accessibilityCursorLine(
        in projection: AccessibilityTextProjection
    ) -> String? {
        guard !projection.text.isEmpty else { return nil }

        let lineStart = projection.text[..<projection.cursorIndex]
            .lastIndex(of: "\n")
            .map { projection.text.index(after: $0) } ?? projection.text.startIndex
        let lineEnd = projection.text[projection.cursorIndex...]
            .firstIndex(of: "\n") ?? projection.text.endIndex
        return String(projection.text[lineStart..<lineEnd])
    }

    static func accessibilityLastMeaningfulLine(
        in lines: [String],
        excluding excludedLine: String? = nil
    ) -> String? {
        let excludedSummary = excludedLine
            .map(accessibilitySummaryLine)
            .flatMap { $0.isEmpty ? nil : $0 }

        for line in lines.reversed() {
            let summary = accessibilitySummaryLine(line)
            if summary.isEmpty { continue }
            if let excludedSummary, summary == excludedSummary { continue }
            return summary
        }

        return nil
    }

    static func accessibilityLastMeaningfulLine(
        in text: String,
        excluding excludedLine: String? = nil
    ) -> String? {
        accessibilityLastMeaningfulLine(
            in: text.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init),
            excluding: excludedLine)
    }

    static func accessibilityInsertedOutputLines(
        from insertedText: String,
        baselineProjection: AccessibilityTextProjection,
        latestProjection: AccessibilityTextProjection
    ) -> [String] {
        guard !insertedText.isEmpty else { return [] }

        var lines = insertedText.split(
            separator: "\n",
            omittingEmptySubsequences: false)
            .map(String.init)

        if insertedText.first == "\n" {
            lines.removeFirst()
        } else if let firstLine = lines.first {
            let firstSummary = accessibilitySummaryLine(firstLine)
            let baselineCursorSummary = accessibilityCursorLine(
                in: baselineProjection)
                .map(accessibilitySummaryLine)
            let matchesBaselineCursor = baselineCursorSummary
                .map { $0 == firstSummary } ?? false

            if firstSummary.isEmpty ||
                matchesBaselineCursor {
                lines.removeFirst()
            }
        }

        let cursorSummary = accessibilityCursorLine(in: latestProjection)
            .map(accessibilitySummaryLine)
            .flatMap { $0.isEmpty ? nil : $0 }

        while let lastLine = lines.last {
            let lastSummary = accessibilitySummaryLine(lastLine)
            if lastSummary.isEmpty {
                lines.removeLast()
                continue
            }

            if let cursorSummary, lastSummary == cursorSummary {
                lines.removeLast()
                continue
            }

            break
        }

        return lines
    }

    func accessibilityFallbackCommandOutputSummary(
        for state: AccessibilityFloodState
    ) -> AccessibilityCommandOutputSummary {
        let estimatedLineCount = max(state.changedLineEstimate, state.maxDirtyRows)
        let latestProjection = state.latestProjection ?? lastAccessibilityNotifiedProjection
        let cursorLine = latestProjection.flatMap(Self.accessibilityCursorLine)
        let fallbackLastLine = latestProjection.flatMap {
            Self.accessibilityLastMeaningfulLine(
                in: $0.visibleText,
                excluding: cursorLine)
        }

        guard let baselineProjection = state.baselineProjection,
              let latestProjection = latestProjection,
              let diff = accessibilityTextEditDiff(
                oldText: baselineProjection.text,
                newText: latestProjection.text),
              !diff.insertedText.isEmpty else {
            return AccessibilityCommandOutputSummary(
                lineCount: estimatedLineCount,
                lastMeaningfulLine: fallbackLastLine,
                semanticOutput: false,
                source: "visibleEstimate",
                commandOutputText: nil)
        }

        let insertedLines = Self.accessibilityInsertedOutputLines(
            from: diff.insertedText,
            baselineProjection: baselineProjection,
            latestProjection: latestProjection)

        guard !insertedLines.isEmpty else {
            return AccessibilityCommandOutputSummary(
                lineCount: estimatedLineCount,
                lastMeaningfulLine: fallbackLastLine,
                semanticOutput: false,
                source: "visibleEstimate",
                commandOutputText: nil)
        }

        let commandOutputText = insertedLines.joined(separator: "\n")
        return AccessibilityCommandOutputSummary(
            lineCount: insertedLines.count,
            lastMeaningfulLine: Self.accessibilityLastMeaningfulLine(
                in: insertedLines,
                excluding: cursorLine) ?? fallbackLastLine,
            semanticOutput: false,
            source: "projectionDiff",
            commandOutputText: commandOutputText)
    }

    func noteAccessibilityFloodSignal(
        _ change: ScreenChangeInfo,
        now: TimeInterval,
        sinceLastMs: TimeInterval?
    ) {
        guard accessibilityPipelineEnabled else { return }
        guard window?.firstResponder === self else { return }
        guard !change.usesAlternateScreen else { return }
        guard !semanticAccessibilityState.suppressesTerminalOutput else {
            accessibilityIOFloodWindow = nil
            return
        }
        guard accessibilityBurstSuppressionEnabled else {
            accessibilityIOFloodWindow = nil
            return
        }

        var window = accessibilityIOFloodWindow ?? AccessibilityIOFloodWindow(startedAt: now)
        window.accumulate(
            change,
            now: now,
            windowMs: Self.accessibilityIOFloodWindowMs)
        accessibilityIOFloodWindow = window

        let ioFloodSignal = Self.isAccessibilityIOFloodSignal(
            frame: change,
            window: window)
        let dirtyRowHint = change.dirtyRowCount >= Self.accessibilityFloodFastRows

        if var state = accessibilityFloodState {
            guard ioFloodSignal || dirtyRowHint else {
                traceAccessibilityCue(
                    "ignoredFloodExtensionLowIO generation=\(change.generation) outputBytes=\(change.outputBytes) outputNewlines=\(change.outputNewlines) outputScrollLines=\(change.outputScrollLines) dirtyRows=\(change.dirtyRowCount)")
                return
            }

            state.lastChangeAt = now
            state.accumulatedBytes += change.outputBytes
            state.accumulatedNewlines += change.outputNewlines
            state.accumulatedScrollLines += change.outputScrollLines
            state.maxDirtyRows = max(state.maxDirtyRows, change.dirtyRowCount)
            state.changedLineEstimate = max(
                state.changedLineEstimate,
                state.accumulatedNewlines,
                change.dirtyRowCount)
            accessibilityFloodState = state
            scheduleAccessibilityFloodSummary()
            return
        }

        guard ioFloodSignal else { return }

        lastAccessibilityCommandOutputSnapshot = nil
        let recentCommandStatus: AccessibilityCommandStatus? = {
            guard let status = lastAccessibilityCommandStatus,
                  now - status.finishedAt <= Self.accessibilityCommandStatusTTL else {
                return nil
            }
            return status
        }()
        accessibilityFloodState = AccessibilityFloodState(
            startedAt: now,
            lastChangeAt: now,
            accumulatedBytes: change.outputBytes,
            accumulatedNewlines: change.outputNewlines,
            accumulatedScrollLines: change.outputScrollLines,
            maxDirtyRows: change.dirtyRowCount,
            changedLineEstimate: max(change.outputNewlines, change.dirtyRowCount, 1),
            commandStatus: recentCommandStatus,
            baselineProjection: lastAccessibilityNotifiedProjection,
            latestProjection: nil)
        announceAccessibility(
            "Burst output. Please wait for command to finish.",
            priority: .medium)
        traceAccessibilityCue(
            "floodCandidate generation=\(change.generation) outputBytes=\(change.outputBytes) outputNewlines=\(change.outputNewlines) outputScrollLines=\(change.outputScrollLines) windowBytes=\(window.bytes) windowNewlines=\(window.newlines) windowScrollLines=\(window.scrollLines) dirtyRows=\(change.dirtyRowCount) sinceLastMs=\(sinceLastMs.map { String(format: "%.1f", $0) } ?? "nil")")
        scheduleAccessibilityFloodSummary()
    }

    static func isAccessibilityTypingFrame(_ change: ScreenChangeInfo) -> Bool {
        change.outputNewlines <= accessibilityTypingMaxNewlines &&
            change.outputBytes < accessibilityTypingMaxBytes &&
            change.outputScrollLines == 0
    }

    static func isAccessibilityIOFloodFrame(_ change: ScreenChangeInfo) -> Bool {
        guard !isAccessibilityTypingFrame(change) else { return false }

        return change.outputNewlines >= accessibilityIOFloodNewlines ||
            change.outputBytes >= accessibilityIOFloodBytes ||
            change.outputScrollLines >= accessibilityIOFloodScrollLines
    }

    static func isAccessibilityIOFloodWindow(_ window: AccessibilityIOFloodWindow) -> Bool {
        window.newlines >= accessibilityIOFloodNewlines ||
            window.bytes >= accessibilityIOFloodBytes ||
            window.scrollLines >= accessibilityIOFloodScrollLines
    }

    static func isAccessibilityIOFloodSignal(
        frame: ScreenChangeInfo,
        window: AccessibilityIOFloodWindow
    ) -> Bool {
        if isAccessibilityIOFloodFrame(frame) { return true }
        return isAccessibilityIOFloodWindow(window)
    }

    func scheduleAccessibilityFloodSummary() {
        guard accessibilityFloodState != nil else { return }

        accessibilityFloodSettleWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.flushAccessibilityFloodSummary()
        }
        accessibilityFloodSettleWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.accessibilityFloodSettleDelay,
            execute: workItem)
    }

    func flushAccessibilityFloodSummary() {
        guard accessibilityPipelineEnabled else { return }
        guard window?.firstResponder === self else { return }
        guard accessibilityBurstSuppressionEnabled else {
            accessibilityFloodSettleWorkItem = nil
            accessibilityFloodState = nil
            accessibilityIOFloodWindow = nil
            return
        }
        guard var state = accessibilityFloodState else {
            accessibilityIOFloodWindow = nil
            return
        }

        let status = accessibilityCommandStatus(for: state)
        let quietFor = ProcessInfo.processInfo.systemUptime - state.lastChangeAt
        if status == nil,
           quietFor < Self.accessibilityFloodProjectionQuietTime {
            accessibilityFloodSettleWorkItem = nil
            accessibilityFloodState = state
            scheduleAccessibilityFloodSummary()
            traceAccessibilityCue(
                "deferredFloodSummary quietMs=\(String(format: "%.1f", quietFor * 1000))")
            return
        }

        accessibilityFloodSettleWorkItem = nil
        accessibilityFloodState = nil
        accessibilityIOFloodWindow = nil
        if let latestProjection = refreshAccessibilityProjectionAfterFlood() {
            state.latestProjection = latestProjection
        }

        let fallback = accessibilityFallbackCommandOutputSummary(for: state)
        let summary = readAccessibilityCommandOutputSummary(fallback: fallback)
        if let commandOutputText = summary.commandOutputText,
           !commandOutputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let generation = state.latestProjection?.changeInfo.generation ??
                lastAccessibilityNotifiedGeneration
            lastAccessibilityCommandOutputSnapshot = AccessibilityCommandOutputSnapshot(
                text: commandOutputText,
                source: summary.source,
                generation: generation)
        } else {
            lastAccessibilityCommandOutputSnapshot = nil
        }

        let lineLabel = summary.source == "visibleEstimate"
            ? Self.accessibilityVisibleLineLabel(summary.lineCount)
            : Self.accessibilityLineLabel(summary.lineCount)
        let message: String
        let priority: NSAccessibilityPriorityLevel

        if let exitCode = status?.exitCode, exitCode != 0 {
            priority = .high
            if let lastLine = summary.lastMeaningfulLine {
                message = "Failed, exit \(exitCode), \(lineLabel): \(lastLine)"
            } else {
                message = "Failed, exit \(exitCode), \(lineLabel)"
            }
        } else if status?.exitCode == 0 {
            priority = .medium
            if let lastLine = summary.lastMeaningfulLine {
                message = "Done, \(lineLabel). Last: \(lastLine)"
            } else {
                message = "Done, \(lineLabel)"
            }
        } else {
            priority = .medium
            if let lastLine = summary.lastMeaningfulLine {
                message = "Output, \(lineLabel). Last: \(lastLine)"
            } else {
                message = "Output, \(lineLabel)"
            }
        }

        announceAccessibility(message, priority: priority)
        accessibilityPostFloodTextSyncPending = true
        traceAccessibilityCue(
            "floodSummary source=\(summary.source) semanticOutput=\(summary.semanticOutput) reviewableOutput=\(summary.commandOutputText != nil) lineCount=\(summary.lineCount) exitCode=\(status?.exitCode.map(String.init) ?? "nil") message=\(Self.traceString(message))")
    }

    func refreshAccessibilityProjectionAfterFlood() -> AccessibilityTextProjection? {
        guard !passwordInput else { return nil }

        let oldReviewProjection = accessibilityReviewSelectedRange.map { _ in
            cachedAccessibilityTextProjection.get()
        }
        invalidateAccessibilityTextProjection()
        let projection = cachedAccessibilityTextProjection.get()
        reconcileAccessibilityReviewSelection(
            from: oldReviewProjection,
            to: projection)
        lastAccessibilityProjectionGeneration = projection.changeInfo.generation
        lastAccessibilityNotifiedGeneration = projection.changeInfo.generation
        lastAccessibilityNotifiedProjection = projection
        return projection
    }

    func accessibilityCommandStatus(
        for state: AccessibilityFloodState
    ) -> AccessibilityCommandStatus? {
        let now = ProcessInfo.processInfo.systemUptime
        if let status = state.commandStatus,
           now - status.finishedAt <= Self.accessibilityCommandStatusTTL {
            return status
        }
        if let status = lastAccessibilityCommandStatus,
           status.finishedAt >= state.startedAt - Self.accessibilityCommandStatusTTL,
           now - status.finishedAt <= Self.accessibilityCommandStatusTTL {
            return status
        }
        return nil
    }

    static func shouldAnnounceAccessibilityDeletedText(
        _ diff: AccessibilityTextEditDiff
    ) -> Bool {
        guard !diff.deletedText.isEmpty else { return false }

        let deletedLineBreaks = accessibilityLineBreakCount(in: diff.deletedText)
        let insertedLineBreaks = accessibilityLineBreakCount(in: diff.insertedText)
        if !diff.insertedText.isEmpty &&
            deletedLineBreaks > 0 &&
            insertedLineBreaks > 0 {
            return false
        }

        return true
    }

    func toggleAccessibilityBurstSuppression() -> Bool {
        guard accessibilityPipelineEnabled else { return false }

        accessibilityBurstSuppressionEnabled.toggle()
        accessibilityFloodSettleWorkItem?.cancel()
        accessibilityFloodSettleWorkItem = nil
        let hadFloodState = accessibilityFloodState != nil
        accessibilityFloodState = nil
        accessibilityIOFloodWindow = nil
        accessibilityPostFloodTextSyncPending = false
        if hadFloodState {
            lastAccessibilityCommandOutputSnapshot = nil
        }

        if !accessibilityBurstSuppressionEnabled, hadFloodState {
            _ = refreshAccessibilityProjectionAfterFlood()
        }

        let message = accessibilityBurstSuppressionEnabled
            ? "Burst suppression on"
            : "Burst suppression off"
        announceAccessibility(message, priority: .high)
        traceAccessibilityCue(
            "burstSuppressionToggle enabled=\(accessibilityBurstSuppressionEnabled)")
        return true
    }
}
