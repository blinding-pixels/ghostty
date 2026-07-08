//
//  GhosttyAccessibilitySmokeTests.swift
//  GhosttyUITests
//

import XCTest

final class GhosttyAccessibilitySmokeTests: GhosttyCustomConfigCase {
    @MainActor func testVimNativeInputSmoke() throws {
        try runAccessibilitySmokeTest(mode: "vim-native")
    }

    @MainActor func testPasswordExclusionSmoke() throws {
        try runAccessibilitySmokeTest(mode: "password-exclusion")
    }

    @MainActor private func runAccessibilitySmokeTest(mode: String) throws {
        let resultFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("ghostty-accessibility-smoke")
        defer { try? FileManager.default.removeItem(at: resultFile) }

        let app = try ghosttyApplication(defaultsSuite: "\(Self.defaultsSuiteName).accessibility-smoke")
        app.launchEnvironment["GHOSTTY_ACCESSIBILITY_SMOKE_TEST"] = mode
        app.launchEnvironment["GHOSTTY_ACCESSIBILITY_SMOKE_RESULT_PATH"] = resultFile.path
        app.launch()

        XCTAssertTrue(
            app.wait(for: .notRunning, timeout: 20),
            "Accessibility smoke test app did not exit")

        let result = (try? String(contentsOf: resultFile, encoding: .utf8)) ?? ""
        XCTAssertTrue(
            result.hasPrefix("PASS"),
            result.isEmpty ? "Accessibility smoke test did not write a result" : result)
    }
}
