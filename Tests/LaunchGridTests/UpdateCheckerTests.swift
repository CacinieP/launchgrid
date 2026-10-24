import XCTest
@testable import LaunchGrid

final class UpdateCheckerTests: XCTestCase {
    func testAutomaticChecksRespectDailyIntervalAndDisabledPreference() {
        let previous = Date(timeIntervalSince1970: 100_000)
        XCTAssertFalse(UpdateChecker.shouldCheckAutomatically(enabled: true, lastSuccessfulCheck: previous,
                                                              now: previous.addingTimeInterval(86399)))
        XCTAssertTrue(UpdateChecker.shouldCheckAutomatically(enabled: true, lastSuccessfulCheck: previous,
                                                             now: previous.addingTimeInterval(86400)))
        XCTAssertFalse(UpdateChecker.shouldCheckAutomatically(enabled: false, lastSuccessfulCheck: previous,
                                                              now: previous.addingTimeInterval(172800)))
        XCTAssertFalse(UpdateChecker.shouldCheckAutomatically(enabled: true, lastSuccessfulCheck: previous,
                                                              now: previous.addingTimeInterval(-3600)))
    }

    func testNotarizedDMGInstallationAndWrongVersionPreservesExistingApp() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let dmg = environment["LAUNCHGRID_UPDATE_TEST_DMG"],
              let source = environment["LAUNCHGRID_UPDATE_TEST_APP"] else {
            throw XCTSkip("Set signed/notarized DMG and app paths for isolated installer integration test")
        }
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        let destination = temporary.appendingPathComponent("LaunchGrid.app")
        try fm.copyItem(at: URL(fileURLWithPath: source), to: destination)
        let executable = destination.appendingPathComponent("Contents/MacOS/LaunchGrid")
        let before = try Data(contentsOf: executable)
        XCTAssertThrowsError(try UpdateChecker.verifyDeveloperIdentity(at: destination, expectedTeamID: "0000000000"))
        try UpdateChecker.verifyDeveloperIdentity(at: destination)
        XCTAssertThrowsError(try UpdateChecker.install(dmg: URL(fileURLWithPath: dmg), destination: destination, version: "999.0.0"))
        XCTAssertEqual(try Data(contentsOf: executable), before)
        try UpdateChecker.install(dmg: URL(fileURLWithPath: dmg), destination: destination, version: "0.4.2")
        XCTAssertEqual(try Data(contentsOf: executable), before)
        XCTAssertEqual(Bundle(url: destination)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, "0.4.2")
        XCTAssertTrue(fm.fileExists(atPath: destination.appendingPathComponent("Contents/Resources/LICENSE").path))
    }

    func testNumericVersionsAndInvalidOrPrereleaseInput() {
        XCTAssertLessThan(ReleaseVersion("0.4.2")!, ReleaseVersion("v0.4.10")!)
        XCTAssertLessThan(ReleaseVersion("0.9.9")!, ReleaseVersion("1.0.0")!)
        XCTAssertEqual(ReleaseVersion("1.2"), ReleaseVersion("1.2.0"))
        for value in ["v", "1..2", "1.2.3.4", "1.2-beta", "-1.2", "１.２", "1.9999999999999999999999999999"] {
            XCTAssertNil(ReleaseVersion(value), value)
        }
    }

    func testAcceptsOnlyOfficialAssetWithExactVersionAndDigest() throws {
        let digest = "sha256:" + String(repeating: "a", count: 64)
        func release(_ url: String, draft: Bool = false, prerelease: Bool = false, assetDigest: String? = nil) -> UpdateRelease {
            UpdateRelease(tag_name: "v0.4.2", draft: draft, prerelease: prerelease, assets: [
                UpdateRelease.Asset(name: "LaunchGrid-0.4.2.dmg", browser_download_url: URL(string: url)!, digest: assetDigest ?? digest)
            ])
        }
        let official = "https://github.com/CacinieP/launchgrid/releases/download/v0.4.2/LaunchGrid-0.4.2.dmg"
        XCTAssertNotNil(release(official).verifiedAsset())
        XCTAssertNil(release(official, draft: true).verifiedAsset())
        XCTAssertNil(release(official, prerelease: true).verifiedAsset())
        XCTAssertNil(release(official.replacingOccurrences(of: "github.com", with: "github.com.evil.test")).verifiedAsset())
        XCTAssertNil(release(official.replacingOccurrences(of: "https:", with: "http:")).verifiedAsset())
        XCTAssertNil(release(official + "?redirect=1").verifiedAsset())
        XCTAssertNil(release(official, assetDigest: "sha256:invalid").verifiedAsset())
    }

    func testDigestMismatchIsRejected() {
        let data = Data("hello".utf8)
        XCTAssertTrue(UpdateRelease.matchesDigest(data, expected: "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"))
        XCTAssertFalse(UpdateRelease.matchesDigest(data, expected: "sha256:" + String(repeating: "0", count: 64)))
        XCTAssertFalse(UpdateRelease.matchesDigest(data, expected: "md5:hello"))
    }
}
