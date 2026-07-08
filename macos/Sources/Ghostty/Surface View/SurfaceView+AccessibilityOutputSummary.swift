import AppKit
import GhosttyKit

extension Ghostty.SurfaceView {
    func readAccessibilityCommandOutputSummary(
        fallback: AccessibilityCommandOutputSummary
    ) -> AccessibilityCommandOutputSummary {
        guard let surface else {
            return fallback
        }

        var text = ghostty_text_s()
        guard ghostty_surface_accessibility_command_output(surface, &text),
              let value = Self.string(from: text.text, count: Int(text.text_len)) else {
            return fallback
        }
        defer { ghostty_surface_free_text(surface, &text) }

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
            source: "semantic")
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
                source: "visibleEstimate")
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
                source: "visibleEstimate")
        }

        return AccessibilityCommandOutputSummary(
            lineCount: insertedLines.count,
            lastMeaningfulLine: Self.accessibilityLastMeaningfulLine(
                in: insertedLines,
                excluding: cursorLine) ?? fallbackLastLine,
            semanticOutput: false,
            source: "projectionDiff")
    }

    func noteAccessibilityFloodSignal(
        _ change: ScreenChangeInfo,
        now: TimeInterval,
        sinceLastMs: TimeInterval?
    ) {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        guard window?.firstResponder === self else { return }
        guard !change.usesAlternateScreen else { return }

        let fastMultiRowChange = change.dirtyRowCount >= Self.accessibilityFloodFastRows &&
            (sinceLastMs ?? .greatestFiniteMagnitude) <= Self.accessibilityFloodFastWindowMs
        let likelyFlood = change.dirtyRowCount >= Self.accessibilityFloodFullRows ||
            fastMultiRowChange
        guard likelyFlood else { return }

        if accessibilityFloodState == nil {
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
                maxDirtyRows: change.dirtyRowCount,
                changedLineEstimate: max(change.dirtyRowCount, 1),
                sawMeaningfulOutput: false,
                commandStatus: recentCommandStatus,
                baselineProjection: lastAccessibilityNotifiedProjection,
                latestProjection: nil)
        } else if var state = accessibilityFloodState {
            state.lastChangeAt = now
            state.maxDirtyRows = max(state.maxDirtyRows, change.dirtyRowCount)
            state.changedLineEstimate = max(
                state.changedLineEstimate,
                change.dirtyRowCount)
            accessibilityFloodState = state
        }
    }

    func updateAccessibilityFloodState(
        lineMetrics: AccessibilityProjectionLineMetrics?,
        latestProjection: AccessibilityTextProjection
    ) {
        guard var state = accessibilityFloodState else { return }
        state.latestProjection = latestProjection

        if Self.isAccessibilityFloodOutput(lineMetrics) {
            state.sawMeaningfulOutput = true
            if let lineMetrics {
                state.changedLineEstimate = max(
                    state.changedLineEstimate,
                    lineMetrics.changedVisibleLineCount,
                    lineMetrics.insertedLineBreakCount + 1)
            }
        }

        if let status = lastAccessibilityCommandStatus,
           state.commandStatus == nil,
           status.finishedAt >= state.startedAt - Self.accessibilityCommandStatusTTL {
            state.commandStatus = status
        }

        accessibilityFloodState = state
        scheduleAccessibilityFloodSummary()
    }

    static func isAccessibilityFloodOutput(
        _ lineMetrics: AccessibilityProjectionLineMetrics?
    ) -> Bool {
        guard let lineMetrics else { return false }
        return lineMetrics.changedVisibleLineCount >= accessibilityFloodFastRows ||
            lineMetrics.insertedLineBreakCount >= accessibilityFloodFastRows
    }

    func scheduleAccessibilityFloodSummary() {
        guard let state = accessibilityFloodState,
              state.sawMeaningfulOutput else { return }

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
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        guard window?.firstResponder === self else { return }
        guard let state = accessibilityFloodState,
              state.sawMeaningfulOutput else {
            accessibilityFloodState = nil
            return
        }

        accessibilityFloodSettleWorkItem = nil
        accessibilityFloodState = nil

        let fallback = accessibilityFallbackCommandOutputSummary(for: state)
        let summary = readAccessibilityCommandOutputSummary(fallback: fallback)
        let lineLabel = summary.source == "visibleEstimate"
            ? Self.accessibilityVisibleLineLabel(summary.lineCount)
            : Self.accessibilityLineLabel(summary.lineCount)
        let status = accessibilityCommandStatus(for: state)
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
        suppressPostFloodInputEdits = true
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

    static func isAccessibilityInputOnlyEdit(
        lineMetrics: AccessibilityProjectionLineMetrics?,
        diff: AccessibilityTextEditDiff?
    ) -> Bool {
        guard let lineMetrics,
              let diff,
              diff.hasChange else { return false }
        guard lineMetrics.classification == "singleLine" ||
            lineMetrics.classification == "unchanged" else { return false }

        return diff.insertedText.rangeOfCharacter(from: .newlines) == nil &&
            diff.deletedText.rangeOfCharacter(from: .newlines) == nil
    }

    func announceAccessibilityPostFloodInputEdit(
        _ diff: AccessibilityTextEditDiff
    ) {
        if !diff.insertedText.isEmpty {
            let inserted = Self.accessibilitySummaryLine(diff.insertedText)
            if !inserted.isEmpty {
                announceAccessibility(inserted, priority: .medium)
            }
        } else if !diff.deletedText.isEmpty {
            announceAccessibility("Deleted", priority: .medium)
        }
    }
}
