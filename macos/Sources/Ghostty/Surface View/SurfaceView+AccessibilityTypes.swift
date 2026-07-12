import AppKit
import GhosttyKit

extension Ghostty.SurfaceView {
    struct AccessibilityTextProjection {
        static let secureInputText = "Secure input"
        static let secureInputAnnouncement = "Secure text field. Text will not be spoken."

        static let empty: AccessibilityTextProjection = {
            let text = ""
            return AccessibilityTextProjection(
                text: text,
                viewportRange: text.startIndex..<text.endIndex,
                cursorIndex: text.endIndex,
                selectionRange: nil,
                changeInfo: .empty)
        }()

        static func secureInput(changeInfo: ScreenChangeInfo) -> AccessibilityTextProjection {
            let text = secureInputText
            return AccessibilityTextProjection(
                text: text,
                viewportRange: text.startIndex..<text.endIndex,
                cursorIndex: text.endIndex,
                selectionRange: nil,
                changeInfo: changeInfo)
        }

        let text: String
        let viewportRange: Range<String.Index>
        let cursorIndex: String.Index
        let selectionRange: NSRange?
        let changeInfo: ScreenChangeInfo

        var visibleText: String {
            String(text[viewportRange])
        }

        var utf16Length: Int {
            text.utf16.count
        }

        var cursorRange: NSRange {
            NSRange(cursorIndex..<cursorIndex, in: text)
        }

        init(
            text: String,
            viewportRange: Range<String.Index>,
            cursorIndex: String.Index,
            selectionRange: NSRange?,
            changeInfo: ScreenChangeInfo
        ) {
            self.text = text
            self.viewportRange = viewportRange
            self.cursorIndex = cursorIndex
            self.selectionRange = selectionRange
            self.changeInfo = changeInfo
        }

        init(
            text: String,
            viewportStart: Int,
            viewportEnd: Int,
            cursorOffset: Int,
            selectionStart: Int,
            selectionEnd: Int,
            selectionPresent: Bool,
            changeInfo: ScreenChangeInfo
        ) {
            let utf8 = text.utf8
            let startByte = min(max(viewportStart, 0), utf8.count)
            let endByte = min(max(viewportEnd, startByte), utf8.count)
            let cursorByte = min(max(cursorOffset, 0), utf8.count)
            let selectionStartByte = min(max(selectionStart, 0), utf8.count)
            let selectionEndByte = min(max(selectionEnd, selectionStartByte), utf8.count)
            let startUTF8 = utf8.index(utf8.startIndex, offsetBy: startByte)
            let endUTF8 = utf8.index(utf8.startIndex, offsetBy: endByte)
            let cursorUTF8 = utf8.index(utf8.startIndex, offsetBy: cursorByte)
            let selectionStartUTF8 = utf8.index(utf8.startIndex, offsetBy: selectionStartByte)
            let selectionEndUTF8 = utf8.index(utf8.startIndex, offsetBy: selectionEndByte)

            self.text = text
            if let start = String.Index(startUTF8, within: text),
               let end = String.Index(endUTF8, within: text) {
                self.viewportRange = start..<end
            } else {
                self.viewportRange = text.startIndex..<text.endIndex
            }
            self.cursorIndex = String.Index(cursorUTF8, within: text) ?? text.endIndex
            if selectionPresent,
               let start = String.Index(selectionStartUTF8, within: text),
               let end = String.Index(selectionEndUTF8, within: text) {
                self.selectionRange = NSRange(start..<end, in: text)
            } else {
                self.selectionRange = nil
            }
            self.changeInfo = changeInfo
        }
    }

    struct ScreenChangeInfo {
        static let empty = ScreenChangeInfo()

        let generation: Int
        let cursorRow: Int
        let cursorColumn: Int
        let dirtyRowRange: ClosedRange<Int>?
        let dirtyRowCount: Int
        let usesAlternateScreen: Bool
        let outputBytes: Int
        let outputNewlines: Int
        let outputScrollLines: Int

        init() {
            self.generation = 0
            self.cursorRow = 0
            self.cursorColumn = 0
            self.dirtyRowRange = nil
            self.dirtyRowCount = 0
            self.usesAlternateScreen = false
            self.outputBytes = 0
            self.outputNewlines = 0
            self.outputScrollLines = 0
        }

        init(_ text: ghostty_accessibility_text_s) {
            let dirtyCount = Int(text.dirty_count)
            let dirtyStart = Int(text.dirty_start_row)
            let dirtyEnd = Int(text.dirty_end_row)

            self.generation = max(Int(text.change_generation), 0)
            self.cursorRow = max(Int(text.cursor_row), 0)
            self.cursorColumn = max(Int(text.cursor_col), 0)
            self.dirtyRowCount = max(dirtyCount, 0)
            self.usesAlternateScreen = text.alternate_screen != 0

            if dirtyCount > 0 {
                self.dirtyRowRange = max(dirtyStart, 0)...max(dirtyStart, dirtyEnd)
            } else {
                self.dirtyRowRange = nil
            }

            self.outputBytes = 0
            self.outputNewlines = 0
            self.outputScrollLines = 0
        }

        init(_ change: ghostty_accessibility_change_s) {
            let dirtyCount = Int(change.dirty_count)
            let dirtyStart = Int(change.dirty_start_row)
            let dirtyEnd = Int(change.dirty_end_row)

            self.generation = max(Int(change.change_generation), 0)
            self.cursorRow = max(Int(change.cursor_row), 0)
            self.cursorColumn = max(Int(change.cursor_col), 0)
            self.dirtyRowCount = max(dirtyCount, 0)
            self.usesAlternateScreen = change.alternate_screen != 0
            self.outputBytes = max(Int(change.output_bytes), 0)
            self.outputNewlines = max(Int(change.output_newlines), 0)
            self.outputScrollLines = max(Int(change.output_scroll_lines), 0)

            if dirtyCount > 0 {
                self.dirtyRowRange = max(dirtyStart, 0)...max(dirtyStart, dirtyEnd)
            } else {
                self.dirtyRowRange = nil
            }
        }

        init(_ change: Ghostty.Action.ScreenChanged) {
            self.generation = change.generation
            self.cursorRow = change.cursorRow
            self.cursorColumn = change.cursorCol
            self.dirtyRowCount = change.dirtyCount
            self.usesAlternateScreen = change.usesAlternateScreen
            self.outputBytes = change.outputBytes
            self.outputNewlines = change.outputNewlines
            self.outputScrollLines = change.outputScrollLines

            if change.dirtyCount > 0 {
                self.dirtyRowRange = change.dirtyStartRow...max(change.dirtyStartRow, change.dirtyEndRow)
            } else {
                self.dirtyRowRange = nil
            }
        }
    }

    struct AccessibilityIOFloodWindow {
        var startedAt: TimeInterval
        var bytes: Int = 0
        var newlines: Int = 0
        var scrollLines: Int = 0

        mutating func accumulate(
            _ change: ScreenChangeInfo,
            now: TimeInterval,
            windowMs: TimeInterval
        ) {
            if now - startedAt > windowMs {
                startedAt = now
                bytes = 0
                newlines = 0
                scrollLines = 0
            }

            bytes += change.outputBytes
            newlines += change.outputNewlines
            scrollLines += change.outputScrollLines
        }
    }

    enum AccessibilityTextNotification {
        enum TextStateChangeType {
            static let unknown = 0
            static let edit = 1
            static let selectionMove = 2
        }

        enum TextEditType {
            static let delete = 1
            static let insert = 2
            static let typing = 3
        }

        static let textChangeElement = NSAccessibility.NotificationUserInfoKey(
            rawValue: "AXTextChangeElement")
        static let textChangeValue = NSAccessibility.NotificationUserInfoKey(
            rawValue: "AXTextChangeValue")
        static let textChangeValueLength = NSAccessibility.NotificationUserInfoKey(
            rawValue: "AXTextChangeValueLength")
        static let textChangeValues = NSAccessibility.NotificationUserInfoKey(
            rawValue: "AXTextChangeValues")
        static let textEditType = NSAccessibility.NotificationUserInfoKey(
            rawValue: "AXTextEditType")
        static let textSelectionChangedFocus = NSAccessibility.NotificationUserInfoKey(
            rawValue: "AXTextSelectionChangedFocus")
        static let textSelectionDirection = NSAccessibility.NotificationUserInfoKey(
            rawValue: "AXTextSelectionDirection")
        static let textSelectionGranularity = NSAccessibility.NotificationUserInfoKey(
            rawValue: "AXTextSelectionGranularity")
        static let textStateChangeType = NSAccessibility.NotificationUserInfoKey(
            rawValue: "AXTextStateChangeType")
        static let textStateSync = NSAccessibility.NotificationUserInfoKey(
            rawValue: "AXTextStateSync")
    }

    struct AccessibilityTextEditDiff {
        let deletedText: String
        let insertedText: String

        var hasChange: Bool {
            !deletedText.isEmpty || !insertedText.isEmpty
        }
    }

    struct AccessibilityProjectionLineMetrics {
        let oldVisibleLineCount: Int
        let newVisibleLineCount: Int
        let changedVisibleLineCount: Int
        let insertedLineBreakCount: Int
        let deletedLineBreakCount: Int

        var classification: String {
            if changedVisibleLineCount == 0 &&
                insertedLineBreakCount == 0 &&
                deletedLineBreakCount == 0 {
                return "unchanged"
            }

            if changedVisibleLineCount <= 1 &&
                insertedLineBreakCount == 0 &&
                deletedLineBreakCount == 0 {
                return "singleLine"
            }

            return "multiLine"
        }
    }

    struct AccessibilityCommandStatus {
        let exitCode: Int?
        let finishedAt: TimeInterval
    }

    struct AccessibilityFloodState {
        let startedAt: TimeInterval
        var lastChangeAt: TimeInterval
        var accumulatedBytes: Int
        var accumulatedNewlines: Int
        var accumulatedScrollLines: Int
        var maxDirtyRows: Int
        var changedLineEstimate: Int
        var commandStatus: AccessibilityCommandStatus?
        var baselineProjection: AccessibilityTextProjection?
        var latestProjection: AccessibilityTextProjection?
    }

    struct AccessibilityCommandOutputSummary {
        let lineCount: Int
        let lastMeaningfulLine: String?
        let semanticOutput: Bool
        let source: String
        let commandOutputText: String?
    }

    struct AccessibilityCommandOutputSnapshot {
        let text: String
        let source: String
        let generation: Int
    }

    enum AccessibilityCommandOutputAnchor {
        case start
        case end
    }

    struct AccessibilityCommandOutputAnchorTarget {
        let range: NSRange
        let spokenLine: String
    }
}
