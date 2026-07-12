@testable import Ghostty
import AppKit
import Foundation
import Testing

struct SurfaceViewAppKitTests {
    @Test(arguments: [
        ("\u{0008}", true),
        ("\u{001F}", true),
        ("\u{007F}", false),
        (" ", false),
        ("h", false),
        ("", false),
        ("\u{0009}x", false),
        ("\u{0009}\u{0009}", false),
    ])
    func suppressesOnlySingleC0ControlTextWhileComposing(
        text: String,
        expected: Bool
    ) {
        #expect(
            Ghostty.SurfaceView.shouldSuppressComposingControlInput(
                text,
                composing: true
            ) == expected
        )
    }

    @Test func doesNotSuppressControlTextWhenNotComposing() {
        #expect(
            Ghostty.SurfaceView.shouldSuppressComposingControlInput(
                "\u{0008}",
                composing: false
            ) == false
        )
    }

    @Test func doesNotSuppressMissingText() {
        #expect(
            Ghostty.SurfaceView.shouldSuppressComposingControlInput(
                nil,
                composing: true
            ) == false
        )
    }

    @Test func rebasesAccessibilityReviewRangeAfterTextInsertedBeforeIt() {
        let oldText = "prompt\noutput\nreview\n"
        let newText = "prompt\noutput\nadded\nreview\n"
        let range = NSRange(location: 14, length: 6)

        #expect(
            Ghostty.SurfaceView.rebasedAccessibilityRange(
                range,
                from: oldText,
                to: newText
            ) == NSRange(location: 20, length: 6)
        )
    }

    @Test func clampsAccessibilityReviewRangeWhenItsTextIsReplaced() {
        let oldText = "prompt\nold\n"
        let newText = "prompt\nnew\n"
        let range = NSRange(location: 7, length: 3)

        #expect(
            Ghostty.SurfaceView.rebasedAccessibilityRange(
                range,
                from: oldText,
                to: newText
            ) == NSRange(location: 7, length: 3)
        )
    }

    @Test func recognizesAccessibilityPromptShortcut() throws {
        let event = try #require(Self.keyEvent(
            characters: "Z",
            charactersIgnoringModifiers: "z",
            modifierFlags: [.shift, .function],
            keyCode: 0x06))

        #expect(Ghostty.SurfaceView.isAccessibilityPromptShortcut(event))
        #expect(!Ghostty.SurfaceView.isAccessibilityBurstSuppressionShortcut(event))
    }

    @Test func recognizesAccessibilityBurstSuppressionShortcut() throws {
        let event = try #require(Self.keyEvent(
            characters: "X",
            charactersIgnoringModifiers: "x",
            modifierFlags: [.shift, .function],
            keyCode: 0x07))

        #expect(Ghostty.SurfaceView.isAccessibilityBurstSuppressionShortcut(event))
        #expect(!Ghostty.SurfaceView.isAccessibilityPromptShortcut(event))
    }

    @Test func recognizesAccessibilityLastOutputStartShortcut() throws {
        let event = try #require(Self.keyEvent(
            characters: "{",
            charactersIgnoringModifiers: "[",
            modifierFlags: [.shift, .function],
            keyCode: 0x21))

        #expect(Ghostty.SurfaceView.isAccessibilityLastOutputStartShortcut(event))
        #expect(!Ghostty.SurfaceView.isAccessibilityLastOutputEndShortcut(event))
    }

    @Test func recognizesShiftedAccessibilityLastOutputStartShortcut() throws {
        let event = try #require(Self.keyEvent(
            characters: "{",
            charactersIgnoringModifiers: "{",
            modifierFlags: [.shift, .function],
            keyCode: 0x21))

        #expect(Ghostty.SurfaceView.isAccessibilityLastOutputStartShortcut(event))
        #expect(!Ghostty.SurfaceView.isAccessibilityLastOutputEndShortcut(event))
    }

    @Test func recognizesAccessibilityLastOutputEndShortcut() throws {
        let event = try #require(Self.keyEvent(
            characters: "}",
            charactersIgnoringModifiers: "]",
            modifierFlags: [.shift, .function],
            keyCode: 0x1E))

        #expect(Ghostty.SurfaceView.isAccessibilityLastOutputEndShortcut(event))
        #expect(!Ghostty.SurfaceView.isAccessibilityLastOutputStartShortcut(event))
    }

    @Test func recognizesShiftedAccessibilityLastOutputEndShortcut() throws {
        let event = try #require(Self.keyEvent(
            characters: "}",
            charactersIgnoringModifiers: "}",
            modifierFlags: [.shift, .function],
            keyCode: 0x1E))

        #expect(Ghostty.SurfaceView.isAccessibilityLastOutputEndShortcut(event))
        #expect(!Ghostty.SurfaceView.isAccessibilityLastOutputStartShortcut(event))
    }

    @Test(arguments: [
        NSEvent.ModifierFlags.shift,
        NSEvent.ModifierFlags.function,
        [.shift, .control],
        [.shift, .function, .control],
        [.shift, .function, .option],
        [.shift, .function, .command],
        [.control, .option],
    ])
    func rejectsNearbyAccessibilityPromptShortcuts(
        modifierFlags: NSEvent.ModifierFlags
    ) throws {
        let event = try #require(Self.keyEvent(
            characters: "Z",
            charactersIgnoringModifiers: "z",
            modifierFlags: modifierFlags,
            keyCode: 0x06))

        #expect(!Ghostty.SurfaceView.isAccessibilityPromptShortcut(event))
    }

    @Test func rejectsNonZAccessibilityPromptShortcut() throws {
        let event = try #require(Self.keyEvent(
            characters: "P",
            charactersIgnoringModifiers: "p",
            modifierFlags: [.shift, .function],
            keyCode: 0x23))

        #expect(!Ghostty.SurfaceView.isAccessibilityPromptShortcut(event))
    }

    @Test(arguments: [
        NSEvent.ModifierFlags.shift,
        NSEvent.ModifierFlags.function,
        [.shift, .control],
        [.shift, .function, .control],
        [.shift, .function, .option],
        [.shift, .function, .command],
        [.control, .option],
    ])
    func rejectsNearbyAccessibilityBurstSuppressionShortcuts(
        modifierFlags: NSEvent.ModifierFlags
    ) throws {
        let event = try #require(Self.keyEvent(
            characters: "X",
            charactersIgnoringModifiers: "x",
            modifierFlags: modifierFlags,
            keyCode: 0x07))

        #expect(!Ghostty.SurfaceView.isAccessibilityBurstSuppressionShortcut(event))
    }

    @Test func rejectsNonXAccessibilityBurstSuppressionShortcut() throws {
        let event = try #require(Self.keyEvent(
            characters: "Z",
            charactersIgnoringModifiers: "z",
            modifierFlags: [.shift, .function],
            keyCode: 0x06))

        #expect(!Ghostty.SurfaceView.isAccessibilityBurstSuppressionShortcut(event))
    }

    @Test(arguments: [
        NSEvent.ModifierFlags.shift,
        NSEvent.ModifierFlags.function,
        [.shift, .control],
        [.shift, .function, .control],
        [.shift, .function, .option],
        [.shift, .function, .command],
        [.control, .option],
    ])
    func rejectsNearbyAccessibilityLastOutputStartShortcuts(
        modifierFlags: NSEvent.ModifierFlags
    ) throws {
        let event = try #require(Self.keyEvent(
            characters: "{",
            charactersIgnoringModifiers: "[",
            modifierFlags: modifierFlags,
            keyCode: 0x21))

        #expect(!Ghostty.SurfaceView.isAccessibilityLastOutputStartShortcut(event))
    }

    @Test func rejectsNonBracketAccessibilityLastOutputStartShortcut() throws {
        let event = try #require(Self.keyEvent(
            characters: "X",
            charactersIgnoringModifiers: "x",
            modifierFlags: [.shift, .function],
            keyCode: 0x07))

        #expect(!Ghostty.SurfaceView.isAccessibilityLastOutputStartShortcut(event))
    }

    @Test(arguments: [
        NSEvent.ModifierFlags.shift,
        NSEvent.ModifierFlags.function,
        [.shift, .control],
        [.shift, .function, .control],
        [.shift, .function, .option],
        [.shift, .function, .command],
        [.control, .option],
    ])
    func rejectsNearbyAccessibilityLastOutputEndShortcuts(
        modifierFlags: NSEvent.ModifierFlags
    ) throws {
        let event = try #require(Self.keyEvent(
            characters: "}",
            charactersIgnoringModifiers: "]",
            modifierFlags: modifierFlags,
            keyCode: 0x1E))

        #expect(!Ghostty.SurfaceView.isAccessibilityLastOutputEndShortcut(event))
    }

    @Test func rejectsNonBracketAccessibilityLastOutputEndShortcut() throws {
        let event = try #require(Self.keyEvent(
            characters: "X",
            charactersIgnoringModifiers: "x",
            modifierFlags: [.shift, .function],
            keyCode: 0x07))

        #expect(!Ghostty.SurfaceView.isAccessibilityLastOutputEndShortcut(event))
    }

    @Test func findsStartOfSemanticCommandOutputInProjection() throws {
        let projection = Self.projection("$ ls\nalpha\nbeta\n$ ")
        let target = try #require(Ghostty.SurfaceView.accessibilityCommandOutputAnchorTarget(
            commandOutput: "alpha\nbeta\n",
            in: projection,
            anchor: .start))

        #expect(target.range == NSRange(location: 5, length: 0))
        #expect(target.spokenLine == "alpha")
    }

    @Test func findsEndOfSemanticCommandOutputInProjection() throws {
        let projection = Self.projection("$ ls\nalpha\nbeta\n$ ")
        let target = try #require(Ghostty.SurfaceView.accessibilityCommandOutputAnchorTarget(
            commandOutput: "alpha\nbeta\n",
            in: projection,
            anchor: .end))

        #expect(target.range == NSRange(location: 11, length: 0))
        #expect(target.spokenLine == "beta")
    }

    @Test func anchorsProjectionDiffCommandOutputWithoutTrailingNewline() throws {
        let projection = Self.projection("$ ls\nalpha\nbeta\n$ ")
        let start = try #require(Ghostty.SurfaceView.accessibilityCommandOutputAnchorTarget(
            commandOutput: "alpha\nbeta",
            in: projection,
            anchor: .start))
        let end = try #require(Ghostty.SurfaceView.accessibilityCommandOutputAnchorTarget(
            commandOutput: "alpha\nbeta",
            in: projection,
            anchor: .end))

        #expect(start.range == NSRange(location: 5, length: 0))
        #expect(start.spokenLine == "alpha")
        #expect(end.range == NSRange(location: 11, length: 0))
        #expect(end.spokenLine == "beta")
    }

    @Test func skipsBlankLinesWhenAnchoringCommandOutput() throws {
        let projection = Self.projection("$ cmd\n\nalpha\n\nbeta\n\n$ ")
        let start = try #require(Ghostty.SurfaceView.accessibilityCommandOutputAnchorTarget(
            commandOutput: "\nalpha\n\nbeta\n\n",
            in: projection,
            anchor: .start))
        let end = try #require(Ghostty.SurfaceView.accessibilityCommandOutputAnchorTarget(
            commandOutput: "\nalpha\n\nbeta\n\n",
            in: projection,
            anchor: .end))

        #expect(start.range == NSRange(location: 7, length: 0))
        #expect(end.range == NSRange(location: 14, length: 0))
    }

    @Test func returnsNilWhenCommandOutputIsOutsideProjection() {
        let projection = Self.projection("$ ls\nvisible\n$ ")

        #expect(Ghostty.SurfaceView.accessibilityCommandOutputAnchorTarget(
            commandOutput: "missing\n",
            in: projection,
            anchor: .start) == nil)
    }

    private static func keyEvent(
        characters: String,
        charactersIgnoringModifiers: String,
        modifierFlags: NSEvent.ModifierFlags,
        keyCode: UInt16
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: 1,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: keyCode)
    }

    private static func projection(
        _ text: String
    ) -> Ghostty.SurfaceView.AccessibilityTextProjection {
        Ghostty.SurfaceView.AccessibilityTextProjection(
            text: text,
            viewportRange: text.startIndex..<text.endIndex,
            cursorIndex: text.endIndex,
            selectionRange: nil,
            changeInfo: .empty)
    }
}
