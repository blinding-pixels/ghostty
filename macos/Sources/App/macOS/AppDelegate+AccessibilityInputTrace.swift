import AppKit

extension AppDelegate {
    var inputTraceEnabled: Bool {
        ProcessInfo.processInfo.environment["GHOSTTY_ACCESSIBILITY_INPUT_TRACE"] != nil
    }

    func traceInput(_ message: @autoclosure () -> String) {
        guard inputTraceEnabled else { return }
        FileHandle.standardError.write(Data("[app-input-trace] \(message())\n".utf8))
    }

    func traceInputEvent(_ label: String, event: NSEvent) {
        guard inputTraceEnabled else { return }
        traceInput(
            "\(label) type=\(event.type.rawValue) keyCode=\(event.keyCode) chars=\(Self.traceEventCharacters(event)) ignoring=\(Self.traceEventCharactersIgnoringModifiers(event)) mods=\(event.modifierFlags.rawValue) timestamp=\(event.timestamp)")
    }

    static func traceEventCharacters(_ event: NSEvent) -> String {
        guard event.type == .keyDown || event.type == .keyUp else { return "n/a" }
        return traceString(event.characters)
    }

    static func traceEventCharactersIgnoringModifiers(_ event: NSEvent) -> String {
        guard event.type == .keyDown || event.type == .keyUp else { return "n/a" }
        return traceString(event.charactersIgnoringModifiers)
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
}
