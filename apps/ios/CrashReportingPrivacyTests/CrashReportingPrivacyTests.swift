import XCTest

#if canImport(Sentry)
import Sentry
@testable import CrashReportingIntegration

final class CrashReportingPrivacyTests: XCTestCase {
    func testOnlyCrashAddressesAndBuildInformationLeaveTheDevice() throws {
        let privateValue = "private@example.test https://example.test/private-capability 151.123 secret phrase"
        let original = Event(level: .fatal)
        original.message = SentryMessage(formatted: privateValue)
        original.extra = ["private": privateValue]
        original.tags = ["private": privateValue]
        original.context = ["private": ["value": privateValue]]
        original.releaseName = "signalword@0.1.0+1"
        let exception = Exception(value: privateValue, type: privateValue)
        let frame = Frame()
        frame.instructionAddress = "0x123abc"
        frame.imageAddress = privateValue
        frame.fileName = privateValue
        frame.vars = ["private": privateValue]
        frame.contextLine = privateValue
        exception.stacktrace = SentryStacktrace(frames: [frame], registers: ["private": privateValue])
        original.exceptions = [exception]
        let safe = try XCTUnwrap(CrashReporting.sanitized(original))
        let payload = String(decoding: try JSONSerialization.data(withJSONObject: safe.serialize()), as: UTF8.self)
        XCTAssertFalse(payload.contains("private@example.test"))
        XCTAssertFalse(payload.contains("private-capability"))
        XCTAssertFalse(payload.contains("151.123"))
        XCTAssertFalse(payload.contains("secret phrase"))
        XCTAssertTrue(payload.contains("0x123abc"))
        XCTAssertTrue(payload.contains("signalword@0.1.0+1"))
        XCTAssertNil(safe.breadcrumbs)
        XCTAssertNil(safe.user)
        XCTAssertNil(safe.request)
        // Optional operator fixture: export only the actual sanitized SDK serialization.
        // Never start Sentry or transmit anything from this test.
        if let path = ProcessInfo.processInfo.environment["SIGNALWORD_SANITIZED_FIXTURE_OUTPUT"] {
            let bytes = try JSONSerialization.data(withJSONObject: safe.serialize(), options: [.sortedKeys])
            try bytes.write(to: URL(fileURLWithPath: path), options: [.withoutOverwriting])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
    }
}

#else
@testable import CrashReportingIntegration
final class CrashReportingUnavailableTests: XCTestCase {
    func testUnavailableSDKLeavesSafetyWorkflowUsable() {
        XCTAssertFalse(CrashReporting.sdkAvailable)
        CrashReporting.start()
    }
}
#endif
