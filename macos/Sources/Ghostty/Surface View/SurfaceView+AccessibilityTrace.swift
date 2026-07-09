import AppKit
import Darwin
import GhosttyKit

extension Ghostty.SurfaceView {
    var inputTraceEnabled: Bool {
        ProcessInfo.processInfo.environment["GHOSTTY_ACCESSIBILITY_INPUT_TRACE"] != nil
    }

    var accessibilityCueTraceEnabled: Bool {
        ProcessInfo.processInfo.environment["GHOSTTY_ACCESSIBILITY_CUE_TRACE"] != nil
    }

    func traceInput(_ message: @autoclosure () -> String) {
        guard inputTraceEnabled else { return }
        writeAccessibilityTraceLine("[input-trace] \(message())\n")
    }

    func traceAccessibilityCue(_ message: @autoclosure () -> String) {
        guard accessibilityCueTraceEnabled else { return }
        let uptime = String(format: "%.3f", ProcessInfo.processInfo.systemUptime)
        writeAccessibilityTraceLine(
            "[accessibility-cue-trace] t=\(uptime) \(message())\n")
    }

    func writeAccessibilityTraceLine(_ line: String) {
        line.withCString { pointer in
            _ = Darwin.write(STDERR_FILENO, pointer, strlen(pointer))
        }
    }

    func traceInputEvent(
        _ label: String,
        event: NSEvent,
        text: String? = nil,
        handled: Bool? = nil
    ) {
        guard inputTraceEnabled else { return }
        var parts = [
            "\(label)",
            "type=\(event.type.rawValue)",
            "keyCode=\(event.keyCode)",
            "chars=\(accessibilityTraceEventCharacters(event))",
            "ignoring=\(accessibilityTraceEventCharactersIgnoringModifiers(event))",
            "ghosttyChars=\(accessibilityTraceEventGhosttyCharacters(event))",
            "mods=\(event.modifierFlags.rawValue)",
            "timestamp=\(event.timestamp)",
        ]
        if let text {
            parts.append("text=\(accessibilityTraceInputText(text))")
        }
        if let handled {
            parts.append("handled=\(handled)")
        }
        traceInput(parts.joined(separator: " "))
    }

    func accessibilityTraceInputText(_ value: String?) -> String {
        if passwordInput {
            let length = value?.utf16.count ?? 0
            return "<secure:\(length)>"
        }

        return Self.traceString(value)
    }

    func accessibilityTraceEventCharacters(_ event: NSEvent) -> String {
        guard event.type == .keyDown || event.type == .keyUp else { return "n/a" }
        return accessibilityTraceInputText(event.characters)
    }

    func accessibilityTraceEventCharactersIgnoringModifiers(_ event: NSEvent) -> String {
        guard event.type == .keyDown || event.type == .keyUp else { return "n/a" }
        return accessibilityTraceInputText(event.charactersIgnoringModifiers)
    }

    func accessibilityTraceEventGhosttyCharacters(_ event: NSEvent) -> String {
        guard event.type == .keyDown || event.type == .keyUp else { return "n/a" }
        return accessibilityTraceInputText(event.ghosttyCharacters)
    }

    static func traceEventCharacters(_ event: NSEvent) -> String {
        guard event.type == .keyDown || event.type == .keyUp else { return "n/a" }
        return traceString(event.characters)
    }

    static func traceEventCharactersIgnoringModifiers(_ event: NSEvent) -> String {
        guard event.type == .keyDown || event.type == .keyUp else { return "n/a" }
        return traceString(event.charactersIgnoringModifiers)
    }

    static func traceEventGhosttyCharacters(_ event: NSEvent) -> String {
        guard event.type == .keyDown || event.type == .keyUp else { return "n/a" }
        return traceString(event.ghosttyCharacters)
    }

    static func traceString(_ value: String?) -> String {
        guard let value else { return "nil" }
        let escaped = value
            .unicodeScalars
            .map { scalar -> String in
                switch scalar.value {
                case 0x1B: return "\\u{1B}"
                case 0x0D: return "\\r"
                case 0x0A: return "\\n"
                case 0x09: return "\\t"
                default: return String(scalar)
                }
            }
            .joined()
        return "\"\(escaped)\""
    }

    static func traceAction(_ action: ghostty_input_action_e) -> String {
        switch action {
        case GHOSTTY_ACTION_PRESS:
            return "press"
        case GHOSTTY_ACTION_RELEASE:
            return "release"
        case GHOSTTY_ACTION_REPEAT:
            return "repeat"
        default:
            return "unknown(\(action.rawValue))"
        }
    }
}
