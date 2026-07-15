import AppKit

extension Ghostty.SurfaceView {
    struct SemanticAccessibilityBlock: Decodable {
        let id: String
        let role: String
        let label: String
        let text: String
        let isError: Bool?
    }

    struct SemanticAccessibilityEvent: Decodable {
        let version: Int
        let sessionId: String
        let sequence: Int
        let type: String
        let block: SemanticAccessibilityBlock?
        let state: String?
        let id: String?
        let text: String?
        let priority: String?
    }

    final class SemanticAccessibilityState {
        static let maximumBlocks = 200
        static let maximumAnnouncementIDs = 256

        var active = false
        var suppressesTerminalOutput = false
        var sessionId = ""
        var lastSequence = 0
        var blockOrder: [String] = []
        var blocks: [String: SemanticAccessibilityBlock] = [:]
        var elements: [String: NSAccessibilityElement] = [:]
        var transcriptElement: NSAccessibilityElement?
        var announcementIDs: Set<String> = []
        var announcementOrder: [String] = []

        func reset(sessionId: String, sequence: Int) {
            active = true
            suppressesTerminalOutput = false
            self.sessionId = sessionId
            lastSequence = sequence
            blockOrder.removeAll(keepingCapacity: true)
            blocks.removeAll(keepingCapacity: true)
            elements.removeAll(keepingCapacity: true)
            announcementIDs.removeAll(keepingCapacity: true)
            announcementOrder.removeAll(keepingCapacity: true)
        }

        func clear() {
            active = false
            suppressesTerminalOutput = false
            sessionId = ""
            lastSequence = 0
            blockOrder.removeAll(keepingCapacity: true)
            blocks.removeAll(keepingCapacity: true)
            elements.removeAll(keepingCapacity: true)
            transcriptElement = nil
            announcementIDs.removeAll(keepingCapacity: true)
            announcementOrder.removeAll(keepingCapacity: true)
        }

        func upsert(_ block: SemanticAccessibilityBlock) {
            if blocks[block.id] == nil {
                blockOrder.append(block.id)
            }
            blocks[block.id] = block

            while blockOrder.count > Self.maximumBlocks {
                let removedID = blockOrder.removeFirst()
                blocks.removeValue(forKey: removedID)
                elements.removeValue(forKey: removedID)
            }
        }

        func shouldAnnounce(_ id: String) -> Bool {
            guard announcementIDs.insert(id).inserted else { return false }
            announcementOrder.append(id)
            while announcementOrder.count > Self.maximumAnnouncementIDs {
                announcementIDs.remove(announcementOrder.removeFirst())
            }
            return true
        }
    }

    func receiveSemanticAccessibilityPayload(_ encodedPayload: Data) {
        guard encodedPayload.count <= 32 * 1024,
              let decodedPayload = Data(base64Encoded: encodedPayload),
              let event = try? JSONDecoder().decode(
                SemanticAccessibilityEvent.self,
                from: decodedPayload),
              event.version == 1 else {
            traceAccessibilityCue("semanticAccessibility invalidPayload")
            return
        }

        if event.type == "reset" {
            semanticAccessibilityState.reset(
                sessionId: event.sessionId,
                sequence: event.sequence)
            semanticAccessibilityLayoutDidChange()
            traceAccessibilityCue(
                "semanticAccessibility reset session=\(event.sessionId) sequence=\(event.sequence)")
            return
        }

        guard semanticAccessibilityState.active,
              event.sessionId == semanticAccessibilityState.sessionId,
              event.sequence > semanticAccessibilityState.lastSequence else {
            traceAccessibilityCue(
                "semanticAccessibility ignored type=\(event.type) session=\(event.sessionId) sequence=\(event.sequence)")
            return
        }
        semanticAccessibilityState.lastSequence = event.sequence

        switch event.type {
        case "block":
            guard let block = event.block else { return }
            semanticAccessibilityState.upsert(block)
            semanticAccessibilityLayoutDidChange()

        case "activity":
            let suppressesTerminalOutput = event.state == "busy"
            semanticAccessibilityState.suppressesTerminalOutput = suppressesTerminalOutput
            resetAccessibilityFloodForSemanticActivity()
            if !suppressesTerminalOutput {
                _ = refreshAccessibilityProjectionAfterFlood()
            }

        case "announcement":
            guard accessibilityPipelineEnabled,
                  let id = event.id,
                  let text = event.text,
                  semanticAccessibilityState.shouldAnnounce(id) else { return }
            announceAccessibility(
                text,
                priority: event.priority == "immediate" ? .high : .medium)

        case "close":
            semanticAccessibilityState.clear()
            resetAccessibilityFloodForSemanticActivity()
            semanticAccessibilityLayoutDidChange()

        default:
            traceAccessibilityCue(
                "semanticAccessibility unknownType=\(event.type)")
        }
    }

    func resetAccessibilityFloodForSemanticActivity() {
        accessibilityTextUpdateWorkItem?.cancel()
        accessibilityTextUpdateWorkItem = nil
        accessibilityFloodSettleWorkItem?.cancel()
        accessibilityFloodSettleWorkItem = nil
        accessibilityFloodState = nil
        accessibilityIOFloodWindow = nil
        accessibilityPostFloodTextSyncPending = false
    }

    func semanticAccessibilityChildren() -> [Any]? {
        guard semanticAccessibilityState.active else { return nil }

        let frame = semanticAccessibilityFrame()
        let transcript = semanticAccessibilityState.transcriptElement ?? NSAccessibilityElement()
        semanticAccessibilityState.transcriptElement = transcript
        transcript.setAccessibilityRole(.group)
        transcript.setAccessibilityLabel("Pi transcript")
        transcript.setAccessibilityIdentifier("GhosttyPiSemanticTranscript")
        transcript.setAccessibilityParent(self)
        transcript.setAccessibilityFrame(frame)

        let children: [NSAccessibilityElement] = semanticAccessibilityState.blockOrder.compactMap { id in
            guard let block = semanticAccessibilityState.blocks[id] else { return nil }
            let element = semanticAccessibilityState.elements[id] ?? NSAccessibilityElement()
            semanticAccessibilityState.elements[id] = element
            element.setAccessibilityRole(.staticText)
            element.setAccessibilityLabel(block.label)
            element.setAccessibilityValue(block.text)
            element.setAccessibilityIdentifier("GhosttyPiSemanticBlock.\(block.id)")
            element.setAccessibilityParent(transcript)
            element.setAccessibilityFrame(frame)
            return element
        }
        transcript.setAccessibilityChildren(children)
        return [transcript]
    }

    func semanticAccessibilityLayoutDidChange() {
        guard accessibilityPipelineEnabled else { return }
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    func semanticAccessibilityFrame() -> NSRect {
        let windowRect = convert(bounds, to: nil)
        return window?.convertToScreen(windowRect) ?? windowRect
    }
}
