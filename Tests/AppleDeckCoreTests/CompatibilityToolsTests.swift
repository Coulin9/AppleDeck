import XCTest
@testable import AppleDeckCore

final class CompatibilityToolsTests: XCTestCase {
    func testSteamCMDUsesLatestCompleteDownloadRecord() throws {
        let output = "Update state (0x3) reconfiguring, progress: 0.00 (0 / 0)\n"
            + "Update state (0x61) downloading, progress: 3.52 (3916256 / 111284048)\r"
            + "Update state (0x61) downloading, progress: 70.95 (78956736 / 111284048)\r"
            + "Update state (0x0) unknown, progress: 0.00 (0 / 0)\n"
            + "Update state (0x61) downloading, progress: 75.00 (83"
        let progress = try XCTUnwrap(CompatibilityDownloadProgress.steamCMD(in: output))
        XCTAssertEqual(progress.receivedBytes, 78_956_736)
        XCTAssertEqual(progress.expectedBytes, 111_284_048)
        XCTAssertEqual(try XCTUnwrap(progress.fraction), 0.7095, accuracy: 0.0001)
    }

    func testSteamCMDIgnoresOtherPhasesAndDownloadsWithoutATotal() {
        let output = """
            Update state (0x3) reconfiguring, progress: 0.00 (0 / 0)
            Update state (0x61) downloading, progress: 0.00 (0 / 0)
            Update state (0x81) verifying update, progress: 100.00 (111284048 / 111284048)
            """
        XCTAssertNil(CompatibilityDownloadProgress.steamCMD(in: output))
    }

    func testDownloadWithUnknownLengthStillReportsBytes() {
        let progress = CompatibilityDownloadProgress(receivedBytes: 1_234_567, expectedBytes: -1)
        XCTAssertEqual(progress.receivedBytes, 1_234_567)
        XCTAssertNil(progress.expectedBytes)
        XCTAssertNil(progress.fraction)
    }

    func testNeptuneToggleAllowsARM64OnMullionAndLetsUsersClearStoredSelections() {
        let arm = tool(architecture: "aarch64")
        XCTAssertTrue(arm.canToggleNeptune(for: .mullion))
        XCTAssertFalse(arm.canToggleNeptune(for: .neptune))
        XCTAssertFalse(arm.canToggleNeptune(for: .venus))
        XCTAssertTrue(tool(architecture: "aarch64", enabled: true).canToggleNeptune(for: .neptune))
        for backend: GraphicsBackend in [.neptune, .mullion] {
            XCTAssertTrue(tool(architecture: "x86_64").canToggleNeptune(for: backend))
            XCTAssertFalse(tool(architecture: "x86_64", problem: "Unsupported Wine layout").canToggleNeptune(for: backend))
            XCTAssertTrue(tool(architecture: "x86_64", enabled: true, problem: "Unsupported Wine layout").canToggleNeptune(for: backend))
        }
    }

    private func tool(architecture: String, enabled: Bool = false, problem: String? = nil) -> CompatibilityTool {
        CompatibilityTool(id: "steam:4628710", name: "Proton 11.0", source: .steam, architecture: architecture,
                          installed: true, downloading: false, progress: nil, neptuneEnabled: enabled,
                          neptuneGenerated: false, neptuneProblem: problem, neptuneError: nil)
    }
}
