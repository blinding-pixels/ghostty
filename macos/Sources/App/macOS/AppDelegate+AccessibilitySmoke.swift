import AppKit
import GhosttyKit

#if DEBUG
extension AppDelegate {
    @MainActor
    func startAccessibilitySmokeTestIfNeeded() {
        guard !accessibilitySmokeTestStarted else { return }
        let mode = ProcessInfo.processInfo.environment["GHOSTTY_ACCESSIBILITY_SMOKE_TEST"]
        guard mode == "vim-direct" ||
            mode == "vim-native" ||
            mode == "vim-native-normal" ||
            mode == "password-exclusion" else {
            return
        }

        accessibilitySmokeTestStarted = true
        Task { @MainActor in
            switch mode {
            case "password-exclusion":
                await runPasswordExclusionAccessibilitySmokeTest()
            default:
                await runVimAccessibilitySmokeTest(mode: mode ?? "")
            }
        }
    }

    @MainActor
    func runVimAccessibilitySmokeTest(mode: String) async {
        smokeLog("starting vim accessibility smoke test mode=\(mode)")

        guard let surfaceView = await waitForFocusedSurface(timeout: 5) else {
            smokeFail("timed out waiting for focused surface")
        }
        guard let surface = surfaceView.surfaceModel else {
            smokeFail("focused surface has no surface model")
        }

        surface.sendText("vim\r")

        guard let vimPID = await waitForForegroundProcess(
            surface: surface,
            matching: { $0.contains("vim") },
            timeout: 5
        ) else {
            smokeFail("timed out waiting for vim foreground process")
        }
        smokeLog("vim foreground pid=\(vimPID)")

        if mode != "vim-native-normal" {
            surfaceView.insertText("iabc", replacementRange: NSRange(location: NSNotFound, length: 0))
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        switch mode {
        case "vim-direct":
            sendVimSmokeCommandKey(.escape, surface: surface)
            try? await Task.sleep(nanoseconds: 100_000_000)
            surfaceView.insertText(":q!", replacementRange: NSRange(location: NSNotFound, length: 0))
            try? await Task.sleep(nanoseconds: 100_000_000)
            sendVimSmokeCommandKey(.enter, surface: surface)
        case "vim-native", "vim-native-normal":
            sendVimSmokeCommandKey(.escape, surface: surface)
            try? await Task.sleep(nanoseconds: 100_000_000)
            surfaceView.insertText(":q!", replacementRange: NSRange(location: NSNotFound, length: 0))
            try? await Task.sleep(nanoseconds: 100_000_000)
            sendVimSmokeCommandKey(.enter, surface: surface)
        default:
            smokeFail("unknown smoke mode \(mode)")
        }

        guard await waitForForegroundProcess(
            surface: surface,
            matching: { !$0.contains("vim") },
            timeout: 5
        ) != nil else {
            let current = surface.foregroundPID.flatMap(processCommand(pid:)) ?? "unknown"
            if let value = surfaceView.accessibilityValue() as? String {
                smokeLog("screen value on failure:\n\(value)")
            }
            smokeFail("vim did not exit; foreground=\(current)")
        }

        smokePass("vim exited mode=\(mode)")
        exit(0)
    }

    @MainActor
    func runPasswordExclusionAccessibilitySmokeTest() async {
        smokeLog("starting password exclusion accessibility smoke test")

        guard let surfaceView = await waitForFocusedSurface(timeout: 5) else {
            smokeFail("timed out waiting for focused surface")
        }
        guard let surface = surfaceView.surfaceModel else {
            smokeFail("focused surface has no surface model")
        }

        let secret = "ghostty-secret-\(UUID().uuidString)"
        let command = """
        printf 'Password: '; stty -echo; IFS= read -r secret; status=$?; stty echo; printf '\\npassword-length:%s status:%s\\n' "${#secret}" "$status"\r
        """
        surface.sendText(command)

        guard await waitForPasswordInput(surfaceView: surfaceView, expected: true, timeout: 5) else {
            let value = surfaceView.accessibilityValue() as? String ?? ""
            smokeLog("screen value while waiting for password mode:\n\(value)")
            smokeFail("timed out waiting for password input")
        }

        assertPasswordExcluded(
            surfaceView: surfaceView,
            secret: secret,
            context: "before secret entry")

        surfaceView.insertText(secret, replacementRange: NSRange(location: NSNotFound, length: 0))
        try? await Task.sleep(nanoseconds: 200_000_000)

        guard surfaceView.passwordInput else {
            smokeFail("password input ended before return")
        }

        assertPasswordExcluded(
            surfaceView: surfaceView,
            secret: secret,
            context: "after secret entry")

        surface.sendInputText("\r")

        guard await waitForPasswordInput(surfaceView: surfaceView, expected: false, timeout: 5) else {
            smokeFail("timed out waiting for password input to end")
        }

        guard await waitForAccessibilityValue(
            surfaceView: surfaceView,
            matching: { $0.contains("password-length:\(secret.count) status:0") },
            timeout: 5
        ) else {
            let value = surfaceView.accessibilityValue() as? String ?? ""
            smokeLog("screen value after password prompt:\n\(value)")
            smokeFail("timed out waiting for password command result")
        }

        assertPasswordExcluded(
            surfaceView: surfaceView,
            secret: secret,
            context: "after password input")

        smokePass("password excluded from accessibility projection")
        exit(0)
    }

    @MainActor
    func sendVimSmokeCommandKey(
        _ key: Ghostty.Input.Key,
        surface: Ghostty.Surface
    ) {
        surface.sendKeyEvent(.init(key: key, action: .press, mods: []))
        surface.sendKeyEvent(.init(key: key, action: .release, mods: []))
    }

    @MainActor
    func waitForFocusedSurface(timeout seconds: TimeInterval) async -> Ghostty.SurfaceView? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let surface = TerminalController.preferredParent?.focusedSurface,
               surface.surfaceModel != nil {
                return surface
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    @MainActor
    func waitForForegroundProcess(
        surface: Ghostty.Surface,
        matching predicate: (String) -> Bool,
        timeout seconds: TimeInterval
    ) async -> Int? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let pid = surface.foregroundPID,
               let command = processCommand(pid: pid),
               predicate(command) {
                return pid
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    @MainActor
    func waitForPasswordInput(
        surfaceView: Ghostty.SurfaceView,
        expected: Bool,
        timeout seconds: TimeInterval
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if surfaceView.passwordInput == expected {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    @MainActor
    func waitForAccessibilityValue(
        surfaceView: Ghostty.SurfaceView,
        matching predicate: (String) -> Bool,
        timeout seconds: TimeInterval
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let value = surfaceView.accessibilityValue() as? String ?? ""
            if predicate(value) {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    @MainActor
    func assertPasswordExcluded(
        surfaceView: Ghostty.SurfaceView,
        secret: String,
        context: String
    ) {
        let value = surfaceView.accessibilityValue() as? String ?? ""
        if value.contains(secret) {
            smokeLog("leaking accessibility value at \(context):\n\(value)")
            smokeFail("secret was present in accessibility value at \(context)")
        }

        if surfaceView.passwordInput &&
            value != Ghostty.SurfaceView.AccessibilityTextProjection.secureInputText {
            smokeLog("unexpected secure accessibility value at \(context):\n\(value)")
            smokeFail("secure input did not use password exclusion placeholder at \(context)")
        }
    }

    func processCommand(pid: Int) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "comm="]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func smokeLog(_ message: String) {
        FileHandle.standardError.write(Data("[accessibility-smoke] \(message)\n".utf8))
    }

    func smokePass(_ message: String) {
        smokeResult("PASS \(message)")
    }

    func smokeFail(_ message: String) -> Never {
        smokeResult("FAIL \(message)")
        exit(1)
    }

    func smokeResult(_ message: String) {
        smokeLog(message)

        guard let path = ProcessInfo.processInfo.environment["GHOSTTY_ACCESSIBILITY_SMOKE_RESULT_PATH"] else {
            return
        }

        try? message.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
#endif
